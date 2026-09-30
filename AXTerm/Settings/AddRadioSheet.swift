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
    /// Called once, with the radio when finished and nil when canceled.
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
        SetupFrame(title: flow.mode == .new ? "Add a Radio" : "Set Up Your Radio",
                   subtitle: stepSubtitle,
                   steps: AddRadioFlow.Step.allCases.map(\.title),
                   current: flow.step.rawValue) {
            stepContent
        } buttons: {
            buttons
        }
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

    private var stepSubtitle: String {
        switch flow.step {
        case .connect: return "How AXTerm reaches the TNC or radio. Nothing is transmitted while you set it up."
        case .channel: return "What this radio's frequency is for. It decides which services run on it."
        case .identity: return "The address this radio goes on the air with."
        case .basics: return "The few settings this channel needs. Everything else is on the radio's page."
        case .done: return "Check it over. Done switches the radio on."
        }
    }

    @ViewBuilder
    private var buttons: some View {
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
        let choices = RadioLinkChoice.selectable(including: linkBinding.wrappedValue)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                 count: min(max(choices.count, 1), 3)),
                  spacing: 8) {
            ForEach(choices) { choice in
                SetupTile(symbol: Self.symbol(for: choice), title: Self.shortTitle(for: choice),
                          detail: Self.tagline(for: choice),
                          selected: linkBinding.wrappedValue == choice) {
                    linkBinding.wrappedValue = choice
                }
            }
        }

        SetupCard(title: linkBinding.wrappedValue.title, note: linkBinding.wrappedValue.summary) {
            LabeledContent("Name") {
                DraftTextField("Name", text: $viewModel.name, prompt: RadioProfile.defaultName(for: radio))
                    .labelsHidden()
                    .frame(maxWidth: 240)
            }
            Divider()
            switch viewModel.selectedTransport {
            case .network: NetworkSettingsContent(viewModel: viewModel)
            case .serial: SerialSettingsContent(viewModel: viewModel)
            case .ble: BLESettingsContent(viewModel: viewModel)
            case .modem: ModemSettingsContent(viewModel: viewModel)
            }
        }

        SetupCard(note: "Connects now to check the TNC answers. Nothing goes out on the air, and "
                    + "you can skip this and connect later from the radio's page.") {
            HStack(spacing: 10) {
                Circle()
                    .fill(Self.ledColor(viewModel.radioConnectionStatus))
                    .frame(width: 9, height: 9)
                    .shadow(color: Self.ledColor(viewModel.radioConnectionStatus).opacity(0.6), radius: 3)
                Text(Self.statusText(viewModel.radioConnectionStatus))
                    .font(.callout.weight(.medium))
                Spacer()
                if !viewModel.radioConnected, viewModel.radioConnectionStatus != .connecting {
                    Button("Test the Link") {
                        flow.testLink { viewModel.connectThisRadio() }
                    }
                    .disabled(viewModel.radioUnavailableReason != nil)
                } else if viewModel.radioConnectionStatus == .connecting {
                    ProgressView().controlSize(.small)
                }
            }
            if !viewModel.radioConnected, let reason = viewModel.radioUnavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func symbol(for choice: RadioLinkChoice) -> String {
        switch choice {
        case .ble: return "dot.radiowaves.left.and.right"
        case .serial: return "cable.connector"
        case .network: return "network"
        case .modemUSB: return "waveform"
        case .modemWiFi: return "wifi"
        }
    }

    private static func shortTitle(for choice: RadioLinkChoice) -> String {
        switch choice {
        case .ble: return "Bluetooth LE"
        case .serial: return "Serial / USB"
        case .network: return "Network KISS"
        case .modemUSB: return "Sound modem"
        case .modemWiFi: return "Icom over Wi\u{2011}Fi"
        }
    }

    private static func tagline(for choice: RadioLinkChoice) -> String {
        switch choice {
        case .ble: return "Mobilinkd TNC4 and other BLE TNCs"
        case .serial: return "A KISS TNC on a serial or USB port"
        case .network: return "Direwolf, BPQ or a TNC on TCP"
        case .modemUSB: return "AXTerm's modem through the radio's USB audio"
        case .modemWiFi: return "AXTerm's modem over Icom's LAN protocol"
        }
    }

    private static func ledColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return Color.secondary.opacity(0.5)
        }
    }

    private static func statusText(_ status: ConnectionStatus) -> String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting\u{2026}"
        case .failed: return "Couldn't connect"
        case .disconnected: return "Not tested"
        }
    }

    // MARK: - 2. Channel

    @ViewBuilder
    private var channelStep: some View {
        HStack(spacing: 10) {
            SetupTile(symbol: "point.3.connected.trianglepath.dotted", title: "Packet",
                      detail: "A node or BBS frequency, for connected sessions, NET/ROM and the "
                        + "mailbox. No APRS goes out on it.",
                      selected: channel == .packet) { flow.setChannel(.packet) }
            SetupTile(symbol: "mappin.and.ellipse", title: "APRS",
                      detail: "A shared APRS frequency such as 144.390 MHz, for position beacons "
                        + "and APRS messages. The node and mailbox stay off.",
                      selected: channel == .aprs) { flow.setChannel(.aprs) }
        }
        Text("A radio is one or the other. You can change it later on the radio's page.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - 3. Identity

    private var stationCallsign: String { settings.myCallsign.uppercased() }

    @ViewBuilder
    private var identityStep: some View {
        let taken = SSIDSuggestion.taken(by: settings, except: flow.radioID)
        let onAir = radio.resolvedCallsign(station: settings.myCallsign)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ON THE AIR AS")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(onAir.isEmpty ? "N0CALL" : onAir)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(onAir.isEmpty ? .secondary : .primary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if let ssid = flow.ssid, !usesOwnCallsign,
               let meaning = SSIDConvention.detail(ssid: ssid, family: channel == .aprs ? .aprs : nil, usage: [:]) {
                Text(meaning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .padding(12)
        .background(SetupSurface())

        if stationCallsign.isEmpty {
            SetupCard(note: "Set your callsign under General first, or give this radio a callsign of its own.") {
                CallsignField(title: "Callsign", text: $viewModel.callsign)
            }
        } else {
            SetupCard(title: "SSID",
                      note: channel == .aprs
                        ? "APRS software reads the SSID: 0 is a fixed home station, 9 a mobile, 7 a "
                            + "handheld. Each of your radios needs its own."
                        : "Packet has no standard for SSIDs. Pick one none of your other radios uses, "
                            + "so callers can reach this radio in particular.") {
                HStack(spacing: 6) {
                    Text("Suggested")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(SSIDSuggestion.suggest(for: channel, taken: taken), id: \.self) { ssid in
                        Button(ssid == 0 ? stationCallsign : "\(stationCallsign)-\(ssid)") {
                            usesOwnCallsign = false
                            flow.setSSID(ssid)
                        }
                        .font(.system(.callout, design: .monospaced))
                        .buttonStyle(.bordered)
                        .tint(flow.ssid == ssid && !usesOwnCallsign ? .accentColor : nil)
                    }
                }
                Divider()
                Picker("All SSIDs", selection: ssidBinding) {
                    ForEach(Array(SSIDConvention.range), id: \.self) { ssid in
                        ssidRow(ssid, taken: taken).tag(Optional(ssid))
                    }
                    Text("Another callsign\u{2026}").tag(Optional<Int>.none)
                }
                if ssidBinding.wrappedValue == nil {
                    CallsignField(title: stationCallsign, text: $viewModel.callsign)
                }
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
        SetupCard(title: "Position beacon",
                  note: "The beacon uses the station position from General. A fixed position, a "
                    + "comment and the rest are on the radio's page.") {
            LabeledContent("Symbol") {
                HStack(spacing: 8) {
                    Text("\(String(symbol.table))\(String(symbol.code))")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(symbol.label).lineLimit(1)
                    Button("Choose\u{2026}") { showingSymbolPicker = true }
                }
            }
            Divider()
            Toggle("Send a position beacon", isOn: radioBinding(\.beacon.enabled))
            if radio.beacon.enabled {
                Stepper(value: radioBinding(\.beacon.intervalMinutes), in: 5...240, step: 5) {
                    HStack {
                        Text("Every")
                        Text("\(radio.beacon.intervalMinutes) min")
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        SetupCard(title: "APRS path") {
            RadioAPRSPathRow(path: Binding(
                get: { radio.effectiveAPRSPath },
                set: { value in settings.updateRadio(flow.radioID) { $0.aprsPath = value.uppercased() } }))
        }
    }

    @ViewBuilder
    private var packetBasics: some View {
        SetupCard(title: "Services on this radio",
                  note: "Whether the node and the mailbox are on the air at all is set for the whole "
                    + "station under Packet Node and BBS. Leave the digipeater off unless this radio "
                    + "should repeat other people's traffic.") {
            Toggle("Announce the NET/ROM node", isOn: radioBinding(\.announcesNode))
            if settings.netRomNodeIdentity == .perRadio, radio.announcesNode {
                LabeledContent("Node alias on this radio") {
                    TextField(settings.netRomNodeAlias.isEmpty ? "e.g. UHFNOD" : settings.netRomNodeAlias,
                              text: Binding(
                                get: { radio.netRomAlias },
                                set: { value in settings.updateRadio(flow.radioID) { $0.netRomAlias = value.uppercased() } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 160)
                }
            }
            Divider()
            Toggle("Answer mailbox calls", isOn: radioBinding(\.answersMailbox))
            Divider()
            Toggle("Digipeat on this radio", isOn: radioBinding(\.digi.enabled))
        }
    }

    private func radioBinding<V>(_ keyPath: WritableKeyPath<RadioProfile, V>) -> Binding<V> {
        Binding(
            get: { radio[keyPath: keyPath] },
            set: { value in settings.updateRadio(flow.radioID) { $0[keyPath: keyPath] = value } })
    }

    // MARK: - Done

    private var doneStep: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 10) {
                SetupReadout(rows: [
                    ("Radio", RadioDetailView.title(for: radio)),
                    ("Link", radio.displayEndpoint),
                    ("Call", radio.resolvedCallsign(station: settings.myCallsign)),
                    ("Channel", channel.title),
                ])
                Text("Done switches this radio on. The rest of its settings are on its page "
                     + "under Settings \u{203A} Radios.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(SetupSurface())
    }
}
