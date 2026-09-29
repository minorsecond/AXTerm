import SwiftUI
import UniformTypeIdentifiers

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
    @State private var isPickingAttachment = false
    @State private var attachmentError: String?
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

    /// A byte count short enough to sit on one line.
    ///
    /// `ByteCountFormatter` spells zero as "Zero KB" and pads small values,
    /// which is fine in a table column and wrong in a status footer where the
    /// number is next to a progress bar.
    nonisolated static func compactSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if bytes <= 0 { return "0 KB" }
        if kb < 1 { return "<1 KB" }
        if kb < 100 { return String(format: "%.1f KB", kb) }
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        return String(format: "%.1f MB", kb / 1024)
    }

    /// A field with its name beside it on iOS, and unchanged on macOS where
    /// the field already draws its own title.
    @ViewBuilder
    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        #if os(iOS)
        LabeledContent(title, content: content)
        #else
        content()
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // A `TextField` title is drawn beside the field on macOS and
                // *replaced* by the prompt on iOS, so on a handheld these
                // three rows arrived as unlabelled boxes. `LabeledContent`
                // puts the name back without changing the Mac.
                labelled("To:") {
                    TextField("To:", text: $viewModel.toText,
                              prompt: Text("Callsign or email, comma-separated"))
                        .focused($focusedAddressField, equals: .to)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        #endif
                }
                .explain("Recipients: callsigns (W1AW) or internet addresses (name@example.com — sent through the Winlink internet gateway).",
                         showsIndicator: false)
                addressSuggestions(for: .to)

                labelled("Cc:") {
                    TextField("Cc:", text: $viewModel.ccText, prompt: Text("Optional"))
                        .focused($focusedAddressField, equals: .cc)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        #endif
                }
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
                                Image(systemName: item.isCompressed ? "doc.zipper" : "paperclip")
                                Text(item.name).font(.caption)
                                if let original = item.original {
                                    Text(ByteCount.string(Int64(original.data.count))
                                        + " → "
                                        + ByteCount.string(Int64(item.data.count)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help("Zipped before sending — LZHUF (the only compression "
                                              + "Winlink puts on the wire) has a 2 KB window and "
                                              + "barely dents a file this size. The recipient opens "
                                              + "the zip with any tool. Right-click to send the "
                                              + "original instead.")
                                } else {
                                    Text(ByteCount.string(Int64(item.data.count)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
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
                            .contextMenu {
                                if item.isCompressed {
                                    Button("Send Original (Uncompressed)") {
                                        viewModel.revertAttachmentCompression(id: item.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    isPickingAttachment = true
                } label: {
                    Label("Attach…", systemImage: "paperclip")
                }
                .explain("Attach a file. Keep it small — see the size budget.",
                         showsIndicator: false)
                .fileImporter(isPresented: $isPickingAttachment,
                              allowedContentTypes: [.item],
                              allowsMultipleSelection: true,
                              onCompletion: addAttachments)
                .alert("Attachment not added", isPresented: .constant(attachmentError != nil)) {
                    Button("OK") { attachmentError = nil }
                } message: {
                    Text(attachmentError ?? "")
                }

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
            // Formatted by hand rather than by ByteCountFormatter, which
            // renders 0 as "Zero KB" — three words where one number belongs,
            // and enough of them to wrap the footer onto three lines.
            Text("\(Self.compactSize(total)) / \(Self.compactSize(budget))")
                .fixedSize(horizontal: true, vertical: false)
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

    /// Reads the files the operator picked.
    ///
    /// A file that cannot be read is reported rather than skipped: silently
    /// attaching three of four selected files sends an incomplete message
    /// over airtime that cannot be recovered.
    private func addAttachments(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentError = error.localizedDescription
        case .success(let urls):
            var failed: [String] = []
            for url in urls {
                // A file outside the app's container needs explicit access,
                // and that scope must be released again afterwards.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    viewModel.addAttachment(name: url.lastPathComponent, data: data)
                } else {
                    failed.append(url.lastPathComponent)
                }
            }
            if !failed.isEmpty {
                attachmentError = "Could not read: " + failed.joined(separator: ", ")
            }
        }
    }
}
