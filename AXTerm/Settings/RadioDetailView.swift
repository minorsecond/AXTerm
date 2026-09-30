import SwiftUI

/// One radio's page, the same for one radio or several.
///
/// The radio's hardware and identity, top to bottom: how it is reached and
/// whether it is up, the callsign it goes on the air with, its channel and
/// its timing. What the radio does on the air is on the service page for its
/// channel: its APRS path and position beacon under APRS, its packet
/// services, digipeater and ID beacon under Packet Node (`RadioRoleSections`).
/// The channel section says what is set there and links to it.
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

    /// Whether the identity picker is showing the free-text field rather than
    /// an SSID under the station callsign. Seeded from what is stored, then
    /// the operator's, so choosing "Another callsign" does not snap back while
    /// the field is still empty.
    @State private var usesOwnCallsign = false
    /// The clock the receive-health warning is judged by, moved on every 30
    /// seconds while the radio is connected. A deaf receiver brings no
    /// frames, and so nothing else that would redraw the page.
    @State private var healthClock = Date()

    /// The sections a deep link can land on.
    static let landingSections: Set<SettingsSection> = [
        .radioConnection, .radioReceiveAudio, .radioIdentity, .radioChannel, .radioTiming,
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
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } else {
                Text("Connected. Disconnecting from the first radio stops every radio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button { viewModel.connectThisRadio() } label: {
                Label("Connect", systemImage: "link")
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
            Picker("On the air as", selection: ssidBinding) {
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

    /// Which SSID convention to quote: the published one on an APRS channel,
    /// the neighbors' habits on a packet channel. See `SSIDConvention.family(for:)`.
    private var adviceFamily: RadioTrafficFamily {
        SSIDConvention.family(for: channel)
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
        case .ax25 where SSIDConvention.hasLocalMeanings(ssidUsage):
            text += " Packet has no standard for SSIDs, so the meanings shown are what "
                + "this station has heard its own neighbors use them for."
        case .ax25:
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
            roleRow
        } header: {
            Text("Channel")
        } footer: {
            Text(channel == .aprs
                 ? "An APRS channel carries position beacons and APRS messages. The packet "
                    + "services (the node, ping, the mailbox and AXDP) stay off on it; their "
                    + "settings are kept and come back if you choose Packet."
                 : settings.hasMultipleRadios
                    ? "A packet channel runs the node, ping and the mailbox where you switch them "
                        + "on for this radio under Packet Node. APRS messages and the \u{201C}who "
                        + "can hear me\u{201D} query go out only on your radios whose channel is APRS."
                    : "A packet channel runs the node, ping and the mailbox where you switch them "
                        + "on for this radio under Packet Node. With one radio, an APRS message you "
                        + "send still goes out on it.")
        }
        .id(SettingsSection.radioChannel)
    }

    /// What this radio does on its channel, in one line, and the way to the
    /// page where it is set.
    private var roleRow: some View {
        LabeledContent {
            Button(channel == .aprs ? "Open in APRS" : "Open in Packet Node") {
                router.navigate(to: channel == .aprs ? .aprsRadios : .packetRadios, radio: radioID)
            }
        } label: {
            Text(channel == .aprs ? "Path and position beacon" : "Services, digipeater and ID beacon")
            Text(RadioRoleSections.summary(for: profile))
        }
    }
}
