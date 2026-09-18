import SwiftUI

/// The Connection pane on a Mac — and, once there is more than one radio,
/// the Radios pane.
///
/// With one radio this is that radio's form and nothing else: no list, no
/// back button, no name to edit, exactly the Connection pane the app has
/// always had, plus one quiet row at the bottom for adding a second radio.
/// Nothing says "radios" until the operator has two. From then on it is a
/// list with a form pushed over it, and a deep link that names a radio — the
/// toolbar capsule's "TNC Settings…", the Link Layer page's "Open Radio
/// Settings…" — lands on that form with the list beneath it for the back
/// button, which is where those links have always landed.
struct RadiosSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    @EnvironmentObject private var router: SettingsRouter
    @State private var path: [RadioID] = []

    var body: some View {
        if settings.hasMultipleRadios {
            NavigationStack(path: $path) {
                RadiosListView(settings: settings, client: client,
                               destination: { $0 },
                               onAdd: { path = [$0] })
                    .navigationDestination(for: RadioID.self) { id in
                        RadioDetailView(radioID: id, settings: settings, client: client)
                    }
            }
            .onAppear(perform: honourDeepLink)
            .onChange(of: router.pendingRadio) { _, _ in honourDeepLink() }
        } else if let only = settings.activeRadios.first {
            RadioDetailView(radioID: only.id, settings: settings, client: client,
                            onAddSecondRadio: { path = [settings.addRadio().id] })
                .id(only.id)
                .onAppear { router.pendingRadio = nil }
        }
    }

    private func honourDeepLink() {
        guard let radio = router.pendingRadio else { return }
        router.pendingRadio = nil
        if settings.radio(radio) != nil { path = [radio] }
    }
}

/// One row per radio. Generic over the navigation value so the Mac pane can
/// push a `RadioID` while the iOS shell pushes its own destination enum
/// through the stack it already owns.
struct RadiosListView<Destination: Hashable>: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    let destination: (RadioID) -> Destination
    let onAdd: (RadioID) -> Void

    var body: some View {
        List {
            Section {
                ForEach(settings.activeRadios) { radio in
                    NavigationLink(value: destination(radio.id)) {
                        RadioListRow(radio: radio,
                                     status: status(for: radio),
                                     stationCallsign: settings.myCallsign)
                    }
                }
                .onMove { settings.moveRadios(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Radios")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    // Stated rather than discovered: until the link layer can
                    // hold more than one radio, this is exactly what happens.
                    if settings.hasMultipleRadios {
                        Text("AXTerm connects to the first enabled radio. Drag to reorder.")
                    }
                    ForEach(issueLines, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }

            Section {
                Button {
                    onAdd(settings.addRadio().id)
                } label: {
                    Label("Add Radio\u{2026}", systemImage: "plus")
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
    }

    /// The engine holds one link, and it is the primary radio's.
    private func status(for radio: RadioProfile) -> ConnectionStatus {
        radio.id == settings.primaryRadio?.id ? client.status : .disconnected
    }

    private var issueLines: [String] {
        RadioProfileIssue.issues(in: settings.radios, stationCallsign: settings.myCallsign).map { issue in
            switch issue {
            case let .duplicateLink(a, b):
                return "\(name(a)) and \(name(b)) use the same TNC and port; only one can hold it."
            case let .duplicateCallsign(a, b, call):
                return "\(name(a)) and \(name(b)) both answer as \(call). Fine on different frequencies, a collision on the same one."
            case let .duplicateAudioDevice(a, b):
                return "\(name(a)) and \(name(b)) share an audio device; a sound device can serve one modem."
            case let .duplicateSerialPort(a, b):
                return "\(name(a)) and \(name(b)) use the same serial port; only one can open it."
            }
        }
    }

    private func name(_ id: RadioID) -> String {
        settings.radio(id)?.name ?? "A radio"
    }
}

private struct RadioListRow: View {
    let radio: RadioProfile
    let status: ConnectionStatus
    let stationCallsign: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .help(RadioPresentation.dotHelp(summary))
            VStack(alignment: .leading, spacing: 2) {
                Text(radio.name.isEmpty ? radio.displayEndpoint : radio.name)
                    .foregroundStyle(radio.enabled ? .primary : .secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !radio.enabled {
                Text("Off")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let call = radio.resolvedCallsign(station: stationCallsign)
        return call.isEmpty ? radio.displayEndpoint : "\(call) \u{b7} \(radio.displayEndpoint)"
    }

    private var summary: RadioStatusSummary {
        RadioStatusSummary(id: radio.id, name: radio.name,
                           callsign: radio.resolvedCallsign(station: stationCallsign),
                           status: status, endpoint: radio.displayEndpoint,
                           host: radio.kind == .tcp ? radio.host : "",
                           port: radio.kind == .tcp ? radio.port : nil,
                           lastError: nil, lastRx: nil, lastTx: nil)
    }

    private var tint: Color {
        switch RadioPresentation.tint(for: status) {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: Color(platform: .platformTertiaryLabel)
        }
    }
}

/// The two halves of a radio's form, once there are enough radios to have
/// halves: reaching it, and what it does once reached.
///
/// Only shown for a second radio. One radio's form carries no name,
/// callsign, beacon, services or digipeater rows at all, so there is nothing
/// to divide and a picker over a single page would be furniture.
enum RadioPage: String, CaseIterable, Identifiable {
    case connection
    case onAir

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: "Connection"
        case .onAir: "On the air"
        }
    }
}

/// One radio's form: how its TNC is reached and the link as it stands — and,
/// once there are several radios, what it is called and whether it is on.
///
/// Only controls the code acts on. The per-radio callsign, KISS port and
/// auto-connect exist in the profile and arrive here with the phases that
/// give them effect — a switch that changes nothing teaches the operator to
/// stop trusting switches.
struct RadioDetailView: View {
    let radioID: RadioID
    @ObservedObject var settings: AppSettingsStore
    /// Read for the harvested station directory, which is what the SSID picker
    /// annotates itself from on a packet channel.
    let client: PacketEngine
    @StateObject private var viewModel: ConnectionTransportViewModel
    /// Supplied by the single-radio pane: the one door to a second radio.
    var onAddSecondRadio: (() -> Void)?

    @State private var showingSymbolPicker = false
    /// Whether the identity picker is showing the free-text field rather than
    /// an SSID under the station callsign. Seeded from what is stored, then
    /// the operator's, so choosing "Another callsign" does not snap back while
    /// the field is still empty.
    @State private var usesOwnCallsign = false
    @State private var page: RadioPage = .connection

    /// One radio has no pages, so its connection rows are always showing.
    private var showsConnection: Bool {
        !settings.hasMultipleRadios || page == .connection
    }

    init(radioID: RadioID, settings: AppSettingsStore, client: PacketEngine,
         onAddSecondRadio: (() -> Void)? = nil) {
        self.radioID = radioID
        self.settings = settings
        self.client = client
        self.onAddSecondRadio = onAddSecondRadio
        _viewModel = StateObject(wrappedValue: ConnectionTransportViewModel(
            radioID: radioID, settings: settings, packetEngine: client))
    }

    var body: some View {
        let linkBinding = Binding<RadioLinkChoice>(
            get: {
                RadioLinkChoice.of(transport: viewModel.selectedTransport,
                                   rigLink: viewModel.modemRigLink)
            },
            set: { viewModel.userDidChangeLink($0) }
        )

        Form {
            // A name and a switch only mean something against other radios.
            if settings.hasMultipleRadios, page == .connection {
                Section {
                    DraftTextField("Name", text: $viewModel.name, prompt: RadioProfile.defaultName(for: profile))
                    Toggle("Enabled", isOn: $viewModel.enabled)
                } header: {
                    Text("Radio")
                } footer: {
                    Text(viewModel.enabled
                         ? "Every enabled radio connects. The first in the list leads where one radio must stand for the station."
                         : "Off: kept in the list, not connected.")
                }
            }

            // With one radio its callsign is the station callsign, set under
            // General; a second field saying the same thing would be noise.
            if settings.hasMultipleRadios, page == .onAir {
                Section {
                    Picker("SSID", selection: ssidBinding) {
                        ForEach(Array(SSIDConvention.range), id: \.self) { ssid in
                            ssidRow(ssid).tag(Optional(ssid))
                        }
                        Text("Another callsign\u{2026}").tag(Optional<Int>.none)
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
                .onAppear {
                    usesOwnCallsign = Self.ssidUnderStation(viewModel.callsign,
                                                            station: stationCallsign) == nil
                }
            }

            if showsConnection {
                Section {
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
                    Text("Transport")
                }

                #if os(macOS)
                if viewModel.selectedTransport == .modem {
                    // Over Wi-Fi the CI-V port is the network session itself, so
                    // the serial-port section only makes sense for a USB radio.
                    // The address is not the port, though: it is addressed on
                    // both links, and hiding it here left a Wi-Fi operator no way
                    // to correct the one setting that silences CI-V outright.
                    if viewModel.modemRigLink == .usb {
                        ModemRigSection(viewModel: viewModel)
                    } else {
                        ModemLANRigSection(viewModel: viewModel)
                    }
                    ModemTransmitSection(viewModel: viewModel)
                    ModemRadioSection(viewModel: viewModel)
                }
                #endif

                Section {
                    ConnectionStatusView(status: viewModel.radioConnectionStatus)

                    // Why this radio has no link — an empty address, a missing
                    // audio device — so "Disconnected" is not the whole story.
                    if !viewModel.radioConnected, let reason = viewModel.radioUnavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if viewModel.selectedTransport == .modem, viewModel.radioConnected {
                        ModemStatusRows(viewModel: viewModel)
                    }

                    // What is on the other end of the link. Direwolf answers the
                    // in-band KISS hardware query with its name and version; a
                    // silent TNC is plain KISS, which is itself the answer.
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
                            .help("The TNC named itself over the KISS hardware "
                                  + "query — asked and answered on this TCP link, "
                                  + "nothing transmitted on the air.")
                        } else {
                            LabeledContent {
                                Button("Ask") { viewModel.identifyTNC() }
                                    .controlSize(.small)
                            } label: {
                                Text("Software")
                                Text("Has not identified itself — plain KISS, "
                                     + "or the query went unanswered.")
                            }
                            .help("Sends the KISS SetHardware \u{201C}TNC:\u{201D} query. "
                                  + "Direwolf answers with its version; hardware "
                                  + "TNCs that don't implement the extension "
                                  + "ignore it. Nothing is transmitted on RF.")
                        }
                    }

                    // Connect this radio. Opening reconciles every enabled
                    // radio, so a second radio comes up without disturbing the
                    // first. Disconnect stops all links, so it is offered only
                    // from the first radio, where it reads as "stop".
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
            }


            if settings.hasMultipleRadios, page == .onAir {
                Section {
                    Toggle("Beacon on this radio", isOn: beaconBinding(\.enabled))
                    if beaconBinding(\.enabled).wrappedValue {
                        Picker("Type", selection: beaconKindBinding) {
                            Text("Text").tag(BeaconKind.text)
                            Text("APRS position").tag(BeaconKind.aprsPosition)
                        }
                        if beaconBinding(\.kind).wrappedValue == .aprsPosition {
                            aprsBeaconEditor
                        } else {
                            textBeaconEditor
                        }
                        if beaconBinding(\.kind).wrappedValue == .aprsPosition {
                            // One path per radio: an APRS beacon and an APRS
                            // ping ask the same question of the same channel.
                            aprsPathRow
                        } else {
                            LabeledContent("Via digipeaters") {
                                TextField("direct", text: beaconBinding(\.path))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)
                            }
                        }
                        Stepper("Send every \(beaconBinding(\.intervalMinutes).wrappedValue) min",
                                value: beaconBinding(\.intervalMinutes), in: 5...240, step: 5)
                        beaconNowRow
                    }
                } header: {
                    Text("Beacon")
                } footer: {
                    Text("This radio's own beacon — text or an APRS position, its own path "
                         + "and interval. An added radio does not beacon until you switch it "
                         + "on here, so one radio's identity never goes out on another's channel.")
                }

                Section {
                    Toggle("APRS on this radio", isOn: aprsServiceBinding)
                        .help("This radio's channel is APRS: APRS messages and the \u{201C}Who can hear me\u{201D} query may go out on it. Leave off for a node or BBS frequency. Switched on for you the first time this radio is given an APRS position beacon, and yours to change after that.")
                    if settings.radio(radioID)?.aprsEnabled == true { aprsPathRow }
                } header: {
                    Text("APRS")
                } footer: {
                    Text(aprsSectionFooter)
                }

                Section {
                    Toggle("Ping stations", isOn: serviceBinding(\.pings))
                    Toggle("Announce the NET/ROM node", isOn: serviceBinding(\.announcesNode))
                    if serviceBinding(\.announcesNode).wrappedValue {
                        LabeledContent("Node alias (this radio)") {
                            TextField("station alias", text: netRomAliasBinding)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                                .help("The alias this radio's node announces under when the "
                                      + "NET/ROM node identity is per-radio (Transmission "
                                      + "settings). Empty uses the station alias.")
                        }
                    }
                    Toggle("Answer mailbox calls", isOn: serviceBinding(\.answersMailbox))
                } header: {
                    Text("Packet")
                } footer: {
                    Text(packetSectionFooter)
                }
                .disabled(isAPRSChannel)

                Section {
                    Toggle("Digipeat on this radio", isOn: digiBinding(\.enabled))
                    if digiBinding(\.enabled).wrappedValue {
                        Toggle("Fill-in (WIDE1-1)", isOn: digiBinding(\.fillIn))
                        Stepper(digiBinding(\.wideAreaMaxHops).wrappedValue == 0
                                ? "Wide-area: off"
                                : "Wide-area hops: \(digiBinding(\.wideAreaMaxHops).wrappedValue)",
                                value: digiBinding(\.wideAreaMaxHops), in: 0...7)
                        LabeledContent("Also answer to") {
                            TextField("aliases (comma-separated)", text: digiAliasesBinding)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                        }
                        Stepper("Dupe window: \(digiBinding(\.dupeSeconds).wrappedValue) s",
                                value: digiBinding(\.dupeSeconds), in: 5...120, step: 5)
                    }
                } header: {
                    Text("Digipeater")
                } footer: {
                    Text("Repeat other stations' traffic on this radio's channel: explicit "
                         + "calls/aliases, fill-in WIDE1-1, and wide-area WIDEn-N up to the hop "
                         + "cap. Off by default. Use it to make this radio an APRS digipeater "
                         + "without touching your other radio.")
                }
            }

            if settings.hasMultipleRadios {
                Section {
                    Button("Remove Radio", role: .destructive) {
                        settings.archiveRadio(radioID)
                        dismiss()
                    }
                }
            } else if let onAddSecondRadio {
                // The one place a second radio can come from. Quiet, at the
                // bottom, and the only thing on this form that is new.
                Section {
                    Button {
                        onAddSecondRadio()
                    } label: {
                        Label("Add a second radio\u{2026}", systemImage: "plus")
                    }
                } footer: {
                    Text("Another TNC — a second Direwolf, a portable rig, a station reached over the network. Each radio has its own connection.")
                }
            }
        }
        .formStyle(.grouped)
        // Pinned rather than scrolled with the rows. Inside the Form it left
        // the page it was switching, so a form scrolled past its first
        // section showed neither which page it was on nor a way back.
        .safeAreaInset(edge: .top, spacing: 0) {
            if settings.hasMultipleRadios {
                VStack(spacing: 0) {
                    Picker("Page", selection: $page) {
                        ForEach(RadioPage.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    Divider()
                }
                .background(.bar)
            }
        }
        .sheet(isPresented: $showingSymbolPicker) {
            APRSSymbolPicker(
                selectedTable: currentSymbol.table,
                selectedCode: currentSymbol.code) { table, code in
                    settings.updateRadio(radioID) {
                        if $0.beacon.aprs == nil { $0.beacon.aprs = APRSPositionConfig() }
                        $0.beacon.aprs?.symbolTable = String(table)
                        $0.beacon.aprs?.symbolCode = String(code)
                    }
                    SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
                }
        }
        .navigationTitle(settings.hasMultipleRadios
                         ? (viewModel.name.isEmpty ? RadioProfile.defaultName(for: profile) : viewModel.name)
                         : "Connection")
        .onAppear {
            viewModel.onAppear()
            viewModel.suspendAutoReconnect(true)
        }
        .onDisappear {
            viewModel.onDisappear()
            viewModel.suspendAutoReconnect(false)
        }
    }

    @Environment(\.dismiss) private var dismiss

    private var profile: RadioProfile {
        settings.radio(radioID) ?? RadioProfile(id: radioID, name: "")
    }

    private var stationCallsign: String { settings.myCallsign.uppercased() }

    /// The digipeater path for everything APRS this radio sends.
    ///
    /// Its own row, above the beacon's, because nothing on APRS is repeated
    /// unless the frame asks: a station with no path is heard only by whoever
    /// is in direct earshot, whatever its antenna. Presets rather than a bare
    /// field because the two paths worth using are conventions, not
    /// preferences — and typing is still allowed, because a local network with
    /// a named digipeater is a real answer the presets cannot know.
    @ViewBuilder
    private var aprsPathRow: some View {
        let path = aprsPathBinding.wrappedValue
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("APRS path") {
                HStack(spacing: 8) {
                    TextField("direct", text: aprsPathBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    Menu {
                        ForEach(APRSPath.presets, id: \.self) { preset in
                            Button(APRSPath.label(preset)) { aprsPathBinding.wrappedValue = preset }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help("Common paths.")
                }
            }
            if case let .failure(problem) = BeaconPlan.planPath(path) {
                Text(problem.operatorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Self.pathExplanation(path))
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
    static func pathExplanation(_ path: String) -> String {
        let total = APRSPath.transmissions(path)
        if total == 1 {
            return "Direct only — heard by stations in range of this radio, and no further. "
                + "Nothing on APRS is repeated unless the frame asks."
        }
        return "Asks for \(total - 1) digipeater hop\(total - 1 == 1 ? "" : "s"): "
            + "\(total) transmissions of every frame. Used by the position beacon, "
            + "Ping and messages you send."
    }

    /// Beacon this radio now, and say why not when it cannot.
    ///
    /// The interval is a floor of five minutes and usually half an hour, so
    /// without this the only way to see whether a beacon works was to wait for
    /// it — and an APRS beacon with no fix simply did nothing, silently.
    @ViewBuilder
    private var beaconNowRow: some View {
        let obstacle = SessionCoordinator.shared?.beaconObstacle(for: radioID, settings: settings)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Send one now") {
                    SessionCoordinator.shared?.sendBeacon(for: radioID, settings: settings)
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
            }
        }
    }

    @ViewBuilder
    private var textBeaconEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Beacon text", text: beaconBinding(\.text), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Text("\(beaconBinding(\.text).wrappedValue.utf8.count) of "
                 + "\(BeaconPlan.maxTextBytes) bytes · sent to BEACON")
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
    }

    @ViewBuilder
    private var aprsBeaconEditor: some View {
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

        if (settings.radio(radioID)?.beacon.aprs?.symbolTable ?? "/") != "/" {
            LabeledContent("Overlay") {
                TextField("none", text: overlayBinding)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 60)
                    .help("A single 0–9 or A–Z drawn over an alternate-table symbol "
                          + "(e.g. an S over the digi star). Leave empty for the plain "
                          + "alternate symbol.")
            }
        }

        Toggle("Use GPS position", isOn: aprsBinding(\.useGPS, default: false))
        if !aprsBinding(\.useGPS, default: false).wrappedValue {
            LabeledContent("Latitude") {
                TextField("39.5000", text: coordString(\.latitude))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
            }
            LabeledContent("Longitude") {
                TextField("-105.2500", text: coordString(\.longitude))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
            }
        }

        TextField("Comment (optional)", text: aprsBinding(\.comment, default: ""))
            .textFieldStyle(.roundedBorder)
        Stepper("Position ambiguity: \(aprsBinding(\.ambiguityDigits, default: 0).wrappedValue)",
                value: aprsBinding(\.ambiguityDigits, default: 0), in: 0...4)
        Toggle("Compressed position", isOn: aprsBinding(\.compressed, default: false))

        if let example = aprsExample {
            Text(example)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// The symbol the beacon currently uses, resolved to its catalog label.
    private var currentSymbol: APRSSymbol {
        let aprs = settings.radio(radioID)?.beacon.aprs
        let table = aprs?.symbolTable.first ?? "/"
        let code = aprs?.symbolCode.first ?? "-"
        return APRSSymbolCatalog.symbol(table: table, code: code)
            ?? APRSSymbol(table: table, code: code, label: "Custom")
    }

    /// The exact info field this beacon would send, for the operator to see
    /// before it goes out. Nil when there is no fixed position to show.
    private var aprsExample: String? {
        guard let aprs = settings.radio(radioID)?.beacon.aprs else { return nil }
        let lat = aprs.useGPS ? 39.5 : aprs.latitude
        let lon = aprs.useGPS ? -105.25 : aprs.longitude
        guard let la = lat, let lo = lon else { return nil }
        let report = APRSBeacon.PositionReport(
            latitude: la, longitude: lo,
            symbolTable: aprs.symbolTable.first ?? "/",
            symbolCode: aprs.symbolCode.first ?? "-",
            ambiguity: aprs.ambiguityDigits, comment: aprs.comment, compressed: aprs.compressed)
        let prefix = aprs.useGPS ? "e.g. " : ""
        return prefix + APRSBeacon.infoField(report)
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
                    if $0.beacon.aprs == nil { $0.beacon.aprs = APRSPositionConfig() }
                    if let ch, ch != "/", ch != "\\" {
                        $0.beacon.aprs?.symbolTable = String(ch)
                    } else {
                        // Cleared: overlays live on the alternate table.
                        $0.beacon.aprs?.symbolTable = "\\"
                    }
                }
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
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
                    if $0.beacon.aprs == nil { $0.beacon.aprs = APRSPositionConfig() }
                    $0.beacon.aprs?[keyPath: keyPath] = value
                }
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
            })
    }

    private func serviceBinding(_ keyPath: WritableKeyPath<RadioProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.radio(radioID)?[keyPath: keyPath] ?? true },
            set: { value in
                settings.updateRadio(radioID) { $0[keyPath: keyPath] = value }
                // The node's L2 aliases are registered when configured, not
                // when announced.
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
            })
    }

    /// The APRS switch: the one place that decides whether this radio's
    /// channel is APRS.
    ///
    /// It used to be forced on and greyed out whenever the beacon was an APRS
    /// position, on the same reasoning that put `beacon.kind` inside
    /// `handlesAPRS`. That reasoning is wrong in both places for the same
    /// reason: beaconing a position on a channel is not a promise that APRS
    /// messaging and the reachability flood belong there too, and an operator
    /// who wants the beacon without the rest had no way to say so. Choosing an
    /// APRS beacon still seeds this switch on; it no longer holds it down.
    private var aprsServiceBinding: Binding<Bool> {
        Binding(
            get: { settings.radio(radioID)?.aprsEnabled ?? false },
            set: { value in settings.updateRadio(radioID) { $0.aprsEnabled = value } })
    }

    /// This radio's APRS path, resolving an older build's beacon path on
    /// first read so an upgrade never silently shortens a station's reach.
    private var aprsPathBinding: Binding<String> {
        Binding(
            get: { settings.radio(radioID)?.effectiveAPRSPath ?? "" },
            set: { value in
                settings.updateRadio(radioID) { $0.aprsPath = value.uppercased() }
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
            })
    }

    /// Bind one field of this radio's beacon. Writing re-applies so the new
    /// content/interval takes effect at the next beacon rather than at relaunch.
    /// Whether this radio's channel is APRS, which settles what may run on it.
    private var isAPRSChannel: Bool {
        settings.radio(radioID)?.aprsEnabled == true
    }

    private var aprsSectionFooter: String {
        "APRS only goes out on radios switched on here, so a node frequency is never flooded "
            + "with an APRS query. Switching this on turns the packet services below off for "
            + "this radio: a shared beacon channel is no place for a node broadcast, a mailbox, "
            + "a ping or an AXDP probe. Your settings are kept, not cleared, and come back if "
            + "you switch APRS off."
    }

    private var packetSectionFooter: String {
        if isAPRSChannel {
            return "Off while this radio is on an APRS channel. Nothing here has been changed — "
                + "switch APRS off above and these come back as you left them."
        }
        return "Whether a service runs at all is set under Transmission and BBS; these rows only "
            + "say which radios it uses (the mailbox is one shared store)."
    }

    // MARK: - Identity

    /// What this radio has been heard carrying, when the traffic settles it.
    ///
    /// Both families or neither reads as unsettled. A radio bridging two
    /// worlds has no single convention to quote, and advice for the wrong one
    /// is worse than none: `SSIDConvention.detail` shows what it can either
    /// way rather than picking a side on a coin toss.
    private var trafficFamily: RadioTrafficFamily? {
        let families = RadioTrafficClassifier.families(from: client.stations)[radioID] ?? []
        return families.count == 1 ? families.first : nil
    }

    /// This radio's SSID, or nil when it operates under a callsign of its own.
    ///
    /// Nil is a real choice rather than an empty state: a club call and a
    /// tactical alias are both legitimate, and a picker that could only count
    /// to fifteen would have removed them. Choosing an SSID rewrites the
    /// callsign field, so the stored shape is unchanged and nothing
    /// downstream learns a new rule.
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
                viewModel.callsign = ssid == 0 ? base : "\(base)-\(ssid)"
            })
    }

    /// The SSID a callsign carries *under this station's own call*, or nil
    /// when it is some other identity.
    ///
    /// A club call or a tactical alias is its own identity even when it has an
    /// SSID, so only the station's own base maps back onto the picker.
    static func ssidUnderStation(_ callsign: String, station: String) -> Int? {
        if callsign.isEmpty { return 0 }
        guard let ssid = SSIDConvention.ssid(of: callsign) else {
            return callsign.uppercased() == station.uppercased() ? 0 : nil
        }
        let base = callsign.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return base.uppercased() == station.uppercased() ? ssid : nil
    }

    /// What this station has heard other people use each SSID for.
    ///
    /// Recomputed per appearance rather than cached: a settings pane is opened
    /// rarely and briefly, and a stale table here would be advice that has
    /// quietly stopped matching the channel.
    private var ssidUsage: [Int: [StationServiceParser.Service: Int]] {
        guard let services = try? client.stationServices?.allServices() else { return [:] }
        return SSIDConvention.localUsage(from: services)
    }

    @ViewBuilder
    private func ssidRow(_ ssid: Int) -> some View {
        let call = stationCallsign.isEmpty ? "NOCALL" : stationCallsign
        if let detail = SSIDConvention.detail(ssid: ssid,
                                              family: trafficFamily,
                                              usage: ssidUsage) {
            Text("\(ssid == 0 ? call : "\(call)-\(ssid)")  \u{2014}  \(detail)")
        } else {
            Text(ssid == 0 ? call : "\(call)-\(ssid)")
        }
    }

    private var identityFooter: String {
        let base = "Give this radio its own SSID when two radios share a frequency, or when a "
            + "remote station should be able to reach this radio in particular. A call to an "
            + "SSID only one radio uses is answered by that radio whichever link heard it."
        switch trafficFamily {
        case .aprs:
            return base + " The meanings shown are the published APRS convention, which other "
                + "people's software reads whatever you meant by it."
        case .ax25:
            return base + " Packet has no standard for SSIDs, so the meanings shown are what "
                + "this station has heard its own neighbours use them for."
        case nil:
            return base + " Meanings appear here once this radio has heard enough traffic to "
                + "tell which kind of channel it is on."
        }
    }

    /// The beacon's Type, which seeds `aprsEnabled` when it first becomes an
    /// APRS position.
    ///
    /// Choosing an APRS beacon says the channel is APRS, and making the
    /// operator then find a second switch to say the same thing is how the old
    /// `handlesAPRS ||` came to exist. Seeding is the convenience without the
    /// coupling: switching back to Text leaves the APRS switch where the
    /// operator last saw it rather than silently reaching over and moving it.
    private var beaconKindBinding: Binding<BeaconKind> {
        Binding(
            get: { settings.radio(radioID)?.beacon.kind ?? .text },
            set: { kind in
                settings.updateRadio(radioID) { radio in
                    radio.beacon.kind = kind
                    if kind == .aprsPosition { radio.aprsEnabled = true }
                }
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
            })
    }

    private func beaconBinding<V>(_ keyPath: WritableKeyPath<BeaconConfig, V>) -> Binding<V> {
        Binding(
            get: { (settings.radio(radioID)?.beacon ?? BeaconConfig())[keyPath: keyPath] },
            set: { value in
                settings.updateRadio(radioID) { $0.beacon[keyPath: keyPath] = value }
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
            })
    }

    /// Bind one field of this radio's digipeater config.
    private func digiBinding<V>(_ keyPath: WritableKeyPath<DigiConfig, V>) -> Binding<V> {
        Binding(
            get: { (settings.radio(radioID)?.digi ?? DigiConfig())[keyPath: keyPath] },
            set: { value in
                settings.updateRadio(radioID) { $0.digi[keyPath: keyPath] = value }
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
            })
    }

    /// This radio's NET/ROM node alias (used when the node identity is
    /// per-radio). Empty means the station alias.
    private var netRomAliasBinding: Binding<String> {
        Binding(
            get: { settings.radio(radioID)?.netRomAlias ?? "" },
            set: { value in
                settings.updateRadio(radioID) { $0.netRomAlias = value.uppercased() }
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
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
            })
    }

    /// Bind one field of this radio's APRS position config, creating it on
    /// first write so switching a beacon to APRS needs no separate step.
    private func aprsBinding<V>(_ keyPath: WritableKeyPath<APRSPositionConfig, V>,
                               default def: V) -> Binding<V> {
        Binding(
            get: { settings.radio(radioID)?.beacon.aprs?[keyPath: keyPath] ?? def },
            set: { value in
                settings.updateRadio(radioID) {
                    if $0.beacon.aprs == nil { $0.beacon.aprs = APRSPositionConfig() }
                    $0.beacon.aprs?[keyPath: keyPath] = value
                }
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
            })
    }
}
