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
                Button("Add the Radio Set") {
                    settings.ownerControlCommands = OwnerControlCommand.adding(OwnerControlCommand.radioPreset,
                                                                                to: settings.ownerControlCommands)
                    if settings.controlRadios.isEmpty { settings.controlRadios = ControlRadio.warblerPreset }
                }
                .help("QRG, MODE, PWR, SIG and VOLTS for any radio named after them, such as PWR 710 50; "
                      + "and Warbler's IC-705 (705) and FT-710 (710) if no radios are set up yet.")
                #if os(macOS)
                Button("Open the Scripts Folder") {
                    if let folder = try? ApplicationScriptRunner.folder() { NSWorkspace.shared.open(folder) }
                }
                #endif
            }
        } header: {
            Text("Control commands")
        }
        ControlRadiosSection(settings: settings)
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
        case .radio(let quantity): "\(quantity.rawValue) of the radio named after it"
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
                Text("Reads or sets a radio named after it").tag(OwnerControlDraft.ActionKind.radio)
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
                HStack {
                    TextField("Scale", text: $draft.scaleText).frame(maxWidth: 80)
                    TextField("Unit, such as W", text: $draft.unit).frame(maxWidth: 120)
                }
                Text("A typed number is divided by the scale on its way to rigctld, and a number read back is "
                     + "multiplied by it. Hamlib gives power as a fraction of full power, so 10 makes the "
                     + "IC-705 take and show watts. 1 leaves numbers alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .script:
                TextField("Script in the scripts folder, such as beacon.sh", text: $draft.scriptName)
                TextField("Script that puts it back, such as beacon-off.sh", text: $draft.restoreName)
            case .radio:
                Picker("What", selection: $draft.quantity) {
                    Text("Frequency").tag(OwnerControlCommand.RadioQuantity.frequency)
                    Text("Mode").tag(OwnerControlCommand.RadioQuantity.mode)
                    Text("Power, in watts; can be set").tag(OwnerControlCommand.RadioQuantity.power)
                    Text("Signal").tag(OwnerControlCommand.RadioQuantity.signal)
                    Text("Supply voltage").tag(OwnerControlCommand.RadioQuantity.voltage)
                }
                Text("Typed with a radio's name after it, such as PWR 705; power also takes watts, such as "
                     + "PWR 705 5, inside that radio's range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if draft.actionKind != .radio {
            Toggle("Changes how the station transmits", isOn: $draft.changesTransmission)
            Text("Frequency, mode, power, beacons and the like. The fail-safe puts these back, using the "
                 + "line that reads the current value or the script that puts it back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

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

/// The radios control commands can name, with each one's power range.
private struct ControlRadiosSection: View {
    @ObservedObject var settings: BBSSettings
    @State private var editing: ControlRadio?

    var body: some View {
        Section {
            if settings.controlRadios.isEmpty {
                Text("None yet. Add the Radio Set above names Warbler's IC-705 and FT-710.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.controlRadios) { radio in
                HStack(alignment: .firstTextBaseline) {
                    Text(radio.name).font(.body.monospaced())
                    VStack(alignment: .leading) {
                        Text("rigctld \(radio.host):\(radio.port), "
                             + "\(OwnerControlCommand.ArgumentRule.format(radio.minWatts)) to "
                             + "\(OwnerControlCommand.ArgumentRule.format(radio.maxWatts)) W")
                        if !radio.allowsChanges {
                            Text("Read only from the road").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Edit") { editing = radio }.buttonStyle(.borderless)
                    Button("Remove") { settings.controlRadios.removeAll { $0.id == radio.id } }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add a Radio\u{2026}") {
                editing = ControlRadio(name: "", host: "localhost", port: 4532, fullPowerWatts: 100,
                                       minWatts: 5, maxWatts: 100)
            }
        } header: {
            Text("Radios for control commands")
        } footer: {
            Text("PWR 705 5 sets the radio named 705 to 5 W. A power outside a radio's range is refused "
                 + "before anything reaches it. Read only keeps a radio to QRG, PWR and the like.")
        }
        .sheet(item: $editing) { radio in
            ControlRadioEditor(radio: radio, others: settings.controlRadios) { saved in
                if let index = settings.controlRadios.firstIndex(where: { $0.id == saved.id }) {
                    settings.controlRadios[index] = saved
                } else {
                    settings.controlRadios.append(saved)
                }
                editing = nil
            } onCancel: { editing = nil }
        }
    }
}

private struct ControlRadioEditor: View {
    @State var radio: ControlRadio
    let others: [ControlRadio]
    let onSave: (ControlRadio) -> Void
    let onCancel: () -> Void

    @State private var portText = ""
    @State private var fullText = ""
    @State private var minText = ""
    @State private var maxText = ""

    private var edited: ControlRadio {
        var copy = radio
        copy.name = radio.name.trimmingCharacters(in: .whitespaces)
        copy.port = Int(portText) ?? 0
        copy.fullPowerWatts = Double(fullText) ?? 0
        copy.minWatts = Double(minText) ?? 0
        copy.maxWatts = Double(maxText) ?? 0
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Radio").font(.headline)
            TextField("Name to type, such as 710", text: $radio.name)
            HStack {
                TextField("Computer running its rigctld", text: $radio.host)
                TextField("Port", text: $portText).frame(maxWidth: 80)
            }
            HStack {
                TextField("Lowest W", text: $minText)
                TextField("Highest W", text: $maxText)
                TextField("Full power W", text: $fullText)
            }
            Text("Full power is what the radio gives at Hamlib's RFPOWER 1: 10 W on the IC-705, 100 W on "
                 + "the FT-710.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Can be changed from the road", isOn: $radio.allowsChanges)
            if let problem = edited.problem(among: others), !radio.name.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(edited) }
                    .disabled(edited.problem(among: others) != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .frame(minWidth: 420)
        .onAppear {
            portText = String(radio.port)
            fullText = OwnerControlCommand.ArgumentRule.format(radio.fullPowerWatts)
            minText = OwnerControlCommand.ArgumentRule.format(radio.minWatts)
            maxText = OwnerControlCommand.ArgumentRule.format(radio.maxWatts)
        }
    }
}
