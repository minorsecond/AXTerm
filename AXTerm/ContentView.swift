//
//  ContentView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI
import Combine

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
    /// Shared so a callsign resolved on the map stays resolved
    /// everywhere else in the session.
    @StateObject private var callsignLookup: CallsignLookupService
    /// Learns node aliases (DRLNOD, HORSE) from ID beacons already
    /// arriving, so via-path hops can be placed.
    @StateObject private var nodeAliases = NodeAliasStore()
    /// The Mac gets the same identity view the handheld does — a callsign in
    /// the console is the same question there as here.
    @StateObject private var profiles = NodeProfileCoordinator()
    @State private var lookingUpCallsign: String?
    /// Map overlays, owned here so a layer arriving as a Winlink attachment
    /// and a layer the operator drew end up in the same place.
    @StateObject private var overlayStore = MapOverlayStore()

    /// Grid squares for RMS gateways, keyed by callsign with SSID — a
    /// gateway's position is known from the CMS even when its licensee
    /// has never been looked up.
    /// Records what stations announced and what digipeaters demonstrated.
    /// Folds what the live window shows into the durable path table.
    ///
    /// Runs on the same throttle as the service harvest and for the same
    /// reason: the network's own record of itself should grow wherever the
    /// operator happens to be, not only while a map is on screen.
    private func recordNetworkPaths(from packets: [Packet]) {
        guard let store = client.networkPaths else { return }
        let recent = Array(packets.suffix(600))
        let observed = NetworkPathObserver.paths(in: recent,
                                                 localCallsign: settings.myCallsign)
        // Only what was actually observed. Transitive paths are re-derived on
        // demand from whatever the graph holds, and storing an inference
        // would let it harden into a fact that outlives its evidence.
        try? store.record(observed, now: Date())
    }

    private func harvestServices(from packets: [Packet]) {
        guard let services = client.stationServices else { return }
        let recent = Array(packets.suffix(400))
        try? services.record(
            StationServiceHarvester.declarations(in: recent)
                + StationServiceHarvester.demonstratedDigipeaters(in: recent))
    }

    /// Same gathering as the handheld's, from the Mac's own view state.
    /// The graph the identity page reasons over.
    ///
    /// Live traffic merged with what previous sessions recorded, so "which
    /// stations does the network depend on" is answered from days of evidence
    /// rather than from the last few minutes of it.
    private var rememberedNetworkPaths: [NetworkPath] {
        let live = NetworkPathObserver.paths(
            in: Array(client.packets.suffix(600)),
            localCallsign: settings.myCallsign)
        let remembered = (try? client.networkPaths?.paths(
            since: Date().addingTimeInterval(-SQLiteNetworkPathStore.retention))) ?? []
        return NetworkPath.merging(live + remembered)
    }

    private var macResolver: NodeProfileResolver {
        let stations = client.stations
        let heard = HeardStationMap.entries(
            stations: stations,
            directory: callsignLookup.records,
            gatewayGrids: gatewayGrids,
            excluding: settings.myCallsign)
        let aliasEntries = HeardStationMap.aliasEntries(
            aliases: nodeAliases.directory,
            usedAliases: HeardStationMap.aliasesInUse(stations),
            directory: callsignLookup.records,
            stations: stations)
        let neighbours = client.netRomIntegration?.currentNeighbors() ?? []
        let routes = client.netRomIntegration?.currentRoutes() ?? []

        return NodeProfileResolver(
            localCallsign: settings.myCallsign,
            aliases: nodeAliases.directory,
            heardEntries: heard + aliasEntries,
            directory: callsignLookup.records,
            linkQuality: winlinkContext.mapLinkQuality,
            observer: Maidenhead.center(of: winlinkContext.settings.gridSquare)
                .map(GreatCircle.Point.init),
            neighbourQuality: Dictionary(
                neighbours.map { ($0.call.uppercased(), $0.quality) },
                uniquingKeysWith: max),
            routes: routes.map { (destination: $0.destination.uppercased(),
                                  via: ($0.path.first ?? $0.origin).uppercased(),
                                  isBroadcast: $0.sourceType == "broadcast") },
            digipeaters: HeardStationMap.aliasesInUse(stations),
            linkStats: client.netRomIntegration?.exportLinkStats() ?? [],
            declaredServices: nodeAliases.declaredServices,
            networkPaths: rememberedNetworkPaths,
            serviceStore: client.stationServices,
            historyStore: client.linkQualityHistory)
    }

    private var gatewayGrids: [String: String] {
        guard let store = winlinkContext.store else { return [:] }
        let stations = (try? store.stations()) ?? []
        return Dictionary(stations.map { ($0.callsign.uppercased(), $0.gridSquare) },
                          uniquingKeysWith: { first, _ in first })
    }

    @Environment(\.openSettings) private var openSettings

    @State private var selectedNav: NavigationItem = .terminal
    @StateObject private var searchModel = AppToolbarSearchModel()
    @State private var filters = PacketFilters()

    @State private var selection = Set<Packet.ID>()
    /// Surfaced when turning a map layer into a Winlink draft fails.
    @State private var layerSendError: String?
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
        _callsignLookup = StateObject(wrappedValue: CallsignLookupService(
            store: winlinkContext.store,
            isNetworkEnabled: winlinkContext.settings.callsignLookupEnabled))
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
        .alert("Could not prepare the layer", isPresented: Binding(
            get: { layerSendError != nil },
            set: { if !$0 { layerSendError = nil } })) {
            Button("OK") { layerSendError = nil }
        } message: {
            Text(layerSendError ?? "")
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
            // Analytics owns the derivation; the context owns the decision
            // to publish. Wired here because this is the one place holding
            // both, and it keeps the store from reaching up into analytics
            // for packets and inferred roles.
            analyticsViewModel.onStationDirectoryChanged = { [weak winlinkContext] directory in
                winlinkContext?.publishLocalActivity(directory, callsign: settings.myCallsign)
            }
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
            case .map:
                // Learn aliases from beacons already received. Cheap —
                // only ID/beacon destinations are inspected — and it
                // runs off the view-update path.
                nodeAliases.ingest(packets: client.packets)
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
        // Harvested wherever the operator happens to be. Tying this to the
        // Map tab meant the network's own directory only grew while someone
        // was looking at a map, which is the one time they are not reading it.
        .onReceive(client.$packets.throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)) { packets in
            harvestServices(from: packets)
            recordNetworkPaths(from: packets)
        }
        // One sheet, not two.
        //
        // SwiftUI honours a single `.sheet` per view: attach two and the
        // second silently shadows the first. That is why the identity page
        // opened once and then refused to reappear after being dismissed —
        // the packet inspector's sheet was fighting it for the same slot.
        // Both are routed through one modifier and one enum instead.
        .sheet(item: rootSheet) { sheet in
            switch sheet {
            case .inspector(let packetID):
                inspectorSheet(PacketInspectorSelection(id: packetID))
            case .profile(let presentation):
                profileSheet(presentation)
            }
        }
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

    /// Reads whichever source is active and clears both on dismissal.
    ///
    /// The rules live in `RootSheetRoute` so they can be tested; this is only
    /// the wiring between them and the two pieces of view state.
    private var rootSheet: Binding<RootSheetRoute?> {
        Binding(
            get: {
                RootSheetRoute.current(inspector: inspectorSelection?.id,
                                       profile: profiles.presented)
            },
            set: { newValue in
                let next = RootSheetRoute.apply(newValue)
                inspectorSelection = next.inspector.map(PacketInspectorSelection.init(id:))
                profiles.presented = next.profile
            })
    }

    @ViewBuilder
    private func inspectorSheet(_ selection: PacketInspectorSelection) -> some View {
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

    @ViewBuilder
    private func profileSheet(_ presentation: NodeProfileCoordinator.Presentation) -> some View {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { profiles.dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                NodeProfileView(
                    profile: macResolver.profile(for: presentation.callsign),
                    localCallsign: settings.myCallsign,
                    lookupEnabled: winlinkContext.settings.callsignLookupEnabled,
                    isLookingUp: lookingUpCallsign == presentation.callsign,
                    noteStore: client.stationNotes,
                    presentation: presentation.isPage ? .page : .sheet,
                    onOpenFullPage: presentation.isPage
                        ? nil : { profiles.promoteSheetToPage() })
                    .task(id: presentation.callsign) {
                        guard winlinkContext.settings.callsignLookupEnabled else { return }
                        lookingUpCallsign = presentation.callsign
                        defer { lookingUpCallsign = nil }
                        await callsignLookup.resolve(presentation.callsign)
                    }
            }
            .frame(minWidth: presentation.isPage ? 560 : 440,
                   minHeight: presentation.isPage ? 620 : 500)
    }

    private func syncSearchScope(for item: NavigationItem) {
        switch item {
        case .terminal: searchModel.scope = .terminal
        case .packets: searchModel.scope = .packets
        case .routes: searchModel.scope = .routes
        case .analytics: searchModel.scope = .analytics
        case .map: searchModel.scope = .terminal
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
        case .packets, .analytics, .mail, .map:
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
        case .map: return "map"
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

    /// A callsign collision breaks every link this station has, and its
    /// symptoms look like a dozen unrelated faults until somebody names the
    /// cause — so it sits above the transport error, not below it.
    @ViewBuilder
    private var banners: some View {
        if let collision = client.identityCollision {
            IdentityCollisionBanner(collision: collision) {
                client.dismissIdentityCollision()
            }
        }
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
    }

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            banners

            switch selectedNav {
            case .terminal:
                TerminalView(
                    client: client,
                    settings: settings,
                    sessionCoordinator: sessionCoordinator,
                    connectCoordinator: connectCoordinator,
                    searchModel: searchModel,
                    locationService: winlinkContext.locationService,
                    onIdentity: { profiles.peek($0) },
                    onIdentityMenu: { profiles.openPage($0) }
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
            case .map:
                StationsMapView(
                    stations: client.stations,
                recentPackets: Array(client.packets.suffix(600)),
                    gatewayGrids: gatewayGrids,
                    observerGrid: winlinkContext.settings.gridSquare,
                    myCallsign: settings.myCallsign,
                    lookup: callsignLookup,
                    aliases: nodeAliases,
                    settings: winlinkContext.settings,
                    noteStore: client.stationNotes,
                    pathStore: client.networkPaths,
                    serviceStore: client.stationServices,
                    onOpenProfile: { profiles.openPage($0) },
                    focusCallsign: .constant(nil),
                    overlayStore: overlayStore,
                    onSendLayer: layerSendAction)
            case .mail:
                WinlinkMailView(
                    context: winlinkContext,
                    appSettings: settings,
                    sessionCoordinator: sessionCoordinator,
                    client: client,
                    onAddToMap: addSpatialAttachmentToMap
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

    /// Imports a spatial attachment onto the map and switches to it.
    ///
    /// Switching views is the point: an operator who asked to put a boundary
    /// on the map wants to see it, and leaving them in the mailbox wondering
    /// whether it worked is the same failure as a silent save.
    private func addSpatialAttachmentToMap(_ attachment: WinlinkB2Message.Attachment,
                                           from sender: String) {
        let added = overlayStore.addFromAttachment(
            data: attachment.data, filename: attachment.name, senderCallsign: sender)
        if added != nil { selectedNav = .map }
    }

    /// Nil without a mailbox, which hides the send action rather than
    /// offering one that cannot work.
    ///
    /// Spelled out with an explicit type: a ternary yielding a bare `nil` for
    /// an optional closure gives the type checker nothing to work from, and
    /// it gives up on the whole view body rather than on this line.
    private var layerSendAction: ((MapOverlayLayer, MapOverlayExport.Format) -> Void)? {
        guard winlinkContext.store != nil else { return nil }
        return { layer, format in sendLayerViaWinlink(layer, format: format) }
    }

    /// Turns a map layer into a Winlink draft and opens the mailbox on it.
    ///
    /// A draft rather than a queued message: the operator chooses the
    /// recipient, and — given what a layer can cost in airtime — should see
    /// the size before it goes anywhere.
    private func sendLayerViaWinlink(_ layer: MapOverlayLayer,
                                     format: MapOverlayExport.Format) {
        guard let store = winlinkContext.store else { return }
        do {
            let data: Data
            switch format {
            case .geoJSON: data = try GeoJSONWriter.data(for: layer)
            case .shapefile: data = try ShapefileWriter.zippedShapefile(layer: layer)
            }

            // The same airtime estimator the catalog uses, so the number in
            // the body is measured where this station has evidence and says
            // so where it does not.
            let airtime = WinlinkAirtimeEstimate.forGateway(
                callsign: winlinkContext.settings.gatewayCallsign,
                frequencyHz: nil,
                quality: winlinkContext.mapLinkQuality)
            let assessment = MapOverlayExport.assess(byteCount: data.count, airtime: airtime)

            let draft = MapOverlayMessage.draft(
                layer: layer, format: format, attachment: data,
                assessment: assessment,
                operatorCallsign: settings.myCallsign,
                generatedAt: Date())

            let message = WinlinkB2Message(
                mid: WinlinkB2Message.generateMID(callsign: settings.myCallsign),
                date: Date(),
                type: .privateMessage,
                from: settings.myCallsign,
                to: [],
                cc: [],
                subject: draft.subject,
                mbo: settings.myCallsign,
                body: Data(draft.body.utf8),
                attachments: [.init(name: draft.attachmentName, data: draft.attachment)])

            try store.saveDraft(message)
            winlinkContext.refreshUnread()
            selectedNav = .mail
        } catch let error as ShapefileWriter.WriteError {
            layerSendError = error.explanation
        } catch {
            layerSendError = "Could not prepare \(layer.name) for sending: \(error.localizedDescription)"
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if sessionCoordinator.adaptiveTransmissionEnabled, client.status == .connected {
                AdaptiveToolbarControl(
                    store: sessionCoordinator.adaptiveStatusStore,
                    linkViz: sessionCoordinator.linkVizMonitor,
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
            // Between the adaptive chip and the TNC pill: both report "is
            // this station working", and the mailbox being current on the
            // operator's other radio belongs in the same glance.
            if let sync = winlinkContext.sync {
                SyncStatusIndicator(sync: sync)
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
                .stroke(Color(platform: .platformSeparator).opacity(0.35), lineWidth: 0.5)
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
        case .disconnected: return Color(platform: .platformTertiaryLabel)
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
