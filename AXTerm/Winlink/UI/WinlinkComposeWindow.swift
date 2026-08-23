import SwiftUI
import AppKit

/// Compose window content. Always edits a persisted draft row (created
/// by the mail pane before the window opens), so drafts survive
/// restarts and reopening.
struct WinlinkComposeWindow: View {

    @ObservedObject private var viewModel: WinlinkComposeViewModel
    @Environment(\.dismiss) private var dismiss
    var onChanged: () -> Void
    var locationService: StationLocationService?
    private let contactStore: ContactStore?
    @State private var isFetchingPosition = false
    @FocusState private var focusedAddressField: AddressField?

    enum AddressField { case to, cc }

    init(store: WinlinkStore, myCallsign: String, draftMID: String,
         locationService: StationLocationService? = nil,
         contactStore: ContactStore? = nil,
         onChanged: @escaping () -> Void) {
        self.locationService = locationService
        self.contactStore = contactStore
        let stored = try? store.message(mid: draftMID)
        _viewModel = ObservedObject(wrappedValue: WinlinkComposeViewModel(
            store: store,
            myCallsign: myCallsign,
            prefill: stored?.message,
            existingDraftMID: draftMID))
        self.onChanged = onChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("To:", text: $viewModel.toText, prompt: Text("Callsign or email, comma-separated"))
                    .focused($focusedAddressField, equals: .to)
                    .help("Recipients: callsigns (W1AW) or internet addresses (name@example.com — sent through the Winlink internet gateway).")
                addressSuggestions(for: .to)
                TextField("Cc:", text: $viewModel.ccText, prompt: Text("Optional"))
                    .focused($focusedAddressField, equals: .cc)
                addressSuggestions(for: .cc)
                HStack {
                    TextField("Subject:", text: $viewModel.subject)
                    Text("\(viewModel.subjectRemaining)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(viewModel.subjectRemaining < 0 ? .red : .secondary)
                        .help("Winlink subjects are limited to \(WinlinkB2Message.maxSubjectLength) characters.")
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(12)

            Divider()

            TextEditor(text: $viewModel.bodyText)
                .font(.body.monospaced())
                .padding(4)

            if !viewModel.attachments.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.attachments) { item in
                            HStack(spacing: 5) {
                                Image(systemName: "paperclip")
                                Text(item.name).font(.caption)
                                Text(ByteCountFormatter.string(
                                    fromByteCount: Int64(item.data.count), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Button {
                                    viewModel.removeAttachment(id: item.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    addAttachment()
                } label: {
                    Label("Attach…", systemImage: "paperclip")
                }
                .help("Attach a file. Keep it small — see the size budget.")

                if let locationService {
                    Button {
                        isFetchingPosition = true
                        Task { @MainActor in
                            defer { isFetchingPosition = false }
                            guard let location = await locationService.currentLocation() else { return }
                            let stamp = StationLocationFormat.stamp(location)
                            if !viewModel.bodyText.isEmpty, !viewModel.bodyText.hasSuffix("\n") {
                                viewModel.bodyText += "\n"
                            }
                            viewModel.bodyText += stamp + "\n"
                        }
                    } label: {
                        if isFetchingPosition {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Position", systemImage: "location")
                        }
                    }
                    .disabled(isFetchingPosition)
                    .help("Insert your position (GPS when available, otherwise your grid square's center) into the message body.")
                }

                sizeGauge

                if let error = viewModel.validationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                Spacer()

                Button("Save Draft") {
                    if viewModel.saveDraft() != nil {
                        onChanged()
                        dismiss()
                    }
                }
                .help("Keep editing later — drafts live in the Drafts folder.")

                Button("Queue for Sending") {
                    if viewModel.queueForSending() != nil {
                        recordContactUse()
                        onChanged()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .help("Freezes the message and moves it to the Outbox. It is transmitted at the next Connect & Exchange.")
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private var sizeGauge: some View {
        let total = viewModel.totalSizeBytes
        let budget = WinlinkComposeViewModel.messageSizeBudget
        let fraction = min(1.0, Double(total) / Double(budget))
        return HStack(spacing: 6) {
            ProgressView(value: fraction)
                .frame(width: 90)
                .tint(viewModel.isOverBudget ? .red : (fraction > 0.75 ? .orange : .accentColor))
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(budget), countStyle: .file))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(viewModel.isOverBudget ? .red : .secondary)
        }
        .help(WinlinkCopy.attachmentBudgetTooltip)
    }

    /// Contact chips completing the fragment after the last comma.
    @ViewBuilder
    private func addressSuggestions(for field: AddressField) -> some View {
        if let contactStore, focusedAddressField == field {
            let text = field == .to ? viewModel.toText : viewModel.ccText
            let fragment = text.split(separator: ",", omittingEmptySubsequences: false)
                .last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let matches = ((try? contactStore.searchContacts(fragment)) ?? [])
                .filter { $0.preferredAddress != nil }
                .prefix(5)
            if !matches.isEmpty, fragment.count >= 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(matches)) { contact in
                            Button {
                                complete(field: field, with: contact)
                            } label: {
                                HStack(spacing: 4) {
                                    if contact.favorite {
                                        Image(systemName: "star.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.yellow)
                                    }
                                    Text(contact.displayName).font(.caption)
                                    Text(contact.preferredAddress ?? "")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Use \(contact.preferredAddress ?? "") from your contacts")
                        }
                    }
                }
            }
        }
    }

    private func complete(field: AddressField, with contact: WinlinkContactRecord) {
        guard let address = contact.preferredAddress else { return }
        let text = field == .to ? viewModel.toText : viewModel.ccText
        var parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty {
            parts = [address]
        } else {
            parts[parts.count - 1] = address
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        if field == .to {
            viewModel.toText = joined
        } else {
            viewModel.ccText = joined
        }
    }

    /// Bumps contact recency for every queued address.
    private func recordContactUse() {
        guard let contactStore else { return }
        let (to, _) = WinlinkComposeViewModel.parseAddressList(viewModel.toText)
        let (cc, _) = WinlinkComposeViewModel.parseAddressList(viewModel.ccText)
        let now = Date()
        for address in to + cc {
            try? contactStore.touchContact(address: address, at: now)
        }
    }

    private func addAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let data = try? Data(contentsOf: url) {
                    viewModel.addAttachment(name: url.lastPathComponent, data: data)
                }
            }
        }
    }
}
