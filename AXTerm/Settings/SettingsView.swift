//
//  SettingsView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    let packetStore: PacketStore?
    let consoleStore: ConsoleStore?
    let rawStore: RawStore?
    let eventLogger: EventLogger?
    let notificationManager: NotificationAuthorizationManager

    @State private var showingClearConfirmation = false
    @State private var clearFeedback: String?
    @State private var notificationFeedback: String?
    @State private var launchAtLoginFeedback: String?
    /// Uses @AppStorage directly to avoid feedback loops with MenuBarExtra scene updates.
    @AppStorage(AppSettingsStore.runInMenuBarKey) private var runInMenuBar = AppSettingsStore.defaultRunInMenuBar

    /// Adaptive transmission settings
    @State private var txAdaptiveSettings = TxAdaptiveSettings()

    /// Callsign to add to "use default config" (per-station reset)
    @State private var adaptiveResetCallsign = ""

    private let retentionStep = 1_000

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Host", text: $settings.host)
                    .textFieldStyle(.roundedBorder)

                TextField("Port", text: $settings.port)
                    .textFieldStyle(.roundedBorder)

                Toggle("Auto-connect on launch", isOn: $settings.autoConnectOnLaunch)

                if shouldSuggestReconnect {
                    Text("Reconnect to apply host/port changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Identity") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("My Callsign", text: Binding(
                        get: { settings.myCallsign },
                        set: { settings.myCallsign = $0 }
                    ))
                        .textFieldStyle(.roundedBorder)

                    Text("Used to highlight your node in the graph.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !settings.myCallsign.isEmpty && !CallsignValidator.isValid(settings.myCallsign) {
                        Text("Enter a valid callsign (e.g. N0CALL or N0CALL-7).")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Watch List") {
                VStack(alignment: .leading, spacing: 16) {
                    watchCallsignsSection
                    watchKeywordsSection
                }
            }

            Section("History") {
                Toggle("Persist history", isOn: $settings.persistHistory)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Packet retention")
                        Spacer()
                        Text("\(settings.retentionLimit) packets")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.retentionLimit,
                            format: .number
                        )
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Retention limit")

                        Stepper(
                            "",
                            value: $settings.retentionLimit,
                            in: AppSettingsStore.minRetention...AppSettingsStore.maxRetention,
                            step: retentionStep
                        )
                        .labelsHidden()
                    }

                    Text("Adjust how many packets are retained on disk. Older packets are pruned in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.persistHistory)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Console retention")
                        Spacer()
                        Text("\(settings.consoleRetentionLimit) lines")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.consoleRetentionLimit,
                            format: .number
                        )
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Console retention")

                        Stepper(
                            "",
                            value: $settings.consoleRetentionLimit,
                            in: AppSettingsStore.minLogRetention...AppSettingsStore.maxLogRetention,
                            step: retentionStep
                        )
                        .labelsHidden()
                    }

                    Text("Console history includes system messages and packet summaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.persistHistory)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Raw retention")
                        Spacer()
                        Text("\(settings.rawRetentionLimit) chunks")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.rawRetentionLimit,
                            format: .number
                        )
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Raw retention")

                        Stepper(
                            "",
                            value: $settings.rawRetentionLimit,
                            in: AppSettingsStore.minLogRetention...AppSettingsStore.maxLogRetention,
                            step: retentionStep
                        )
                        .labelsHidden()
                    }

                    Text("Raw history stores KISS byte streams and parse errors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.persistHistory)

                HStack {
                    Button("Clear History…") {
                        showingClearConfirmation = true
                    }

                    if let feedback = clearFeedback {
                        Text(feedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Event retention")
                        Spacer()
                        Text("\(settings.eventRetentionLimit) events")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.eventRetentionLimit,
                            format: .number
                        )
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Event retention")

                        Stepper(
                            "",
                            value: $settings.eventRetentionLimit,
                            in: AppSettingsStore.minLogRetention...AppSettingsStore.maxLogRetention,
                            step: retentionStep
                        )
                        .labelsHidden()
                    }

                    Text("Diagnostics entries are retained separately from packet history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Display") {
                Toggle("Console day separators", isOn: $settings.showConsoleDaySeparators)
                Toggle("Raw day separators", isOn: $settings.showRawDaySeparators)
            }

            Section("Menu Bar") {
                Toggle("Run in menu bar", isOn: $runInMenuBar)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if let feedback = launchAtLoginFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Toggle("Notify on watch hits", isOn: $settings.notifyOnWatchHits)
                Toggle("Play sound", isOn: $settings.notifyPlaySound)
                Toggle("Only notify when AXTerm is not frontmost", isOn: $settings.notifyOnlyWhenInactive)

                HStack {
                    Button("Enable Notifications…") {
                        requestNotificationAuthorization()
                    }

                    Button("Test Notification") {
                        notificationManager.sendTestNotification()
                    }

                    if let feedback = notificationFeedback {
                        Text(feedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Routes") {
                Toggle("Hide expired routes", isOn: $settings.hideExpiredRoutes)

                Text("When enabled, routes with 0% freshness are hidden from the Routes page. All routes are still kept in the database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Stale policy", selection: $settings.stalePolicyMode) {
                        Text("Adaptive (per-origin)").tag("adaptive")
                        Text("Global (fixed TTL)").tag("global")
                    }
                    .pickerStyle(.segmented)

                    if settings.stalePolicyMode == "adaptive" {
                        Text("Routes are considered stale after missing multiple expected broadcasts from their origin. Each origin's broadcast interval is tracked automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Missed broadcasts")
                            Spacer()
                            Text("\(settings.adaptiveStaleMissedBroadcasts)")
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            TextField(
                                "",
                                value: $settings.adaptiveStaleMissedBroadcasts,
                                format: .number
                            )
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Missed broadcasts threshold")

                            Stepper(
                                "",
                                value: $settings.adaptiveStaleMissedBroadcasts,
                                in: AppSettingsStore.minAdaptiveStaleMissedBroadcasts...AppSettingsStore.maxAdaptiveStaleMissedBroadcasts
                            )
                            .labelsHidden()
                        }

                        Text("Number of missed broadcasts before a route is considered stale. Lower values detect staleness faster but may cause more false positives.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Global TTL is always shown - it's the fallback for adaptive and the primary for global mode
                    HStack {
                        Text(settings.stalePolicyMode == "adaptive" ? "Fallback stale threshold" : "Stale threshold")
                        Spacer()
                        Text("\(settings.globalStaleTTLHours) hour\(settings.globalStaleTTLHours == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.globalStaleTTLHours,
                            format: .number
                        )
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Stale threshold hours")

                        Stepper(
                            "",
                            value: $settings.globalStaleTTLHours,
                            in: AppSettingsStore.minGlobalStaleTTLHours...AppSettingsStore.maxGlobalStaleTTLHours
                        )
                        .labelsHidden()
                    }

                    if settings.stalePolicyMode == "adaptive" {
                        Text("Used for origins with no broadcast interval data yet. Once an origin's pattern is learned, their adaptive threshold takes over.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Routes older than this are considered stale. Affects freshness display and filtering.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Neighbor activity decay TTL
                    HStack {
                        Text("Neighbor stale threshold")
                        Spacer()
                        Text("\(settings.neighborStaleTTLHours) hour\(settings.neighborStaleTTLHours == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.neighborStaleTTLHours,
                            format: .number
                        )
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Neighbor stale threshold hours")

                        Stepper(
                            "",
                            value: $settings.neighborStaleTTLHours,
                            in: AppSettingsStore.minNeighborStaleTTLHours...AppSettingsStore.maxNeighborStaleTTLHours
                        )
                        .labelsHidden()
                    }

                    Text("Neighbors are considered stale after this long without any packet activity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Link stat activity decay TTL
                    HStack {
                        Text("Link quality stale threshold")
                        Spacer()
                        Text("\(settings.linkStatStaleTTLHours) hour\(settings.linkStatStaleTTLHours == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.linkStatStaleTTLHours,
                            format: .number
                        )
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Link quality stale threshold hours")

                        Stepper(
                            "",
                            value: $settings.linkStatStaleTTLHours,
                            in: AppSettingsStore.minLinkStatStaleTTLHours...AppSettingsStore.maxLinkStatStaleTTLHours
                        )
                        .labelsHidden()
                    }

                    Text("Link quality entries are considered stale after this long without any activity on that link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Retention period")
                        Spacer()
                        Text("\(settings.routeRetentionDays) days")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: $settings.routeRetentionDays,
                            format: .number
                        )
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Route retention days")

                        Stepper(
                            "",
                            value: $settings.routeRetentionDays,
                            in: AppSettingsStore.minRouteRetentionDays...AppSettingsStore.maxRouteRetentionDays,
                            step: 7
                        )
                        .labelsHidden()
                    }

                    Text("Routes older than this are permanently deleted on app startup. Keeps database size manageable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sentry") {
                Toggle("Enable Sentry reporting", isOn: $settings.sentryEnabled)

                Toggle("Send connection details (host/port tags)", isOn: $settings.sentrySendConnectionDetails)
                    .disabled(!settings.sentryEnabled)

                Toggle("Send packet contents", isOn: $settings.sentrySendPacketContents)
                    .disabled(!settings.sentryEnabled)

                Text("Packet contents are off by default. When off, events include only minimal packet metadata (frame type, byte count, from/to, via count).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let config = SentryConfiguration.load(settings: settings)
                Text(config.dsn == nil ? "DSN: Not configured" : "DSN: Configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transmission") {
                transmissionSettingsSection
            }

            Section("File Transfers") {
                fileTransferPermissionsSection
            }
        }
        .accessibilityIdentifier("settingsView")
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            // Seed adaptive settings from persisted app settings so that AXDP
            // toggles reflect the configured transmission behavior across launches.
            txAdaptiveSettings.axdpExtensionsEnabled = settings.axdpExtensionsEnabled
            txAdaptiveSettings.autoNegotiateCapabilities = settings.axdpAutoNegotiateCapabilities
            txAdaptiveSettings.compressionEnabled = settings.axdpCompressionEnabled
            if let algo = AXDPCompression.Algorithm(rawValue: settings.axdpCompressionAlgorithmRaw) {
                txAdaptiveSettings.compressionAlgorithm = algo
            }
            txAdaptiveSettings.maxDecompressedPayload = UInt32(settings.axdpMaxDecompressedPayload)
            txAdaptiveSettings.showAXDPDecodeDetails = settings.axdpShowDecodeDetails

            // Also push into the live session coordinator on first open.
            syncAdaptiveSettingsToSessionCoordinator()
            if let coordinator = SessionCoordinator.shared {
                coordinator.adaptiveTransmissionEnabled = settings.adaptiveTransmissionEnabled
                coordinator.syncSessionManagerConfigFromAdaptive()
            }
        }
        .confirmationDialog(
            "Clear all stored packet history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                clearHistory()
            }
        } message: {
            Text("This removes persisted packets, console history, and raw history. Live data will continue to appear.")
        }
        .onChange(of: settings.retentionLimit) { _, newValue in
            eventLogger?.log(
                level: .info,
                category: .settings,
                message: "Packet retention set to \(newValue)",
                metadata: ["retention": "\(newValue)"]
            )
        }
        .onChange(of: settings.consoleRetentionLimit) { _, newValue in
            eventLogger?.log(
                level: .info,
                category: .settings,
                message: "Console retention set to \(newValue)",
                metadata: ["retention": "\(newValue)"]
            )
        }
        .onChange(of: settings.rawRetentionLimit) { _, newValue in
            eventLogger?.log(
                level: .info,
                category: .settings,
                message: "Raw retention set to \(newValue)",
                metadata: ["retention": "\(newValue)"]
            )
        }
        .onChange(of: settings.eventRetentionLimit) { _, newValue in
            eventLogger?.log(
                level: .info,
                category: .settings,
                message: "Event retention set to \(newValue)",
                metadata: ["retention": "\(newValue)"]
            )
        }
        .onChange(of: settings.launchAtLogin) { _, newValue in
            updateLaunchAtLogin(enabled: newValue)
        }
        .onChange(of: settings.sentryEnabled) { _, _ in
            SentryManager.shared.startIfEnabled(settings: settings)
        }
        .onChange(of: settings.sentrySendPacketContents) { _, _ in
            SentryManager.shared.startIfEnabled(settings: settings)
        }
        .onChange(of: settings.sentrySendConnectionDetails) { _, _ in
            SentryManager.shared.startIfEnabled(settings: settings)
        }
    }

    private var shouldSuggestReconnect: Bool {
        guard client.status == .connected else { return false }
        if let connectedHost = client.connectedHost, connectedHost != settings.host {
            return true
        }
        if let connectedPort = client.connectedPort, connectedPort != settings.portValue {
            return true
        }
        return false
    }

    private func clearHistory() {
        clearFeedback = nil
        DispatchQueue.global(qos: .utility).async { [packetStore, consoleStore, rawStore] in
            do {
                try packetStore?.deleteAll()
                try consoleStore?.deleteAll()
                try rawStore?.deleteAll()
            } catch {
                return
            }
            DispatchQueue.main.async {
                client.clearPackets()
                client.clearStations()
                client.clearConsole(clearPersisted: false)
                client.clearRaw(clearPersisted: false)
                clearFeedback = "Cleared"
                eventLogger?.log(level: .info, category: .ui, message: "Cleared history", metadata: nil)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    clearFeedback = nil
                }
            }
        }
    }

    private func requestNotificationAuthorization() {
        notificationFeedback = nil
        Task {
            let granted = await notificationManager.requestAuthorization()
            await MainActor.run {
                notificationFeedback = granted ? "Enabled" : "Not allowed"
            }
        }
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        launchAtLoginFeedback = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginFeedback = "Launch at login failed"
            // Avoid publishing changes synchronously from within the `.onChange` transaction.
            DispatchQueue.main.async {
                settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var watchCallsignsSection: some View {
        GroupBox("Callsigns") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(settings.watchCallsigns.indices, id: \.self) { index in
                    let value = settings.watchCallsigns.indices.contains(index) ? settings.watchCallsigns[index] : ""
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Callsign", text: bindingForWatchCallsign(at: index))
                                .textFieldStyle(.roundedBorder)

                            Button {
                                guard settings.watchCallsigns.indices.contains(index) else { return }
                                settings.watchCallsigns.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove callsign")
                        }

                        if !value.isEmpty && !CallsignValidator.isValid(value) {
                            Text("Invalid callsign.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Button("Add Callsign") {
                    settings.watchCallsigns.append("")
                }
            }
            .padding(.top, 4)
        }
    }

    private var watchKeywordsSection: some View {
        GroupBox("Keywords") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(settings.watchKeywords.indices, id: \.self) { index in
                    HStack {
                        TextField("Keyword", text: bindingForWatchKeyword(at: index))
                            .textFieldStyle(.roundedBorder)

                        Button {
                            guard settings.watchKeywords.indices.contains(index) else { return }
                            settings.watchKeywords.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove keyword")
                    }
                }

                Button("Add Keyword") {
                    settings.watchKeywords.append("")
                }
            }
            .padding(.top, 4)
        }
    }

    private func bindingForWatchCallsign(at index: Int) -> Binding<String> {
        Binding(
            get: { settings.watchCallsigns.indices.contains(index) ? settings.watchCallsigns[index] : "" },
            set: { newValue in
                guard settings.watchCallsigns.indices.contains(index) else { return }
                settings.watchCallsigns[index] = CallsignValidator.normalize(newValue)
            }
        )
    }

    private func bindingForWatchKeyword(at index: Int) -> Binding<String> {
        Binding(
            get: { settings.watchKeywords.indices.contains(index) ? settings.watchKeywords[index] : "" },
            set: { newValue in
                guard settings.watchKeywords.indices.contains(index) else { return }
                settings.watchKeywords[index] = newValue
            }
        )
    }

    // MARK: - Transmission Settings Section

    @ViewBuilder
    private var transmissionSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Adaptive transmission: enable/disable and clear
            GroupBox("Adaptive Transmission") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable adaptive transmission", isOn: Binding(
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
                        HStack(spacing: 6) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text("Learning from session and network – params update automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Clear all learned settings") {
                        if let coordinator = SessionCoordinator.shared {
                            coordinator.clearAllLearned()
                            txAdaptiveSettings = TxAdaptiveSettings()
                            syncAdaptiveSettingsToSessionCoordinator()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.adaptiveTransmissionEnabled)

                    HStack(spacing: 8) {
                        TextField("Callsign (e.g. N0CALL-2)", text: $adaptiveResetCallsign)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                        Button("Reset adaptive for this station") {
                            let call = adaptiveResetCallsign.trimmingCharacters(in: .whitespaces)
                            guard !call.isEmpty else { return }
                            SessionCoordinator.shared?.resetStationToDefault(callsign: call)
                            adaptiveResetCallsign = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(adaptiveResetCallsign.trimmingCharacters(in: .whitespaces).isEmpty || !settings.adaptiveTransmissionEnabled)
                    }
                    .help("Use default transmission params for this station only.")

                    if let coordinator = SessionCoordinator.shared, !coordinator.useDefaultConfigForDestinations.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Stations using default config:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(coordinator.useDefaultConfigForDestinations).sorted(), id: \.self) { callsign in
                                HStack {
                                    Text(callsign)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Button("Use global again") {
                                        coordinator.useGlobalAdaptiveForStation(callsign: callsign)
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }

            // Traffic Shaping (window size, RTO, retries apply to both messaging and file transfer)
            GroupBox("Traffic Shaping") {
                VStack(alignment: .leading, spacing: 12) {
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
                .padding(.top, 4)
            }

            // AXDP Protocol
            GroupBox("AXDP Protocol") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable AXDP Extensions", isOn: $txAdaptiveSettings.axdpExtensionsEnabled)
                        .onChange(of: txAdaptiveSettings.axdpExtensionsEnabled) { _, _ in
                            syncAdaptiveSettingsToSessionCoordinator()
                        }

                    Toggle("Auto-negotiate Capabilities", isOn: $txAdaptiveSettings.autoNegotiateCapabilities)
                        .disabled(!txAdaptiveSettings.axdpExtensionsEnabled)
                        .onChange(of: txAdaptiveSettings.autoNegotiateCapabilities) { _, _ in
                            syncAdaptiveSettingsToSessionCoordinator()
                        }

                    Toggle("Enable Compression", isOn: $txAdaptiveSettings.compressionEnabled)
                        .disabled(!txAdaptiveSettings.axdpExtensionsEnabled)
                        .onChange(of: txAdaptiveSettings.compressionEnabled) { _, _ in
                            syncAdaptiveSettingsToSessionCoordinator()
                        }

                    if txAdaptiveSettings.compressionEnabled && txAdaptiveSettings.axdpExtensionsEnabled {
                        Picker("Compression Algorithm", selection: $txAdaptiveSettings.compressionAlgorithm) {
                            Text("LZ4 (fast)").tag(AXDPCompression.Algorithm.lz4)
                            Text("Deflate (better ratio)").tag(AXDPCompression.Algorithm.deflate)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: txAdaptiveSettings.compressionAlgorithm) { _, _ in
                            syncAdaptiveSettingsToSessionCoordinator()
                        }
                    }

                    Text("AXDP extensions provide compression, capability negotiation, and reliable transfers. They are backward-compatible with stations that don't support them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            // Debug
            GroupBox("Debug") {
                Toggle("Show AXDP decode details in console", isOn: $txAdaptiveSettings.showAXDPDecodeDetails)
                    .onChange(of: txAdaptiveSettings.showAXDPDecodeDetails) { _, _ in
                        syncAdaptiveSettingsToSessionCoordinator()
                    }
            }
        }
    }

    /// Propagate AXDP-related adaptive settings into the live session coordinator so
    /// that negotiation and compression behavior follow the user's configuration.
    private func syncAdaptiveSettingsToSessionCoordinator() {
        print("[SettingsView] syncAdaptiveSettingsToSessionCoordinator called")
        print("[SettingsView] SessionCoordinator.shared = \(SessionCoordinator.shared != nil ? "exists" : "nil")")
        print("[SettingsView] txAdaptiveSettings.axdpExtensionsEnabled = \(txAdaptiveSettings.axdpExtensionsEnabled)")
        print("[SettingsView] txAdaptiveSettings.autoNegotiateCapabilities = \(txAdaptiveSettings.autoNegotiateCapabilities)")
        
        guard let coordinator = SessionCoordinator.shared else {
            print("[SettingsView] ERROR: SessionCoordinator.shared is nil!")
            return
        }
        
        // Persist into app settings for durability
        settings.axdpExtensionsEnabled = txAdaptiveSettings.axdpExtensionsEnabled
        settings.axdpAutoNegotiateCapabilities = txAdaptiveSettings.autoNegotiateCapabilities
        settings.axdpCompressionEnabled = txAdaptiveSettings.compressionEnabled
        settings.axdpCompressionAlgorithmRaw = txAdaptiveSettings.compressionAlgorithm.rawValue
        settings.axdpMaxDecompressedPayload = Int(txAdaptiveSettings.maxDecompressedPayload)
        settings.axdpShowDecodeDetails = txAdaptiveSettings.showAXDPDecodeDetails

        // Push into live session coordinator so new sessions use updated behavior
        // CRITICAL: TxAdaptiveSettings is a struct (value type), so we must assign the entire struct,
        // not mutate individual properties (which would mutate a copy, not the original)
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

        print("[SettingsView] Updated coordinator settings:")
        print("[SettingsView]   coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = \(coordinator.globalAdaptiveSettings.axdpExtensionsEnabled)")
        print("[SettingsView]   coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = \(coordinator.globalAdaptiveSettings.autoNegotiateCapabilities)")
        print("[SettingsView]   coordinator.connectedSessions.count = \(coordinator.connectedSessions.count)")

        // If auto-negotiation is now enabled while sessions are already
        // connected, proactively trigger capability discovery for those
        // initiator sessions so the user doesn't have to reconnect manually.
        if txAdaptiveSettings.axdpExtensionsEnabled &&
            txAdaptiveSettings.autoNegotiateCapabilities {
            print("[SettingsView] Calling triggerCapabilityDiscoveryForConnectedInitiators()")
            coordinator.triggerCapabilityDiscoveryForConnectedInitiators()
        } else {
            print("[SettingsView] NOT calling triggerCapabilityDiscoveryForConnectedInitiators() - conditions not met")
        }
    }

    // MARK: - File Transfer Permissions Section

    @ViewBuilder
    private var fileTransferPermissionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Control which stations can send you files without prompting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Auto-Accept List
            GroupBox("Auto-Accept") {
                VStack(alignment: .leading, spacing: 10) {
                    if settings.allowedFileTransferCallsigns.isEmpty {
                        Text("No callsigns configured")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(settings.allowedFileTransferCallsigns, id: \.self) { callsign in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)

                                Text(callsign)
                                    .font(.system(.body, design: .monospaced))

                                Spacer()

                                Button {
                                    settings.removeCallsignFromFileTransferAllowlist(callsign)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from auto-accept list")
                            }
                        }
                    }

                    HStack {
                        TextField("Add callsign", text: $newAllowCallsign)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                addToAllowList()
                            }

                        Button("Add") {
                            addToAllowList()
                        }
                        .disabled(newAllowCallsign.isEmpty || !CallsignValidator.isValid(newAllowCallsign))
                    }

                    Text("Files from these callsigns are accepted automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            // Auto-Deny List
            GroupBox("Auto-Deny") {
                VStack(alignment: .leading, spacing: 10) {
                    if settings.deniedFileTransferCallsigns.isEmpty {
                        Text("No callsigns configured")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(settings.deniedFileTransferCallsigns, id: \.self) { callsign in
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)

                                Text(callsign)
                                    .font(.system(.body, design: .monospaced))

                                Spacer()

                                Button {
                                    settings.removeCallsignFromFileTransferDenylist(callsign)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from auto-deny list")
                            }
                        }
                    }

                    HStack {
                        TextField("Add callsign", text: $newDenyCallsign)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                addToDenyList()
                            }

                        Button("Add") {
                            addToDenyList()
                        }
                        .disabled(newDenyCallsign.isEmpty || !CallsignValidator.isValid(newDenyCallsign))
                    }

                    Text("Files from these callsigns are declined automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            // Clear All Button
            if !settings.allowedFileTransferCallsigns.isEmpty || !settings.deniedFileTransferCallsigns.isEmpty {
                Button("Clear All Permissions") {
                    settings.allowedFileTransferCallsigns.removeAll()
                    settings.deniedFileTransferCallsigns.removeAll()
                }
                .foregroundStyle(.red)
            }
        }
    }

    @State private var newAllowCallsign = ""
    @State private var newDenyCallsign = ""

    private func addToAllowList() {
        guard !newAllowCallsign.isEmpty, CallsignValidator.isValid(newAllowCallsign) else { return }
        settings.allowCallsignForFileTransfer(newAllowCallsign)
        newAllowCallsign = ""
    }

    private func addToDenyList() {
        guard !newDenyCallsign.isEmpty, CallsignValidator.isValid(newDenyCallsign) else { return }
        settings.denyCallsignForFileTransfer(newDenyCallsign)
        newDenyCallsign = ""
    }

    @ViewBuilder
    private func adaptiveSettingRow(
        title: String,
        setting: AdaptiveSetting<Int>,
        onToggle: @escaping () -> Void,
        onValueChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Picker("", selection: Binding(
                    get: { setting.mode },
                    set: { _ in onToggle() }
                )) {
                    Text("Auto").tag(AdaptiveMode.auto)
                    Text("Manual").tag(AdaptiveMode.manual)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            if setting.mode == .auto {
                HStack {
                    Text("Current: \(setting.currentAdaptive)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let reason = setting.adaptiveReason {
                        Text("(\(reason))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                if let range = setting.range {
                    HStack {
                        Text("Value:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("", value: Binding(
                            get: { setting.manualValue },
                            set: { onValueChange($0) }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)

                        Stepper("", value: Binding(
                            get: { setting.manualValue },
                            set: { onValueChange($0) }
                        ), in: range)
                        .labelsHidden()

                        Spacer()

                        Text("(\(range.lowerBound)-\(range.upperBound))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView(
        settings: AppSettingsStore(),
        client: PacketEngine(settings: AppSettingsStore()),
        packetStore: nil,
        consoleStore: nil,
        rawStore: nil,
        eventLogger: nil,
        notificationManager: NotificationAuthorizationManager()
    )
}
