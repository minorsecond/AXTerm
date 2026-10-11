import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The operator's control commands, in the mailbox settings
/// (Docs/RemoteAccessPlan.md, "Owner control commands"): each is a word to
/// type from the road that sends a line to rigctld or runs a script.
struct OwnerControlSection: View {
    @ObservedObject var settings: BBSSettings

    @State private var editing: OwnerControlDraft?

    var body: some View {
        Section {
            Text("Words you type from the road, signed in as the owner, that send a line to a radio's "
                 + "rigctld or run a script. Warbler serves the IC-705's rigctld on localhost:4533. A "
                 + "command that changes how the station transmits needs a paired device's key, runs only "
                 + "on a direct link on 2 m or above outside the segments 97.201 excludes, and is put back "
                 + "if the link fails or you are silent for two and a half minutes. Hanging up keeps it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.ownerControlCommands.isEmpty {
                Text("None yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.ownerControlCommands) { command in
                HStack(alignment: .firstTextBaseline) {
                    Text(command.name).font(.body.monospaced())
                    VStack(alignment: .leading) {
                        Text(command.help.isEmpty ? Self.summary(command) : command.help)
                        if command.changesTransmission {
                            Text("Changes how the station transmits")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Edit") { editing = OwnerControlDraft(command) }
                        .buttonStyle(.borderless)
                    Button("Remove") { settings.ownerControlCommands.removeAll { $0.id == command.id } }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add a Command\u{2026}") { editing = OwnerControlDraft() }
                #if os(macOS)
                Button("Open the Scripts Folder") {
                    if let folder = try? ApplicationScriptRunner.folder() { NSWorkspace.shared.open(folder) }
                }
                #endif
            }
        } header: {
            Text("Control commands")
        }
        .sheet(item: Binding(get: { editing.map(EditingDraft.init) }, set: { editing = $0?.draft })) { item in
            OwnerControlEditor(draft: item.draft, others: settings.ownerControlCommands) { command in
                if let index = settings.ownerControlCommands.firstIndex(where: { $0.id == command.id }) {
                    settings.ownerControlCommands[index] = command
                } else {
                    settings.ownerControlCommands.append(command)
                }
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }

    private static func summary(_ command: OwnerControlCommand) -> String {
        switch command.action {
        case .rigctl(let host, let port, let set, _): "rigctld \(host):\(port): \(set)"
        case .script(let name, _): "runs \(name)"
        }
    }

    private struct EditingDraft: Identifiable {
        let draft: OwnerControlDraft
        var id: UUID { draft.id }
    }
}

/// Adding or changing one control command.
private struct OwnerControlEditor: View {
    @State var draft: OwnerControlDraft
    let others: [OwnerControlCommand]
    let onSave: (OwnerControlCommand) -> Void
    let onCancel: () -> Void

    private var built: Result<OwnerControlCommand, OwnerControlDraft.Problem> { draft.build(among: others) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Control command").font(.headline)
            TextField("Word to type, such as FREQ", text: $draft.name)
            TextField("Help line, such as tune the 705", text: $draft.help)

            Picker("After the word", selection: $draft.argumentKind) {
                Text("Nothing").tag(OwnerControlDraft.ArgumentKind.none)
                Text("A number").tag(OwnerControlDraft.ArgumentKind.number)
                Text("One of a list").tag(OwnerControlDraft.ArgumentKind.choice)
            }
            switch draft.argumentKind {
            case .none: EmptyView()
            case .number:
                HStack {
                    TextField("Lowest", text: $draft.minText)
                    TextField("Highest", text: $draft.maxText)
                }
            case .choice:
                TextField("Choices, such as FM USB LSB", text: $draft.choicesText)
            }

            Picker("It", selection: $draft.actionKind) {
                Text("Sends a line to rigctld").tag(OwnerControlDraft.ActionKind.rigctl)
                #if os(macOS)
                Text("Runs a script").tag(OwnerControlDraft.ActionKind.script)
                #endif
            }
            switch draft.actionKind {
            case .rigctl:
                HStack {
                    TextField("Computer", text: $draft.host)
                    TextField("Port", text: $draft.portText).frame(maxWidth: 80)
                }
                TextField("Line to send; {arg} is what follows the word, such as F {arg}", text: $draft.setText)
                TextField("Line that reads the current value, such as f", text: $draft.readText)
            case .script:
                TextField("Script in the scripts folder, such as beacon.sh", text: $draft.scriptName)
                TextField("Script that puts it back, such as beacon-off.sh", text: $draft.restoreName)
            }

            Toggle("Changes how the station transmits", isOn: $draft.changesTransmission)
            Text("Frequency, mode, power, beacons and the like. The fail-safe puts these back, using the "
                 + "line that reads the current value or the script that puts it back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .failure(let problem) = built, !draft.name.isEmpty {
                Text(problem.text).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { if case .success(let command) = built { onSave(command) } }
                    .disabled({ if case .success = built { return false }; return true }())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .frame(minWidth: 440)
    }
}
