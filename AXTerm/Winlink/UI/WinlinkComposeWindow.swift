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
    @State private var isFetchingPosition = false

    init(store: WinlinkStore, myCallsign: String, draftMID: String,
         locationService: StationLocationService? = nil,
         onChanged: @escaping () -> Void) {
        self.locationService = locationService
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
                    .help("Recipients: callsigns (W1AW) or internet addresses (name@example.com — sent through the Winlink internet gateway).")
                TextField("Cc:", text: $viewModel.ccText, prompt: Text("Optional"))
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
