//
//  PacketNodeSettingsView.swift
//  AXTerm
//
//  Services › Packet Node: the packet services. Whether the node runs and
//  announces itself, then a set of sections for each radio on a packet
//  channel (which services use it, its digipeater and ID beacon), then how
//  ping is paced, the AX.25 link layer, adaptive transmission, AXDP and file
//  transfers.
//

import SwiftUI

struct PacketNodeSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    @EnvironmentObject var router: SettingsRouter
    /// Whether the mailbox is on the air (its own page's switch), for the
    /// summary at the top; nil leaves it out.
    var mailboxOnAir: Bool? = nil
    /// The mailbox's callsign, so the node's is not offered it.
    var mailboxCallsign: String? = nil
    /// The switched-off radios' sections, shown on request.
    @State private var showsFoldedRadios = false
    /// Folded under Advanced: the link layer and protocol tuning.
    @AppStorage("settings.packetNode.showsAdvanced") private var showsAdvanced = false
    static let foldedSections: Set<SettingsSection> = [.linkLayer, .adaptiveTransmission, .axdpProtocol]
    @Environment(\.openWindow) private var openWindow
    
    @State private var txAdaptiveSettings = TxAdaptiveSettings()
    /// Reset Station Parameters asks for a callsign.
    @State private var prompt: TextEntryPrompt?
    

    var body: some View {
        SettingsForm(landing: [.netRomNode, .packetMailbox, .ping, .linkLayer, .adaptiveTransmission,
                               .axdpProtocol],
                     radios: RadioLanding(section: .packetRadios) { radio in
                         RadioRoleSections.landing(for: radio, among: packetRadios, on: .packet)
                     }) {
            summarySection

            PreferencesSection("NET/ROM Node", id: .netRomNode) {
                if settings.allRadiosOnAPRS { aprsLockNote }
                Toggle("Run the node: answer callers with the node shell",
                       isOn: $settings.netRomAcceptInbound)
                    .disabled(settings.allRadiosOnAPRS)
                    .help("Accept NET/ROM circuits AND plain AX.25 connects "
                          + "to the node alias. Callers land at an AXTerm "
                          + "node prompt with NODES, ROUTES, MH, INFO; BBS "
                          + "drops them into the mailbox when it is on the "
                          + "air; C bridges them onward through this "
                          + "station\u{2019}s own circuits. Off answers every "
                          + "request with the standard refusal. Up to three "
                          + "callers at once.\n\nIf you advertise this "
                          + "station (below), turning this on is what makes "
                          + "the advertisement honest.")

                Stepper(value: $settings.autoRouteMaxChainLength, in: 1...6) {
                    HStack {
                        Text("Auto-routing may chain up to")
                        Spacer()
                        Text("\(settings.autoRouteMaxChainLength) node"
                             + "\(settings.autoRouteMaxChainLength == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                }
                .help("The airtime budget for the Auto ladder\u{2019}s node-prompt "
                      + "relays. Each hop is a full connected-mode leg the "
                      + "whole channel shares; four hops can hold the "
                      + "frequency for minutes. The pre-connect preview, the "
                      + "profile page\u{2019}s planned path and the dial all obey "
                      + "the same cap.")

                Text("AXTerm always listens to NET/ROM and learns routes from what it hears. "
                     + "These switches decide whether it also speaks. Both change what other "
                     + "operators' nodes do, so both start off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Node alias") {
                    // Applied on commit, never per keystroke: this used to
                    // push a NODES broadcast on every character typed.
                    TextField("e.g. EPINOD", text: $settings.netRomNodeAlias)
                        .callsignInput($settings.netRomNodeAlias)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .onSubmit { applyNetRomSettings() }
                }
                .help("Six characters, the mnemonic other nodes show beside this station's "
                      + "callsign. BPQ calls it NODEALIAS. When each radio is its own node, "
                      + "each radio's section below can give it an alias of its own.")

                if settings.netRomNodeIdentity == .unified {
                    LabeledContent("Node callsign") {
                        Picker("Node callsign", selection: nodeSSIDBinding) {
                            Text("Same as the station (\(settings.primaryCallsign))").tag(-1)
                            ForEach(NodeCallsignChoices.ssids(taken: radioSSIDs, current: settings.netRomNodeSSID),
                                    id: \.self) { ssid in
                                Text("\(stationBaseCall)-\(ssid)").tag(ssid)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .help("The node's own callsign. BPQ calls it NODECALL. Operators expect a node on a "
                          + "callsign of its own, often -7: it and the alias both reach the node, its NODES "
                          + "broadcasts and links to other nodes use it, and the station's callsign stays "
                          + "yours. \"Same as the station\" gives the node and you one callsign.")
                }

                LabeledContent("Hang up idle callers") {
                    Picker("Hang up idle callers", selection: nodeIdleBinding) {
                        Text("Never").tag(0)
                        ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                            Text("After \(minutes) minutes").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .help("A caller at the node prompt who types nothing for this long is told "
                      + "\"no activity\" and disconnected, as a BPQ node's IDLETIME does, so nobody "
                      + "holds the channel open after wandering off. Only their typing counts; the "
                      + "link's own polls do not. The mailbox has its own timeout.")

                Toggle("Announce this station to the network", isOn: $settings.netRomAdvertiseSelf)
                    .onChange(of: settings.netRomAdvertiseSelf) { _, _ in applyNetRomSettings() }
                    .disabled(settings.allRadiosOnAPRS)
                    .help("Sends NODES broadcasts so neighbors learn this station exists and "
                          + "can route to it. Every node that hears one writes this station "
                          + "into its own routing table.")

                NetRomNodeIdentityRows(settings: settings, onChange: applyNetRomSettings)
                // Each radio's own alias when each radio is its own node. Its
                // L2 alias is registered whether or not the node announces.
                if settings.netRomNodeIdentity == .perRadio {
                    ForEach(packetRadios.filter(\.announcesNode)) { radio in
                        perRadioAliasRow(radio)
                    }
                }

                if settings.netRomAdvertiseSelf {
                    CarriedOnRow(settings: settings, radios: liveRadios, service: \.announcesNode,
                                 none: "No radio announces the node. Pick one here.")
                        .help("The radios that carry the NODES broadcast. Each radio's frame "
                              + "leaves under that radio's own callsign; several take turns two "
                              + "seconds apart.")

                    durationRow(
                        "Announce every",
                        value: $settings.netRomBroadcastMinutes,
                        presets: [5, 10, 15, 20, 30, 45, 60, 90, 120, 240],
                        label: Self.minutesLabel
                    )
                    .onChange(of: settings.netRomBroadcastMinutes) { _, _ in applyNetRomSettings() }
                    .help("BPQ's default is 60 minutes. Shorter intervals spend more of a "
                          + "shared channel on routing overhead.")

                    if settings.netRomNodeAlias.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Set a node alias. Announcing without one is legal but leaves "
                             + "a blank name in every neighbor's node list.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle("Carry other stations' traffic (transit routing)",
                       isOn: $settings.netRomForwarding)
                    .onChange(of: settings.netRomForwarding) { _, _ in applyNetRomSettings() }
                    .disabled(settings.allRadiosOnAPRS)
                    .help("Forwards NET/ROM datagrams addressed to other nodes. This spends "
                          + "this station's airtime on other people's packets and makes it "
                          + "answerable for delivering them.")

                if settings.netRomForwarding && !settings.netRomAdvertiseSelf {
                    Text("Forwarding without announcing has little effect: no other node knows "
                         + "to route through this station.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PreferencesSection("Mailbox", id: .packetMailbox) {
                CarriedOnRow(settings: settings, radios: liveRadios, service: \.answersMailbox,
                             none: "The mailbox answers on no radio. Pick one here.")
                    .help("The radios the mailbox answers calls on. Whether it is on the air at "
                          + "all, and everything else about it, is in the mailbox settings.")
                Button("Mailbox Settings\u{2026}") { router.navigate(to: .bbs) }
                    .buttonStyle(.borderless)
            }

            PreferencesSection("Ping", id: .ping) {
                Text("Asks stations whether they can hear this one, using a frame "
                     + "any AX.25 station answers, with no connection and nothing opened. "
                     + "An answer proves radio works both ways right now; it does "
                     + "not mean the station will route or accept a call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Ping stations automatically", isOn: $settings.pingEnabled)
                    .onChange(of: settings.pingEnabled) { _, _ in applyNetRomSettings() }
                    .disabled(settings.allRadiosOnAPRS)
                if settings.allRadiosOnAPRS { aprsLockNote }

                if settings.pingEnabled {
                    CarriedOnRow(settings: settings, radios: liveRadios, service: \.pings,
                                 none: "No radio pings. Pick one here.")
                        .help("A station is pinged on the radio that heard it. A radio left out "
                              + "here asks nobody, and stations heard only there are left alone. "
                              + "The hourly budget is the station's.")
                    LabeledContent("Only between") {
                        HStack(spacing: 6) {
                            Picker("", selection: $settings.pingWindowStartHour) {
                                ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                            }
                            .labelsHidden().frame(width: 96)
                            Text("and")
                            Picker("", selection: $settings.pingWindowEndHour) {
                                ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                            }
                            .labelsHidden().frame(width: 96)
                        }
                    }
                    .onChange(of: settings.pingWindowStartHour) { _, _ in applyNetRomSettings() }
                    .onChange(of: settings.pingWindowEndHour) { _, _ in applyNetRomSettings() }
                    .help("Local time, and it may wrap past midnight. Set both the "
                          + "same for any hour.")

                    durationRow(
                        "At most",
                        value: $settings.pingMaxProbesPerHour,
                        presets: [1, 2, 3, 4, 6, 8, 12, 20, 30, 60],
                        label: { "\($0) per hour" }
                    )
                    .onChange(of: settings.pingMaxProbesPerHour) { _, _ in applyNetRomSettings() }
                    .help("A hard ceiling, whatever the spacing below would allow.")

                    IntervalPicker(
                        "At least",
                        seconds: $settings.pingMinSecondsBetween,
                        presetSeconds: [30, 60, 90, 120, 180, 300, 600, 900])
                    .onChange(of: settings.pingMinSecondsBetween) { _, _ in applyNetRomSettings() }
                    .help("Between any two probes, whoever they are for.")

                    IntervalPicker(
                        "Each station at most every",
                        minutes: $settings.pingBoxCooldownMinutes,
                        presetMinutes: [15, 30, 45, 60, 120, 240, 480, 720, 1440],
                        offLabel: "No limit")
                    .onChange(of: settings.pingBoxCooldownMinutes) { _, _ in applyNetRomSettings() }
                    .help("One station, whatever its SSIDs. K0NTS-1, -7, -10 and -14 "
                          + "are one radio on one antenna, and asking the second "
                          + "address learns nothing the first did not, but "
                          + "without this they come due together and go out back to "
                          + "back. Set it to No limit to pace each address alone.")

                    IntervalPicker(
                        "Each SSID at most every",
                        minutes: $settings.pingStationCooldownMinutes,
                        presetMinutes: [10, 15, 20, 30, 45, 60, 120, 240, 480, 720, 1440])
                    .onChange(of: settings.pingStationCooldownMinutes) { _, _ in applyNetRomSettings() }
                    .help("The exact address, SSID and all. Doubles each time it does "
                          + "not answer, up to a day, so a silent address is asked "
                          + "less and less rather than more. Only adds to the rule "
                          + "above when set longer than it.")

                    Toggle("Also stations others are calling",
                           isOn: $settings.pingProbeStationsOthersCall)
                        .onChange(of: settings.pingProbeStationsOthersCall) { _, _ in applyNetRomSettings() }
                        .help("Stations this receiver has never heard, but that a "
                              + "neighbor was heard calling. Asks whether this station "
                              + "can reach what its neighbors reach: a longer shot, "
                              + "and a transmission either way.")

                    Text("Never while a session is running, never within 10 s of other "
                         + "traffic, and never a station already connected.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let coordinator = SessionCoordinator.shared,
                   !coordinator.pingProber.recent.isEmpty {
                    Divider()
                    ForEach(coordinator.pingProber.recent.prefix(8), id: \.call) { record in
                        HStack {
                            Text(record.call)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(Self.outcome(record))
                                .font(.caption2)
                                .foregroundStyle(record.lastAnswered == nil ? .secondary : .primary)
                        }
                    }
                    // The eight most recent answer "is it running". Which
                    // stations answer, how the round trips spread and how
                    // much of the channel this is using need the log.
                    Button("Ping Activity\u{2026}") { openWindow(id: "pingActivity") }
                        .buttonStyle(.borderless)
                        .help("Every probe sent, what answered, when, and how long "
                              + "it took.")
                }
            }

            packetRadioSections

            SettingsAdvancedToggle(isShown: $showsAdvanced,
                                   summary: "Link layer, adaptive transmission and AXDP.")
            if SettingsFold.showsAdvanced(stored: showsAdvanced, landing: router.highlightSection,
                                          folded: Self.foldedSections) {
                PreferencesSection("Link Layer (AX.25 Connected Mode)", id: .linkLayer) {
                    LinkLayerSettingsView(
                        settings: settings,
                        txAdaptiveSettings: $txAdaptiveSettings,
                        syncToCoordinator: syncAdaptiveSettingsToSessionCoordinator
                    )
                }

                PreferencesSection("Adaptive Transmission", id: .adaptiveTransmission) {
                    Toggle("Enable Adaptive Transmission", isOn: Binding(
                        get: { settings.adaptiveTransmissionEnabled },
                        set: { newValue in
                            settings.adaptiveTransmissionEnabled = newValue
                            if let coordinator = SessionCoordinator.shared {
                                coordinator.adaptiveTransmissionEnabled = newValue
                                coordinator.syncSessionManagerConfigFromAdaptive()
                                if newValue { TxLog.adaptiveEnabled() } else { TxLog.adaptiveDisabled() }
                            }
                        }
                    ))
                
                    if settings.adaptiveTransmissionEnabled {
                        LabeledContent("Status") {
                            HStack(spacing: 6) {
                                Image(systemName: "chart.line.uptrend.xyaxis")
                                    .foregroundStyle(.green)
                                Text("Learning from session and network")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    
                        Text("PACLEN, K and N2 set to Auto under Link Layer follow what each link "
                             + "achieves.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    
                        LabeledContent("Overrides") {
                            HStack {
                                Button("Reset Specific Station…") {
                                    resetStationAlert()
                                }
                            
                                Button("Clear All Learned Data") {
                                    if let coordinator = SessionCoordinator.shared {
                                        coordinator.clearAllLearned()
                                        seedAdaptiveSettings()
                                    }
                                }
                            }
                        }
                        .disabled(!settings.adaptiveTransmissionEnabled)
                    }
                }

                PreferencesSection("AXDP Protocol", id: .axdpProtocol) {
                    if settings.allRadiosOnAPRS { aprsLockNote }
                    Toggle("Enable AXDP Extensions", isOn: $txAdaptiveSettings.axdpExtensionsEnabled)
                        .disabled(settings.allRadiosOnAPRS)
                        .onChange(of: txAdaptiveSettings.axdpExtensionsEnabled) { _, _ in
                            syncAdaptiveSettingsToSessionCoordinator()
                        }

                    if txAdaptiveSettings.axdpExtensionsEnabled {
                        Toggle("Auto-negotiate Capabilities", isOn: $txAdaptiveSettings.autoNegotiateCapabilities)
                            .onChange(of: txAdaptiveSettings.autoNegotiateCapabilities) { _, _ in
                                syncAdaptiveSettingsToSessionCoordinator()
                            }

                        Toggle("Enable Compression", isOn: $txAdaptiveSettings.compressionEnabled)
                            .onChange(of: txAdaptiveSettings.compressionEnabled) { _, _ in
                                syncAdaptiveSettingsToSessionCoordinator()
                            }

                        if txAdaptiveSettings.compressionEnabled {
                            Picker("Compression Algorithm", selection: $txAdaptiveSettings.compressionAlgorithm) {
                                Text("LZ4 (fast)").tag(AXDPCompression.Algorithm.lz4)
                                Text("Deflate (better ratio)").tag(AXDPCompression.Algorithm.deflate)
                            }
                            .pickerStyle(.menu)
                            .onChange(of: txAdaptiveSettings.compressionAlgorithm) { _, _ in
                                syncAdaptiveSettingsToSessionCoordinator()
                            }
                        }
                    
                        Toggle("Show AXDP decode details in console", isOn: $txAdaptiveSettings.showAXDPDecodeDetails)
                             .onChange(of: txAdaptiveSettings.showAXDPDecodeDetails) { _, _ in
                                 syncAdaptiveSettingsToSessionCoordinator()
                             }
                    }

                    Text("AXDP extensions provide compression, capability negotiation, and reliable transfers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .settingsPagePadding()
        .opensAdvanced($showsAdvanced, for: Self.foldedSections, router: router)
        .onAppear {
            seedAdaptiveSettings()
        }
        // Text fields apply on commit, and an operator who types an alias
        // and closes the window has committed. Safe to call now that
        // applying settings no longer transmits by itself.
        .onDisappear {
            applyNetRomSettings()
        }
        .textEntryPrompt($prompt)
    }
    
    // MARK: - Each packet radio

    private var packetRadios: [RadioProfile] {
        RadioRoleSections.radios(on: .packet, in: settings.activeRadios)
    }

    /// The packet radios that are switched on: the ones a service can run on.
    private var liveRadios: [RadioProfile] {
        PacketNodeSummary.shown(packetRadios)
    }

    /// What is on the air now, at the top of the page.
    private var summarySection: some View {
        let summary = PacketNodeSummary(radios: packetRadios, nodeRuns: settings.netRomAcceptInbound,
                                        announces: settings.netRomAdvertiseSelf,
                                        alias: settings.netRomNodeAlias, pings: settings.pingEnabled,
                                        mailboxOnAir: mailboxOnAir)
        return Section {
            ForEach(summary.on, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary)
            }
            if let off = summary.off {
                Label(off, systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("On the air now")
        }
    }

    private func perRadioAliasRow(_ radio: RadioProfile) -> some View {
        let bind = RadioRoleBindings(radioID: radio.id, settings: settings)
        return LabeledContent("Node alias on \(RadioDetailView.title(for: radio))") {
            TextField("Node alias on \(RadioDetailView.title(for: radio))", text: bind.netRomAlias,
                      prompt: Text(settings.netRomNodeAlias.isEmpty ? "e.g. UHFNOD" : settings.netRomNodeAlias))
                .callsignInput(bind.netRomAlias)
                .labelsHidden()
                .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
        }
        .help("The six-character name this radio's node announces under, because each radio is "
              + "its own node (Node identity, above). Empty uses the station alias, which two "
              + "nodes cannot share.")
    }

    /// Each packet radio's services, digipeater and ID beacon, in list order.
    @ViewBuilder
    private var packetRadioSections: some View {
        if packetRadios.isEmpty {
            Section {
                Text("No radio is on a packet channel. A radio's services, digipeater and ID "
                     + "beacon appear here once its channel is Packet.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Radios\u{2026}") { router.navigate(to: .radios) }
            }
            .id(SettingsSection.packetRadios)
        } else {
            ForEach(liveRadios) { radio in
                RadioPacketSections(radioID: radio.id, settings: settings, client: client)
            }
            let folded = PacketNodeSummary.folded(packetRadios)
            if !folded.isEmpty {
                Section {
                    ForEach(folded) { radio in
                        HStack {
                            Text("\(RadioDetailView.title(for: radio)) is switched off and carries nothing.")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    Button(showsFoldedRadios ? "Hide Their Settings" : "Show Their Settings") {
                        showsFoldedRadios.toggle()
                    }
                    .buttonStyle(.borderless)
                }
                if showsFoldedRadios {
                    ForEach(folded) { radio in
                        RadioPacketSections(radioID: radio.id, settings: settings, client: client)
                    }
                }
            }
        }
    }

    // MARK: - Helpers
    
    // ... Copying existing helpers (seedAdaptiveSettings, syncAdaptiveSettingsToSessionCoordinator) ...
    // Since we are overwriting the file structure, we need to ensure we include these.
    
    private static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    // MARK: Duration menus

    /// A pop-up menu for a paced-transmission setting. These were Steppers,
    /// which made wide ranges click-torture: 120 s to 900 s of probe spacing
    /// was twenty-six clicks on a control a few pixels tall. A menu shows
    /// every sensible choice at once, matching the hour-window pickers above.
    @ViewBuilder
    private func durationRow(
        _ title: String,
        value: Binding<Int>,
        presets: [Int],
        label: @escaping (Int) -> String
    ) -> some View {
        LabeledContent(title) {
            Picker("", selection: value) {
                ForEach(Self.durationMenuOptions(presets: presets,
                                                 current: value.wrappedValue),
                        id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// A value dialed in under the old steppers (say 25 min) may not be a
    /// preset; a macOS pop-up whose selection has no matching tag renders
    /// blank, so the current value is spliced into the list when missing.
    nonisolated static func durationMenuOptions(presets: [Int], current: Int) -> [Int] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    nonisolated static func minutesLabel(_ minutes: Int) -> String {
        guard minutes >= 60, minutes.isMultiple(of: 60) else { return "\(minutes) min" }
        return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }

    nonisolated static func secondsLabel(_ seconds: Int) -> String {
        guard seconds >= 60, seconds.isMultiple(of: 60) else { return "\(seconds) s" }
        return "\(seconds / 60) min"
    }

    /// What a station's probing history amounts to, in a phrase.
    private static func outcome(_ record: PingProber.Record) -> String {
        guard let answered = record.lastAnswered else {
            return record.consecutiveSilences > 0
                ? "no answer (\(record.consecutiveSilences)×)" : "asked, waiting"
        }
        let rtt = record.lastRTT.map { String(format: "%.1f s", $0) } ?? "—"
        let kind = record.lastAnswerKind ?? "answered"
        let stamp = answered.formatted(date: .omitted, time: .shortened)
        return "\(rtt) · \(kind) · \(stamp)"
    }

    private func seedAdaptiveSettings() {
        // Start from the live settings, or the stored choices when there is
        // no coordinator yet. Starting from a blank copy and syncing it back
        // reset manual K and N2 to their defaults on every visit.
        txAdaptiveSettings = SessionCoordinator.shared?.globalAdaptiveSettings
            ?? settings.ax25LinkTuning.applied(to: TxAdaptiveSettings())
        txAdaptiveSettings.axdpExtensionsEnabled = settings.axdpExtensionsEnabled
        txAdaptiveSettings.autoNegotiateCapabilities = settings.axdpAutoNegotiateCapabilities
        txAdaptiveSettings.compressionEnabled = settings.axdpCompressionEnabled
        if let algo = AXDPCompression.Algorithm(rawValue: settings.axdpCompressionAlgorithmRaw) {
            txAdaptiveSettings.compressionAlgorithm = algo
        }
        txAdaptiveSettings.maxDecompressedPayload = UInt32(settings.axdpMaxDecompressedPayload)
        txAdaptiveSettings.showAXDPDecodeDetails = settings.axdpShowDecodeDetails

        syncAdaptiveSettingsToSessionCoordinator()
        if let coordinator = SessionCoordinator.shared {
            coordinator.adaptiveTransmissionEnabled = settings.adaptiveTransmissionEnabled
            coordinator.syncSessionManagerConfigFromAdaptive()
        }
    }
    
    /// Push the NET/ROM node policy into the live coordinator. Both
    /// switches change what goes on the air, so they take effect the
    /// moment the operator sets them rather than at next launch.
    private func applyNetRomSettings() {
        SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
    }

    /// Minutes before the node hangs up on an idle caller, 0 for never.
    private var nodeIdleBinding: Binding<Int> {
        Binding(get: { settings.netRomNodeIdleMinutes },
                set: { value in
                    settings.netRomNodeIdleMinutes = value
                    applyNetRomSettings()
                })
    }

    /// The node's SSID, -1 for the station's callsign.
    private var nodeSSIDBinding: Binding<Int> {
        Binding(get: { settings.netRomNodeSSID ?? -1 },
                set: { value in
                    settings.netRomNodeSSID = value < 0 ? nil : value
                    applyNetRomSettings()
                })
    }

    private var stationBaseCall: String {
        CallsignNormalizer.parse(settings.myCallsign).call.uppercased()
    }

    /// The station's SSIDs in use, the radios' and the mailbox's, which
    /// the node's callsign must not take.
    private var radioSSIDs: [Int] {
        NodeCallsignChoices.taken(
            radios: settings.activeRadios.map { $0.resolvedCallsign(station: settings.myCallsign) },
            mailbox: mailboxCallsign, station: settings.myCallsign)
    }

    /// Why a packet service's switch is grayed out. The services are also
    /// kept off APRS radios where they run (RadioProfile.runsPacketServices);
    /// this makes the settings say so instead of offering a switch that
    /// would do nothing.
    private var aprsLockNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(.green)
            Text(settings.hasMultipleRadios
                 ? "Off: every radio is on an APRS channel, and a shared beacon channel is no place for it. A radio's channel is set on its page under Radios."
                 : "Off: your radio is on an APRS channel, and a shared beacon channel is no place for it. Its channel is set on its page under Radios.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Radios\u{2026}") {
                router.navigate(to: .radioChannel,
                                radio: settings.hasMultipleRadios ? nil : settings.activeRadios.first?.id)
            }
            .controlSize(.small)
        }
    }

    private func syncAdaptiveSettingsToSessionCoordinator() {
        guard let coordinator = SessionCoordinator.shared else { return }
        
        settings.axdpExtensionsEnabled = txAdaptiveSettings.axdpExtensionsEnabled
        settings.axdpAutoNegotiateCapabilities = txAdaptiveSettings.autoNegotiateCapabilities
        settings.axdpCompressionEnabled = txAdaptiveSettings.compressionEnabled
        settings.axdpCompressionAlgorithmRaw = txAdaptiveSettings.compressionAlgorithm.rawValue
        settings.axdpMaxDecompressedPayload = Int(txAdaptiveSettings.maxDecompressedPayload)
        settings.axdpShowDecodeDetails = txAdaptiveSettings.showAXDPDecodeDetails
        settings.ax25LinkTuning = AX25LinkTuning(txAdaptiveSettings)

        var updatedSettings = coordinator.globalAdaptiveSettings
        updatedSettings.axdpExtensionsEnabled = txAdaptiveSettings.axdpExtensionsEnabled
        updatedSettings.autoNegotiateCapabilities = txAdaptiveSettings.autoNegotiateCapabilities
        updatedSettings.compressionEnabled = txAdaptiveSettings.compressionEnabled
        updatedSettings.compressionAlgorithm = txAdaptiveSettings.compressionAlgorithm
        updatedSettings.maxDecompressedPayload = txAdaptiveSettings.maxDecompressedPayload
        updatedSettings.showAXDPDecodeDetails = txAdaptiveSettings.showAXDPDecodeDetails
        updatedSettings.paclen = txAdaptiveSettings.paclen
        updatedSettings.windowSize = txAdaptiveSettings.windowSize
        updatedSettings.maxRetries = txAdaptiveSettings.maxRetries
        updatedSettings.rtoMin = txAdaptiveSettings.rtoMin
        updatedSettings.rtoMax = txAdaptiveSettings.rtoMax
        coordinator.globalAdaptiveSettings = updatedSettings
        coordinator.syncSessionManagerConfigFromAdaptive()

        if txAdaptiveSettings.axdpExtensionsEnabled && txAdaptiveSettings.autoNegotiateCapabilities {
            coordinator.triggerCapabilityDiscoveryForAllConnected()
        }
    }
    
    private func resetStationAlert() {
        prompt = TextEntryPrompt(
            id: "resetStation",
            title: "Reset Station Parameters",
            message: "Enter the callsign whose learned link parameters should be discarded. The station starts again from the defaults and re-learns from what it observes.",
            placeholder: "N0CALL-1",
            confirmTitle: "Reset",
            uppercases: true) { call in
                SessionCoordinator.shared?.resetStationToDefault(callsign: call)
            }
    }

    @ViewBuilder
    private func adaptiveSettingRow(
        title: String,
        setting: AdaptiveSetting<Int>,
        onToggle: @escaping () -> Void,
        onValueChange: @escaping (Int) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Picker("Mode", selection: Binding(
                    get: { setting.mode },
                    set: { _ in onToggle() }
                )) {
                    Text("Auto").tag(AdaptiveMode.auto)
                    Text("Manual").tag(AdaptiveMode.manual)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .labelsHidden()
                
                if setting.mode == .auto {
                     Text("\(setting.currentAdaptive)")
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .frame(width: 50, alignment: .trailing)
                } else {
                     TextField("", value: Binding(
                         get: { setting.manualValue },
                         set: { onValueChange($0) }
                     ), format: .number)
                     .textFieldStyle(.roundedBorder)
                     .frame(width: 50)
                }
            }
        }
    }
}
