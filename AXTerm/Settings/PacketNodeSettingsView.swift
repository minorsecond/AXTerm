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
    @Environment(\.openWindow) private var openWindow
    
    @State private var txAdaptiveSettings = TxAdaptiveSettings()
    
    // File transfer list logic
    @State private var newAllowCallsign = ""
    @State private var newDenyCallsign = ""
    @State private var prompt: TextEntryPrompt?

    var body: some View {
        SettingsForm(landing: [.netRomNode, .ping, .linkLayer, .adaptiveTransmission,
                               .axdpProtocol, .fileTransfer],
                     radios: RadioLanding(section: .packetRadios) { radio in
                         RadioRoleSections.landing(for: radio, among: packetRadios, on: .packet)
                     }) {
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

                Toggle("Announce this station to the network", isOn: $settings.netRomAdvertiseSelf)
                    .onChange(of: settings.netRomAdvertiseSelf) { _, _ in applyNetRomSettings() }
                    .disabled(settings.allRadiosOnAPRS)
                    .help("Sends NODES broadcasts so neighbors learn this station exists and "
                          + "can route to it. Every node that hears one writes this station "
                          + "into its own routing table.")

                NetRomNodeIdentityRows(settings: settings, onChange: applyNetRomSettings)

                if settings.netRomAdvertiseSelf {
                    RunsOnRow(names: ServiceRadios.names(settings.activeRadios) { $0.mayAnnounceNode },
                              none: "No radio announces the node. Switch it on for a packet radio below.")
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

            packetRadioSections

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
                    RunsOnRow(names: ServiceRadios.names(settings.activeRadios) { $0.mayPing },
                              none: "No radio pings. Switch Ping stations on for a packet radio above.")
                        .help("A station is pinged on the radio that heard it. A radio with Ping "
                              + "stations off asks nobody, and stations heard only there are left "
                              + "alone. The hourly budget is the station's.")
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

            PreferencesSection("File Transfers", id: .fileTransfer) {
                Text("Control which stations can send you files without prompting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                // Keep the existing custom list components for now, but wrapped natively
                // Or standardized?
                // Let's use the fileTransferList helper function, but styling might need tweak.
                // We'll reimplement it inline for cleaner code or use helper.
                
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
                }
            }
        }
        .settingsPagePadding()
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
            ForEach(packetRadios) { radio in
                RadioPacketSections(radioID: radio.id, settings: settings, client: client)
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
