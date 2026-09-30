#if os(iOS)
import SwiftUI

/// Asks what to do with a file another app handed to AXTerm.
///
/// Small on purpose: a name, a size and a button per thing that can be done
/// with it right now. The choices come from `IncomingDocumentRouter`, which
/// is where the rules live (packet only while a session is connected).
struct IncomingFileSheet: View {

    let file: IncomingDocumentRouter.StagedFile
    let choices: [IncomingDocumentRouter.Choice]
    var onChoose: (IncomingDocumentRouter.Choice) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: file.isImage ? "photo" : "doc")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.headline)
                                .lineLimit(2)
                            Text(ByteCount.string(file.byteCount))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                Section {
                    if choices.isEmpty {
                        Text("There is nothing to send it with yet. Winlink needs a working mailbox, and a packet transfer needs a connected session.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(choices) { choice in
                        Button {
                            onChoose(choice)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(IncomingDocumentRouter.title(for: choice),
                                      systemImage: symbol(for: choice))
                                if let detail = IncomingDocumentRouter.detail(for: choice, file: file) {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Send File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func symbol(for choice: IncomingDocumentRouter.Choice) -> String {
        switch choice {
        case .winlink: "envelope"
        case .packet: "antenna.radiowaves.left.and.right"
        }
    }
}
#endif
