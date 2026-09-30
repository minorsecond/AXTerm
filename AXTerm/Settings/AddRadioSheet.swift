import SwiftUI

/// Adding a radio, one question at a time: how it is reached, what its
/// channel is for, the SSID it goes on the air with, and the few settings
/// that role needs. Done opens the radio's page, where everything else is.
///
/// The steps reuse the radio page's own transport views and view model, so
/// the sheet and the page cannot disagree about what a field does. See
/// `AddRadioFlow` for how Cancel leaves nothing behind.
struct AddRadioSheet: View {
    @ObservedObject var flow: AddRadioFlow
    let client: PacketEngine
    /// Called once, with the radio when finished and nil when cancelled.
    let onClose: (RadioID?) -> Void

    @StateObject private var viewModel: ConnectionTransportViewModel
    @State private var showingSymbolPicker = false
    @State private var usesOwnCallsign = false

    init(flow: AddRadioFlow, client: PacketEngine, onClose: @escaping (RadioID?) -> Void) {
        self.flow = flow
        self.client = client
        self.onClose = onClose
        _viewModel = StateObject(wrappedValue: ConnectionTransportViewModel(
            radioID: flow.radioID, settings: flow.settings, packetEngine: client))
    }

    private var settings: AppSettingsStore { flow.settings }
    private var radio: RadioProfile { flow.radio }
    private var channel: RadioChannel { RadioChannel.of(radio) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form { stepContent }
                .formStyle(.grouped)
            Divider()
            buttons
        }
        #if os(macOS)
        .frame(width: 560, height: 580)
        #endif
        .interactiveDismissDisabled()
        .onAppear {
            viewModel.onAppear()
            viewModel.suspendAutoReconnect(true)
        }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: viewModel.radioState) { _, state in flow.observe(state) }
        .sheet(isPresented: $showingSymbolPicker) {
            APRSSymbolPicker(selectedTable: symbol.table, selectedCode: symbol.code) { table, code in
                settings.updateRadio(flow.radioID) {
                    if $0.beacon.aprs == nil { $0.beacon.aprs = .followingStation }
                    $0.beacon.aprs?.symbolTable = String(table)
                    $0.beacon.aprs?.symbolCode = String(code)
                }
            }
        }
    }

    // MARK: - Frame

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(flow.mode == .new ? "Add a Radio" : "Set Up Your Radio")
                .font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(AddRadioFlow.Step.allCases, id: \.self) { step in
                    Text(step.title)
                        .font(.caption.weight(step == flow.step ? .semibold : .regular))
                        .foregroundStyle(step == flow.step ? .primary : .secondary)
                    if step != .done {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(flow.step.rawValue + 1) of \(AddRadioFlow.Step.allCases.count): \(flow.step.title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var buttons: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                flow.cancel()
                viewModel.suspendAutoReconnect(false)
                onClose(nil)
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if flow.canGoBack {
                Button("Back") { flow.back() }
            }
            if flow.step == .done {
                Button("Done") {
                    let id = flow.finish()
                    viewModel.suspendAutoReconnect(false)
                    onClose(id)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { flow.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// The one step that can hold the operator back is Identity with no
    /// callsign to put an SSID under and no callsign of the radio's own.
    private var canContinue: Bool {
        guard flow.step == .identity else { return true }
        return !radio.resolvedCallsign(station: settings.myCallsign).isEmpty
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .connect: connectStep
        case .channel: channelStep
        case .identity: identityStep
        case .basics: basicsStep
        case .done: doneStep
        }
    }

    // MARK: - 1. Connect

    private var linkBinding: Binding<RadioLinkChoice> {
        Binding(
            get: { RadioLinkChoice.of(transport: viewModel.selectedTransport, rigLink: viewModel.modemRigLink) },
            set: { viewModel.userDidChangeLink($0) })
    }

    @ViewBuilder
    private var connectStep: some View {
        Section {
            DraftTextField("Name", text: $viewModel.name, prompt: RadioProfile.defaultName(for: radio))
            Picker("Reached by", selection: linkBinding) {
                ForEach(RadioLinkChoice.selectable(including: linkBinding.wrappedValue)) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            Text(linkBinding.wrappedValue.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch viewModel.selectedTransport {
            case .network: NetworkSettingsContent(viewModel: viewModel)
            case .serial: SerialSettingsContent(viewModel: viewModel)
            case .ble: BLESettingsContent(viewModel: viewModel)
            case .modem: ModemSettingsContent(viewModel: viewModel)
            }
        } header: {
            Text("How is this radio reached?")
        }

        Section {
            ConnectionStatusView(status: viewModel.radioConnectionStatus)
            if !viewModel.radioConnected, let reason = viewModel.radioUnavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !viewModel.radioConnected, viewModel.radioConnectionStatus != .connecting {
                Button("Test the Link") {
                    flow.testLink { viewModel.connectThisRadio() }
                }
                .disabled(viewModel.radioUnavailableReason != nil)
            }
        } footer: {
            Text("Connects to the TNC or radio now, to check it answers. Nothing goes out on "
                 + "the air. You can skip this and connect later from the radio's page.")
        }
    }

    // MARK: - 2. Channel

    private var channelStep: some View {
        Section {
            Picker("Channel", selection: Binding(get: { channel }, set: { flow.setChannel($0) })) {
                ForEach(RadioChannel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(channel == .aprs
                 ? "A shared APRS frequency such as 144.390 MHz: position beacons, APRS "
                    + "messages and the map's Ping. The node, ping and the mailbox stay off here."
                 : "A node, BBS or keyboard-to-keyboard frequency: connected sessions, the "
                    + "NET/ROM node and the mailbox. No APRS goes out on it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("What is this radio's frequency for?")
        } footer: {
            Text("A radio is one or the other. You can change it later on the radio's page.")
        }
    }

    // MARK: - 3. Identity

    private var stationCallsign: String { settings.myCallsign.uppercased() }

    @ViewBuilder
    private var identityStep: some View {
        let taken = SSIDSuggestion.taken(by: settings, except: flow.radioID)
        if stationCallsign.isEmpty {
            Section {
                Text("Set your callsign under General first, or give this radio a callsign of its own below.")
                    .font(.callout)
                CallsignField(title: "Callsign", text: $viewModel.callsign)
            } header: {
                Text("Identity")
            }
        } else {
            Section {
                HStack {
                    ForEach(SSIDSuggestion.suggest(for: channel, taken: taken), id: \.self) { ssid in
                        Button(ssid == 0 ? stationCallsign : "\(stationCallsign)-\(ssid)") {
                            usesOwnCallsign = false
                            flow.setSSID(ssid)
                        }
                    }
                }
                Picker("SSID", selection: ssidBinding) {
                    ForEach(Array(SSIDConvention.range), id: \.self) { ssid in
                        ssidRow(ssid, taken: taken).tag(Optional(ssid))
                    }
                    Text("Another callsign\u{2026}").tag(Optional<Int>.none)
                }
                if ssidBinding.wrappedValue == nil {
                    CallsignField(title: stationCallsign, text: $viewModel.callsign)
                }
            } header: {
                Text("What does this radio go on the air as?")
            } footer: {
                Text(channel == .aprs
                     ? "APRS software reads the SSID: 0 is a fixed home station, 9 a mobile, 7 a "
                        + "handheld. Each of your radios needs its own."
                     : "Packet has no standard for SSIDs. Pick one none of your other radios uses, "
                        + "so callers can reach this radio in particular.")
            }
        }
    }

    private var ssidBinding: Binding<Int?> {
        Binding(
            get: { usesOwnCallsign ? nil : flow.ssid },
            set: { ssid in
                guard let ssid else { usesOwnCallsign = true; return }
                usesOwnCallsign = false
                flow.setSSID(ssid)
            })
    }

    @ViewBuilder
    private func ssidRow(_ ssid: Int, taken: Set<Int>) -> some View {
        let call = ssid == 0 ? stationCallsign : "\(stationCallsign)-\(ssid)"
        let detail = taken.contains(ssid)
            ? "used by another radio"
            : SSIDConvention.detail(ssid: ssid, family: channel == .aprs ? .aprs : nil, usage: [:])
        if let detail {
            Text("\(call)  \u{2014}  \(detail)")
        } else {
            Text(call)
        }
    }

    // MARK: - 4. Basics

    @ViewBuilder
    private var basicsStep: some View {
        switch channel {
        case .aprs: aprsBasics
        case .packet: packetBasics
        }
    }

    private var symbol: APRSSymbol {
        let aprs = radio.beacon.aprs
        let table = aprs?.symbolTable.first ?? "/"
        let code = aprs?.symbolCode.first ?? "-"
        return APRSSymbolCatalog.symbol(table: table, code: code)
            ?? APRSSymbol(table: table, code: code, label: "Custom")
    }

    @ViewBuilder
    private var aprsBasics: some View {
        Section {
            LabeledContent("Symbol") {
                HStack(spacing: 8) {
                    Text(symbol.label).lineLimit(1)
                    Spacer()
                    Button("Choose\u{2026}") { showingSymbolPicker = true }
                }
            }
            Toggle("Send a position beacon", isOn: radioBinding(\.beacon.enabled))
            if radio.beacon.enabled {
                Stepper("Every \(radio.beacon.intervalMinutes) min",
                        value: radioBinding(\.beacon.intervalMinutes), in: 5...240, step: 5)
            }
        } header: {
            Text("Position beacon")
        } footer: {
            Text("The beacon uses the station position from General. You can give this radio a "
                 + "fixed position, a comment and more on its page.")
        }
        Section {
            RadioAPRSPathRow(path: Binding(
                get: { radio.effectiveAPRSPath },
                set: { value in settings.updateRadio(flow.radioID) { $0.aprsPath = value.uppercased() } }))
        } header: {
            Text("APRS path")
        }
    }

    @ViewBuilder
    private var packetBasics: some View {
        Section {
            Toggle("Announce the NET/ROM node", isOn: radioBinding(\.announcesNode))
            if settings.netRomNodeIdentity == .perRadio, radio.announcesNode {
                LabeledContent("Node alias on this radio") {
                    TextField(settings.netRomNodeAlias.isEmpty ? "e.g. UHFNOD" : settings.netRomNodeAlias,
                              text: Binding(
                                get: { radio.netRomAlias },
                                set: { value in settings.updateRadio(flow.radioID) { $0.netRomAlias = value.uppercased() } }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                }
            }
            Toggle("Answer mailbox calls", isOn: radioBinding(\.answersMailbox))
            Toggle("Digipeat on this radio", isOn: radioBinding(\.digi.enabled))
        } header: {
            Text("Services on this radio")
        } footer: {
            Text("Whether the node announces itself and the mailbox is on the air at all is set "
                 + "for the whole station under Packet Node and BBS. The digipeater stays off "
                 + "unless you want this radio repeating other people's traffic.")
        }
    }

    private func radioBinding<V>(_ keyPath: WritableKeyPath<RadioProfile, V>) -> Binding<V> {
        Binding(
            get: { radio[keyPath: keyPath] },
            set: { value in settings.updateRadio(flow.radioID) { $0[keyPath: keyPath] = value } })
    }

    // MARK: - Done

    private var doneStep: some View {
        Section {
            LabeledContent("Name", value: RadioDetailView.title(for: radio))
            LabeledContent("Reached by", value: radio.displayEndpoint)
            LabeledContent("On the air as", value: radio.resolvedCallsign(station: settings.myCallsign))
            LabeledContent("Channel", value: channel.title)
        } header: {
            Text("Ready")
        } footer: {
            Text("Done switches this radio on and opens its page, where its timing, beacon and "
                 + "everything else are.")
        }
    }
}
