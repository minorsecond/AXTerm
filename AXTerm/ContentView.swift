//
//  ContentView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

enum NavigationItem: String, Hashable, CaseIterable {
    case terminal = "Terminal"
    case packets = "Packets"
    case routes = "Routes"
    case analytics = "Analytics"
    case raw = "Raw"
}

struct ContentView: View {
    @StateObject private var client: PacketEngine
    @ObservedObject private var settings: AppSettingsStore
    @ObservedObject private var inspectionRouter: PacketInspectionRouter
    private let inspectionCoordinator = PacketInspectionCoordinator()

    /// Session coordinator for connected-mode sessions - survives tab switches
    /// Uses SessionCoordinator.shared so Settings can update the same instance
    @StateObject private var sessionCoordinator: SessionCoordinator

    @State private var selectedNav: NavigationItem = .terminal
    @StateObject private var searchModel = AppToolbarSearchModel()
    @State private var filters = PacketFilters()
    @State private var showFilterPopover = false

    @State private var selection = Set<Packet.ID>()
    @State private var inspectorSelection: PacketInspectorSelection?
    @FocusState private var isSearchFocused: Bool
    @State private var didLoadPacketsHistory = false
    @State private var didLoadConsoleHistory = false
    @State private var didLoadRawHistory = false
    @State private var selectionMutationScheduler = SelectionMutationScheduler()
    @StateObject private var analyticsViewModel: AnalyticsDashboardViewModel

    init(client: PacketEngine, settings: AppSettingsStore, inspectionRouter: PacketInspectionRouter) {
        _client = StateObject(wrappedValue: client)
        _settings = ObservedObject(wrappedValue: settings)
        _inspectionRouter = ObservedObject(wrappedValue: inspectionRouter)
        // Initialize analytics view model with settings store for persistence
        _analyticsViewModel = StateObject(wrappedValue: AnalyticsDashboardViewModel(settingsStore: settings, netRomIntegration: client.netRomIntegration))
        // Get or create the shared session coordinator so Settings can update the same instance
        let coordinator: SessionCoordinator
        if let existing = SessionCoordinator.shared {
            coordinator = existing
        } else {
            coordinator = SessionCoordinator()
        }
        coordinator.localCallsign = settings.myCallsign
        coordinator.appSettings = settings
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
            case .raw:
                guard !didLoadRawHistory else { return }
                didLoadRawHistory = true
                await Task.yield()
                client.loadPersistedRaw()
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
        }
    }

    private func syncSearchScope(for item: NavigationItem) {
        switch item {
        case .terminal: searchModel.scope = .terminal
        case .packets: searchModel.scope = .packets
        case .routes: searchModel.scope = .routes
        case .analytics: searchModel.scope = .analytics
        case .raw: searchModel.scope = .terminal // Fallback or new scope if needed
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
                        StationRowView(
                            station: station,
                            isSelected: client.selectedStationCall == station.call,
                            capability: client.capabilityStore.capabilities(for: station.call)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if client.selectedStationCall == station.call {
                                client.selectedStationCall = nil
                            } else {
                                client.selectedStationCall = station.call
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
        case .raw: return "doc.text"
        }
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
                TerminalView(client: client, settings: settings, sessionCoordinator: sessionCoordinator, searchModel: searchModel)
            case .packets:
                packetsView
            case .routes:
                NetRomRoutesView(integration: client.netRomIntegration, packetEngine: client, settings: settings)
            case .analytics:
                AnalyticsDashboardView(packetEngine: client, settings: settings, viewModel: analyticsViewModel)
            case .raw:
                RawView(
                    chunks: client.rawChunks,
                    showDaySeparators: settings.showRawDaySeparators,
                    clearedAt: $settings.rawClearedAt
                )
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
        // Left: Connection status
        ToolbarItem(placement: .navigation) {
            connectionStatusIndicator
        }
        
        ToolbarItemGroup(placement: .principal) {
            if activeFilterCount > 0 {
                filterSummary
            }
        }
        
        // Right: Actions
        ToolbarItemGroup(placement: .primaryAction) {
            connectionActionButton
            filterButton
        }
    }

    // MARK: - Toolbar Components
    
    /// Left zone: Connection status indicator
    @ViewBuilder
    private var connectionStatusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.2), value: client.status)
    }
    
    
    /// Center zone: Filter summary badge
    @ViewBuilder
    private var filterSummary: some View {
        Text("\(activeFilterCount) filter\(activeFilterCount == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    
    /// Right zone: Connection action button (state-aware)
    @ViewBuilder
    private var connectionActionButton: some View {
        switch client.status {
        case .disconnected, .failed:
            Menu {
                Button("Connect…") {
                    client.connect(host: settings.host, port: settings.portValue)
                }
            } label: {
                Text("Connect…")
            } primaryAction: {
                client.connect(host: settings.host, port: settings.portValue)
            }
            .buttonStyle(.borderedProminent)
            .help("Connect to TNC at \(settings.host):\(settings.port)")
            
        case .connecting:
            Button("Cancel") {
                client.disconnect()
            }
            .buttonStyle(.bordered)
            .help("Cancel connection attempt")
            
        case .connected:
            Menu {
                Button("Disconnect") {
                    client.disconnect()
                }
                Button("Reconnect") {
                    client.disconnect()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        client.connect(host: settings.host, port: settings.portValue)
                    }
                }
                Divider()
                Button("Copy Address") {
                    let address = "\(settings.host):\(settings.port)"
                    ClipboardWriter.copy(address)
                }
            } label: {
                Text("Disconnect")
            } primaryAction: {
                client.disconnect()
            }
            .buttonStyle(.bordered)
            .help("Disconnect from TNC")
        }
    }
    
    /// Right zone: Filter button with popover
    @ViewBuilder
    private var filterButton: some View {
        Button {
            showFilterPopover.toggle()
        } label: {
            Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .help("Packet filters")
        .popover(isPresented: $showFilterPopover) {
            FilterPopoverView(
                filters: $filters,
                hasPackets: !client.packets.isEmpty,
                hasPinnedPackets: !client.pinnedPacketIDs.isEmpty,
                onReset: {
                    filters = PacketFilters()
                    showFilterPopover = false
                }
            )
        }
        .overlay(alignment: .topTrailing) {
            if activeFilterCount > 0 {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
                    .offset(x: 4, y: -4)
            }
        }
    }

    // MARK: - Computed Properties

    private var statusText: String {
        switch client.status {
        case .connected:
            return "TNC: \(connectionHostPort)"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Connection Failed"
        }
    }
    
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
    
    private var activeFilterCount: Int {
        var count = 0
        let defaultFilters = PacketFilters()
        if filters.showUI != defaultFilters.showUI { count += 1 }
        if filters.showI != defaultFilters.showI { count += 1 }
        if filters.showS != defaultFilters.showS { count += 1 }
        if filters.showU != defaultFilters.showU { count += 1 }
        if filters.payloadOnly != defaultFilters.payloadOnly { count += 1 }
        if filters.onlyPinned != defaultFilters.onlyPinned { count += 1 }
        return count
    }

    private var statusDetail: String {
        "\(formatBytes(client.bytesReceived)) • \(client.packets.count) pkts"
    }

    private var statusColor: Color {
        switch client.status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return Color(nsColor: .tertiaryLabelColor)
        case .failed: return .red
        }
    }

    private var connectionHostPort: String {
        let hostValue = client.connectedHost ?? settings.host
        let portValue = client.connectedPort.map(String.init) ?? String(settings.port)
        return "\(hostValue):\(portValue)"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func toggleConnection() {
        switch client.status {
        case .connected, .connecting:
            client.disconnect()
        case .disconnected, .failed:
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
    static func aggregateLinkQualityForAdaptive(_ records: [LinkStatRecord], localCallsign: String? = nil) -> (lossRate: Double, etx: Double)? {
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
