//
//  ContentView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

nonisolated enum NavigationItem: String, Hashable, CaseIterable {
    case terminal = "Terminal"
    case packets = "Packets"
    case routes = "Routes"
    case analytics = "Analytics"
    case mail = "Mail"
    //case raw = "Raw"
}

/// Which tier of network evidence produced an adaptive sample.
nonisolated enum AdaptiveAggregateScope: Equatable, Sendable {
    /// Links involving my own station — ground truth about my RF paths.
    case localLinks
    /// Third-party traffic on the shared channel — weaker, condition-level evidence.
    case channelWide

    var sourceLabel: String {
        switch self {
        case .localLinks: return "network"
        case .channelWide: return "network (channel-wide)"
        }
    }
}

struct ContentView: View {
    @StateObject private var client: PacketEngine
    @ObservedObject private var settings: AppSettingsStore
    @ObservedObject private var inspectionRouter: PacketInspectionRouter
    @ObservedObject private var winlinkContext: WinlinkContext
    private let inspectionCoordinator = PacketInspectionCoordinator()

    /// Session coordinator for connected-mode sessions - survives tab switches
    /// Uses SessionCoordinator.shared so Settings can update the same instance
    @StateObject private var sessionCoordinator: SessionCoordinator
    @StateObject private var connectCoordinator = ConnectCoordinator()

    @Environment(\.openSettings) private var openSettings

    @State private var selectedNav: NavigationItem = .terminal
    @StateObject private var searchModel = AppToolbarSearchModel()
    @State private var filters = PacketFilters()

    @State private var selection = Set<Packet.ID>()
    @State private var inspectorSelection: PacketInspectorSelection?
    @FocusState private var isSearchFocused: Bool
    @State private var didLoadPacketsHistory = false
    @State private var didLoadConsoleHistory = false
    @State private var didLoadRawHistory = false
    @State private var selectionMutationScheduler = SelectionMutationScheduler()
    @StateObject private var analyticsViewModel: AnalyticsDashboardViewModel
    @State private var lastTapTimes: [String: Date] = [:]

    nonisolated static func stationDefaultConnectMode() -> ConnectBarMode {
        .ax25
    }

    init(client: PacketEngine, settings: AppSettingsStore, inspectionRouter: PacketInspectionRouter, winlinkContext: WinlinkContext) {
        _client = StateObject(wrappedValue: client)
        _settings = ObservedObject(wrappedValue: settings)
        _inspectionRouter = ObservedObject(wrappedValue: inspectionRouter)
        _winlinkContext = ObservedObject(wrappedValue: winlinkContext)
        // Initialize analytics view model with settings store for persistence
        _analyticsViewModel = StateObject(wrappedValue: AnalyticsDashboardViewModel(
            settingsStore: settings,
            netRomIntegration: client.netRomIntegration,
            databaseAggregationProvider: { interval, bucket, calendar, options in
                await client.aggregateAnalytics(
                    in: interval,
                    bucket: bucket,
                    calendar: calendar,
                    options: options
                )
            },
            captureEventsProvider: { interval in
                guard let events = await client.captureConnectionEvents(around: interval) else { return nil }
                let isLive = await MainActor.run { client.status == .connected }
                return (events.connects, events.disconnects, isLive)
            },
            timeframePacketsProvider: { interval in
                await client.loadPackets(in: interval)
            }
        ))
        // Get or create the shared session coordinator so Settings can update the same instance.
        // Only seed @Published properties on a new coordinator — re-seeding an existing shared
        // instance during view init triggers "Publishing changes from within view updates".
        let coordinator: SessionCoordinator
        if let existing = SessionCoordinator.shared {
            coordinator = existing
        } else {
            coordinator = SessionCoordinator()
            // Seed AXDP / transmission adaptive settings from persisted settings
            var adaptive = TxAdaptiveSettings()
            adaptive.axdpExtensionsEnabled = settings.axdpExtensionsEnabled
            adaptive.autoNegotiateCapabilities = settings.axdpAutoNegotiateCapabilities
            adaptive.compressionEnabled = settings.axdpCompressionEnabled
            if let algo = AXDPCompression.Algorithm(rawValue: settings.axdpCompressionAlgorithmRaw) {
                adaptive.compressionAlgorithm = algo
            }
            adaptive.maxDecompressedPayload = UInt32(settings.axdpMaxDecompressedPayload)
            adaptive.showAXDPDecodeDetails = settings.axdpShowDecodeDetails
            coordinator.globalAdaptiveSettings = adaptive
            coordinator.adaptiveTransmissionEnabled = settings.adaptiveTransmissionEnabled
            coordinator.syncSessionManagerConfigFromAdaptive()
            if settings.adaptiveTransmissionEnabled {
                TxLog.adaptiveEnabled()
            } else {
                TxLog.adaptiveDisabled()
            }
        }
        coordinator.localCallsign = settings.myCallsign
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: client)
        _sessionCoordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .accessibilityIdentifier("mainWindowRoot")
        .searchable(text: $searchModel.query, prompt: searchPlaceholder)
        .searchFocused($isSearchFocused)
        .toolbar {
            toolbarContent
        }
        .overlay(alignment: .topLeading) {
            if TestModeConfiguration.shared.isTestMode {
                Text(connectionMessage)
                    .font(.caption)
                    .opacity(0.01)
                    .accessibilityIdentifier("connectionStatus")
                    .accessibilityLabel(connectionMessage)
                    .accessibilityHidden(false)
                    .frame(width: 1, height: 1)
            }
        }
        .sheet(item: $inspectorSelection) { selection in
            if let packet = client.packet(with: selection.id) {
                PacketInspectorView(
                    packet: packet,
                    isPinned: client.isPinned(packet.id),
                    onTogglePin: { client.togglePin(for: packet.id) },
                    onFilterStation: { call in
                        client.selectedStationCall = call
                    },
                    onClose: {
                        SentryManager.shared.addBreadcrumb(category: "ui.inspector", message: "Inspector closed", level: .info, data: ["packetID": selection.id.uuidString])
                        inspectorSelection = nil
                    }
                )
            } else {
                Text("Packet unavailable")
                    .padding()
            }
        }
        .task {
            guard !didLoadConsoleHistory else { return }
            didLoadConsoleHistory = true
            SentryManager.shared.addBreadcrumb(category: "app.lifecycle", message: "Main UI ready", level: .info, data: nil)
            // Load console history for the default Terminal view
            client.loadPersistedConsole()
        }
        .task {
            // Warm analytics caches in the background so first tab-open is fast.
            analyticsViewModel.prewarmIfNeeded(with: client.packets)
        }
        .onReceive(client.$packets) { packets in
            analyticsViewModel.prewarmIfNeeded(with: packets)
        }
        .task {
            // Feed network-wide link quality into adaptive settings periodically (don't overwhelm, don't be too conservative).
            // Skip when active sessions exist — the session learner provides direct ground truth
            // (actual ACK/retry tracking) which is far more accurate than inferred routing table metrics.
            //
            // Warm-up: link stats restore from the snapshot within the first
            // second of launch, so the first sample is attempted immediately
            // and retried every second until one lands (or the warm-up budget
            // runs out) — a fixed 30 s first sleep left the popover claiming
            // "waiting for evidence" while the answer sat ready in memory.
            var didSampleEver = false
            var attempts = 0
            while true {
                attempts += 1
                if let coordinator = SessionCoordinator.shared,
                   coordinator.adaptiveTransmissionEnabled,
                   !coordinator.hasActiveSessions,
                   let integration = client.netRomIntegration,
                   let sample = Self.aggregateLinkQualityForAdaptive(
                       integration.exportLinkStats(),
                       localCallsign: coordinator.localCallsign
                   ) {
                    coordinator.applyLinkQualitySample(lossRate: sample.lossRate, etx: sample.etx, srtt: nil, source: sample.scope.sourceLabel)
                    didSampleEver = true
                }
                let delay = Self.networkSampleDelaySeconds(didSampleEver: didSampleEver, attempts: attempts)
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
        .task(id: selectedNav) {
            switch selectedNav {
            case .terminal:
                // Terminal view loads console for session output
                guard !didLoadConsoleHistory else { return }
                didLoadConsoleHistory = true
                await Task.yield()
                client.loadPersistedConsole()
            case .packets:
                // Load packets when navigating to Packets view
                guard !didLoadPacketsHistory else { return }
                didLoadPacketsHistory = true
                await Task.yield()
                client.loadPersistedPackets()
            //case .raw:
            //    guard !didLoadRawHistory else { return }
            //    didLoadRawHistory = true
            //    await Task.yield()
            //    client.loadPersistedRaw()
            case .analytics:
                return
            case .routes:
                // Routes view handles its own data loading
                return
            case .mail:
                // Mail view loads its own data from the Winlink store
                return
            }
        }
        .task(id: inspectionRouter.requestedPacketID) {
            guard let packetID = inspectionRouter.requestedPacketID else { return }
            await openInspectorFromRouterRequest(packetID: packetID)
        }
        .focusedValue(\.searchFocus, SearchFocusAction { isSearchFocused = true })
        .focusedValue(\.toggleConnection, ToggleConnectionAction { toggleConnection() })
        .focusedValue(\.inspectPacket, InspectPacketAction { inspectSelectedPacket() })
        .focusedValue(\.selectNavigation, SelectNavigationAction { item in
            selectedNav = item
        })
        .onChange(of: settings.myCallsign) { _, newValue in
            sessionCoordinator.localCallsign = newValue
        }
        .onChange(of: selectedNav) { _, newValue in
            syncSearchScope(for: newValue)
            syncConnectContext(for: newValue)
        }
        .onAppear {
            SettingsRouter.shared.openAction = { openSettings() }
            connectCoordinator.navigateToTerminal = {
                selectedNav = .terminal
                connectCoordinator.activeContext = .terminal
            }
            syncConnectContext(for: selectedNav)
        }
    }

    private func syncSearchScope(for item: NavigationItem) {
        switch item {
        case .terminal: searchModel.scope = .terminal
        case .packets: searchModel.scope = .packets
        case .routes: searchModel.scope = .routes
        case .analytics: searchModel.scope = .analytics
        case .mail: searchModel.scope = .terminal  // Mail has its own in-pane search
        //case .raw: searchModel.scope = .terminal // Fallback or new scope if needed
        }
    }

    private func syncConnectContext(for item: NavigationItem) {
        switch item {
        case .terminal:
            connectCoordinator.activeContext = .terminal
        case .routes:
            connectCoordinator.activeContext = .routes
        case .packets, .analytics, .mail:
            connectCoordinator.activeContext = .unknown
        }
    }

    private var connectionMessage: String {
        switch client.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Not connected"
        case .failed: return "Connection failed"
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedNav) {
            Section("Views") {
                ForEach(NavigationItem.allCases, id: \.self) { item in
                    Label(item.rawValue, systemImage: iconFor(item))
                        .badge(item == .mail && winlinkContext.unreadCount > 0
                               ? winlinkContext.unreadCount : 0)
                        .tag(item)
                        .accessibilityIdentifier("nav-\(item.rawValue.lowercased())")
                }
            }

            Section("Stations (\(client.stations.count))") {
                // "All" option
                HStack {
                    Text("All Packets")
                        .fontWeight(client.selectedStationCall == nil ? .semibold : .regular)
                    Spacer()
                    if client.selectedStationCall == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    Group {
                        if client.selectedStationCall == nil {
                            Color.accentColor.opacity(0.15)
                        } else {
                            Color.clear
                        }
                    }
                )
                .cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture {
                    client.selectedStationCall = nil
                }

                if client.stations.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 16))
                        Text("No stations heard")
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
                } else {
                    // Precompute per-render constants outside the ForEach.
                    // bestRouteTo() calls currentRoutes() which sorts and allocates the full route
                    // array — calling it once per station row was O(stations × routes log routes).
                    // hasRoute(to:) is an O(1) dict lookup; connectedCallsigns avoids an O(sessions)
                    // scan per row.
                    let integration = client.netRomIntegration
                    let defaultStationMode = Self.stationDefaultConnectMode()
                    let connectedCallsigns = Set(
                        sessionCoordinator.connectedSessions
                            .map { CallsignValidator.normalize($0.remoteAddress.display) }
                    )
                    ForEach(client.stations) { station in
                        let normalizedCall = CallsignValidator.normalize(station.call)
                        let stationHasNetRomRoute = integration?.hasRoute(to: normalizedCall) ?? false
                        let preferredMode = connectCoordinator.preferredMode(
                            for: station.call,
                            hasNetRomRoute: stationHasNetRomRoute
                        )
                        let isConnectedStation = connectedCallsigns.contains(normalizedCall)

                        StationRowView(
                            station: station,
                            isSelected: client.selectedStationCall == station.call,
                            isConnected: isConnectedStation,
                            capability: client.capabilityStore.capabilities(for: station.call)
                        )
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Connect") {
                                issueStationConnectRequest(
                                    stationCall: station.call,
                                    mode: defaultStationMode,
                                    executeImmediately: true
                                )
                            }
                            Button("Connect via AX.25") {
                                issueStationConnectRequest(
                                    stationCall: station.call,
                                    mode: .ax25,
                                    executeImmediately: true
                                )
                            }
                            Button("Connect via NET/ROM") {
                                issueStationConnectRequest(
                                    stationCall: station.call,
                                    mode: .netrom,
                                    executeImmediately: true
                                )
                            }
                            .disabled(!stationHasNetRomRoute)

                            Menu("Routing Options") {
                                Button("Prefill Preferred Route") {
                                    issueStationConnectRequest(
                                        stationCall: station.call,
                                        mode: preferredMode,
                                        executeImmediately: false
                                    )
                                }
                                Button("Prefill AX.25 Draft") {
                                    issueStationConnectRequest(
                                        stationCall: station.call,
                                        mode: .ax25,
                                        executeImmediately: false
                                    )
                                }
                                Button("Prefill NET/ROM Draft") {
                                    issueStationConnectRequest(
                                        stationCall: station.call,
                                        mode: .netrom,
                                        executeImmediately: false
                                    )
                                }
                                .disabled(!stationHasNetRomRoute)
                            }
                            Divider()
                            Button("Copy Callsign") {
                                ClipboardWriter.copy(CallsignValidator.normalize(station.call))
                            }
                        }
                        .onTapGesture {
                            let now = Date()
                            let previousTap = lastTapTimes[station.call] ?? .distantPast
                            let isDoubleClick = now.timeIntervalSince(previousTap) < NSEvent.doubleClickInterval
                            lastTapTimes[station.call] = now

                            // Always apply the selection immediately (zero lag)
                            client.selectedStationCall = station.call

                            if isDoubleClick {
                                issueStationConnectRequest(
                                    stationCall: station.call,
                                    mode: defaultStationMode,
                                    executeImmediately: true
                                )
                            } else {
                                let capturedCall = station.call
                                let capturedMode = defaultStationMode
                                // Double-async ensures the checkmark renders before connect-bar cascade begins
                                DispatchQueue.main.async {
                                    DispatchQueue.main.async {
                                        issueStationConnectRequest(
                                            stationCall: capturedCall,
                                            mode: capturedMode,
                                            executeImmediately: false
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    private func iconFor(_ item: NavigationItem) -> String {
        switch item {
        case .terminal: return "terminal"
        case .packets: return "list.bullet.rectangle"
        case .routes: return "arrow.triangle.branch"
        case .analytics: return "chart.bar"
        case .mail: return "envelope"
        //case .raw: return "doc.text"
        }
    }

    private func issueStationConnectRequest(stationCall: String, mode: ConnectBarMode, executeImmediately: Bool) {
        connectCoordinator.activeContext = .stations
        let normalized = CallsignValidator.normalize(stationCall)
        let intent: ConnectIntent
        switch mode {
        case .netrom:
            intent = ConnectIntent(
                kind: .netrom(nextHopOverride: nil),
                to: normalized,
                sourceContext: .stations,
                suggestedRoutePreview: nil,
                validationErrors: [],
                routeHint: nil,
                note: nil
            )
        case .ax25ViaDigi:
            intent = ConnectIntent(
                kind: .ax25ViaDigis([]),
                to: normalized,
                sourceContext: .stations,
                suggestedRoutePreview: nil,
                validationErrors: [],
                routeHint: nil,
                note: nil
            )
        case .ax25:
            intent = ConnectIntent(
                kind: .ax25Direct,
                to: normalized,
                sourceContext: .stations,
                suggestedRoutePreview: nil,
                validationErrors: [],
                routeHint: nil,
                note: nil
            )
        }

        connectCoordinator.requestConnect(
            ConnectRequest(intent: intent, mode: mode, executeImmediately: executeImmediately)
        )
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            if let err = client.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(err)
                    Spacer()
                }
                .foregroundStyle(.red)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.1))
            }

            switch selectedNav {
            case .terminal:
                TerminalView(
                    client: client,
                    settings: settings,
                    sessionCoordinator: sessionCoordinator,
                    connectCoordinator: connectCoordinator,
                    searchModel: searchModel,
                    locationService: winlinkContext.locationService
                )
            case .packets:
                packetsView
            case .routes:
                NetRomRoutesView(
                    integration: client.netRomIntegration,
                    packetEngine: client,
                    settings: settings,
                    connectCoordinator: connectCoordinator
                )
            case .analytics:
                AnalyticsDashboardView(packetEngine: client, settings: settings, viewModel: analyticsViewModel, connectCoordinator: connectCoordinator)
            case .mail:
                WinlinkMailView(
                    context: winlinkContext,
                    appSettings: settings,
                    sessionCoordinator: sessionCoordinator,
                    client: client
                )
            //case .raw:
            //    RawView(
            //        chunks: client.rawChunks,
            //        showDaySeparators: settings.showRawDaySeparators,
            //        clearedAt: $settings.rawClearedAt
            //    )
            }
        }
    }

    private var packetsView: some View {
        let rows = filteredPackets

        return PacketTableView(
            packets: rows,
            selection: $selection,
            onInspectSelection: {
                inspectSelectedPacket()
            },
            onCopyInfo: { packet in
                ClipboardWriter.copy(packet.infoText ?? "")
            },
            onCopyRawHex: { packet in
                ClipboardWriter.copy(PayloadFormatter.hexString(packet.rawAx25))
            }
        )
        .onChange(of: selection) { _, newSelection in
            guard newSelection.isEmpty else { return }
            deferSelectionMutation {
                SentryManager.shared.addBreadcrumb(category: "ui.selection", message: "Selection cleared", level: .info, data: nil)
                inspectorSelection = nil
            }
        }
        .onChange(of: searchModel.query) { _, _ in scheduleSelectionSync(with: rows) }
        .onChange(of: filters) { _, _ in scheduleSelectionSync(with: rows) }
        .onChange(of: client.selectedStationCall) { _, _ in scheduleSelectionSync(with: rows) }
        .onChange(of: client.packets) { _, _ in scheduleSelectionSync(with: rows) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if sessionCoordinator.adaptiveTransmissionEnabled, client.status == .connected {
                AdaptiveToolbarControl(
                    store: sessionCoordinator.adaptiveStatusStore,
                    onOpenAnalytics: {
                        selectedNav = .analytics
                    }
                )
            }
            if selectedNav == .packets {
                if client.packetsClearedAt != nil {
                    Button {
                        client.restorePackets()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Undo Clear Packets")
                } else {
                    Button {
                        client.clearPackets()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Clear Packet Log")
                }
            }
            tncToolbarMenu
        }
    }

    /// TNC transport status menu — clickable pill with connect/disconnect actions
    @ViewBuilder
    private var tncToolbarMenu: some View {
        HStack(spacing: 8) {
            // TX / RX Blinkenlights
            HStack(spacing: 2) {
                Blinkenlight(color: .green, trigger: client.lastRxTime)
                    .help("RX Activity")
                Blinkenlight(color: .red, trigger: client.lastTxTime)
                    .help("TX Activity")
            }
            
            // Connection status dot
            Circle()
                .fill(tncLedColor)
                .frame(width: 8, height: 8)
                .help("TNC connection status")

            Menu {
                switch client.status {
                case .connected:
                    Button("Disconnect TNC", role: .destructive) {
                        client.disconnect(reason: "user disconnect")
                    }
                    Button("Reconnect TNC") {
                        reconnectToTNC()
                    }
                case .connecting:
                    Button("Cancel") {
                        client.disconnect(reason: "user cancelled connect")
                    }
                case .disconnected, .failed:
                    Button("Connect TNC") {
                        client.connectUsingSettings()
                    }
                    Button("Reconnect TNC") {
                        reconnectToTNC()
                    }
                }

                Divider()

                Section("Endpoint") {
                    Text(connectionEndpointLabel)
                }

                if let lastError = client.lastError {
                    Section("Last error") {
                        Text(lastError)
                    }
                }

                Divider()

                Button("TNC Settings\u{2026}") {
                    SettingsRouter.shared.navigate(to: .network)
                }
            } label: {
                Text(tncCapsuleLabel)
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .help("TNC connection actions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        )
    }
    
    private struct Blinkenlight: View {
        let color: Color
        let trigger: Date
        @State private var isActive = false
        
        var body: some View {
            Circle()
                .fill(isActive ? color : Color.gray.opacity(0.2))
                .frame(width: 5, height: 5)
                .animation(isActive ? .easeIn(duration: 0.05) : .easeOut(duration: 0.4), value: isActive)
                .onChange(of: trigger) { _, _ in
                    isActive = true
                    // Turn off after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        isActive = false
                    }
                }
        }
    }

    private var tncLedColor: Color {
        switch client.status {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    // MARK: - Computed Properties

    private var searchPlaceholder: String {
        switch selectedNav {
        case .terminal:
            return "Filter terminal output"
        case .packets:
            return "Search packets"
        default:
            return "Search"
        }
    }
    
    private var tncCapsuleLabel: String {
        switch client.status {
        case .connected:
            let host = client.connectedHost ?? settings.host
            return "TNC: \(host)"
        case .connecting:
            return "TNC Connecting\u{2026}"
        case .disconnected:
            return "TNC Disconnected"
        case .failed:
            return "TNC Failed"
        }
    }

    private var connectionEndpointLabel: String {
        if settings.isSerialTransport {
            let device = settings.serialDevicePath.isEmpty
                ? "No device"
                : (settings.serialDevicePath as NSString).lastPathComponent
            return "KISS Serial @ \(device)"
        }
        return "KISS TCP @ \(connectionHostPort)"
    }

    private var connectionHostPort: String {
        let hostValue = client.connectedHost ?? settings.host
        let portValue = client.connectedPort.map(String.init) ?? String(settings.port)
        return "\(hostValue):\(portValue)"
    }

    private func toggleConnection() {
        switch client.status {
        case .connected, .connecting:
            client.disconnect(reason: "user toggle connection")
        case .disconnected, .failed:
            client.connectUsingSettings()
        }
    }

    private func reconnectToTNC() {
        client.disconnect(reason: "user reconnect")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            client.connectUsingSettings()
        }
    }

    private func inspectSelectedPacket() {
        guard let selection = inspectionCoordinator.inspectSelectedPacket(
            selection: selection,
            packets: filteredPackets
        ) else {
            return
        }
        deferSelectionMutation {
            SentryManager.shared.addBreadcrumb(category: "ui.inspector", message: "Inspector opened", level: .info, data: ["packetID": selection.id.uuidString])
            inspectorSelection = selection
        }
    }

    private var filteredPackets: [Packet] {
        client.filteredPackets(
            search: searchModel.query,
            filters: filters,
            stationCall: client.selectedStationCall
        )
    }

    private func syncSelection(with packets: [Packet]) {
        let nextSelection = PacketSelectionResolver.filteredSelection(selection, for: packets)
        if nextSelection != selection {
            selection = nextSelection
        }

        if selection.isEmpty {
            inspectorSelection = nil
        }
    }

    @MainActor
    private func openInspectorFromRouterRequest(packetID: Packet.ID) async {
        // Ensure this happens outside of SwiftUI's view-update transaction.
        await Task.yield()

        SentryManager.shared.addBreadcrumb(
            category: "ui.routing",
            message: "Apply inspector route",
            level: .info,
            data: ["packetID": packetID.uuidString]
        )

        if inspectorSelection?.id != packetID {
            inspectorSelection = PacketInspectorSelection(id: packetID)
        }
        if selection != [packetID] {
            selection = [packetID]
        }
        inspectionRouter.consumePacketRequest()
    }

    private func scheduleSelectionSync(with packets: [Packet]) {
        selectionMutationScheduler.schedule {
            syncSelection(with: packets)
        }
    }

    private func deferSelectionMutation(_ mutation: @MainActor @escaping () -> Void) {
        selectionMutationScheduler.schedule {
            mutation()
        }
    }

    /// Aggregate link stats into (lossRate, etx) for adaptive settings. Uses only links with enough observations.
    /// When `localCallsign` is provided, only links involving the local station are considered,
    /// preventing other stations' poor links from dragging adaptive settings to overly conservative values.
    /// Sampling cadence for the idle network learner: retry every second
    /// during launch warm-up until the first sample lands, then settle to the
    /// steady 30 s rhythm. The warm-up budget caps the fast polling when the
    /// gates legitimately have nothing to offer yet.
    nonisolated static func networkSampleDelaySeconds(didSampleEver: Bool, attempts: Int) -> UInt64 {
        let warmupAttempts = 30
        if didSampleEver || attempts >= warmupAttempts {
            return 30
        }
        return 1
    }

    /// Tiered network evidence for adaptive seeding: links involving MY station
    /// are ground truth about my own RF paths and always win — but a
    /// passive-monitoring station may have none (or only rows that fail the
    /// evidence gates), and the shared channel's third-party traffic is still
    /// real evidence about the conditions my next transmission will face.
    /// Per spec 4.2 both tiers feed the EWMAs only, never streaks/probes.
    nonisolated static func aggregateLinkQualityForAdaptive(_ records: [LinkStatRecord], localCallsign: String? = nil) -> (lossRate: Double, etx: Double, scope: AdaptiveAggregateScope)? {
        let minObs = 5

        func aggregate(_ subset: [LinkStatRecord]) -> (lossRate: Double, etx: Double)? {
            // A row qualifies on real forward evidence alone. Requiring BOTH
            // df and dr excluded every one-way transfer: the data sender's row
            // fills df, the acker's row fills dr, and neither passes — so a
            // channel full of healthy BBS traffic read as "no evidence".
            // An unmeasured reverse direction uses the symmetry prior (dr = df),
            // the standard ETX assumption for an unmeasured return path. A
            // MEASURED bad dr still counts against the row.
            let valid = subset.filter { r in
                r.observationCount >= minObs
                    && (r.dfEstimate ?? 0) > 0.05
            }
            guard !valid.isEmpty else { return nil }
            let etxValues = valid.map { r -> Double in
                let df = r.dfEstimate!
                let dr = r.drEstimate ?? df
                return 1.0 / (max(df, 0.05) * max(dr, 0.05))
            }
            let medianEtx = etxValues.sorted()[etxValues.count / 2]
            let meanDf = valid.reduce(0.0) { $0 + ($1.dfEstimate ?? 0) } / Double(valid.count)
            let lossRate = 1.0 - meanDf
            return (lossRate: max(0, min(1, lossRate)), etx: medianEtx)
        }

        if let local = localCallsign, !local.isEmpty {
            let normalizedLocal = CallsignValidator.normalize(local)
            let localRecords = records.filter { r in
                CallsignValidator.normalize(r.fromCall) == normalizedLocal
                    || CallsignValidator.normalize(r.toCall) == normalizedLocal
            }
            if let result = aggregate(localRecords) {
                return (result.lossRate, result.etx, .localLinks)
            }
        }
        guard let result = aggregate(records) else { return nil }
        return (result.lossRate, result.etx, .channelWide)
    }
}

#Preview {
    let settings = AppSettingsStore()
    return ContentView(
        client: PacketEngine(settings: settings),
        settings: settings,
        inspectionRouter: .shared,
        winlinkContext: WinlinkContext(store: nil, settings: WinlinkSettings())
    )
}
