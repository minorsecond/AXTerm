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
    //case raw = "Raw"
}

struct ContentView: View {
    @StateObject private var client: PacketEngine
    @ObservedObject private var settings: AppSettingsStore
    @ObservedObject private var inspectionRouter: PacketInspectionRouter
    private let inspectionCoordinator = PacketInspectionCoordinator()

    /// Session coordinator for connected-mode sessions - survives tab switches
    /// Uses SessionCoordinator.shared so Settings can update the same instance
    @StateObject private var sessionCoordinator: SessionCoordinator
    @StateObject private var connectCoordinator = ConnectCoordinator()

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

    nonisolated static func stationDefaultConnectMode() -> ConnectBarMode {
        .ax25
    }

    init(client: PacketEngine, settings: AppSettingsStore, inspectionRouter: PacketInspectionRouter) {
        _client = StateObject(wrappedValue: client)
        _settings = ObservedObject(wrappedValue: settings)
        _inspectionRouter = ObservedObject(wrappedValue: inspectionRouter)
        // Initialize analytics view model with settings store for persistence
        _analyticsViewModel = StateObject(wrappedValue: AnalyticsDashboardViewModel(
            settingsStore: settings,
            netRomIntegration: client.netRomIntegration,
            databaseAggregationProvider: { interval, bucket, calendar, includeVia, histogramBinCount, topLimit in
                await client.aggregateAnalytics(
                    in: interval,
                    bucket: bucket,
                    calendar: calendar,
                    includeViaDigipeaters: includeVia,
                    histogramBinCount: histogramBinCount,
                    topLimit: topLimit
                )
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
            let intervalSeconds: UInt64 = 30
            while true {
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
                guard let coordinator = SessionCoordinator.shared,
                      coordinator.adaptiveTransmissionEnabled,
                      !coordinator.hasActiveSessions,
                      let integration = client.netRomIntegration else { continue }
                let stats = integration.exportLinkStats()
                guard let (lossRate, etx) = Self.aggregateLinkQualityForAdaptive(stats, localCallsign: coordinator.localCallsign) else { continue }
                coordinator.applyLinkQualitySample(lossRate: lossRate, etx: etx, srtt: nil, source: "network")
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
        //case .raw: searchModel.scope = .terminal // Fallback or new scope if needed
        }
    }

    private func syncConnectContext(for item: NavigationItem) {
        switch item {
        case .terminal:
            connectCoordinator.activeContext = .terminal
        case .routes:
            connectCoordinator.activeContext = .routes
        case .packets, .analytics:
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
                        .tag(item)
                        .accessibilityIdentifier("nav-\(item.rawValue.lowercased())")
                }
            }

            Section("Stations (\(client.stations.count))") {
                // "All" option
                HStack {
                    Text("All Packets")
                    Spacer()
                    if client.selectedStationCall == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    client.selectedStationCall = nil
                }

                if client.stations.isEmpty {
                    Text("No stations heard")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(client.stations) { station in
                        let stationHasNetRomRoute = client.netRomIntegration?.bestRouteTo(CallsignValidator.normalize(station.call)) != nil
                        let preferredMode = connectCoordinator.preferredMode(
                            for: station.call,
                            hasNetRomRoute: stationHasNetRomRoute
                        )
                        let defaultStationMode = Self.stationDefaultConnectMode()
                        let isConnectedStation = sessionCoordinator.connectedSessions.contains {
                            CallsignValidator.normalize($0.remoteAddress.display) == CallsignValidator.normalize(station.call)
                        }

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
                        .onTapGesture(count: 2) {
                            issueStationConnectRequest(
                                stationCall: station.call,
                                mode: defaultStationMode,
                                executeImmediately: true
                            )
                        }
                        .onTapGesture {
                            if client.selectedStationCall == station.call {
                                client.selectedStationCall = nil
                            } else {
                                client.selectedStationCall = station.call
                            }
                            issueStationConnectRequest(
                                stationCall: station.call,
                                mode: defaultStationMode,
                                executeImmediately: false
                            )
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
        //case .raw: return "doc.text"
        }
    }

    private func issueStationConnectRequest(stationCall: String, mode: ConnectBarMode, executeImmediately: Bool) {
        if !executeImmediately {
            connectCoordinator.navigateToTerminal?()
        }
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
                    searchModel: searchModel
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
                AnalyticsDashboardView(packetEngine: client, settings: settings, viewModel: analyticsViewModel)
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
            tncToolbarMenu
        }
    }

    /// TNC transport status menu — clickable pill with connect/disconnect actions
    @ViewBuilder
    private var tncToolbarMenu: some View {
        Menu {
            switch client.status {
            case .connected:
                Button("Disconnect TNC", role: .destructive) {
                    client.disconnect()
                }
                Button("Reconnect TNC") {
                    reconnectToTNC()
                }
            case .connecting:
                Button("Cancel") {
                    client.disconnect()
                }
            case .disconnected, .failed:
                Button("Connect TNC") {
                    client.connect(host: settings.host, port: settings.portValue)
                }
                Button("Reconnect TNC") {
                    reconnectToTNC()
                }
            }

            Divider()

            Section("Endpoint") {
                Text("KISS TCP @ \(connectionHostPort)")
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
            HStack(spacing: 6) {
                Circle()
                    .fill(tncLedColor)
                    .frame(width: 8, height: 8)

                Text(tncCapsuleLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .help("TNC connection status and actions")
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

    private var connectionHostPort: String {
        let hostValue = client.connectedHost ?? settings.host
        let portValue = client.connectedPort.map(String.init) ?? String(settings.port)
        return "\(hostValue):\(portValue)"
    }

    private func toggleConnection() {
        switch client.status {
        case .connected, .connecting:
            client.disconnect()
        case .disconnected, .failed:
            client.connect(host: settings.host, port: settings.portValue)
        }
    }

    private func reconnectToTNC() {
        client.disconnect()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            client.connect(host: settings.host, port: settings.portValue)
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
    nonisolated static func aggregateLinkQualityForAdaptive(_ records: [LinkStatRecord], localCallsign: String? = nil) -> (lossRate: Double, etx: Double)? {
        let minObs = 5

        // Filter to local station links when a callsign is provided
        let filtered: [LinkStatRecord]
        if let local = localCallsign, !local.isEmpty {
            let normalizedLocal = CallsignValidator.normalize(local)
            filtered = records.filter { r in
                CallsignValidator.normalize(r.fromCall) == normalizedLocal
                    || CallsignValidator.normalize(r.toCall) == normalizedLocal
            }
        } else {
            filtered = records
        }

        let valid = filtered.filter { r in
            r.observationCount >= minObs
                && (r.dfEstimate ?? 0) > 0.05
                && (r.drEstimate ?? 0) > 0.05
        }
        guard !valid.isEmpty else { return nil }
        let etxValues = valid.map { 1.0 / ($0.dfEstimate! * $0.drEstimate!) }
        let medianEtx = etxValues.sorted()[etxValues.count / 2]
        let meanDf = valid.reduce(0.0) { $0 + ($1.dfEstimate ?? 0) } / Double(valid.count)
        let lossRate = 1.0 - meanDf
        return (lossRate: max(0, min(1, lossRate)), etx: medianEtx)
    }
}

#Preview {
    let settings = AppSettingsStore()
    return ContentView(
        client: PacketEngine(settings: settings),
        settings: settings,
        inspectionRouter: PacketInspectionRouter()
    )
}
