//
//  TransmissionSettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import SwiftUI

struct TransmissionSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    @EnvironmentObject var router: SettingsRouter
    
    @State private var txAdaptiveSettings = TxAdaptiveSettings()
    
    // File transfer list logic
    @State private var newAllowCallsign = ""
    @State private var newDenyCallsign = ""
    @State private var prompt: TextEntryPrompt?

    var body: some View {
        Form {
            // Link Layer Section (Deep Link Target from Adaptive Chip)
            PreferencesSection("Link Layer (AX.25 Connected Mode)", id: .linkLayer) {
                LinkLayerSettingsView(
                    settings: settings,
                    txAdaptiveSettings: $txAdaptiveSettings,
                    syncToCoordinator: syncAdaptiveSettingsToSessionCoordinator
                )
            }

            // Adaptive Transmission Section (Deep Link Target)
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
                    
                    Text("Parameters update automatically based on link quality.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    
                    // Default Values Grid
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Default Values")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        adaptiveSettingRow(
                            title: "Packet Length",
                            setting: txAdaptiveSettings.paclen,
                            onToggle: {
                                txAdaptiveSettings.paclen.mode = txAdaptiveSettings.paclen.mode == .auto ? .manual : .auto
                            },
                            onValueChange: { txAdaptiveSettings.paclen.manualValue = $0 }
                        )

                        adaptiveSettingRow(
                            title: "Window Size (K)",
                            setting: txAdaptiveSettings.windowSize,
                            onToggle: {
                                txAdaptiveSettings.windowSize.mode = txAdaptiveSettings.windowSize.mode == .auto ? .manual : .auto
                                syncAdaptiveSettingsToSessionCoordinator()
                            },
                            onValueChange: {
                                txAdaptiveSettings.windowSize.manualValue = $0
                                syncAdaptiveSettingsToSessionCoordinator()
                            }
                        )

                        adaptiveSettingRow(
                            title: "Max Retries (N2)",
                            setting: txAdaptiveSettings.maxRetries,
                            onToggle: {
                                txAdaptiveSettings.maxRetries.mode = txAdaptiveSettings.maxRetries.mode == .auto ? .manual : .auto
                                syncAdaptiveSettingsToSessionCoordinator()
                            },
                            onValueChange: {
                                txAdaptiveSettings.maxRetries.manualValue = $0
                                syncAdaptiveSettingsToSessionCoordinator()
                            }
                        )
                    }
                    .padding(.vertical, 4)
                    

                    
                    LabeledContent("Overrides") {
                        HStack {
                            Button("Reset Specific Station…") {
                                resetStationAlert()
                            }
                            
                            Button("Clear All Learned Data") {
                                if let coordinator = SessionCoordinator.shared {
                                    coordinator.clearAllLearned()
                                    txAdaptiveSettings = TxAdaptiveSettings()
                                    syncAdaptiveSettingsToSessionCoordinator()
                                }
                            }
                        }
                    }
                    .disabled(!settings.adaptiveTransmissionEnabled)
                }
            }

            PreferencesSection("NET/ROM Node", id: .netRomNode) {
                Text("AXTerm always listens to NET/ROM and learns routes from what it hears. "
                     + "These switches decide whether it also speaks — both change what other "
                     + "operators' nodes do, so both start off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Node alias") {
                    // Applied on commit, never per keystroke: this used to
                    // push a NODES broadcast on every character typed.
                    TextField("e.g. EPINOD", text: $settings.netRomNodeAlias)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .onSubmit { applyNetRomSettings() }
                }
                .help("Six characters, the mnemonic other nodes show beside this station's "
                      + "callsign. BPQ calls it NODEALIAS.")

                Toggle("Announce this station to the network", isOn: $settings.netRomAdvertiseSelf)
                    .onChange(of: settings.netRomAdvertiseSelf) { _, _ in applyNetRomSettings() }
                    .help("Sends NODES broadcasts so neighbours learn this station exists and "
                          + "can route to it. Every node that hears one writes this station "
                          + "into its own routing table.")

                if settings.netRomAdvertiseSelf {
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
                        Text("Set a node alias — announcing without one is legal but leaves "
                             + "a blank name in every neighbour's node list.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle("Carry other stations' traffic (transit routing)",
                       isOn: $settings.netRomForwarding)
                    .onChange(of: settings.netRomForwarding) { _, _ in applyNetRomSettings() }
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

            PreferencesSection("Beacon", id: .beacon) {
                Text("An unconnected announcement on a timer — what every other "
                     + "node on the channel sends, and how a station that has never "
                     + "heard this one learns it exists. Separate from the NET/ROM "
                     + "announcement above: this one is words, that one is a routing table.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Send a beacon", isOn: $settings.beaconEnabled)
                    .onChange(of: settings.beaconEnabled) { _, _ in applyNetRomSettings() }

                if settings.beaconEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        // Short prompts on purpose. In a settings row a
                        // TextField renders its prompt as a label beside the
                        // field as well as inside it, so a sentence-long
                        // placeholder wraps and the row grows to three lines.
                        TextField("Beacon text", text: $settings.beaconText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                            .onSubmit { applyNetRomSettings() }
                        Text("\(settings.beaconText.utf8.count) of "
                             + "\(BeaconPlan.maxTextBytes) bytes · sent to BEACON as "
                             + "an unconnected frame")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Via digipeaters") {
                        TextField("direct", text: $settings.beaconPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                            .onSubmit { applyNetRomSettings() }
                    }
                    .help("Up to \(BeaconPlan.maxDigis) hops, comma or space separated. "
                          + "A beacon is the one thing worth digipeating — its whole "
                          + "purpose is to reach stations that cannot hear this one "
                          + "directly. Each hop is another transmission on a shared "
                          + "channel, so two is usually plenty.")

                    durationRow(
                        "Send every",
                        value: $settings.beaconMinutes,
                        presets: [10, 15, 20, 30, 45, 60, 90, 120, 240],
                        label: Self.minutesLabel
                    )
                    .onChange(of: settings.beaconMinutes) { _, _ in applyNetRomSettings() }

                    if case let .failure(problem) = BeaconPlan.plan(
                        text: settings.beaconText, path: settings.beaconPath) {
                        Text(problem.operatorText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            Button("Send one now") {
                                SessionCoordinator.shared?.sendBeacon(settings)
                            }
                            Text("Goes out on the air immediately.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            PreferencesSection("Ping", id: .ping) {
                Text("Asks stations whether they can hear this one, using a frame "
                     + "any AX.25 station answers — no connection, nothing opened. "
                     + "An answer proves radio works both ways right now; it does "
                     + "not mean the station will route or accept a call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Ping stations automatically", isOn: $settings.pingEnabled)
                    .onChange(of: settings.pingEnabled) { _, _ in applyNetRomSettings() }

                if settings.pingEnabled {
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

                    durationRow(
                        "At least",
                        value: $settings.pingMinSecondsBetween,
                        presets: [30, 60, 90, 120, 180, 300, 600, 900],
                        label: { "\(Self.secondsLabel($0)) apart" }
                    )
                    .onChange(of: settings.pingMinSecondsBetween) { _, _ in applyNetRomSettings() }
                    .help("Between any two probes, whoever they are for.")

                    durationRow(
                        "Each station at most every",
                        value: $settings.pingStationCooldownMinutes,
                        presets: [10, 15, 20, 30, 45, 60, 120, 240, 480, 720],
                        label: Self.minutesLabel
                    )
                    .onChange(of: settings.pingStationCooldownMinutes) { _, _ in applyNetRomSettings() }
                    .help("Doubles each time a station does not answer, up to a day, "
                          + "so a silent station is asked less and less rather than more.")

                    Toggle("Also stations others are calling",
                           isOn: $settings.pingProbeStationsOthersCall)
                        .onChange(of: settings.pingProbeStationsOthersCall) { _, _ in applyNetRomSettings() }
                        .help("Stations this receiver has never heard, but that a "
                              + "neighbour was heard calling. Asks whether this station "
                              + "can reach what its neighbours reach — a longer shot, "
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
                }
            }

            PreferencesSection("AXDP Protocol", id: .axdpProtocol) {
                Toggle("Enable AXDP Extensions", isOn: $txAdaptiveSettings.axdpExtensionsEnabled)
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
        .formStyle(.grouped)
        .padding(20)
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
    
    // MARK: - Helpers
    
    // ... Copying existing helpers (seedAdaptiveSettings, syncAdaptiveSettingsToSessionCoordinator) ...
    // Since we are overwriting the file structure, we need to ensure we include these.
    
    private static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    // MARK: Duration menus

    /// A pop-up menu for a paced-transmission setting. These were Steppers,
    /// which made wide ranges click-torture — 120 s → 900 s of probe spacing
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

    private func syncAdaptiveSettingsToSessionCoordinator() {
        guard let coordinator = SessionCoordinator.shared else { return }
        
        settings.axdpExtensionsEnabled = txAdaptiveSettings.axdpExtensionsEnabled
        settings.axdpAutoNegotiateCapabilities = txAdaptiveSettings.autoNegotiateCapabilities
        settings.axdpCompressionEnabled = txAdaptiveSettings.compressionEnabled
        settings.axdpCompressionAlgorithmRaw = txAdaptiveSettings.compressionAlgorithm.rawValue
        settings.axdpMaxDecompressedPayload = Int(txAdaptiveSettings.maxDecompressedPayload)
        settings.axdpShowDecodeDetails = txAdaptiveSettings.showAXDPDecodeDetails

        var updatedSettings = coordinator.globalAdaptiveSettings
        updatedSettings.axdpExtensionsEnabled = txAdaptiveSettings.axdpExtensionsEnabled
        updatedSettings.autoNegotiateCapabilities = txAdaptiveSettings.autoNegotiateCapabilities
        updatedSettings.compressionEnabled = txAdaptiveSettings.compressionEnabled
        updatedSettings.compressionAlgorithm = txAdaptiveSettings.compressionAlgorithm
        updatedSettings.maxDecompressedPayload = txAdaptiveSettings.maxDecompressedPayload
        updatedSettings.showAXDPDecodeDetails = txAdaptiveSettings.showAXDPDecodeDetails
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
