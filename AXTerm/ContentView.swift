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
    // Same key the map's layers menu writes — the trickle lookup below
    // follows the operator's layer choice from anywhere in the app.
    @AppStorage("stations.showsDirectoryNodes") private var showsDirectoryNodes = false
    @StateObject private var nodeCapabilities = NodeCapabilityStore()
    /// Locators stations announce in their own beacons — the placement
    /// source for the part of the world no directory covers.
    @StateObject private var announcedGrids = AnnouncedGridStore()
    /// Reads BPQ ROUTES tables out of session transcripts; its rows become
    /// harvested routes when the capability verdict allows it.
    @State private var routesScraper = BpqRoutesScraper()
    /// The Nodes page's search text, held here so the sidebar can point it at
    /// one node's table.
    @State private var nodeQuery: String = ""
    /// The node whose table the Nodes page is restricted to, set by the
    /// sidebar's "Reachable via" rows.
    @State private var nodeRouteFilter: String?
    /// The Mac gets the same identity view the handheld does — a callsign in
    /// the console is the same question there as here.
    @StateObject private var profiles = NodeProfileCoordinator()
    @State private var lookingUpCallsign: String?
    /// The window's content size, read by a background GeometryReader so
    /// sheets can size themselves against the space actually available.
    @State private var windowSize: CGSize = .zero
    /// Measured profile content heights (see NodeProfileContentHeightKey),
    /// keyed per callsign-and-presentation. A dictionary rather than one
    /// value because a single value needed resetting between presentations,
    /// and the reset raced the preference delivery: onAppear zeroed the
    /// height *after* the preference had already fired, the value never
    /// changed again, and the sheet sat on its fallback size forever.
    @State private var profileContentHeights: [String: CGFloat] = [:]
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
        let recent = Array(packets.suffix(400))
        announcedGrids.ingest(packets: recent)
        guard let services = client.stationServices else { return }
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
            announcedGrids: announcedGrids.grids,
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
            capabilities: nodeCapabilities.directory,
            networkPaths: rememberedNetworkPaths,
            serviceStore: client.stationServices,
            historyStore: client.linkQualityHistory,
            heardTimestamps: { [weak client] call in
                guard let client else { return [] }
                let upper = call.uppercased()
                return client.packets.compactMap {
                    $0.fromDisplay.uppercased() == upper ? $0.timestamp : nil
                }
            })
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
    @ObservedObject private var bbsSettings: BBSSettings
    @StateObject private var bbsService: BBSService
    @StateObject private var bbsLibrary: BBSFileLibrary
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


    init(client: PacketEngine, settings: AppSettingsStore, inspectionRouter: PacketInspectionRouter, winlinkContext: WinlinkContext, bbsSettings: BBSSettings) {
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
        // Restore the operator's NET/ROM node policy. Both switches
        // default off, so on a station that has never enabled them this
        // does nothing at all; on one that has, it resumes announcing at
        // launch rather than waiting for a visit to Settings.
        coordinator.applyNetRomNodeSettings(settings)
        coordinator.subscribeToPackets(from: client)
        _sessionCoordinator = StateObject(wrappedValue: coordinator)
        // The personal mailbox. Built here because this is the one place that
        // holds both the coordinator (which owns inbound calls) and the engine
        // (which owns the database and the frame sink).
        _bbsSettings = ObservedObject(wrappedValue: bbsSettings)
        // Hoisted rather than inlined: as one expression the closures push the
        // type checker past its budget.
        let sendFrames: ([OutboundFrame]) -> Void = { [weak client] frames in
            for frame in frames { client?.send(frame: frame) }
        }
        let stationCallsign: () -> String = { settings.myCallsign }
        let winlinkArmed: () -> Bool = { winlinkContext.settings.p2pListenEnabled }
        let winlinkCallsign: () -> String = {
            winlinkContext.settings.effectiveP2PCallsign(stationCallsign: settings.myCallsign)
        }
        let contested: () -> String? = { winlinkContext.contestedIdentityHolder }
        let library = BBSFileLibrary(store: client.bbsMessages)
        _bbsLibrary = StateObject(wrappedValue: library)
        let supportsAXDP: (String) -> Bool = { [weak client] callsign in
            client?.capabilityStore.hasCapabilities(for: callsign) ?? false
        }
        // Built before the mailbox so the mailbox can read its cache.
        let lookup = CallsignLookupService(
            store: winlinkContext.store,
            isNetworkEnabled: winlinkContext.settings.callsignLookupEnabled)
        _callsignLookup = StateObject(wrappedValue: lookup)
        // Cached only: the mailbox answers calls unattended, and looking a
        // caller up over the internet the moment they connect would tell a
        // third party who is talking to this station.
        let licence: (String) -> CallsignRecord? = { [weak lookup] callsign in
            lookup?.cached(callsign)
        }
        let heard: () -> [BBSShell.HeardStation] = { [weak client] in
            (client?.stations ?? []).compactMap { station in
                guard let lastHeard = station.lastHeard else { return nil }
                return BBSShell.HeardStation(callsign: station.call, lastHeard: lastHeard)
            }
        }
        _bbsService = StateObject(wrappedValue: BBSService(
            store: client.bbsMessages,
            settings: bbsSettings,
            coordinator: coordinator,
            sendFrames: sendFrames,
            stationCallsign: stationCallsign,
            isWinlinkP2PArmed: winlinkArmed,
            winlinkP2PCallsign: winlinkCallsign,
            heardStations: heard,
            library: library,
            peerSupportsAXDP: supportsAXDP,
            licenceRecord: licence,
            announce: { [weak client] line in client?.appendSystemNotification(line) },
            resolveLicences: { [weak lookup] callsigns in await lookup?.resolveAll(callsigns) },
            contestedIdentityHolder: contested))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .accessibilityIdentifier("mainWindowRoot")
        .task {
            bbsService.attach()
            syncServiceAddresses()
            bbsLibrary.rescan()
        }
        // Which addresses this station accepts calls on. Watched as one value
        // rather than five separate modifiers, which the type checker cannot
        // afford on a body this size.
        .onChange(of: serviceAddressSignature) { syncServiceAddresses() }
        // Saying goodbye costs one frame. Vanishing mid-session leaves the
        // caller's software retrying into an address that stopped existing,
        // with no way to tell that from a bad path.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            bbsService.shutdown(reason: "AXTerm is closing")
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.willSleepNotification)) { _ in
            bbsService.shutdown(reason: "this station is going to sleep")
        }
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
                // Sweep stored beacons for aliases before anything renders. The
                // sidebar names stations on every page, so waiting until the
                // operator happens to open Map or Nodes left rows unnamed that
                // the app already had the evidence to name.
                nodeAliases.ingest(packets: client.packets)
                nodeCapabilities.ingest(packets: client.packets)
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
            case .map, .nodes:
                // Learn aliases from beacons already received. Cheap —
                // only ID/beacon destinations are inspected — and it
                // runs off the view-update path. The directory page wants
                // the same sweep for the same reason: an alias already sitting
                // in a stored beacon should be on the list before the operator
                // reads it, not after the next one happens to arrive.
                nodeAliases.ingest(packets: client.packets)
                nodeCapabilities.ingest(packets: client.packets)
                return
            case .mail:
                // Mail view loads its own data from the Winlink store
                return
            case .bbs:
                bbsService.reload()
                return
            }
        }
        .task(id: inspectionRouter.requestedPacketID) {
            guard let packetID = inspectionRouter.requestedPacketID else { return }
            await openInspectorFromRouterRequest(packetID: packetID)
        }
        // Positions arrive when stations do, not when the operator happens
        // to open the Map (field ask 2026-08-29 05:24 — the auto-lookup
        // lived on the map view, so a station heard while on Terminal
        // stayed unplaced until someone visited a map). Keyed on the set
        // of heard callsigns: each new station triggers one pass, the
        // service's own attempted-set means at most one network try per
        // callsign per launch, and the whole thing is inert unless the
        // operator opted in to online lookups.
        .task(id: stationLookupKey) {
            guard winlinkContext.settings.callsignLookupEnabled else { return }
            callsignLookup.isNetworkEnabled = true
            let unknown = Set(client.stations.map { CallsignQuery.normalize($0.call) })
                .filter { CallsignQuery.isPlausible($0) && callsignLookup.cached($0) == nil }
                .sorted()
            if !unknown.isEmpty {
                await callsignLookup.resolveAll(unknown)
            }
            // With the directory layer on, the harvested list trickles
            // through the same pipe — nobody should have to press
            // Find Positions a dozen times to see what the toggle
            // already promises (field capture 2026-08-29 05:47: 4 of
            // 533 placed after three presses). Bounded by the list
            // itself: one paced attempt per callsign per launch, results
            // persisted, heard bases skipped because they fold anyway.
            guard showsDirectoryNodes else { return }
            let directory = HeardStationMap.directoryLookupCandidates(
                aliases: nodeAliases.directory,
                cachedCallsigns: Set(callsignLookup.records.keys.map { $0.uppercased() }),
                heardBases: Set(client.stations.map { CallsignQuery.normalize($0.call) }),
                limit: Int.max)
            for call in directory {
                guard !Task.isCancelled, !callsignLookup.isCoolingDown else { return }
                _ = await callsignLookup.resolve(call)
                // A courtesy gap: this is someone's free service and the
                // radio is in no hurry. ~40/minute, and the service's
                // breaker stops the whole pass the moment the far end
                // answers 429 or falls over.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
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
        // Sheets are sized against the window, so the window's size has to
        // be known. A background reader costs nothing and avoids AppKit
        // window plumbing.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { windowSize = proxy.size }
                .onChange(of: proxy.size) { _, newSize in windowSize = newSize }
        })
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
        // Warm the in-memory directory from the on-disk cache the moment a
        // profile is requested. Without this, a station looked up weeks ago
        // still rendered its first frame nameless — the async task then hit
        // the store a beat later and the licence fields popped in.
        .onChange(of: profiles.presented) { _, presented in
            guard let presented else { return }
            // Through the alias, when one was tapped: the cache is keyed by
            // the station's own callsign.
            let station = nodeAliases.directory.callsign(for: presented.callsign)
                ?? presented.callsign
            callsignLookup.preload([station])
        }
        .onChange(of: selectedNav) { _, newValue in
            syncSearchScope(for: newValue)
            syncConnectContext(for: newValue)
        }
        .onAppear {
            // The node directory turns aliases (COSCO, EVANS) into the
            // callsigns NET/ROM addresses by. Wired here rather than in
            // init because the store is a @StateObject.
            sessionCoordinator.nodeAliases = nodeAliases
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
                    sourceAlsoKnownAs: nodeAliases.directory.otherName(for: packet.fromDisplay),
                    destinationAlsoKnownAs: nodeAliases.directory.otherName(for: packet.toDisplay),
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

    /// Every callsign this station knows of, from any source.
    ///
    /// Deliberately wider than the heard list: a station named only in a route
    /// or a neighbour record is still one this station knows about, and the
    /// set is used to decide what may be forgotten. Erring wide keeps entries
    /// that might still be resolving a name.
    private var knownCallsigns: Set<String> {
        var known = Set(client.stations.map(\.call))
        if let integration = client.netRomIntegration {
            let mode = integration.currentMode
            known.formUnion(integration.currentNeighbors(forMode: mode).map(\.call))
            for route in integration.currentRoutes(forMode: mode) {
                known.insert(route.destination)
                known.insert(route.origin)
                known.formUnion(route.path)
            }
        }
        return known
    }

    private func profileMeasureKey(_ presentation: NodeProfileCoordinator.Presentation) -> String {
        presentation.callsign + (presentation.isPage ? "#page" : "#peek")
    }

    @ViewBuilder
    private func profileSheet(_ presentation: NodeProfileCoordinator.Presentation) -> some View {
            let measureKey = profileMeasureKey(presentation)
            let size = profileSheetSize(isPage: presentation.isPage,
                                        contentHeight: profileContentHeights[measureKey])
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { profiles.dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
                Divider()
                let profile = macResolver.profile(for: presentation.callsign)
                NodeProfileView(
                    profile: profile,
                    localCallsign: settings.myCallsign,
                    lookupEnabled: winlinkContext.settings.callsignLookupEnabled,
                    isLookingUp: lookingUpCallsign == presentation.callsign,
                    noteStore: client.stationNotes,
                    presentation: presentation.isPage ? .page : .sheet,
                    onOpenFullPage: presentation.isPage
                        ? nil : { profiles.promoteSheetToPage() },
                    onConnect: {
                        profiles.dismiss()
                        connectFromProfile(profile)
                    },
                    onOpenCallsign: { profiles.peek($0) })
                    .onPreferenceChange(NodeProfileContentHeightKey.self) { height in
                        guard height > 0 else { return }
                        profileContentHeights[measureKey] = height
                    }
                    .task(id: presentation.callsign) {
                        guard winlinkContext.settings.callsignLookupEnabled else { return }
                        lookingUpCallsign = presentation.callsign
                        defer { lookingUpCallsign = nil }
                        // The station behind the name, not the name tapped:
                        // a profile reached via the alias ALBBBS is about
                        // KB8OAK, and "ALBBBS" has no digit so the
                        // plausibility gate (rightly) refuses to look it up
                        // — which left alias-reached stations permanently
                        // nameless.
                        await callsignLookup.resolve(profile.baseCallsign)
                    }
            }
            // Deliberately NOT animated: animating the frame on `size`
            // made the first presentation glide its contents in from the
            // top-left as the fallback frame settled into the fitted one.
            // macOS animates the sheet window's own resize; the content
            // should just be laid out where it belongs.
            .frame(width: size.width, height: size.height)
    }

    /// Fit the sheet to its content, clamped to the window.
    ///
    /// A fixed frame either scrolled on a laptop or rattled around a big
    /// display; the profile reports its natural height and the sheet grows
    /// until nothing needs scrolling or the window runs out. Width is fixed
    /// per presentation — the peek is a column, the page is wide enough for
    /// balanced columns of section cards — because the measured height is
    /// only meaningful at the width it was measured at.
    private func profileSheetSize(isPage: Bool, contentHeight: CGFloat?) -> CGSize {
        let windowHeight = windowSize.height > 0 ? windowSize.height : 900
        let windowWidth = windowSize.width > 0 ? windowSize.width : 1400
        // Done bar plus divider, and a little slack: overshooting leaves a
        // sliver of blank, undershooting brings the scroll bar back.
        let chrome: CGFloat = 58 + 20
        let maxHeight = windowHeight - 80
        let fitted = contentHeight.map { $0 + chrome } ?? (isPage ? 740 : 620)
        // Wide enough for three balanced columns on a big display; a
        // smaller window narrows the page and the columns drop with it.
        let width: CGFloat = isPage
            ? min(1240, max(720, windowWidth - 320))
            : 480
        return CGSize(width: width, height: max(360, min(fitted, maxHeight)))
    }

    /// Connects to whatever the profile is about, the way it is reachable.
    ///
    /// Two different connections behind one button. A station this receiver has
    /// heard is called directly. One that only appears in a node's table has to
    /// be asked for *through* that node, and the alias is what goes on the wire
    /// — BPQ looks it up in its own table, and translating it here would fight
    /// the node that owns the name.
    private func connectFromProfile(_ profile: NodeProfile) {
        if let via = profile.reachVia.first {
            let asked = profile.resolvedFromAlias ?? profile.alias ?? profile.callsign
            issueStationConnectRequest(
                stationCall: asked, mode: .netrom,
                nextHopOverride: via, executeImmediately: true)
        } else {
            issueStationConnectRequest(
                stationCall: profile.callsign, mode: .ax25, executeImmediately: true)
        }
        selectedNav = .terminal
    }

    private func syncSearchScope(for item: NavigationItem) {
        switch item {
        case .terminal: searchModel.scope = .terminal
        case .packets: searchModel.scope = .packets
        case .routes: searchModel.scope = .routes
        case .nodes: searchModel.scope = .terminal  // the page filters in-pane
        case .analytics: searchModel.scope = .analytics
        case .map: searchModel.scope = .terminal
        case .mail: searchModel.scope = .terminal  // Mail has its own in-pane search
        case .bbs: searchModel.scope = .terminal    // The mailbox filters in-pane
        //case .raw: searchModel.scope = .terminal // Fallback or new scope if needed
        }
    }

    private func syncConnectContext(for item: NavigationItem) {
        switch item {
        case .terminal:
            connectCoordinator.activeContext = .terminal
        case .routes:
            connectCoordinator.activeContext = .routes
        case .packets, .analytics, .mail, .map, .bbs, .nodes:
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

    // MARK: - Reachable through a node

    /// A station some node said it can reach, and the node to ask.
    struct ReachableTarget: Identifiable, Hashable {
        let alias: String
        let callsign: String
        let via: String
        var id: String { alias }
    }

    /// What the network says is reachable, grouped by the node to go through.
    ///
    /// Kept apart from Stations because the two are different kinds of fact.
    /// A station in that list was *heard* — this receiver has its frames. An
    /// entry here is a *claim*: a node published a table saying it can get
    /// there, and nothing here has verified it. They also differ in what you
    /// do with them: one you call directly, the other through somebody.
    ///
    /// A station appears under *every* node that listed it, so the groups
    /// overlap. That is the honest shape: two nodes both carrying the same
    /// eighty stations is a fact about the network, and filing each station
    /// under only its freshest teller reported KB5YZB-7 as reaching one
    /// station when its table listed eighty-eight — it had simply been
    /// outbid on recency by COSCO, which changes nothing about what it
    /// reaches (2026-08-27).
    private var reachableByNode: [(via: String, targets: [ReachableTarget])] {
        return nodeAliases.directory.entriesByTeller()
            .map { via, entries in
                (via: via, targets: entries.map {
                    ReachableTarget(alias: $0.alias, callsign: $0.callsign, via: via)
                })
            }
            .sorted {
                if $0.targets.count != $1.targets.count {
                    return $0.targets.count > $1.targets.count
                }
                return $0.via < $1.via
            }
    }

    /// Distinct destinations, not the sum of the group counts — the groups
    /// overlap, and adding them up would count a station once per node that
    /// carries it.
    /// Changes when a station is heard for the first time (or the lookup
    /// opt-in flips), and not on every packet.
    private struct StationLookupKey: Hashable {
        let enabled: Bool
        let showsDirectory: Bool
        let calls: [String]
        let directorySize: Int
    }

    private var stationLookupKey: StationLookupKey {
        StationLookupKey(
            enabled: winlinkContext.settings.callsignLookupEnabled,
            showsDirectory: showsDirectoryNodes,
            calls: Set(client.stations.map { CallsignQuery.normalize($0.call) }).sorted(),
            directorySize: nodeAliases.directory.allEntries.count)
    }

    private var reachableCount: Int {
        Set(nodeAliases.directory.allEntries
            .filter { !$0.reachableVia.isEmpty }
            .map(\.alias)).count
    }

    /// The nodes that can reach things, and how many things each reaches.
    ///
    /// Deliberately not a browser. Expanding one node put eighty-five rows in
    /// the sidebar and pushed the navigation itself off the top — the section
    /// meant to orient the operator swallowed everything they were oriented by.
    /// Browsing is the Nodes page's job, and it is built for it: sectioned by
    /// route, searchable, sortable. Here a node is one line that says how much
    /// it reaches and takes you there.
    @ViewBuilder
    private var reachableSection: some View {
        if reachableCount > 0 {
            Section("Reachable via nodes (\(reachableCount))") {
                ForEach(reachableByNode, id: \.via) { group in
                    Button {
                        // A filter, not a search. Typing the node's name into
                        // the search field matched every entry that mentioned
                        // it anywhere and then re-filed those under whichever
                        // node listed them last, so this row's count and the
                        // page it opened disagreed by two orders of magnitude.
                        nodeRouteFilter = group.via
                        nodeQuery = ""
                        selectedNav = .nodes
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(group.via)
                                .font(.system(.subheadline, design: .monospaced))
                            Spacer()
                            Text("\(group.targets.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(group.via) published a table listing \(group.targets.count) "
                          + "stations it can connect you through to. Its claim, not a "
                          + "route this station has measured, and other nodes may "
                          + "list the same ones. Opens its table in Nodes.")
                }
            }
        }
    }

    /// Live NET/ROM circuits — the native transport, not the terminal
    /// relay. Separate from Stations for the same reason Reachable is:
    /// a circuit is a conversation this station is *holding*, not a
    /// station it has heard, and it may be several hops away with no
    /// direct evidence of the far end at all.
    @ViewBuilder
    private var circuitSection: some View {
        if !sessionCoordinator.netRomDriver.circuits.isEmpty {
            Section("NET/ROM circuits (\(sessionCoordinator.netRomDriver.circuits.count))") {
                ForEach(sessionCoordinator.netRomDriver.circuits) { circuit in
                    HStack(spacing: 6) {
                        Image(systemName: circuit.state == .connected
                              ? "point.3.connected.trianglepath.dotted"
                              : "ellipsis.circle")
                            .font(.caption)
                            .foregroundStyle(circuit.state == .connected ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(circuit.displayName)
                                .font(.system(.subheadline, design: .monospaced))
                            if circuit.neighbor.display != circuit.destination.display {
                                Text("via \(circuit.neighbor.display)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            sessionCoordinator.netRomDriver.disconnect(circuit.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Close this circuit")
                    }
                    .help(circuit.statusLine)
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedNav) {
            Section("Views") {
                ForEach(NavigationItem.allCases, id: \.self) { item in
                    Label(item.rawValue, systemImage: iconFor(item))
                        .badge(badgeCount(for: item))
                        .tag(item)
                        .accessibilityIdentifier("nav-\(item.rawValue.lowercased())")
                }
            }

            // Above Stations, not below it. Thirty heard stations scroll past
            // before the section would appear, so the answer to "what can I
            // reach" sat under the list of what was already reachable.
            // Collapsed, it costs one line per node.
            reachableSection

            circuitSection

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
                    let connectedCallsigns = Set(
                        sessionCoordinator.connectedSessions
                            .map { CallsignValidator.normalize($0.remoteAddress.display) }
                    )
                    // Same reason as the two above: a per-row lookup would scan
                    // the whole alias directory once per station, every render.
                    let alsoKnownAs = nodeAliases.directory.otherNames()
                    ForEach(client.stations) { station in
                        let normalizedCall = CallsignValidator.normalize(station.call)
                        let stationHasNetRomRoute = integration?.hasRoute(to: normalizedCall) ?? false
                        // Was computed and then discarded: both the tap and the
                        // plain "Connect" used a hardcoded AX.25 Direct, so a
                        // station the row showed as "Via DRLNOD" was called
                        // directly and never answered.
                        let preferredMode = connectCoordinator.preferredMode(
                            for: station.call,
                            hasNetRomRoute: stationHasNetRomRoute,
                            heardVia: station.lastVia
                        )
                        let preferredPath = ConnectCoordinator.returnPath(
                            heardVia: station.lastVia)
                        let isConnectedStation = connectedCallsigns.contains(normalizedCall)

                        StationRowView(
                            station: station,
                            isSelected: client.selectedStationCall == station.call,
                            isConnected: isConnectedStation,
                            capability: client.capabilityStore.capabilities(for: station.call),
                            alsoKnownAs: alsoKnownAs[station.call.uppercased()],
                            relayLegOf: nodeCapabilities.borrowedLegOwner(station.call)
                        )
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Connect") {
                                issueStationConnectRequest(
                                    stationCall: station.call,
                                    mode: preferredMode,
                                    viaDigis: preferredPath,
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
                                // Start a fresh pair. Without this a run of
                                // clicks chains into a double-click on every
                                // second one, so an impatient operator issues
                                // a connect request per pair rather than one.
                                lastTapTimes[station.call] = .distantPast
                                issueStationConnectRequest(
                                    stationCall: station.call,
                                    mode: preferredMode,
                                    viaDigis: preferredPath,
                                    executeImmediately: true
                                )
                            } else {
                                let capturedCall = station.call
                                let capturedMode = preferredMode
                                let capturedPath = preferredPath
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

    /// Every input deciding which addresses this station answers on, as one
    /// value, so the view can watch a single thing.
    private var serviceAddressSignature: String {
        let winlink = winlinkContext.settings
        return [settings.myCallsign,
                bbsSettings.onAir ? "1" : "0",
                bbsSettings.callsign,
                winlink.p2pListenEnabled ? "1" : "0",
                winlink.p2pListenCallsign].joined(separator: "|")
    }

    /// Registers every address a service answers on with the session layer.
    ///
    /// Frames not addressed to a registered address never reach the session
    /// layer, so this is what makes a service SSID mean anything at all.
    private func syncServiceAddresses() {
        bbsService.syncServiceAddress()

        let winlink = winlinkContext.settings
        let address = winlink.p2pListenEnabled
            ? winlink.effectiveP2PCallsign(stationCallsign: settings.myCallsign)
            : ""
        sessionCoordinator.sessionManager.setServiceAddress(
            address.isEmpty ? nil : CallsignNormalizer.toAddress(address),
            for: "winlink.p2p")
    }

    /// What each section is waiting on.
    ///
    /// The mailbox badges directory hints as well as unread mail: a fact
    /// spotted in a terminal session lands in a view the operator is not
    /// looking at, so something has to say it is there.
    private func badgeCount(for item: NavigationItem) -> Int {
        switch item {
        case .mail: winlinkContext.unreadCount
        case .bbs: bbsService.suggestions.count
        default: 0
        }
    }

    private func iconFor(_ item: NavigationItem) -> String {
        switch item {
        case .terminal: return "terminal"
        case .packets: return "list.bullet.rectangle"
        case .routes: return "arrow.triangle.branch"
        case .nodes: return "character.book.closed"
        case .analytics: return "chart.bar"
        case .map: return "map"
        case .mail: return "envelope"
        case .bbs: return "tray.full"
        //case .raw: return "doc.text"
        }
    }

    private func issueStationConnectRequest(stationCall: String,
                                            mode: ConnectBarMode,
                                            viaDigis: [String] = [],
                                            nextHopOverride: String? = nil,
                                            executeImmediately: Bool) {
        connectCoordinator.activeContext = .stations
        let normalized = CallsignValidator.normalize(stationCall)
        let intent: ConnectIntent
        switch mode {
        case .netrom:
            // A named next hop is how a directory entry connects: nothing here
            // has measured a route to the station, but a node listed it, so
            // that node is the one to ask.
            intent = ConnectIntent(
                kind: .netrom(nextHopOverride: nextHopOverride.flatMap(CallsignSSID.init)),
                to: normalized,
                sourceContext: .stations,
                suggestedRoutePreview: nil,
                validationErrors: [],
                routeHint: nil,
                note: nil
            )
        case .ax25ViaDigi:
            intent = ConnectIntent(
                kind: .ax25ViaDigis(viaDigis.compactMap(CallsignSSID.init)),
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
                    nodeAliases: nodeAliases,
                    nodeCapabilities: nodeCapabilities,
                    onSessionText: { text, peer in
                        // A node's `N` names its whole view of the network in
                        // one reply; a BBS listing names a dozen operators'
                        // home BBS. Both arrive because the operator went
                        // there, so both are read rather than thrown away.
                        nodeAliases.ingest(text: text, source: peer)
                        nodeCapabilities.ingest(line: text, peer: peer)
                        bbsService.observeSessionText(text, from: peer)
                        // A ROUTES table is the node's own neighbor list with
                        // measured qualities — the only routing knowledge a
                        // NODES-silent channel publishes. Rows become NET/ROM
                        // routes only through the capability gate: a KA-Node's
                        // table can never anchor a circuit.
                        if let row = routesScraper.ingest(line: text, peer: peer, at: Date()) {
                            // Whatever the router does with the row, the fact
                            // itself — "this node's table lists that station" —
                            // is a reachability edge the relay planner can walk.
                            // Routes need the anchor to be a dialable neighbor;
                            // a teller claim needs only the telling, so a table
                            // scraped three hops out (SOLBPQ, 2026-08-28 18:52)
                            // still teaches the planner a path.
                            nodeAliases.recordClaim(
                                station: row.neighbor, teller: peer, at: row.observedAt)
                            let decision = HarvestedRoutePolicy.decide(
                                rows: [row],
                                anchorCanRouteNetRom: nodeCapabilities.canRouteNetRom(peer),
                                localCallsign: settings.myCallsign)
                            if !decision.accepted.isEmpty {
                                client.netRomIntegration?.harvestedRoutes(
                                    from: peer,
                                    destinations: decision.accepted,
                                    timestamp: row.observedAt)
                            }
                            for refusal in decision.refused {
                                Telemetry.breadcrumb(
                                    category: "netrom.harvest",
                                    message: "Scraped route refused",
                                    data: ["neighbor": refusal.neighbor, "reason": refusal.reason],
                                    level: .debug)
                            }
                        }
                    },
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
            case .nodes:
                NodeDirectoryView(
                    aliases: nodeAliases,
                    query: $nodeQuery,
                    routeFilter: $nodeRouteFilter,
                    onSelect: { profiles.peek($0) },
                    onConnect: { alias, via in
                        issueStationConnectRequest(
                            stationCall: alias, mode: .netrom,
                            nextHopOverride: via, executeImmediately: true)
                        selectedNav = .terminal
                    },
                    knownCallsigns: knownCallsigns,
                    localCallsign: settings.myCallsign)
            case .analytics:
                AnalyticsDashboardView(packetEngine: client, settings: settings, viewModel: analyticsViewModel, connectCoordinator: connectCoordinator)
            case .map:
                StationsMapView(
                    stations: client.stations,
                recentPackets: Array(client.packets.suffix(600)),
                    gatewayGrids: gatewayGrids,
                    announcedGrids: announcedGrids.grids,
                    observerGrid: winlinkContext.settings.gridSquare,
                    myCallsign: settings.myCallsign,
                    lookup: callsignLookup,
                    aliases: nodeAliases,
                    settings: winlinkContext.settings,
                    noteStore: client.stationNotes,
                    pathStore: client.networkPaths,
                    serviceStore: client.stationServices,
                    onOpenProfile: { profiles.openPage($0) },
                    plannedChainFor: { macResolver.profile(for: $0).plannedChain },
                    onConnect: { call in
                        connectFromProfile(macResolver.profile(for: call))
                    },
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
            case .bbs:
                BBSView(
                    service: bbsService,
                    settings: bbsSettings,
                    library: bbsLibrary,
                    stationCallsign: settings.myCallsign
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
    ContentView(
        client: PacketEngine(settings: settings),
        settings: settings,
        inspectionRouter: .shared,
        winlinkContext: WinlinkContext(store: nil, settings: WinlinkSettings()),
        bbsSettings: BBSSettings()
    )
}
