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
    
    @ObservedObject var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            GeneralSettingsView(settings: settings, client: client)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)
            
            NotificationSettingsView(settings: settings, notificationManager: notificationManager)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(SettingsTab.notifications)

            NetworkSettingsView(settings: settings)
                .tabItem { Label("Network", systemImage: "network") }
                .tag(SettingsTab.network)
            
            TransmissionSettingsView(settings: settings, client: client, navigation: navigation)
                .tabItem { Label("Transmission", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(SettingsTab.transmission)
            
            AdvancedSettingsView(
                settings: settings,
                client: client,
                packetStore: packetStore,
                consoleStore: consoleStore,
                rawStore: rawStore,
                eventLogger: eventLogger
            )
            .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            .tag(SettingsTab.advanced)
        }
        .frame(width: 550, height: 600)
        .accessibilityIdentifier("settingsView")
    }
}

// MARK: - General Tab

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    
    @State private var launchAtLoginFeedback: String?
    @AppStorage(AppSettingsStore.runInMenuBarKey) private var runInMenuBar = AppSettingsStore.defaultRunInMenuBar
    
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
        }
        .formStyle(.grouped)
        .padding(20)
        .onChange(of: settings.launchAtLogin) { _, newValue in
            updateLaunchAtLogin(enabled: newValue)
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
            DispatchQueue.main.async {
                settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
}

// MARK: - Notifications Tab

struct NotificationSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    let notificationManager: NotificationAuthorizationManager
    
    @State private var notificationFeedback: String?
    
    var body: some View {
        Form {
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
            
            Section("Watch List") {
                VStack(alignment: .leading, spacing: 16) {
                    watchCallsignsSection
                    watchKeywordsSection
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
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
    
    private var watchCallsignsSection: some View {
        GroupBox("Callsigns") {
            VStack(alignment: .leading, spacing: 8) {
                if settings.watchCallsigns.isEmpty {
                    Text("No callsigns in watch list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
                
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
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
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

                Button("Add Callsign…") {
                    let alert = NSAlert()
                    alert.messageText = "Add Watch Callsign"
                    alert.informativeText = "Enter a callsign to watch for."
                    alert.addButton(withTitle: "Add")
                    alert.addButton(withTitle: "Cancel")
                    
                    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                    input.placeholderString = "N0CALL"
                    alert.accessoryView = input
                    alert.window.initialFirstResponder = input
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        let call = input.stringValue.trimmingCharacters(in: .whitespaces)
                        if !call.isEmpty {
                            settings.watchCallsigns.append(CallsignValidator.normalize(call))
                        }
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .padding(.top, 4)
        }
    }

    private var watchKeywordsSection: some View {
        GroupBox("Keywords") {
            VStack(alignment: .leading, spacing: 8) {
                if settings.watchKeywords.isEmpty {
                    Text("No keywords in watch list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
                
                ForEach(settings.watchKeywords.indices, id: \.self) { index in
                    HStack {
                        TextField("Keyword", text: bindingForWatchKeyword(at: index))
                            .textFieldStyle(.roundedBorder)

                        Button {
                            guard settings.watchKeywords.indices.contains(index) else { return }
                            settings.watchKeywords.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove keyword")
                    }
                }

                Button("Add Keyword…") {
                    let alert = NSAlert()
                    alert.messageText = "Add Watch Keyword"
                    alert.informativeText = "Enter a keyword to watch for."
                    alert.addButton(withTitle: "Add")
                    alert.addButton(withTitle: "Cancel")
                    
                    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                    input.placeholderString = "Emergency"
                    alert.accessoryView = input
                    alert.window.initialFirstResponder = input
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        let keyword = input.stringValue.trimmingCharacters(in: .whitespaces)
                        if !keyword.isEmpty {
                            settings.watchKeywords.append(keyword)
                        }
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .padding(.top, 4)
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
}

// MARK: - Network Tab

struct NetworkSettingsView: View {
    @ObservedObject var settings: AppSettingsStore

    private let retentionStep = 1_000

    var body: some View {
        Form {
            Section("Routes") {
                Toggle("Hide expired routes", isOn: $settings.hideExpiredRoutes)

                Text("When enabled, routes with 0% freshness are hidden from the Routes page. All routes are still kept in the database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Stale Policy") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Mode", selection: $settings.stalePolicyMode) {
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
                            
                            Stepper(
                                "",
                                value: $settings.adaptiveStaleMissedBroadcasts,
                                in: AppSettingsStore.minAdaptiveStaleMissedBroadcasts...AppSettingsStore.maxAdaptiveStaleMissedBroadcasts
                            )
                            .labelsHidden()
                        }

                        Text("Number of missed broadcasts before a route is considered stale.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Global TTL
                    HStack {
                        Text(settings.stalePolicyMode == "adaptive" ? "Fallback stale threshold" : "Stale threshold")
                        Spacer()
                        Text("\(settings.globalStaleTTLHours) hour\(settings.globalStaleTTLHours == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField("", value: $settings.globalStaleTTLHours, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)

                        Stepper("", value: $settings.globalStaleTTLHours, in: AppSettingsStore.minGlobalStaleTTLHours...AppSettingsStore.maxGlobalStaleTTLHours)
                            .labelsHidden()
                    }
                }
            }
            
            Section("Thresholds & Retention") {
                // Neighbor activity decay TTL
                HStack {
                    Text("Neighbor stale threshold")
                    Spacer()
                    Text("\(settings.neighborStaleTTLHours) h")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField("", value: $settings.neighborStaleTTLHours, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: $settings.neighborStaleTTLHours, in: AppSettingsStore.minNeighborStaleTTLHours...AppSettingsStore.maxNeighborStaleTTLHours)
                        .labelsHidden()
                }
                
                // Link stat activity decay TTL
                HStack {
                    Text("Link quality stale threshold")
                    Spacer()
                    Text("\(settings.linkStatStaleTTLHours) h")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField("", value: $settings.linkStatStaleTTLHours, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: $settings.linkStatStaleTTLHours, in: AppSettingsStore.minLinkStatStaleTTLHours...AppSettingsStore.maxLinkStatStaleTTLHours)
                        .labelsHidden()
                }
                
                Divider()
                
                // Retention period
                HStack {
                    Text("Route retention period")
                    Spacer()
                    Text("\(settings.routeRetentionDays) days")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField("", value: $settings.routeRetentionDays, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: $settings.routeRetentionDays, in: AppSettingsStore.minRouteRetentionDays...AppSettingsStore.maxRouteRetentionDays, step: 7)
                        .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Transmission Tab

struct TransmissionSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    @ObservedObject var navigation: SettingsNavigation
    
    @State private var txAdaptiveSettings = TxAdaptiveSettings()
    @State private var adaptiveResetCallsign = ""
    
    // File transfer list logic
    @State private var newAllowCallsign = ""
    @State private var newDenyCallsign = ""

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Adaptive Transmission") {
                    // Anchor for deep linking
                    Color.clear.frame(height: 0).id(SettingsSection.adaptiveTransmission)
                    
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
                                .foregroundStyle(.green)
                            Text("Learning from session and network – params update automatically.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    
                    VStack(alignment: .leading, spacing: 10) {
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
                    
                    Divider()
                    
                    Button("Clear all learned settings") {
                        if let coordinator = SessionCoordinator.shared {
                            coordinator.clearAllLearned()
                            txAdaptiveSettings = TxAdaptiveSettings()
                            syncAdaptiveSettingsToSessionCoordinator()
                        }
                    }
                    .disabled(!settings.adaptiveTransmissionEnabled)
                    
                    HStack {
                        Button("Reset Specific Station…") {
                            let alert = NSAlert()
                            alert.messageText = "Reset Station Parameters"
                            alert.informativeText = "Enter the callsign of the station to reset learned parameters for."
                            alert.addButton(withTitle: "Reset")
                            alert.addButton(withTitle: "Cancel")
                            
                            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                            input.placeholderString = "N0CALL-1"
                            alert.accessoryView = input
                            alert.window.initialFirstResponder = input
                            
                            if alert.runModal() == .alertFirstButtonReturn {
                                let call = input.stringValue.trimmingCharacters(in: .whitespaces)
                                if !call.isEmpty {
                                    SessionCoordinator.shared?.resetStationToDefault(callsign: call)
                                }
                            }
                        }
                        .disabled(!settings.adaptiveTransmissionEnabled)
                    }
                    .help("Reset learned parameters for a specific station")
                }


                Section("AXDP Protocol") {
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
                    
                    Toggle("Show AXDP decode details in console", isOn: $txAdaptiveSettings.showAXDPDecodeDetails)
                         .onChange(of: txAdaptiveSettings.showAXDPDecodeDetails) { _, _ in
                             syncAdaptiveSettingsToSessionCoordinator()
                         }
                    
                    Text("AXDP extensions provide compression, capability negotiation, and reliable transfers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("File Transfers") {
                    Text("Control which stations can send you files without prompting.")
                        .font(.caption).foregroundStyle(.secondary)
                    
                    GroupBox("Auto-Accept") {
                        fileTransferList(
                             items: settings.allowedFileTransferCallsigns,
                             newItem: $newAllowCallsign,
                             icon: "checkmark.circle.fill",
                             color: .green,
                             onAdd: addToAllowList,
                             onRemove: { settings.removeCallsignFromFileTransferAllowlist($0) }
                        )
                    }
                    
                    GroupBox("Auto-Deny") {
                        fileTransferList(
                             items: settings.deniedFileTransferCallsigns,
                             newItem: $newDenyCallsign,
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
                handleDeepLink(proxy: proxy)
            }
            .onChange(of: navigation.targetSection) { _, _ in
                handleDeepLink(proxy: proxy)
            }
        }
    }
    
    private func handleDeepLink(proxy: ScrollViewProxy) {
        if let section = navigation.targetSection {
            // Check if we are already on this tab? Yes, SettingsView handles tab switching.
            // Just scroll.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    proxy.scrollTo(section, anchor: .top)
                }
                // Clear target section after scrolling so we don't keep jumping if user scrolls away and back?
                // Or maybe keep it? Better to clear it so subsequent navigations work but simple scrolling doesn't lock.
                // navigation.targetSection = nil // Actually let's not clear it immediately, maybe upon next open.
                // But if we don't clear, onChange won't fire if set to same value.
                // SettingsNavigation.openSettings sets it.
                // We should clear it to allow re-triggering?
                // Actually, the simplest is to wrap in a async and then clear.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if navigation.targetSection == section {
                        navigation.targetSection = nil
                    }
                }
            }
        }
    }
    
    private func seedAdaptiveSettings() {
        // Seed adaptive settings from persisted app settings
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
    
    @ViewBuilder
    private func adaptiveSettingRow(
        title: String,
        setting: AdaptiveSetting<Int>,
        onToggle: @escaping () -> Void,
        onValueChange: @escaping (Int) -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            
            // Mode Selector
            Picker("", selection: Binding(
                get: { setting.mode },
                set: { _ in onToggle() }
            )) {
                Text("Auto").tag(AdaptiveMode.auto)
                Text("Manual").tag(AdaptiveMode.manual)
            }
            .pickerStyle(.segmented)
            .frame(width: 100)
            
            // Value display/editor
            if setting.mode == .auto {
                 Text("\(setting.currentAdaptive)")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
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
    
    @ViewBuilder
    private func fileTransferList(
        items: [String],
        newItem: Binding<String>, // Kept for signature compatibility if needed, but unused in new UI
        icon: String,
        color: Color,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { callsign in
                HStack {
                    Image(systemName: icon).foregroundStyle(color).font(.caption)
                    Text(callsign).monospaced()
                    Spacer()
                    Button { onRemove(callsign) } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }
            }
            
            if items.isEmpty {
                Text("No stations listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            
            Button("Add Station…") {
                let alert = NSAlert()
                alert.messageText = "Add Station"
                alert.informativeText = "Enter the callsign to add to this list."
                alert.addButton(withTitle: "Add")
                alert.addButton(withTitle: "Cancel")
                
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                input.placeholderString = "N0CALL"
                alert.accessoryView = input
                alert.window.initialFirstResponder = input
                
                if alert.runModal() == .alertFirstButtonReturn {
                    newItem.wrappedValue = input.stringValue
                    onAdd()
                }
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .padding(.top, 4)
        }
    }
    
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
}

// MARK: - Advanced Tab

struct AdvancedSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    let packetStore: PacketStore?
    let consoleStore: ConsoleStore?
    let rawStore: RawStore?
    let eventLogger: EventLogger?

    @State private var showingClearConfirmation = false
    @State private var clearFeedback: String?
    @State private var retentionStep = 1000

    var body: some View {
        Form {
            Section("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Event retention")
                        Spacer()
                        Text("\(settings.eventRetentionLimit) events")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        GuardedRetentionInput(
                            value: $settings.eventRetentionLimit,
                            min: AppSettingsStore.minLogRetention,
                            max: AppSettingsStore.maxLogRetention,
                            step: retentionStep
                        )
                        .accessibilityLabel("Event retention")
                    }

                    Text("Controls how many application usage events are kept in the Diagnostics tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HistorySettingsView(
                settings: settings,
                onClearHistory: clearHistory,
                clearFeedback: clearFeedback
            )
            
            Section("Sentry") {
                Toggle("Enable Sentry reporting", isOn: $settings.sentryEnabled)
                Toggle("Send connection details", isOn: $settings.sentrySendConnectionDetails)
                    .disabled(!settings.sentryEnabled)
                Toggle("Send packet contents", isOn: $settings.sentrySendPacketContents)
                    .disabled(!settings.sentryEnabled)
                
                Text(SentryConfiguration.load(settings: settings).dsn == nil ? "DSN: Not configured" : "DSN: Configured")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onChange(of: settings.sentryEnabled) { _, _ in SentryManager.shared.startIfEnabled(settings: settings) }
        .onChange(of: settings.sentrySendPacketContents) { _, _ in SentryManager.shared.startIfEnabled(settings: settings) }
        .onChange(of: settings.sentrySendConnectionDetails) { _, _ in SentryManager.shared.startIfEnabled(settings: settings) }
    }
    
    private func clearHistory() {
        clearFeedback = nil
        DispatchQueue.global(qos: .utility).async { [packetStore, consoleStore, rawStore] in
            do {
                try packetStore?.deleteAll()
                try consoleStore?.deleteAll()
                try rawStore?.deleteAll()
            } catch { return }
            
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
}

// Keep Preview and HistorySettingsView (unchanged)
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

struct HistorySettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @State private var showingClearConfirmation = false
    
    // Pass clear closure from parent
    var onClearHistory: () -> Void
    var clearFeedback: String?
    
    private let retentionStep = 1_000
    
    @State private var pendingRetentionChange: AppSettingsStore.HistoryRetentionDuration?
    @State private var showingRetentionWarning = false

    private var retentionBinding: Binding<AppSettingsStore.HistoryRetentionDuration> {
        Binding(
            get: { settings.retentionDuration },
            set: { newDuration in
                
                let newPacketLimit = newDuration.packetLimit
                let currentPacketLimit = settings.retentionLimit
                
                // If new limit is LOWER than current, warn user
                // (Unless switching to Custom, which retains current values initially, so no data loss immediately)
                if newDuration != .custom && newPacketLimit < currentPacketLimit {
                    pendingRetentionChange = newDuration
                    showingRetentionWarning = true
                } else {
                    settings.retentionDuration = newDuration
                }
            }
        )
    }

    var body: some View {
        Section {
            Toggle("Persist history", isOn: $settings.persistHistory)
            
            if settings.persistHistory {
                VStack(alignment: .leading, spacing: 12) {
                    // Primary Control
                    HStack {
                        Text("Keep history for:")
                        Spacer()
                        Picker("", selection: retentionBinding) {
                            ForEach(AppSettingsStore.HistoryRetentionDuration.allCases) { duration in
                                Text(duration.rawValue).tag(duration)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 150)
                    }
                    
                    // Status Line
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text(storageEstimateText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    // Custom Limits Section
                    if settings.retentionDuration == .custom {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Custom Limits")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            
                            // Packet Retention
                            advancedRetentionRow(
                                title: "Packet Limit",
                                value: $settings.retentionLimit,
                                suffix: "packets",
                                min: AppSettingsStore.minRetention
                            )
                            
                            // Console Retention
                            advancedRetentionRow(
                                title: "Console Limit",
                                value: $settings.consoleRetentionLimit,
                                suffix: "lines",
                                min: AppSettingsStore.minLogRetention
                            )
                            
                            // Raw Retention
                            advancedRetentionRow(
                                title: "Raw Limit",
                                value: $settings.rawRetentionLimit,
                                suffix: "chunks",
                                min: AppSettingsStore.minLogRetention
                            )
                        }
                        .padding(.top, 8)
                        .transition(.opacity)
                    }
                }
                
                // Clear History Action
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
                .padding(.top, 8)
            }
        } header: {
            Text("History")
        }
        .confirmationDialog(
            "Clear all stored packet history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                onClearHistory()
            }
        } message: {
            Text("This removes persisted packets, console history, and raw history. Live data will continue to appear.")
        }
        .confirmationDialog(
             "Reduce History Retention?",
             isPresented: $showingRetentionWarning,
             titleVisibility: .visible
         ) {
             Button("Reduce Retention", role: .destructive) {
                 if let newDuration = pendingRetentionChange {
                     settings.retentionDuration = newDuration
                 }
             }
             Button("Cancel", role: .cancel) {
                 pendingRetentionChange = nil
             }
         } message: {
             if let newDuration = pendingRetentionChange {
                 Text("You are reducing retention to \(newDuration.rawValue). Older history exceeding this limit will be permanently deleted.")
             } else {
                 Text("This action will permanently delete older history.")
             }
         }
    }
    
    // MARK: - Helpers
    
    private var storageEstimateText: String {
        if settings.retentionDuration == .forever {
            return "History will grow indefinitely until disk is full."
        }
        
        let packetBytes = settings.retentionLimit * AppSettingsStore.estimatedBytesPerPacket
        let consoleBytes = settings.consoleRetentionLimit * AppSettingsStore.estimatedBytesPerConsoleLine
        let rawBytes = settings.rawRetentionLimit * AppSettingsStore.estimatedBytesPerRawChunk
        
        let totalBytes = Double(packetBytes + consoleBytes + rawBytes)
        let mb = totalBytes / 1_000_000.0
        
        let sizeStr = String(format: "%.1f MB", mb)
        
        // Coverage estimate
        if settings.retentionDuration == .custom {
            // Estimate based on packet limit
            let days = settings.retentionLimit / AppSettingsStore.estimatedPacketsPerDay
            let durationStr = "~" + (days < 1 ? "<1 day" : "\(days) days")
            return "Max usage: \(sizeStr) • Estimated coverage: \(durationStr)"
        }
        
        // Use simpler text if it's a fixed duration
        return "Max usage: \(sizeStr)"
    }
    
    @ViewBuilder
    private func advancedRetentionRow(title: String, value: Binding<Int>, suffix: String, min: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                if value.wrappedValue == Int.max {
                    Text("Unlimited")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(value.wrappedValue) \(suffix)")
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack {
                // We use our GuardedRetentionInput here for safety, logic still holds
                // (It accepts Int.max but stepper might be weird with it, so careful)
                GuardedRetentionInput(
                    value: value,
                    min: min,
                    max: Int.max, // Allow up to max
                    step: retentionStep
                )
            }
        }
    }
}
