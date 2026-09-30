import SwiftUI

/// One radio's page, the same for one radio or several.
///
/// Top to bottom: how the radio is reached and whether it is up, the
/// callsign it goes on the air with, its channel, what runs on that channel,
/// and its timing. Everything that belongs to one radio is here, and nothing
/// that belongs to the station: station-wide switches live on the service
/// pages (APRS, Packet Node, BBS), which say which radios they run on.
///
/// Only controls the code acts on. The KISS port and auto-connect exist in
/// the profile and arrive here with the phases that give them effect; a
/// switch that changes nothing teaches the operator to stop trusting
/// switches.
struct RadioDetailView: View {
    let radioID: RadioID
    @ObservedObject var settings: AppSettingsStore
    /// Read for the harvested station directory, which is what the SSID picker
    /// annotates itself from on a packet channel.
    let client: PacketEngine
    @StateObject private var viewModel: ConnectionTransportViewModel
    @EnvironmentObject private var router: SettingsRouter
    @Environment(\.dismiss) private var dismiss

    @State private var showingSymbolPicker = false
    /// Whether the identity picker is showing the free-text field rather than
    /// an SSID under the station callsign. Seeded from what is stored, then
    /// the operator's, so choosing "Another callsign" does not snap back while
    /// the field is still empty.
    @State private var usesOwnCallsign = false
    /// The clock the receive-health warning is judged by, moved on every 30
    /// seconds while the radio is connected. A deaf receiver brings no
    /// frames, and so nothing else that would redraw the page.
    @State private var healthClock = Date()
    /// What the last "Send one now" did, shown under the button for a while.
    @State private var beaconNowResult: BeaconNowFeedback.Result?

    /// The sections a deep link can land on.
    static let landingSections: Set<SettingsSection> = [
        .radioConnection, .radioReceiveAudio, .radioIdentity, .radioChannel, .radioAPRSPath,
        .radioBeacon, .radioPacketServices, .radioDigipeater, .radioTiming,
    ]

    init(radioID: RadioID, settings: AppSettingsStore, client: PacketEngine) {
        self.radioID = radioID
        self.settings = settings
        self.client = client
        _viewModel = StateObject(wrappedValue: ConnectionTransportViewModel(
            radioID: radioID, settings: settings, packetEngine: client))
    }

    var body: some View {
        SettingsForm(landing: Self.landingSections) {
            connectionSection
            statusSection
            tncSections

            identitySection
            channelSection

            switch channel {
            case .aprs:
                aprsPathSection
                beaconSection
            case .packet:
                packetServicesSection
                digipeaterSection
                beaconSection
            }

            RadioTimingSection(viewModel: viewModel, delivery: profile.timingDelivery)

            if settings.hasMultipleRadios {
                Section {
                    Button("Remove Radio", role: .destructive) {
                        settings.archiveRadio(radioID)
                        dismiss()
                    }
                }
            }
        }
        // Read a TNC4 as soon as this radio's link comes up, while the page
        // is open (see MobilinkdSettingsSections.readTNC4WhenUp).
        .task(id: viewModel.radioState) {
            await MobilinkdSettingsSections.readTNC4WhenUp(radioID: radioID, client: client,
                                                           state: viewModel.radioState)
        }
        .task(id: viewModel.radioConnected) {
            while viewModel.radioConnected, !Task.isCancelled {
                healthClock = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .sheet(isPresented: $showingSymbolPicker) {
            APRSSymbolPicker(
                selectedTable: currentSymbol.table,
                selectedCode: currentSymbol.code) { table, code in
                    settings.updateRadio(radioID) {
                        if $0.beacon.aprs == nil { $0.beacon.aprs = .followingStation }
                        $0.beacon.aprs?.symbolTable = String(table)
                        $0.beacon.aprs?.symbolCode = String(code)
                    }
                    SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
                }
        }
        .navigationTitle(Self.title(for: profile))
        .onAppear {
            viewModel.onAppear()
            viewModel.suspendAutoReconnect(true)
        }
        .onDisappear {
            viewModel.onDisappear()
            viewModel.suspendAutoReconnect(false)
        }
    }

    /// The page's title: the radio's name, or the name the app gives it.
    nonisolated static func title(for radio: RadioProfile) -> String {
        radio.name.isEmpty ? RadioProfile.defaultName(for: radio) : radio.name
    }

    private var profile: RadioProfile {
        settings.radio(radioID) ?? RadioProfile(id: radioID, name: "")
    }

    private var channel: RadioChannel { RadioChannel.of(profile) }

    private var stationCallsign: String { settings.myCallsign.uppercased() }

    private func apply() {
        SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
    }

    // MARK: - 1. Connection

    private var linkBinding: Binding<RadioLinkChoice> {
        Binding(
            get: {
                RadioLinkChoice.of(transport: viewModel.selectedTransport,
                                   rigLink: viewModel.modemRigLink)
            },
            set: { viewModel.userDidChangeLink($0) })
    }

    private var connectionSection: some View {
        Section {
            // A name and a switch only mean something against other radios.
            if settings.hasMultipleRadios {
                DraftTextField("Name", text: $viewModel.name, prompt: RadioProfile.defaultName(for: profile))
                Toggle("Enabled", isOn: $viewModel.enabled)
            }

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
            case .network:
                NetworkSettingsContent(viewModel: viewModel)
            case .serial:
                SerialSettingsContent(viewModel: viewModel)
            case .ble:
                BLESettingsContent(viewModel: viewModel)
            case .modem:
                ModemSettingsContent(viewModel: viewModel)
            }
        } header: {
            Text("Connection")
        } footer: {
            if settings.hasMultipleRadios {
                Text(viewModel.enabled
                     ? "Every enabled radio connects. The first in the list leads where one radio must stand for the station."
                     : "Off: kept in the list, not connected.")
            }
        }
        .id(SettingsSection.radioConnection)
    }

    private var statusSection: some View {
        Section {
            ConnectionStatusView(status: viewModel.radioConnectionStatus)

            // Why this radio has no link (an empty address, a missing audio
            // device), so "Disconnected" is not the whole story.
            if !viewModel.radioConnected, let reason = viewModel.radioUnavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            receiveHealthRows
            ReceiveLevelFindingRows(radioID: radioID, now: max(healthClock, Date()),
                                    monitor: client.receiveLevel) {
                router.navigate(to: .radioReceiveAudio, radio: radioID)
            }

            if viewModel.selectedTransport == .modem, viewModel.radioConnected {
                ModemStatusRows(viewModel: viewModel)
            }

            tncIdentityRow
            connectRow
        }
    }

    /// A connected radio that has decoded nothing for a while, said where
    /// the operator is already looking, with the TNC4's level meter one
    /// click away (see ReceiveHealth).
    @ViewBuilder
    private var receiveHealthRows: some View {
        if let verdict = client.receiveHealth(for: radioID, now: max(healthClock, Date())) {
            Label(ReceiveHealth.message(verdict), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .help("Worked out from this radio's own traffic: when its link came up, when it last "
                      + "decoded a frame, and how many it has sent since. A radio that has just "
                      + "connected is never flagged.")
            if client.mobilinkdControl(for: radioID) != nil {
                Button("Check the Receive Level\u{2026}") {
                    router.navigate(to: .radioReceiveAudio, radio: radioID)
                }
            }
        }
    }

    /// What is on the other end of the link. Direwolf answers the in-band
    /// KISS hardware query with its name and version; a silent TNC is plain
    /// KISS, which is itself the answer.
    @ViewBuilder
    private var tncIdentityRow: some View {
        if viewModel.radioConnected,
           viewModel.selectedTransport == .network || viewModel.selectedTransport == .modem {
            if let identity = viewModel.tncIdentity {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(identity)
                            .font(.system(.body, design: .monospaced))
                        if TNCIdentifier.isDirewolf(identity) {
                            Text("Direwolf")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.2)))
                                .foregroundStyle(.green)
                        }
                    }
                } label: {
                    Text("Software")
                }
                .help("The TNC named itself over the KISS hardware query, asked and "
                      + "answered on this link. Nothing was transmitted on the air.")
            } else {
                LabeledContent {
                    Button("Ask") { viewModel.identifyTNC() }
                        .controlSize(.small)
                } label: {
                    Text("Software")
                    Text("Has not identified itself: plain KISS, or the query went unanswered.")
                }
                .help("Sends the KISS SetHardware \u{201C}TNC:\u{201D} query. "
                      + "Direwolf answers with its version; hardware TNCs that don't "
                      + "implement the extension ignore it. Nothing is transmitted on RF.")
            }
        }
    }

    /// Connect this radio. Opening reconciles every enabled radio, so a
    /// second radio comes up without disturbing the first. Disconnect stops
    /// all links, so it is offered only from the first radio, where it reads
    /// as "stop".
    @ViewBuilder
    private var connectRow: some View {
        if viewModel.radioConnectionStatus == .connecting {
            Label("Connecting\u{2026}", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        } else if viewModel.radioConnected {
            if viewModel.isPrimary {
                Button { viewModel.disconnect() } label: {
                    Label("Disconnect", systemImage: "bolt.horizontal.circle.fill")
                }
            } else {
                Text("Connected. Disconnecting from the first radio stops every radio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button { viewModel.connectThisRadio() } label: {
                Label("Connect", systemImage: "bolt.horizontal.circle")
            }
            .disabled(!viewModel.enabled || viewModel.radioUnavailableReason != nil)
        }
    }

    /// What the TNC or the radio itself needs set: a TNC4's audio, or the
    /// sound modem's rig control, transmit level and radio setup.
    @ViewBuilder
    private var tncSections: some View {
        MobilinkdSettingsSections(radioID: radioID, client: client, viewModel: viewModel,
                                  onAPRS: channel == .aprs)

        #if os(macOS)
        if viewModel.selectedTransport == .modem {
            // Over Wi-Fi the CI-V port is the network session itself, so the
            // serial-port section only makes sense for a USB radio. The
            // address is not the port, though: it is addressed on both links.
            if viewModel.modemRigLink == .usb {
                ModemRigSection(viewModel: viewModel)
            } else {
                ModemLANRigSection(viewModel: viewModel)
            }
            ModemTransmitSection(viewModel: viewModel)
            ModemRadioSection(viewModel: viewModel)
        }
        #endif
    }

    // MARK: - 2. Identity

    private var identitySection: some View {
        Section {
            Picker("SSID", selection: ssidBinding) {
                ForEach(Array(SSIDConvention.range), id: \.self) { ssid in
                    ssidRow(ssid).tag(Optional(ssid))
                }
                Text("Another callsign\u{2026}").tag(Optional<Int>.none)
            }
            // An SSID is written under the station callsign; with none set
            // there is nothing to put it after.
            if stationCallsign.isEmpty, ssidBinding.wrappedValue != nil {
                Text("Set your callsign under General first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if ssidBinding.wrappedValue == nil {
                CallsignField(title: stationCallsign.isEmpty ? "NOCALL" : stationCallsign,
                              text: $viewModel.callsign)
            }
        } header: {
            Text("Identity")
        } footer: {
            Text(identityFooter)
        }
        .id(SettingsSection.radioIdentity)
        .onAppear {
            usesOwnCallsign = Self.ssidUnderStation(viewModel.callsign,
                                                    station: stationCallsign) == nil
        }
    }

    /// What this radio has been heard carrying, when the traffic settles it.
    ///
    /// Both families or neither reads as unsettled. A radio bridging two
    /// worlds has no single convention to quote, and advice for the wrong one
    /// is worse than none.
    private var trafficFamily: RadioTrafficFamily? {
        let families = RadioTrafficClassifier.families(from: client.stations)[radioID] ?? []
        return families.count == 1 ? families.first : nil
    }

    /// Which SSID convention to quote. What the radio has been heard carrying
    /// wins; before that an APRS channel has its published convention, and a
    /// packet channel has only what the neighbors turn out to use.
    private var adviceFamily: RadioTrafficFamily? {
        trafficFamily ?? (channel == .aprs ? .aprs : nil)
    }

    /// This radio's SSID, or nil when it operates under a callsign of its own.
    ///
    /// Nil is a real choice: a club call and a tactical alias are both
    /// legitimate. Choosing an SSID rewrites the callsign field, so the
    /// stored shape is unchanged and nothing downstream learns a new rule.
    private var ssidBinding: Binding<Int?> {
        Binding(
            get: { usesOwnCallsign ? nil : Self.ssidUnderStation(viewModel.callsign,
                                                                station: stationCallsign) },
            set: { ssid in
                guard let ssid else {
                    // Reveals the free-text field and leaves whatever is in it
                    // alone, so the operator edits rather than retypes.
                    usesOwnCallsign = true
                    return
                }
                usesOwnCallsign = false
                let base = stationCallsign.uppercased()
                // "-5" is not a callsign. With no station callsign the
                // picker says so and changes nothing.
                guard !base.isEmpty else { return }
                viewModel.callsign = ssid == 0 ? base : "\(base)-\(ssid)"
            })
    }

    /// The SSID a callsign carries under this station's own call, or nil
    /// when it is some other identity. See `StationCallsignRules.ssidUnderStation`.
    nonisolated static func ssidUnderStation(_ callsign: String, station: String) -> Int? {
        StationCallsignRules.ssidUnderStation(callsign, station: station)
    }

    /// What this station has heard other people use each SSID for.
    private var ssidUsage: [Int: [StationServiceParser.Service: Int]] {
        guard let services = try? client.stationServices?.allServices() else { return [:] }
        return SSIDConvention.localUsage(from: services)
    }

    @ViewBuilder
    private func ssidRow(_ ssid: Int) -> some View {
        let call = stationCallsign.isEmpty ? "NOCALL" : stationCallsign
        if let detail = SSIDConvention.detail(ssid: ssid,
                                              family: adviceFamily,
                                              usage: ssidUsage) {
            Text("\(ssid == 0 ? call : "\(call)-\(ssid)")  \u{00B7}  \(detail)")
        } else {
            Text(ssid == 0 ? call : "\(call)-\(ssid)")
        }
    }

    private var identityFooter: String {
        var text = "This radio goes on the air as your callsign from General with the SSID "
            + "picked here. Choose another callsign for a club or tactical call."
        if settings.hasMultipleRadios {
            text += " Give each radio its own SSID when two share a frequency, or when a "
                + "remote station should be able to reach this radio in particular."
        }
        switch adviceFamily {
        case .aprs:
            text += " The meanings shown are the published APRS convention, which other "
                + "people's software reads whatever you meant by it."
        case .ax25:
            text += " Packet has no standard for SSIDs, so the meanings shown are what "
                + "this station has heard its own neighbors use them for."
        case nil:
            text += " Packet has no standard for SSIDs. Meanings from your neighbors appear "
                + "here once this radio has heard enough of them."
        }
        return text
    }

    // MARK: - 3. Channel

    private var channelBinding: Binding<RadioChannel> {
        Binding(
            get: { channel },
            set: { newChannel in
                settings.updateRadio(radioID) { newChannel.apply(to: &$0) }
                apply()
            })
    }

    private var channelSection: some View {
        Section {
            Picker("Channel", selection: channelBinding) {
                ForEach(RadioChannel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("APRS for a shared APRS frequency such as 144.390 MHz. Packet for a "
                  + "node, BBS or keyboard-to-keyboard frequency. A radio is one or the other.")
        } header: {
            Text("Channel")
        } footer: {
            Text(channel == .aprs
                 ? "An APRS channel carries position beacons and APRS messages. The packet "
                    + "services (the node, ping, the mailbox and AXDP) stay off on it; their "
                    + "settings are kept and come back if you choose Packet."
                 : settings.hasMultipleRadios
                    ? "A packet channel runs the node, ping and the mailbox where you switch them "
                        + "on below. APRS messages and the \u{201C}who can hear me\u{201D} query go out "
                        + "only on your radios whose channel is APRS."
                    : "A packet channel runs the node, ping and the mailbox where you switch them "
                        + "on below. With one radio, an APRS message you send still goes out on it.")
        }
        .id(SettingsSection.radioChannel)
    }

    // MARK: - 4a. APRS channel

    private var aprsPathSection: some View {
        Section {
            RadioAPRSPathRow(path: aprsPathBinding)
        } header: {
            Text("APRS path")
        } footer: {
            Text("Used by everything APRS this radio sends: the position beacon, the map's "
                 + "Ping and your messages.")
        }
        .id(SettingsSection.radioAPRSPath)
    }

    /// This radio's APRS path, resolving an older build's beacon path on
    /// first read so an upgrade never silently shortens a station's reach.
    private var aprsPathBinding: Binding<String> {
        Binding(
            get: { settings.radio(radioID)?.effectiveAPRSPath ?? "" },
            set: { value in
                settings.updateRadio(radioID) { $0.aprsPath = value.uppercased() }
                apply()
            })
    }

    // MARK: - Beacon (either channel)

    private var beaconSection: some View {
        Section {
            if RadioChannel.beaconMatchesChannel(profile) {
                Toggle(channel == .aprs ? "Send a position beacon" : "Send an ID beacon",
                       isOn: beaconBinding(\.enabled))
                if beaconBinding(\.enabled).wrappedValue {
                    if channel == .aprs {
                        positionBeaconRows
                    } else {
                        idBeaconRows
                    }
                    Stepper("Send every \(beaconBinding(\.intervalMinutes).wrappedValue) min",
                            value: beaconBinding(\.intervalMinutes), in: 5...240, step: 5)
                    beaconNowRow
                }
            } else {
                mismatchedBeaconRows
            }
        } header: {
            Text(channel == .aprs ? "Position beacon" : "ID beacon")
        } footer: {
            Text(channel == .aprs
                 ? "Your position, symbol and comment, sent on this radio only. It uses the "
                    + "station position from General unless you give this radio a fixed one."
                 : "Plain text sent to BEACON on a timer, the way nodes on a packet channel "
                    + "say who they are. A radio does not beacon until you switch it on here.")
        }
        .id(SettingsSection.radioBeacon)
    }

    /// A beacon stored before channels were one or the other, whose kind is
    /// not this channel's. Said plainly, with the one change that fixes it,
    /// rather than showing controls for a beacon this radio does not send.
    @ViewBuilder
    private var mismatchedBeaconRows: some View {
        let beacon = profile.beacon
        let sends = beacon.kind == .aprsPosition ? "an APRS position beacon" : "a text ID beacon"
        Text(beacon.enabled
             ? "This radio sends \(sends) every \(beacon.intervalMinutes) min, which is not the "
                + "kind a \(channel.title) channel uses."
             : "This radio's beacon is set up as \(sends), which is not the kind a "
                + "\(channel.title) channel uses. It is switched off.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        Button(channel == .aprs ? "Use a position beacon" : "Use an ID beacon") {
            settings.updateRadio(radioID) { channel.apply(to: &$0) }
            apply()
        }
    }

    @ViewBuilder
    private var positionBeaconRows: some View {
        let symbol = currentSymbol
        LabeledContent("Symbol") {
            HStack(spacing: 8) {
                Text("\(String(symbol.table))\(String(symbol.code))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(symbol.label).lineLimit(1)
                Spacer()
                Button("Choose\u{2026}") { showingSymbolPicker = true }
            }
        }

        if (profile.beacon.aprs?.symbolTable ?? "/") != "/" {
            LabeledContent("Overlay") {
                TextField("Overlay", text: overlayBinding, prompt: Text("none"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 60)
                    .help("A single 0\u{2013}9 or A\u{2013}Z drawn over an alternate-table symbol "
                          + "(an S over the digi star, say). Leave empty for the plain "
                          + "alternate symbol.")
            }
        }

        TextField("Comment (optional)", text: aprsBinding(\.comment, default: ""))
            .textFieldStyle(.roundedBorder)

        Picker("Position", selection: aprsBinding(\.useGPS, default: true)) {
            Text("Station position").tag(true)
            Text("Fixed position for this radio").tag(false)
        }
        .help("Station position is the one under General \u{203A} Station position, the same one "
              + "the map uses: the exact coordinate when one is set, else this device's location "
              + "when that is switched on, else the center of the grid square. A fixed position "
              + "suits a radio that stays put while the station moves.")
        if aprsBinding(\.useGPS, default: true).wrappedValue {
            Text(stationPositionLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent("Latitude") {
                TextField("Latitude", text: coordString(\.latitude), prompt: Text("39.5000"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
            }
            LabeledContent("Longitude") {
                TextField("Longitude", text: coordString(\.longitude), prompt: Text("-105.2500"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
            }
        }

        Stepper("Position ambiguity: \(aprsBinding(\.ambiguityDigits, default: 0).wrappedValue)",
                value: aprsBinding(\.ambiguityDigits, default: 0), in: 0...4)
            .help("Blanks this many low-order digits of the minutes, so the beacon places you "
                  + "less exactly. 0 sends the position as it is; each step is roughly ten "
                  + "times coarser, and 4 leaves about a degree.")
        Toggle("Compressed position", isOn: aprsBinding(\.compressed, default: false))
            .help("The base-91 form: a shorter frame, less airtime, and more precision than "
                  + "the plain form. Older receivers show the plain form more readably.")

        if let example = aprsExample {
            Text(example)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// Where a beacon that follows the station would put it right now.
    private var stationPositionLine: String {
        guard let position = SessionCoordinator.shared?.aprsLocationProvider?() else {
            return "No station position yet. Set one under General \u{203A} Station position."
        }
        return String(format: "Now: %.4f, %.4f", position.latitude, position.longitude)
    }

    @ViewBuilder
    private var idBeaconRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Beacon text", text: beaconBinding(\.text), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Text("\(beaconBinding(\.text).wrappedValue.utf8.count) of "
                 + "\(BeaconPlan.maxTextBytes) bytes \u{b7} sent to BEACON")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if case let .failure(problem) = BeaconPlan.plan(
                text: beaconBinding(\.text).wrappedValue,
                path: beaconBinding(\.path).wrappedValue) {
                Text(problem.operatorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        LabeledContent("Via digipeaters") {
            TextField("Via digipeaters", text: beaconBinding(\.path), prompt: Text("direct"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
        }
        .help("Up to two digipeaters, comma-separated. Empty sends it direct, heard only "
              + "by stations in range of this radio.")
    }

    /// Beacon this radio now, and say why not when it cannot.
    ///
    /// The interval is a floor of five minutes and usually half an hour, so
    /// without this the only way to see whether a beacon works was to wait for
    /// it.
    @ViewBuilder
    private var beaconNowRow: some View {
        let obstacle = BeaconNowFeedback.blocker(
            obstacle: SessionCoordinator.shared?.beaconObstacle(for: radioID, settings: settings),
            linkUp: viewModel.radioConnected)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Send one now") {
                    guard let coordinator = SessionCoordinator.shared else {
                        beaconNowResult = .failed("AXTerm isn't ready to transmit yet.")
                        return
                    }
                    if let why = coordinator.sendBeacon(for: radioID, settings: settings) {
                        beaconNowResult = .failed(why)
                    } else {
                        beaconNowResult = .sent(Date())
                    }
                }
                .disabled(obstacle != nil)
                Text(obstacle == nil
                     ? "Goes out on this radio immediately."
                     : "Cannot send yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let obstacle {
                Text(obstacle)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let result = beaconNowResult {
                switch result {
                case .sent(let at):
                    Label(BeaconNowFeedback.sentLine(at: at), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let why):
                    Label("Not sent: \(why)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // The confirmation is for the moment after the click, not a record.
        .task(id: beaconNowResult) {
            guard beaconNowResult != nil else { return }
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { beaconNowResult = nil }
        }
    }

    /// The symbol the beacon currently uses, resolved to its catalog label.
    private var currentSymbol: APRSSymbol {
        let aprs = profile.beacon.aprs
        let table = aprs?.symbolTable.first ?? "/"
        let code = aprs?.symbolCode.first ?? "-"
        return APRSSymbolCatalog.symbol(table: table, code: code)
            ?? APRSSymbol(table: table, code: code, label: "Custom")
    }

    /// The exact info field this beacon would send, for the operator to see
    /// before it goes out. Nil when there is no position to show.
    private var aprsExample: String? {
        let aprs = profile.beacon.aprs ?? .followingStation
        let coordinate: (latitude: Double, longitude: Double)?
        if aprs.useGPS {
            coordinate = SessionCoordinator.shared?.aprsLocationProvider?()
        } else if let lat = aprs.latitude, let lon = aprs.longitude {
            coordinate = (lat, lon)
        } else {
            coordinate = nil
        }
        guard let coordinate else { return nil }
        let report = APRSBeacon.PositionReport(
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            symbolTable: aprs.symbolTable.first ?? "/",
            symbolCode: aprs.symbolCode.first ?? "-",
            ambiguity: aprs.ambiguityDigits, comment: aprs.comment, compressed: aprs.compressed)
        return APRSBeacon.infoField(report)
    }

    /// The overlay character (the symbol table byte when it is not `/` or
    /// `\`). Setting it makes the symbol an overlay of the alternate table;
    /// clearing it returns to the plain alternate table.
    private var overlayBinding: Binding<String> {
        Binding(
            get: {
                let t = settings.radio(radioID)?.beacon.aprs?.symbolTable ?? "/"
                return (t == "/" || t == "\\") ? "" : t
            },
            set: { str in
                let ch = str.uppercased().first
                settings.updateRadio(radioID) {
                    if $0.beacon.aprs == nil { $0.beacon.aprs = .followingStation }
                    if let ch, ch != "/", ch != "\\" {
                        $0.beacon.aprs?.symbolTable = String(ch)
                    } else {
                        // Cleared: overlays live on the alternate table.
                        $0.beacon.aprs?.symbolTable = "\\"
                    }
                }
                apply()
            })
    }

    /// A text binding for an optional coordinate field.
    private func coordString(_ keyPath: WritableKeyPath<APRSPositionConfig, Double?>) -> Binding<String> {
        Binding(
            get: {
                if let v = settings.radio(radioID)?.beacon.aprs?[keyPath: keyPath] {
                    return String(v)
                }
                return ""
            },
            set: { str in
                let value = Double(str.trimmingCharacters(in: .whitespaces))
                settings.updateRadio(radioID) {
                    if $0.beacon.aprs == nil { $0.beacon.aprs = .followingStation }
                    $0.beacon.aprs?[keyPath: keyPath] = value
                }
                apply()
            })
    }

    /// Bind one field of this radio's beacon. Writing re-applies so the new
    /// content or interval takes effect at the next beacon, not at relaunch.
    private func beaconBinding<V>(_ keyPath: WritableKeyPath<BeaconConfig, V>) -> Binding<V> {
        Binding(
            get: { (settings.radio(radioID)?.beacon ?? BeaconConfig())[keyPath: keyPath] },
            set: { value in
                settings.updateRadio(radioID) { $0.beacon[keyPath: keyPath] = value }
                apply()
            })
    }

    /// Bind one field of this radio's APRS position config, creating it on
    /// first write. A new config follows the station position.
    private func aprsBinding<V>(_ keyPath: WritableKeyPath<APRSPositionConfig, V>,
                               default def: V) -> Binding<V> {
        Binding(
            get: { settings.radio(radioID)?.beacon.aprs?[keyPath: keyPath] ?? def },
            set: { value in
                settings.updateRadio(radioID) {
                    if $0.beacon.aprs == nil { $0.beacon.aprs = .followingStation }
                    $0.beacon.aprs?[keyPath: keyPath] = value
                }
                apply()
            })
    }

    // MARK: - 4b. Packet channel

    private var packetServicesSection: some View {
        Section {
            Toggle("Announce the NET/ROM node", isOn: serviceBinding(\.announcesNode))
                .help("Carry the node's NODES broadcast on this radio, under this radio's "
                      + "callsign, when the node announces itself (Packet Node).")
            if settings.netRomNodeIdentity == .perRadio,
               serviceBinding(\.announcesNode).wrappedValue {
                LabeledContent("Node alias on this radio") {
                    TextField("Node alias on this radio", text: netRomAliasBinding,
                              prompt: Text(settings.netRomNodeAlias.isEmpty ? "e.g. UHFNOD" : settings.netRomNodeAlias))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                }
                .help("The six-character name this radio's node announces under, because "
                      + "each radio is its own node (Packet Node \u{203A} Node identity). "
                      + "Empty uses the station alias, which two nodes cannot share.")
            }
            Toggle("Ping stations", isOn: serviceBinding(\.pings))
                .help("Ask stations this radio heard whether they can hear it back. A radio "
                      + "switched off here asks nobody. Pacing is the station's (Packet Node).")
            Toggle("Answer mailbox calls", isOn: serviceBinding(\.answersMailbox))
                .help("Let the mailbox answer calls that arrive on this radio. Whether the "
                      + "mailbox is on the air at all is set under BBS.")
        } header: {
            Text("Services on this radio")
        } footer: {
            Text(RadioServiceNotes.packetFooter(radio: profile, settings: settings))
        }
        .id(SettingsSection.radioPacketServices)
    }

    private func serviceBinding(_ keyPath: WritableKeyPath<RadioProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.radio(radioID)?[keyPath: keyPath] ?? true },
            set: { value in
                settings.updateRadio(radioID) { $0[keyPath: keyPath] = value }
                // The node's L2 aliases are registered when configured, not
                // when announced.
                apply()
            })
    }

    /// This radio's NET/ROM node alias (used when the node identity is
    /// per-radio). Empty means the station alias.
    private var netRomAliasBinding: Binding<String> {
        Binding(
            get: { settings.radio(radioID)?.netRomAlias ?? "" },
            set: { value in
                settings.updateRadio(radioID) { $0.netRomAlias = value.uppercased() }
                apply()
            })
    }

    private var digipeaterSection: some View {
        Section {
            Toggle("Digipeat on this radio", isOn: digiBinding(\.enabled))
                .help("Retransmit frames whose via path names this station or an alias below, "
                      + "or a WIDEn-N this digipeater honors. Off by default: it volunteers "
                      + "your transmitter for other people's traffic.")
            if digiBinding(\.enabled).wrappedValue {
                Toggle("Fill-in (WIDE1-1)", isOn: digiBinding(\.fillIn))
                    .help("Repeat the first WIDE1-1 hop, as a home fill-in digipeater does.")
                Stepper(digiBinding(\.wideAreaMaxHops).wrappedValue == 0
                        ? "Wide-area: off"
                        : "Wide-area hops: \(digiBinding(\.wideAreaMaxHops).wrappedValue)",
                        value: digiBinding(\.wideAreaMaxHops), in: 0...7)
                    .help("The largest WIDEn-N this digipeater still repeats. 0 turns wide-area "
                          + "repeating off; 2 is a responsible default that does not "
                          + "regenerate WIDE7-7 floods.")
                LabeledContent("Also answer to") {
                    TextField("Also answer to", text: digiAliasesBinding,
                              prompt: Text("aliases (comma-separated)"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
                .help("Other names this digipeater repeats for, such as a club alias. Its "
                      + "own callsign is always included.")
                Stepper("Dupe window: \(digiBinding(\.dupeSeconds).wrappedValue) s",
                        value: digiBinding(\.dupeSeconds), in: 5...120, step: 5)
                    .help("A frame heard again within this many seconds is not repeated, so "
                          + "the digipeater never loops or echoes.")
            }
        } header: {
            Text("Digipeater")
        } footer: {
            Text("Repeats other stations' traffic on this radio's channel only.")
        }
        .id(SettingsSection.radioDigipeater)
    }

    /// Bind one field of this radio's digipeater config.
    private func digiBinding<V>(_ keyPath: WritableKeyPath<DigiConfig, V>) -> Binding<V> {
        Binding(
            get: { (settings.radio(radioID)?.digi ?? DigiConfig())[keyPath: keyPath] },
            set: { value in
                settings.updateRadio(radioID) { $0.digi[keyPath: keyPath] = value }
                apply()
            })
    }

    /// This radio's digi aliases as one comma-separated field.
    private var digiAliasesBinding: Binding<String> {
        Binding(
            get: { (settings.radio(radioID)?.digi.aliases ?? []).joined(separator: ", ") },
            set: { text in
                let aliases = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                    .map { $0.uppercased() }
                settings.updateRadio(radioID) { $0.digi.aliases = aliases }
                apply()
            })
    }
}


/// The APRS path field, its presets, and what the path costs.
///
/// Presets rather than a bare field because the two paths worth using are
/// conventions, not preferences; typing is still allowed, because a local
/// network with a named digipeater is a real answer the presets cannot know.
struct RadioAPRSPathRow: View {
    @Binding var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Path") {
                HStack(spacing: 8) {
                    // Labels hidden: in a grouped form a text field's title
                    // shows as a second label, and "direct" sat beside a
                    // field that said WIDE1-1,WIDE2-1.
                    TextField("Path", text: $path, prompt: Text("direct"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    // Labeled with the path in the field, or Custom, so the
                    // menu never names a different path from the one used.
                    Menu {
                        ForEach(APRSPath.presets, id: \.self) { preset in
                            Button(APRSPath.label(preset)) { path = preset }
                        }
                    } label: {
                        Text(APRSPath.menuTitle(path))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Common paths.")
                }
            }
            if case let .failure(problem) = BeaconPlan.planPath(path) {
                Text(problem.operatorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Self.explanation(path))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let advice = APRSPath.advice(path) {
                    Text(advice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What a path costs and what it buys, in the operator's terms.
    static func explanation(_ path: String) -> String {
        let total = APRSPath.transmissions(path)
        if total == 1 {
            return "Direct only: heard by stations in range of this radio, and no further. "
                + "Nothing on APRS is repeated unless the frame asks."
        }
        return "Asks for \(total - 1) digipeater hop\(total - 1 == 1 ? "" : "s"): "
            + "\(total) transmissions of every frame."
    }
}

/// What the beacon's "Send one now" button says about itself. Pure, so the
/// wording can be tested.
nonisolated enum BeaconNowFeedback {
    enum Result: Equatable {
        case sent(Date)
        case failed(String)
    }

    /// Why the button can't send: the beacon's own problem first (it needs
    /// fixing whatever the link does), then a radio that isn't connected.
    static func blocker(obstacle: String?, linkUp: Bool) -> String? {
        if let obstacle { return obstacle }
        return linkUp ? nil : "This radio isn't connected. Connect it above, then send."
    }

    /// The confirmation, with the time the frame went to the radio.
    static func sentLine(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return "Sent at \(formatter.string(from: date))"
    }
}

/// The lines under a radio's packet services, saying what the station-wide
/// switches mean for them. Pure, so the wording can be tested.
nonisolated enum RadioServiceNotes {
    @MainActor
    static func packetFooter(radio: RadioProfile, settings: AppSettingsStore) -> String {
        packetFooter(radio: radio,
                     advertises: settings.netRomAdvertiseSelf,
                     pingEnabled: settings.pingEnabled)
    }

    static func packetFooter(radio: RadioProfile, advertises: Bool, pingEnabled: Bool) -> String {
        var off: [String] = []
        if radio.announcesNode, !advertises { off.append("the node does not announce itself") }
        if radio.pings, !pingEnabled { off.append("automatic ping is off") }
        var text = "These say which services use this radio."
        if !off.isEmpty {
            text += " For the station as a whole, " + off.joined(separator: " and ")
                + ", so switching them on here does nothing until that changes under Packet Node."
        }
        return text
    }
}
