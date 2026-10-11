import SwiftUI

/// Which stations may send files without asking, and the largest file
/// accepted. Its own page since the Packet Node redesign (park rehearsal
/// 2026-10-08, finding 46): it is about files, not the node.
struct FileTransferSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @EnvironmentObject var router: SettingsRouter
    @State private var prompt: TextEntryPrompt?

    /// Offer size caps to choose from. The stored value is added when it is
    /// not one of these, so a cap set some other way still shows as chosen.
    private var transferCapChoices: [Int] {
        let base = [65_536, 262_144, 524_288, 1_048_576, 5_242_880, 0]
        let current = settings.maxIncomingTransferBytes
        return base.contains(current) ? base : (base.dropLast() + [current, 0]).sorted { a, b in
            a == 0 ? false : (b == 0 ? true : a < b)
        }
    }

    var body: some View {
        SettingsForm(landing: [.fileTransfer]) {
            PreferencesSection("File Transfers", id: .fileTransfer) {
                Text("Control which stations can send you files without prompting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                VStack(alignment: .leading, spacing: 16) {
                    fileTransferList(
                        title: "Auto-Accept",
                        items: settings.allowedFileTransferCallsigns,
                        icon: "checkmark.circle.fill",
                        color: .green,
                        onAdd: addToAllowList,
                        onRemove: { settings.removeCallsignFromFileTransferAllowlist($0) }
                    )
                    
                    fileTransferList(
                        title: "Auto-Deny",
                        items: settings.deniedFileTransferCallsigns,
                        icon: "xmark.circle.fill",
                        color: .red,
                        onAdd: addToDenyList,
                        onRemove: { settings.removeCallsignFromFileTransferDenylist($0) }
                    )

                    Picker("Largest file accepted", selection: $settings.maxIncomingTransferBytes) {
                        ForEach(transferCapChoices, id: \.self) { bytes in
                            Text(bytes == 0 ? "No limit" : ByteCount.string(bytes)).tag(bytes)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Offers larger than this are declined without asking, even from stations on the "
                          + "auto-accept list. A received file is held in memory until it is complete, and a "
                          + "megabyte takes more than two hours of a 1200 baud channel.")
                }
            }
        }
        .settingsPagePadding()
        .textEntryPrompt($prompt)
    }

    @ViewBuilder
    private func fileTransferList(
        title: String,
        items: [String],
        icon: String,
        color: Color,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 4)
            
            List {
                ForEach(items, id: \.self) { callsign in
                    HStack {
                        Image(systemName: icon)
                            .foregroundStyle(color)
                            .font(.caption)
                        Text(callsign).monospaced()
                        Spacer()
                        Button { onRemove(callsign) } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                
                if items.isEmpty {
                    Text("No stations")
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .frame(height: 100)
            .border(Color.gray.opacity(0.2))
        }
    }
    
    // Actions for add
    private func addToAllowList() {
        prompt = TextEntryPrompt(
            id: "allowFile",
            title: "Add to Auto-Accept",
            message: "Files from this callsign will be accepted and written to disk with no further prompt. Anyone can transmit any callsign, so this is trust in the operator, not proof of identity.",
            placeholder: "N0CALL-7",
            uppercases: true) { call in
                settings.allowCallsignForFileTransfer(call)
            }
    }

    private func addToDenyList() {
        prompt = TextEntryPrompt(
            id: "denyFile",
            title: "Add to Auto-Deny",
            message: "Files offered by this callsign will be refused without asking.",
            placeholder: "N0CALL-7",
            uppercases: true) { call in
                settings.denyCallsignForFileTransfer(call)
            }
    }
}
