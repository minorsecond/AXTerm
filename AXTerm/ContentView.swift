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
    /// Owns the terminal's view model, so leaving the Terminal page no
    /// longer destroys everything it knows about a session that is still up.
    @State private var terminalModels = TerminalModelBox()
    /// Keeps connected-mode sessions past a relaunch. Held by the shell
    /// because the terminal view is torn down on navigation and a session
    /// outlives that.
    @State private var sessionRecorder: TerminalSessionRecorder?
    // Same key the map's layers menu writes — the trickle lookup below
    // follows the operator's layer choice from anywhere in the app.
    @AppStorage("stations.showsDirectoryNodes") private var showsDirectoryNodes = false
    @StateObject private var nodeCapabilities = NodeCapabilityStore()
    /// Locators stations announce in their own beacons — the placement
    /// source for the part of the world no directory covers.
    @StateObject private var announcedGrids = AnnouncedGridStore()
    /// Off-main home for the periodic fold into the durable tables.
    @State private var sweeper = PacketSweeper()
    /// Live traffic merged with what previous sessions recorded, refreshed by
    /// the sweep rather than rebuilt per view evaluation.
    @State private var rememberedPaths: [NetworkPath] = []
    /// Reads BPQ ROUTES tables out of session transcripts; its rows become
    /// harvested routes when the capability verdict allows it.
    @State private var routesScraper = BpqRoutesScraper()
    /// The Nodes page's search text, held here so the sidebar can point it at
    /// one node's table.
    @State private var nodeQuery: String = ""
    /// The universal-search panel's explicit close state. Reset by the
    /// next keystroke; focus cannot drive this, because clicking a
    /// result would blur the field before the click lands.
    @State private var searchPanelDismissed = false
    /// Once true, the map stays mounted for the life of the window.
    @State private var mapKeptAlive = false
    /// Mail summaries for the universal search, loaded once per launch
    /// the first time a query needs them — not per keystroke.
    @State private var mailSearchIndex: [WinlinkMessageSummary] = []
    /// The node whose table the Nodes page is restricted to, set by the
    /// sidebar's "Reachable via" rows.
    @State private var nodeRouteFilter: String?
    /// Which face of the mailbox the BBS page shows. Held here because
    /// the sidebar is what chooses it.
    @State private var bbsPane: BBSPane = .messages
    /// Published by the map so the sidebar's layer rows can be gated and
    /// captioned without recomputing the map's caches on every render.
    @StateObject private var mapLayerStatus = MapLayerStatus()
    /// Live traffic for the map's strip. Its own object so the map is not
    /// re-rendered by frames it does not draw — see `MapTrafficFeed`.
    @StateObject private var mapTraffic = MapTrafficFeed()
    /// What became of the pings this station sent — see `APRSPingTracker`.
    /// Held here rather than in the map so an answer that arrives after the
    /// operator navigates away is still there when they come back.
    @StateObject private var aprsPings = APRSPingTracker()
    /// Who has decoded us and who we have decoded, for the map's coverage
    /// rings. Seeded from history rather than built live only — see
    /// `CoverageEvidenceStore`.
    @StateObject private var coverageEvidence = CoverageEvidenceStore()
    /// Keeps the coverage store fed while history loads — see its `seed`.
    @State private var loadedHistoryObserver: AnyCancellable?
    /// Downloaded terrain. Owned here because both the map's predicted-path
    /// layer and the station pages read it, and two handles to one elevation
    /// database would warm two caches for the same tiles.
    @StateObject private var elevation = ElevationStorage()
    /// The ground between here and the station whose page is open. Computed
    /// off the render pass: a profile is 256 elevation samples.
    @State private var profileTerrain: TerrainProfile?
    /// Whether that profile used the assumed far-antenna height.
    @State private var profileTerrainHeightAssumed = false
    /// The tiles this path still needs, and what they weigh.
    @State private var profileTerrainEstimate: ElevationStorage.Estimate?
    @State private var profileTerrainAreaEstimate: ElevationStorage.Estimate?
    /// False when no elevation source covers this path at all, so the card
    /// says so instead of offering a download that returns a tile of NaN.
    @State private var profileTerrainHasSource = true
    /// How far away the station is, when that is too far for a terrain
    /// profile to answer anything.
    @State private var profileTerrainOutOfRange: Double?
    /// Lifetime totals for the station on screen, read from the log rather
    /// than the capped in-memory window.
    @State private var profileStats: StationStats?
    /// Whether to take this device's GPS as the station's position.
    /// Off by default: the radio is not necessarily with the device.
    @AppStorage("station.useDeviceLocation") private var useDeviceLocation = false
    @AppStorage("station.manualLatitude") private var manualLatitude = ""
    @AppStorage("station.manualLongitude") private var manualLongitude = ""
    /// When a connection to the station on screen last completed over a
    /// path with no digipeater in it.
    @State private var profileLastDirectConnection: Date?
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
    /// Folds what the live window shows into the durable tables: what
    /// stations announced, which digipeaters demonstrably repeated a frame,
    /// and which paths were actually observed.
    ///
    /// Runs wherever the operator happens to be rather than only while a map
    /// is on screen, because the network's own record of itself should grow
    /// the whole time it is listening.
    ///
    /// The parsing and the two write transactions go to `PacketSweeper`, off
    /// this actor. They used to run inline here, which put a blocking GRDB
    /// transaction on the thread that draws the map every five seconds for as
    /// long as the app ran.
    private func sweepPackets(_ packets: [Packet]) {
        // Stays here: it publishes into the views, and it persists to a
        // UserDefaults blob rather than to the database.
        announcedGrids.ingest(packets: Array(packets.suffix(Self.serviceWindow)))
        let services = client.stationServices
        let paths = client.networkPaths
        let localCallsign = settings.myCallsign
        Task {
            let merged = await sweeper.sweep(packets: packets,
                                             localCallsign: localCallsign,
                                             services: services,
                                             paths: paths,
                                             serviceWindow: Self.serviceWindow,
                                             pathWindow: Self.pathWindow,
                                             retention: SQLiteNetworkPathStore.retention)
            rememberedPaths = merged
        }
    }

    /// How much of the live buffer each half of the sweep reads.
    private static let serviceWindow = 400
    private static let pathWindow = 600

    /// Same gathering as the handheld's, from the Mac's own view state.
    /// The graph the identity page reasons over.
    ///
    /// Live traffic merged with what previous sessions recorded, so "which
    /// stations does the network depend on" is answered from days of evidence
    /// rather than from the last few minutes of it.
    /// Gathered by the five-second sweep, off this actor, and held.
    ///
    /// This was a computed property that parsed 600 packets and read the
    /// store's whole retention window on every evaluation. `macResolver` is
    /// also computed and is called from a closure invoked once per station
    /// row, so a list of twenty stations meant twenty fourteen-day reads per
    /// redraw. Nothing here changes between two frames.
    private var rememberedNetworkPaths: [NetworkPath] { rememberedPaths }

    /// Every address this station transmits as, SSIDs included. Any *other*
    /// SSID on the same licence is a different radio — the operator's HT is
    /// K0EPI-4 — and belongs on the map like any other station.
    private var ownAddresses: Set<String> {
        let answered = Set(sessionCoordinator.sessionManager.answeredAddresses
            .map { $0.display.uppercased() })
        return answered.isEmpty ? [settings.myCallsign.uppercased()] : answered
    }

    private var macResolver: NodeProfileResolver {
        let stations = client.stations
        let heard = HeardStationMap.entries(
            stations: stations,
            directory: callsignLookup.records,
            gatewayGrids: gatewayGrids,
            announcedGrids: announcedGrids.grids,
            excluding: ownAddresses)
        let aliasEntries = HeardStationMap.aliasEntries(
            aliases: nodeAliases.directory,
            usedAliases: HeardStationMap.aliasesInUse(stations),
            directory: callsignLookup.records,
            stations: stations)
        let neighbours = client.netRomIntegration?.currentNeighbors() ?? []
        let routes = client.netRomIntegration?.currentRoutes() ?? []

        return NodeProfileResolver(
            maxChainLength: settings.autoRouteMaxChainLength,
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

    /// Our own APRS symbol, drawn on the observer marker when the map is
    /// scoped to a radio that beacons an APRS position — so viewing the map
    /// "through" a radio that is using APRS shows us as the very symbol we
    /// put on the air, not the generic home arrow. Nil when no visible radio
    /// beacons a position, which keeps the plain observer marker for a station
    /// that isn't running APRS.
    private var ownAPRSSymbol: APRSMapSymbol? {
        let visible = settings.activeRadios.filter { !client.hiddenRadioIDs.contains($0.id) }
        let beaconing = visible.filter {
            $0.beacon.kind == .aprsPosition && $0.beacon.aprs != nil
        }
        // Prefer the primary radio's symbol when more than one is beaconing.
        let chosen = beaconing.first { $0.id == settings.primaryRadio?.id } ?? beaconing.first
        guard let aprs = chosen?.beacon.aprs else { return nil }
        return APRSMapSymbol(table: aprs.symbolTable.first ?? "/",
                             code: aprs.symbolCode.first ?? "-")
    }

    @Environment(\.openSettings) private var openSettings

    @State private var selectedNav: NavigationItem = .terminal
    @StateObject private var searchModel = AppToolbarSearchModel()
    @ObservedObject private var bbsSettings: BBSSettings
    @StateObject private var bbsService: BBSService
    @StateObject private var bbsLibrary: BBSFileLibrary
    @State private var filters = PacketFilters()
    @State private var showingPacketFilters = false

    @State private var selection = Set<Packet.ID>()
    /// The station a map "Message" action is composing to, if any.
    private struct APRSComposeTarget: Identifiable { let id = UUID(); let call: String }
    @State private var aprsComposeTarget: APRSComposeTarget?
    /// Surfaced when turning a map layer into a Winlink draft fails.
    @State private var layerSendError: String?
    @State private var inspectorSelection: PacketInspectorSelection?
    @FocusState private var isSearchFocused: Bool
    @State private var didLoadPacketsHistory = false
    @State private var didLoadConsoleHistory = false
    @State private var didLoadRawHistory = false
    @State private var selectionMutationScheduler = SelectionMutationScheduler()
    @StateObject private var analyticsViewModel: AnalyticsDashboardViewModel
    /// Owned here rather than inside the mail pane, because the sidebar
    /// and the message list are siblings: the folders can only appear in
    /// the sidebar if both columns read the same mailbox.
    @StateObject private var mailboxVM: WinlinkMailboxViewModel
    @State private var lastTapTimes: [String: Date] = [:]


    init(client: PacketEngine, settings: AppSettingsStore, inspectionRouter: PacketInspectionRouter, winlinkContext: WinlinkContext, bbsSettings: BBSSettings) {
        _client = StateObject(wrappedValue: client)
        _settings = ObservedObject(wrappedValue: settings)
        _inspectionRouter = ObservedObject(wrappedValue: inspectionRouter)
        _winlinkContext = ObservedObject(wrappedValue: winlinkContext)
        // `store` is a `let` fixed when the context is built at launch,
        // so this cannot latch onto the fallback and then miss a real
        // database arriving later.
        _mailboxVM = StateObject(wrappedValue: WinlinkMailboxViewModel(
            store: winlinkContext.store ?? FallbackWinlinkStore(),
            myCallsign: { [weak settings] in settings?.myCallsign ?? "" }))
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
        // An APRS position beacon set to "use GPS" reads the last known fix
        // (or the manual grid-square position) at send time.
        let locationService = winlinkContext.locationService
        coordinator.aprsLocationProvider = { [weak locationService] in
            guard let loc = locationService?.lastLocation ?? locationService?.manualLocation()
            else { return nil }
            return (loc.latitude, loc.longitude)
        }
        // Restore the operator's NET/ROM node policy. Both switches
        // default off, so on a station that has never enabled them this
        // does nothing at all; on one that has, it resumes announcing at
        // launch rather than waiting for a visit to Settings.
        coordinator.applyNetRomNodeSettings(settings)
        coordinator.subscribeToPackets(from: client)
        // APRS messaging: wire the transmit funnel, the query-answer
        // providers, and start the ACK-retry sweep. Auto-reply defaults to
        // full (auto-ACK incoming messages and answer directed queries).
        if let aprs = client.aprsMessaging {
            aprs.autoReplyProvider = { APRSMessagingService.AutoReply(rawValue: settings.aprsAutoReplyRaw) ?? .full }
            aprs.send = { [weak coordinator] out in _ = coordinator?.sendAPRS(out) }
            aprs.positionInfo = { [weak coordinator] in coordinator?.currentAPRSPositionInfo() }
            aprs.heardDirect = { [weak client] in
                Array((client?.stations ?? []).filter { $0.lastVia.isEmpty }.map { $0.call }
                    .prefix(APRSMessagingService.directsStationLimit))
            }
            // Objects we own, most urgent first — `live()` already sorts
            // that way, and the cap in `objectAnswers` depends on it. Each is
            // rebuilt with the current time rather than replayed: see
            // `reannounced(at:)`.
            aprs.ownObjects = { [weak client, weak coordinator] in
                guard let client else { return [] }
                // The same set `mayRemove` uses: every address this station
                // answers to, not just the configured callsign. An object
                // placed from a second radio's SSID is still ours.
                let answered = Set((coordinator?.sessionManager.answeredAddresses ?? [])
                    .map { $0.display.uppercased() })
                let ours = answered.isEmpty ? [settings.myCallsign.uppercased()] : Array(answered)
                let oursSet = Set(ours)
                let asOf = Date()
                return client.aprsObjects.live()
                    .filter { oursSet.contains($0.reportedBy.uppercased()) }
                    .compactMap { $0.report.reannounced(at: asOf) }
            }
            aprs.versionInfo = {
                let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                return v.isEmpty ? "AXTerm" : "AXTerm \(v)"
            }
            aprs.startRetryTimer()
        }
        // "Who can hear me": flood one unaddressed ?APRS? general query and
        // fold in whoever answers (real APRS stations only, never packet
        // nodes). Xastir-style — one transmission, not a directed poll.
        let probe = client.aprsProbe
        probe.aprsStations = { [weak client] in client?.aprsHeardStations() ?? [] }
        // Sampled when a query goes out, so the results can tell an answer
        // from a station that beacons often enough to land in any window.
        probe.beaconIntervals = { [weak client] in client?.aprsBeaconIntervals() ?? [:] }
        probe.floodQuery = { [weak coordinator] query, reach in
            (coordinator?.floodAPRS(query.rawValue, reach: reach) ?? 0) > 0
        }
        // A queued send has already reported success by the time a radio fails
        // to key, so the probe hears about that the only way it can: a link
        // fault arriving while it is listening.
        client.onLinkError = { [weak probe] message in probe?.transmitDidFail(message) }
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

    /// The window, assembled in layers.
    ///
    /// One chain of thirty modifiers is a single expression, and the Swift
    /// type checker solves it as one problem — this body twice hit "unable to
    /// type-check this expression in reasonable time" and left a stale
    /// indexer pinned on the file for minutes at a stretch. Split into stages,
    /// each is a small problem solved on its own.
    ///
    /// The stages are contiguous slices in their original order, because
    /// modifier order is behaviour: a `.searchable` above an `.overlay` is not
    /// the same view as one below it.
    var body: some View {
        presentationLayer
    }


    /// The window itself. Everything below is a layer over this one.
    private var windowShell: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .accessibilityIdentifier("mainWindowRoot")
    }

    /// Attaching and detaching the station: which addresses it answers on, and
    /// saying goodbye before the machine sleeps or quits.
    private var serviceLifecycleLayer: some View {
        windowShell
        .task {
            if sessionRecorder == nil {
                sessionRecorder = TerminalSessionRecorder(store: client.terminalSessions)
            }
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
    }

    /// The toolbar search field and the panel it opens.
    private var searchLayer: some View {
        serviceLifecycleLayer
        .searchable(text: $searchModel.query, prompt: searchPlaceholder)
        // The toolbar search field is THE search field — on pages that
        // filter in-pane it must drive that filter, not silently sift a
        // pane the operator cannot see (field ask 2026-08-29 06:51: "the
        // universal search doesn't seem to be working on this page").
        .onChange(of: searchModel.query) { _, text in
            if selectedNav == .nodes { nodeQuery = text }
            // A fresh keystroke reopens the panel a click dismissed, and
            // lazily loads the mail index the first time it is needed.
            searchPanelDismissed = false
            if !text.isEmpty, mailSearchIndex.isEmpty { loadMailSearchIndex() }
        }
        // Every category the query matched, floating under the field —
        // "universal" meaning universal (field ask 2026-08-29 07:07).
        // Dismissal is explicit state rather than field focus, because a
        // click inside the panel would drop focus before the click lands.
        .overlay(alignment: .topTrailing) {
            let trimmed = searchModel.query.trimmingCharacters(in: .whitespaces)
            if !searchPanelDismissed,
               trimmed.count >= UniversalSearchIndex.minimumQueryLength {
                UniversalSearchPanel(
                    results: universalSearchResults,
                    query: trimmed,
                    onOpen: { openSearchResult($0) },
                    onDismiss: { searchPanelDismissed = true })
                .padding(.top, 2)
                .padding(.trailing, 12)
            }
        }
        .searchFocused($isSearchFocused)
    }

    /// Toolbar, alerts, and the invisible label the UI tests read.
    private var chromeLayer: some View {
        searchLayer
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
    }

    /// Work that begins once at launch: console history, analytics warm-up, and
    /// the adaptive link-quality sampler.
    private var startupWorkLayer: some View {
        chromeLayer
        .task {
            guard !didLoadConsoleHistory else { return }
            didLoadConsoleHistory = true
            SentryManager.shared.addBreadcrumb(category: "app.lifecycle", message: "Main UI ready", level: .info, data: nil)
            // Load console history for the default Terminal view
            client.loadPersistedConsole()
        }
        .task(id: useDeviceLocation) {
            // Ask for a fix at launch, not only when Settings is open.
            //
            // Requesting one was wired on the Settings page and nowhere
            // else, so an operator who had switched device location on got a
            // grid centre until they happened to open that page — and the
            // toolbar, correctly, reported "No GPS fix" the whole time. The
            // switch is a station-level setting; honouring it is the shell's
            // job, not a side effect of visiting a preferences pane.
            guard useDeviceLocation else { return }
            _ = await winlinkContext.locationService.currentLocation()
            // ...and keep it no staler than the fix lifetime. This loop is
            // the app's only GPS cadence: everyone else reads through the
            // service's cache, so however often the map or Winlink ask,
            // CoreLocation hears about it once per lifetime.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(StationLocationService.gpsFixLifetime))
                guard !Task.isCancelled, useDeviceLocation else { return }
                _ = await winlinkContext.locationService.currentLocation()
            }
        }
        .task {
            // Warm analytics caches in the background so first tab-open is fast.
            analyticsViewModel.prewarmIfNeeded(with: client.packets)
            // Analytics owns the derivation; the context owns the decision
            // to publish. Wired here because this is the one place holding
            // both, and it keeps the store from reaching up into analytics
            // for packets and inferred roles.
            analyticsViewModel.onStationDirectoryChanged = { [weak context = winlinkContext] directory in
                context?.publishLocalActivity(directory, callsign: settings.myCallsign)
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
                   case let records = integration.exportLinkStats(),
                   case let aprsOnly = Self.radiosCarryingOnlyAPRS(families: radioFamilies),
                   case let byRadio = Self.aggregateLinkQualityPerRadio(
                       records, localCallsign: coordinator.localCallsign
                   ), !byRadio.isEmpty || !aprsOnly.isEmpty {
                    // Said whether or not any radio produced a figure: a
                    // station with one APRS radio and nothing else has no
                    // figure to show and the most to explain.
                    coordinator.adaptiveStatusStore.setRadiosCarryingOnlyAPRS(aprsOnly)
                    // One sample per channel, filed against that channel. The
                    // blended figure this replaced was wrong for every radio
                    // that was not average.
                    for (radio, sample) in byRadio {
                        coordinator.applyLinkQualitySample(
                            lossRate: sample.lossRate, etx: sample.etx, srtt: nil,
                            source: sample.scope.sourceLabel,
                            scope: .radio(radio))
                    }
                    didSampleEver = true
                }
                let delay = Self.networkSampleDelaySeconds(didSampleEver: didSampleEver, attempts: attempts)
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }

    /// Work keyed to what the operator is looking at, plus the callsign lookups
    /// that follow heard stations rather than page visits.
    private var navigationWorkLayer: some View {
        startupWorkLayer
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
            case .messages:
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
            // Everything this app already knows, first and unconditionally.
            //
            // The node layer draws a marker only when the operator's record
            // is in memory, and memory starts empty at every launch — so a
            // position cached weeks ago was invisible until something asked
            // for it again. That put a local cache read behind the online
            // toggle and behind the courtesy pacing, and the layer came back
            // a name every second and a half instead of at launch (field ask
            // 2026-09-03: 150 of 170 node operators were sitting in the
            // cache while the map drew a handful).
            callsignLookup.preload(
                client.stations.map(\.call)
                + HeardStationMap.directoryOperatorCallsigns(
                    aliases: nodeAliases.directory))

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
            // After the preload above this is only the genuinely unknown
            // remainder — the twenty or so nobody has ever answered for.
            guard showsDirectoryNodes else { return }
            let directory = HeardStationMap.directoryLookupCandidates(
                aliases: nodeAliases.directory,
                cachedCallsigns: Set(callsignLookup.records.keys.map { $0.uppercased() }),
                heardBases: Set(client.stations.map { CallsignQuery.normalize($0.call) }),
                limit: Int.max)
            // Quiet resolves, published in batches: one @Published
            // change per record re-rendered the whole app every couple
            // of seconds and drove the menu-bar extra into an AppKit
            // update-constraints storm that froze the terminal at launch
            // (field capture 2026-08-29 06:12). A map layer that fills
            // in every half minute is the same feature without the storm.
            defer { callsignLookup.flushStaged() }
            var sinceFlush = 0
            for call in directory {
                guard !Task.isCancelled, !callsignLookup.isCoolingDown else { return }
                let origin = await callsignLookup.resolving(
                    call, publishImmediately: false).origin
                sinceFlush += 1
                if sinceFlush >= 15 {
                    callsignLookup.flushStaged()
                    sinceFlush = 0
                }
                // A courtesy gap: this is someone's free service and the
                // radio is in no hurry. ~40/minute, and the service's
                // breaker stops the whole pass the moment the far end
                // answers 429 or falls over. Owed only for a query that
                // actually left this machine — waiting between local reads
                // is politeness to nobody.
                guard origin == .network else { continue }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// Menu commands, the throttled packet sweep, and the window-size probe.
    private var commandLayer: some View {
        navigationWorkLayer
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
            sweepPackets(packets)
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
    }

    /// Sheets and the state changes that open them.
    private var presentationLayer: some View {
        commandLayer
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
            wireNetRomNodeHost()
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
                    terrain: profileTerrain,
                    terrainHeightIsAssumed: profileTerrainHeightAssumed,
                    terrainEstimate: profileTerrainEstimate,
                    lastDirectConnection: profileLastDirectConnection,
                    terrainAreaEstimate: profileTerrainAreaEstimate,
                    terrainSourceHasCoverage: profileTerrainHasSource,
                    terrainBeyondRadioRange: profileTerrainOutOfRange,
                    terrainOriginPosition: myPosition,
                    isUsingDeviceLocation: useDeviceLocation,
                    onToggleDeviceLocation: {
                        useDeviceLocation.toggle()
                        Task { await refreshProfileTerrain(for: profile) }
                    },
                    stats: profileStats,
                    isDownloadingTerrain: elevation.downloadState.isBusy,
                    onDownloadTerrain: {
                        guard let path = terrainPath(to: profile) else { return }
                        elevation.download(alongPathFrom: path.origin, to: path.destination)
                    },
                    onDownloadTerrainArea: {
                        guard let path = terrainPath(to: profile) else { return }
                        elevation.download(around: path.origin)
                    },
                    presentation: presentation.isPage ? .page : .sheet,
                    onOpenFullPage: presentation.isPage
                        ? nil : { profiles.promoteSheetToPage() },
                    onConnect: {
                        profiles.dismiss()
                        connectFromProfile(profile)
                    },
                    onOpenCallsign: { profiles.peek($0) },
                    onForgetStation: {
                        // Clears the directory entry and every claim this
                        // station made about reaching others. The operator's
                        // call: a misattributed claim is indistinguishable
                        // from a correct one after the fact.
                        let tally = nodeAliases.forgetStation(profile.callsign)
                        client.appendSystemNotification(
                            tally.removedAnything
                            ? "Forgot \(profile.callsign): \(tally.ownEntries) entry, "
                              + "\(tally.claims) claim\(tally.claims == 1 ? "" : "s") about other stations."
                            : "Nothing was stored about \(profile.callsign).")
                        profiles.dismiss()
                    })
                    .onPreferenceChange(NodeProfileContentHeightKey.self) { height in
                        guard height > 0 else { return }
                        profileContentHeights[measureKey] = height
                    }
                    .task(id: presentation.callsign) {
                        await refreshProfileTerrain(for: profile)
                    }
                    // A finished download is new evidence about the same
                    // path, so the card recomputes rather than leaving the
                    // operator to close and reopen the page they just
                    // fetched tiles from.
                    .task(id: elevation.tileCount) {
                        await refreshProfileTerrain(for: profile)
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
                nextHopOverride: via, executeImmediately: true,
                origin: .explicitAction)
        } else {
            issueStationConnectRequest(
                stationCall: profile.callsign, mode: .ax25, executeImmediately: true,
                origin: .explicitAction)
        }
        selectedNav = .terminal
    }

    /// The node service behind inbound NET/ROM circuits: identity, what
    /// it may say, and the mailbox to hand callers to. Wired on appear
    /// for the same @StateObject reason as nodeAliases.
    private func wireNetRomNodeHost() {
        let host = sessionCoordinator.netRomNodeHost
        host.identityProvider = { [weak settings] in
            let alias = settings?.netRomNodeAlias
                .trimmingCharacters(in: .whitespaces).uppercased() ?? ""
            return (alias.isEmpty ? "NODE" : alias,
                    settings?.myCallsign.uppercased() ?? "N0CALL",
                    "AXTerm")
        }
        host.snapshotProvider = { [weak client, weak nodeAliases, weak bbsSettings] in
            var snapshot = NetRomNodeShell.Snapshot()
            if let integration = client?.netRomIntegration {
                let aliasFor = { (call: String) -> String in
                    nodeAliases?.directory.allEntries.first {
                        $0.callsign.uppercased() == call.uppercased()
                    }?.alias ?? ""
                }
                snapshot.routes = integration.currentRoutes().map { route in
                    NetRomNodeShell.Snapshot.Route(
                        destination: route.destination,
                        alias: aliasFor(route.destination),
                        nextHop: route.origin,
                        quality: route.quality)
                }
                snapshot.neighbors = integration.currentNeighbors().map { neighbor in
                    NetRomNodeShell.Snapshot.Neighbor(
                        callsign: neighbor.call,
                        quality: neighbor.quality,
                        count: max(1, neighbor.obsolescenceCount))
                }
            }
            snapshot.heard = (client?.stations ?? []).compactMap { station in
                station.lastHeard.map {
                    NetRomNodeShell.Snapshot.Heard(callsign: station.call, lastHeard: $0)
                }
            }
            snapshot.stationInfo = bbsSettings?.stationInfo ?? ""
            snapshot.bbsAvailable = bbsSettings?.onAir ?? false
            return snapshot
        }
        host.bbsSessionFactory = { [weak bbsService] caller in
            bbsService?.beginCircuitSession(caller: caller)
        }
    }

    private func syncSearchScope(for item: NavigationItem) {
        switch item {
        case .terminal: searchModel.scope = .terminal
        case .packets: searchModel.scope = .packets
        case .routes: searchModel.scope = .routes
        case .nodes: searchModel.scope = .terminal  // mirrored into nodeQuery below
        case .analytics: searchModel.scope = .analytics
        case .map: searchModel.scope = .terminal
        case .mail: searchModel.scope = .terminal  // Mail has its own in-pane search
        case .bbs: searchModel.scope = .terminal    // The mailbox filters in-pane
        case .messages: searchModel.scope = .terminal  // Messages filter in-pane
        //case .raw: searchModel.scope = .terminal // Fallback or new scope if needed
        }
    }

    private func syncConnectContext(for item: NavigationItem) {
        switch item {
        case .terminal:
            connectCoordinator.activeContext = .terminal
        case .routes:
            connectCoordinator.activeContext = .routes
        case .packets, .analytics, .mail, .map, .bbs, .nodes, .messages:
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
    /// The station's radios, each with a switch that shows or hides its
    /// traffic everywhere. Absent with one radio: there is nothing to choose.
    private var radiosSection: some View {
        if settings.hasMultipleRadios {
            let summaries = client.radioSummaries
            let connected = summaries.filter { $0.status == .connected }.count
            Section(RadioPresentation.sidebarTitle(total: summaries.count, connected: connected,
                                                   hidden: client.hiddenRadioIDs.count)) {
                HStack {
                    Label("All Radios", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(.subheadline))
                    Spacer()
                    if client.hiddenRadioIDs.isEmpty {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(client.hiddenRadioIDs.isEmpty ? .secondary : .primary)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { client.hiddenRadioIDs = [] }
                .help("Show every radio's traffic together, interleaved.")

                ForEach(summaries, id: \.id) { radio in
                    RadioRowView(radio: radio, isShown: radioShownBinding(radio.id),
                                 families: radioFamilies[radio.id] ?? [])
                        .contextMenu {
                            switch radio.status {
                            case .connected:
                                Button("Disconnect \(radio.name)") { client.radioManager.close(radio.id) }
                            case .connecting:
                                Button("Cancel") { client.radioManager.close(radio.id) }
                            case .disconnected, .failed:
                                Button("Connect \(radio.name)") { client.radioManager.open(radio.id) }
                            }
                            if !radio.callsign.isEmpty {
                                Button("Copy Callsign") { ClipboardWriter.copy(radio.callsign) }
                            }
                            Divider()
                            Button("Radio Settings\u{2026}") {
                                SettingsRouter.shared.navigate(to: .radios, radio: radio.id)
                            }
                        }

                    // The map layers that only mean anything for what this
                    // radio carries, under the radio itself. A flat list of
                    // every layer could not say that "Transmitted Positions"
                    // is an APRS idea, so leaving it on emptied the map of a
                    // packet channel's stations.
                    // Nothing while the radio is hidden: its layers cannot
                    // draw anything, and four dimmed rows that do nothing are
                    // four rows of the list spent saying so.
                    if sidebarSection == .mapLayers,
                       !client.hiddenRadioIDs.contains(radio.id),
                       let families = mapLayerPlan.perRadio[radio.id], !families.isEmpty {
                        CollapsibleMapLayerToggles(
                            status: mapLayerStatus,
                            scope: .families(families),
                            expansionKey: "stations.expandedRadioLayers." + radio.id.rawValue)
                            .padding(.leading, 14)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }
            }
        }
    }

    /// What each radio has been heard carrying. Drives the row's badge and
    /// which layers are filed under it.
    /// Stations to offer as APRS addressees: what has actually been heard,
    /// so the commonest case is picking rather than typing a callsign.
    ///
    /// Drawn from heard traffic rather than from a contacts list, because the
    /// station worth messaging on APRS is almost always one that just said
    /// something.
    private var aprsAddresseeSuggestions: [APRSComposeModel.Suggestion] {
        client.stations.map { station in
            APRSComposeModel.Suggestion(
                callsign: station.call.uppercased(),
                lastHeard: station.lastHeard,
                via: station.lastVia.isEmpty ? nil : station.lastViaDisplay)
        }
    }

    private var radioFamilies: [RadioID: Set<RadioTrafficFamily>] {
        RadioTrafficClassifier.families(from: client.stations)
    }

    /// Which family's layers sit under which radio, and which are left in the
    /// shared Layers section.
    private var mapLayerPlan: MapLayerPlacement.Plan {
        MapLayerPlacement.plan(families: radioFamilies,
                               radios: client.radioSummaries.map(\.id))
    }

    private func radioShownBinding(_ id: RadioID) -> Binding<Bool> {
        Binding(
            get: { !client.hiddenRadioIDs.contains(id) },
            set: { shown in
                if shown { client.hiddenRadioIDs.remove(id) } else { client.hiddenRadioIDs.insert(id) }
            })
    }

    /// The radios that heard a station, most recent first, for its row.
    private func heardOnText(_ station: Station) -> String? {
        guard settings.hasMultipleRadios, !station.perRadio.isEmpty else { return nil }
        let names = station.heardOn.compactMap { id in
            settings.radio(id).map { $0.name.isEmpty ? RadioProfile.defaultName(for: $0) : $0.name }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// The map's scope line while some radio is hidden.
    private var radioScopeNote: String? {
        client.visibleRadioNames.map { "Showing stations heard on \($0.joined(separator: ", ")) only" }
    }

    @ViewBuilder
    private var reachableSection: some View {
        if reachableCount > 0 {
            Section("Reachable via nodes (\(reachableCount))") {
                ForEach(reachableByNode, id: \.via) { group in
                    reachableRow(via: group.via, count: group.targets.count)
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

    /// Whether the station filter drives the frontmost page. The filter
    /// shapes the Terminal, Packets and Analytics views; everywhere else
    /// its selection styling is quieted so the sidebar shows one "you
    /// are here" at a time.
    private var stationFilterApplies: Bool {
        switch selectedNav {
        case .terminal, .packets, .analytics: return true
        default: return false
        }
    }

    /// What belongs in the sidebar beside the frontmost page.
    private var sidebarSection: SidebarContext.Section {
        SidebarContext.section(for: selectedNav)
    }

    private var showsRadioSections: Bool { sidebarSection == .radio }

    /// The radio show/hide filter is shown on the standard-sidebar pages —
    /// the ones the filter actually scopes — which is everything except Mail
    /// and BBS, whose own navigation columns would compete with it.
    private var showsRadioFilter: Bool {
        sidebarSection == .radio || sidebarSection == .mapLayers
    }

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
            // Mail and BBS bring their own navigation column, and nothing
            // here shapes them — showing it anyway left two sidebars
            // competing before the content started.
            // The radio filter is a global scope — it decides what every page
            // draws, not just the station-filtered ones — so it stays in the
            // sidebar on the Map, Analytics, Routes and Nodes pages too, where
            // the operator most wants to say "just the 705" or "just Direwolf"
            // and watch it apply. (Self-hides with a single radio.) Left off
            // Mail and BBS, which bring their own navigation column.
            if showsRadioFilter {
                radiosSection
            }

            if showsRadioSections {
                reachableSection

                circuitSection
            }

            // What the page navigates by, in the place the sidebar keeps it.
            // Two navigation columns before any content began was the
            // complaint; a sidebar that changes with the page answers it
            // without taking anything away.
            switch sidebarSection {
            case .radio:
                EmptyView()   // Drawn above, where its three sections belong.
            case .mapLayers:
                // With one radio, or before any traffic has been classified,
                // every layer stays in one list — there is no second network
                // to separate it from.
                MapLayerRows(status: mapLayerStatus, radioScope: radioScopeNote,
                             scope: settings.hasMultipleRadios && mapLayerPlan.isGrouped
                                 ? .shared(mapLayerPlan.orphans)
                                 : .everything)
            case .mailFolders:
                WinlinkFolderRows(viewModel: mailboxVM)
            case .bbsPanes:
                BBSPaneRows(pane: $bbsPane,
                            liveCallers: bbsService.live == nil ? 0 : 1,
                            messageCount: bbsService.messages.count)
            }

            if showsRadioSections {
            Section("Stations (\(client.stations.filter(client.isVisible).count))") {
                // "All" option. The accent treatment appears only while a
                // page this filter actually drives is frontmost — on the
                // Nodes or Map page a lit "All Packets" beside the lit
                // page item read as three simultaneous locations (field
                // ask 2026-08-29 06:59). The checkmark alone remembers
                // the choice everywhere.
                HStack {
                    Text("All Packets")
                        .fontWeight(client.selectedStationCall == nil
                                    && stationFilterApplies ? .semibold : .regular)
                    Spacer()
                    if client.selectedStationCall == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(stationFilterApplies ? .secondary : .tertiary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    Group {
                        if client.selectedStationCall == nil, stationFilterApplies {
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
                    ForEach(client.stations.filter(client.isVisible)) { station in
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
                            isSelected: client.selectedStationCall == station.call
                                && stationFilterApplies,
                            isConnected: isConnectedStation,
                            capability: client.capabilityStore.capabilities(for: station.call),
                            alsoKnownAs: alsoKnownAs[station.call.uppercased()],
                            relayLegOf: nodeCapabilities.borrowedLegOwner(station.call),
                            heardOn: heardOnText(station)
                        )
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Connect") {
                                issueStationConnectRequest(
                                    stationCall: station.call,
                                    mode: preferredMode,
                                    viaDigis: preferredPath,
                                    executeImmediately: true,
                                    origin: .explicitAction
                                )
                            }
                            Button("Connect via AX.25") {
                                issueStationConnectRequest(
                                    stationCall: station.call,
                                    mode: .ax25,
                                    executeImmediately: true,
                                    origin: .explicitAction
                                )
                            }
                            Button("Connect via NET/ROM") {
                                issueStationConnectRequest(
                                    stationCall: station.call,
                                    mode: .netrom,
                                    executeImmediately: true,
                                    origin: .explicitAction
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
                                    executeImmediately: true,
                                    origin: .explicitAction
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
                                            viaDigis: capturedPath,
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
        case .messages: client.aprsMessaging?.unreadCount ?? 0
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
        case .messages: return "message"
        //case .raw: return "doc.text"
        }
    }

    private func issueStationConnectRequest(stationCall: String,
                                            mode: ConnectBarMode,
                                            viaDigis: [String] = [],
                                            nextHopOverride: String? = nil,
                                            executeImmediately: Bool,
                                            origin: ConnectOrigin = .selection) {
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
            ConnectRequest(intent: intent, mode: mode,
                           executeImmediately: executeImmediately, origin: origin)
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

            ZStack {
                detailSwitch
                // The map lives OUTSIDE the switch: mounted on first
                // visit or three seconds after launch (whichever comes
                // first) and never unmounted, so tiles, Metal state and
                // the camera are warm before the operator clicks Map —
                // and still where they left them when they come back.
                if mapKeptAlive || selectedNav == .map {
                    // The map is mounted the whole time (see below), so
                    // without this it re-ran its body on every packet on
                    // every tab — the AttributeGraph/Observation churn that
                    // held the main thread at 40%% of a core. The box prunes
                    // that subtree between meaningful changes: its key folds
                    // in everything the map visibly depends on plus a 1 s
                    // bucket, and the marker math it guards is already
                    // 15 s-bucketed, so nothing on screen moves less often
                    // than it did. Internal state (selection, a drag) changes
                    // the map's own @State and re-renders it regardless of
                    // this key, so interaction is untouched.
                    EquatableBox(key: mapRenderKey) { stationsMapDetail }
                        .equatable()
                        .opacity(selectedNav == .map ? 1 : 0)
                        .allowsHitTesting(selectedNav == .map)
                        .accessibilityHidden(selectedNav != .map)
                }
            }
        }
        .onChange(of: selectedNav) { _, nav in
            if nav == .map { mapKeptAlive = true }
        }
        .task {
            // Pre-warm after the launch flood has settled: mounting the
            // map costs one Metal init and a screen of tile fetches,
            // which is exactly the work we do not want on first click.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            mapKeptAlive = true
        }
    }

    /// The radios the map's traffic strip may show: enabled, and not hidden
    /// on the map. Hiding a radio hides its traffic with its stations — they
    /// are one channel, and showing the traffic without the dots is what had
    /// AX.25 frames scrolling past an operator watching APRS.
    private var trafficRadios: [MapTrafficRadio] {
        settings.activeRadios
            .filter { $0.enabled && !client.hiddenRadioIDs.contains($0.id) }
            .map { MapTrafficRadio(
                id: $0.id,
                name: $0.name.isEmpty ? RadioProfile.defaultName(for: $0) : $0.name) }
    }

/// Everything the map's appearance depends on, as a cheap string.
    ///
    /// Changes here are the only thing that re-renders the map subtree while
    /// it sits mounted behind another tab or between packets. A one-second
    /// bucket keeps coverage rings and recency tints feeling live; anything
    /// structural (a new station, a placed object, an alert, a toggle, the
    /// tab coming to the front) is named explicitly so it shows at once
    /// rather than waiting out the bucket.
    private var mapRenderKey: String {
        var parts: [String] = []
        parts.append(selectedNav == .map ? "on" : "off")
        parts.append(String(Int(Date().timeIntervalSince1970)))   // 1 s bucket
        parts.append(String(client.stations.count))
        parts.append(String(client.aprsObjects.live().count))
        parts.append(String(client.aprsAlerts.alerts.count))
        parts.append(String(callsignLookup.records.count))
        parts.append(String(nodeAliases.directory.allEntries.count))
        parts.append(settings.myCallsign)
        parts.append(winlinkContext.settings.gridSquare)
        if let pos = myPosition {
            parts.append("\(pos.point.latitude),\(pos.point.longitude)")
        } else {
            parts.append("-")
        }
        parts.append(client.hiddenRadioIDs.map(\.rawValue).sorted().joined(separator: ","))
        return parts.joined(separator: "|")
    }

        private var stationsMapDetail: some View {
        StationsMapView(
            stations: client.stations.filter(client.isVisible),
            objects: client.aprsObjects,
            alerts: client.aprsAlerts,
            probe: client.aprsProbe,
            recentPackets: Array(client.packets.suffix(600)),
            gatewayGrids: gatewayGrids,
            announcedGrids: announcedGrids.grids,
            observerGrid: winlinkContext.settings.gridSquare,
            observerPosition: myPosition,
            myCallsign: settings.myCallsign,
            ownCallsigns: ownAddresses,
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
            onMessage: { call in aprsComposeTarget = APRSComposeTarget(call: call.uppercased()) },
            onQuery: { ask in
                // Reach is the operator's, not a default: a direct query with
                // no path answers "can you hear me" and nothing else, while
                // the radio's own APRS path reaches the stations a digipeater
                // hop away — most of the channel — but proves only
                // reachability.
                let path = ask.reach == .direct
                    ? []
                    : sessionCoordinator.aprsPath(forRadio: nil, addressee: ask.callsign)
                _ = sessionCoordinator.sendAPRS(APRSOutbound(
                    info: APRSMessage.directedQueryInfo(to: ask.callsign, query: ask.token),
                    addressee: ask.callsign,
                    path: path,
                    radioID: nil))
                aprsPings.record(ping: ask.callsign, query: ask.token, reach: ask.reach)
            },
            pingState: { aprsPings.outcome(for: $0) },
            // Both directions of coverage, narrowed to the radios that carry
            // each family: a station heard on 2 m APRS says nothing about
            // what the packet radio on another band can hear.
            coverageEvidence: MapCoverageEvidence(coverageEvidence.evidence,
                                                  families: radioFamilies),
            // Built on demand: measuring the channel walks the recent packet
            // history, which is not worth doing for a panel that is closed.
            channelReport: {
                let evidence = MapCoverageEvidence(coverageEvidence.evidence,
                                                   families: radioFamilies)
                return APRSChannelReport.build(
                    packets: client.packets,
                    repeatHops: evidence.repeatHopsAPRS,
                    ownFramesHeardBack: evidence.ownFramesHeardBackAPRS,
                    path: sessionCoordinator.aprsPath(forRadio: nil))
            },
            // What we have heard from the station, so a ping goes out at a
            // reach that can actually span the gap.
            reachAdvice: { [weak client] call in
                client?.stations.first { $0.call.caseInsensitiveCompare(call) == .orderedSame }?
                    .reachAdvice ?? .neverHeard
            },
            repeatsUs: { aprsPings.repeatedUs($0) },
            layerStatus: mapLayerStatus,
            traffic: mapTraffic,
            trafficRadios: trafficRadios,
            hiddenRadios: client.hiddenRadioIDs,
            focusCallsign: .constant(nil),
            elevation: elevation,
            overlayStore: overlayStore,
            onSendLayer: layerSendAction,
            ownAPRSSymbol: ownAPRSSymbol,
            onBeacon: { sessionCoordinator.sendBeacon(settings) },
            // Placing and standing down are the same frame with one byte
            // different, so they are one hook rather than two.
            onPlaceObject: { name, live, latitude, longitude, table, code, comment in
                sessionCoordinator.sendAPRSObject(
                    name: name, live: live, latitude: latitude, longitude: longitude,
                    symbolTable: table, symbolCode: code, comment: comment,
                    settings: settings)
            },
            beaconObstacle: { sessionCoordinator.beaconObstacle(settings) })
        // Started here rather than at launch: the strip costs nothing until
        // the operator opens the map, and `absorb` fills it from the engine's
        // log the moment it does.
        .task {
            let mine = AX25Address(call: settings.myCallsign.uppercased()).call
            let sessions = sessionCoordinator.sessionManager
            mapTraffic.follow(client.$packets) { packet in
                let answered = packet.to.map { sessions.answers($0) } ?? false
                return MapTrafficFeed.Attribution(
                    // "Ours" is the licence, not the SSID: a station's beacon,
                    // its node and its BBS are all the operator's own traffic.
                    isOurs: packet.from?.call.uppercased() == mine,
                    isForUs: TrafficAddressing.isForUs(
                        destinationAnswered: answered,
                        info: packet.info,
                        ours: sessions.answeredAddresses.map(\.display)))
            }
            // A ping is only half an exchange until something comes back.
            // Two kinds of evidence, and they are not equal: a station that
            // addresses us has proved it heard us, while one that merely
            // transmits has proved nothing unless the timing is improbable
            // for it — see `APRSPingTracker`.
            aprsPings.beaconInterval = { [weak engine = client] call in
                engine?.aprsBeaconIntervals()[call.uppercased()]
            }
            // Our own frames come back off the air when a digipeater repeats
            // them, and they are the only proof of reception a silent station
            // ever gives us. Matched on the licence rather than the SSID: the
            // digi repeats whichever of our addresses transmitted.
            aprsPings.isOurs = { call in
                call.uppercased().split(separator: "-").first.map(String.init) == mine
            }
            aprsPings.follow(client.packetPublisher)
            // Coverage has two directions and both are measured from frames
            // already on disk, so the rings start from the history rather
            // than waiting for the next beacon to come back.
            coverageEvidence.isOurs = { call in
                call.uppercased().split(separator: "-").first.map(String.init) == mine
            }
            coverageEvidence.seed(client.packets)
            coverageEvidence.follow(client.packetPublisher)
            // History is read after launch, so the buffer here may still be
            // empty or hold only what arrived in the last second. Seeding is
            // idempotent and only rescans when the run has at least doubled.
            loadedHistoryObserver = client.$packets
                .receive(on: DispatchQueue.main)
                .sink { [weak store = coverageEvidence] packets in
                    store?.seed(packets)
                }
            aprsPings.startExpiry()
            client.aprsMessaging?.onDirectedTraffic = { [weak pings = aprsPings] call in
                pings?.noteDirectedReply(from: call)
            }
            // Our own frames never enter the packet log — see
            // `PacketEngine.onFrameTransmitted`. Without this the strip showed
            // a busy channel and no sign of our own beacon going out.
            client.onFrameTransmitted = { [weak traffic = mapTraffic] tx in
                traffic?.record(MapTrafficFeed.Line(
                    id: tx.id, at: tx.at, from: tx.from, to: tx.to,
                    via: tx.via.joined(separator: ","), summary: tx.text,
                    isOurs: true, wasTransmitted: true, isForUs: false, radio: tx.radio,
                    // Handed to the radio is not on the air. Where the radio
                    // can tell us the difference, say so until it does.
                    transmit: tx.awaitsKeying ? .pending : nil))
            }
            client.onTransmitOutcome = { [weak traffic = mapTraffic] radio, onAir, dropped in
                traffic?.resolveTransmits(radio: radio, onAir: onAir, dropped: dropped)
            }
        }
        .sheet(item: $aprsComposeTarget) { target in
            APRSComposeSheet(myCallsign: settings.myCallsign,
                             initialTo: target.call,
                             heardStations: aprsAddresseeSuggestions) { to, text in
                client.aprsMessaging?.sendMessage(
                    to: to, text: text, from: settings.myCallsign,
                    path: sessionCoordinator.aprsPath(forRadio: nil), radioID: nil)
            }
        }
    }

    @ViewBuilder
    private var detailSwitch: some View {
        switch selectedNav {
            case .terminal:
                TerminalView(
                    client: client,
                    settings: settings,
                    sessionCoordinator: sessionCoordinator,
                    connectCoordinator: connectCoordinator,
                    nodeAliases: nodeAliases,
                    nodeCapabilities: nodeCapabilities,
                    // Held above the view so navigating away cannot reset
                    // what the UI knows about a live session.
                    txViewModel: terminalModels.model(
                        sourceCall: settings.myCallsign,
                        make: {
                            ObservableTerminalTxViewModel(
                                client: client,
                                settings: settings,
                                sourceCall: settings.myCallsign,
                                sessionManager: sessionCoordinator.sessionManager)
                        }),
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
                    sessionRecorder: sessionRecorder,
                    remoteSessionStore: winlinkContext.terminalSessionReplication,
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
                            nextHopOverride: via, executeImmediately: true,
                origin: .explicitAction)
                        selectedNav = .terminal
                    },
                    knownCallsigns: knownCallsigns,
                    localCallsign: settings.myCallsign)
            case .analytics:
                AnalyticsDashboardView(packetEngine: client, settings: settings, viewModel: analyticsViewModel, connectCoordinator: connectCoordinator)
            case .map:
                // Rendered by the persistent layer below, so the map view
                // — its MKMapView, tile cache, Metal state and camera —
                // survives tab switches instead of cold-starting on each
                // visit (field ask 2026-08-29: "map tiles are missing for
                // a few seconds").
                Color.clear
            case .mail:
                WinlinkMailView(
                    context: winlinkContext,
                    appSettings: settings,
                    sessionCoordinator: sessionCoordinator,
                    client: client,
                    mailboxVM: mailboxVM,
                    onAddToMap: addSpatialAttachmentToMap
                )
            case .bbs:
                BBSView(
                    service: bbsService,
                    settings: bbsSettings,
                    library: bbsLibrary,
                    stationCallsign: settings.myCallsign,
                    remoteMailbox: winlinkContext.bbsMailboxReplication,
                    pane: $bbsPane
                )
            case .messages:
                if let messaging = client.aprsMessaging {
                    APRSMessagesView(messaging: messaging, probe: client.aprsProbe,
                                     myCallsign: settings.myCallsign)
                } else {
                    Text("APRS messaging is unavailable without a database.")
                        .foregroundStyle(.secondary)
                }
            //case .raw:
            //    RawView(
            //        chunks: client.rawChunks,
            //        showDaySeparators: settings.showRawDaySeparators,
            //        clearedAt: $settings.rawClearedAt
            //    )
            }
    }

    private var packetsView: some View {
        let rows = filteredPackets

        return VStack(spacing: 0) {
        PacketTableView(
            packets: rows,
            radioNames: client.radioNames,
            isLoadingHistory: client.isLoadingPersistedPackets,
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

            packetStatusBar(shown: rows.count)
        }
    }

    /// What the table is and is not showing.
    ///
    /// Always present, not only while filtering. This is the one page in the
    /// app that is not an inference — every other view derives its claims
    /// from these frames — so "I looked at the packets and it wasn't there"
    /// has to be trustworthy, and that means the page states its own scope
    /// rather than letting the operator assume it.
    @ViewBuilder
    private func packetStatusBar(shown: Int) -> some View {
        let total = client.visiblePacketCount
        let station = client.selectedStationCall
        HStack(spacing: 8) {
            Text(filters.statusLine(shown: shown, total: total, station: station,
                                    radios: client.visibleRadioNames))
                .font(.caption)
                .foregroundStyle(shown == 0 && total > 0 ? .orange : .secondary)
            Spacer()
            if !filters.isDefault || station != nil || !client.hiddenRadioIDs.isEmpty {
                Button("Show Everything") {
                    filters = PacketFilters()
                    client.selectedStationCall = nil
                    client.hiddenRadioIDs = []
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Clear the frame filters, the station filter, and any hidden radios.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The ground between this station and the one whose page is open.
    ///
    /// Nil whenever the answer would be a guess dressed as a picture: no
    /// terrain downloaded, no position for either end. `TerrainProfile`
    /// itself refuses to read a gap in coverage as sea level, so a partial
    /// download returns an "unknown" verdict rather than a clear path — the
    /// most dangerous possible way to be wrong here.
    ///
    /// Off the main actor: 256 elevation samples per profile, and the
    /// station sheet opens on a click.
    /// When a connection to this station last completed with no digipeater
    /// in the path.
    ///
    /// The bar is deliberately high. Hearing a station proves their
    /// transmitter reaches us and nothing about the reverse, and a frame that
    /// arrived through a digipeater proves the digipeater is well sited. Only
    /// a completed connection over a clean path means frames crossed that
    /// ground both ways, which is the one thing that can outrank a terrain
    /// verdict.
    ///
    /// Full-callsign matching against our own addresses, as CoverageEstimate
    /// does: a node relaying under a borrowed SSID is that node's transmitter,
    /// not ours.
    private func lastDirectConnection(to callsign: String) async -> Date? {
        guard let store = client.networkPaths else { return nil }
        let target = Callsign(callsign)?.base ?? callsign.uppercased()
        let ours = CallsignValidator.normalize(settings.myCallsign)
        guard !ours.isEmpty else { return nil }
        let cutoff = Date().addingTimeInterval(-CoverageEstimate.evidenceWindow)
        // Off the main thread, like `stationStats`: this reads the path table
        // over the whole evidence window, and it is called while a profile
        // sheet is opening.
        return await Task.detached(priority: .userInitiated) {
            let paths = (try? store.paths(since: cutoff)) ?? []
            return paths
                .filter { path in
                    guard path.via.isEmpty, path.evidence == .sessionEstablished else { return false }
                    let ends = [path.from, path.to].map { $0.uppercased() }
                    guard ends.contains(ours) else { return false }
                    return ends.contains { (Callsign($0)?.base ?? $0) == target }
                }
                .map(\.lastSeen)
                .max()
        }.value
    }

    /// Lifetime totals for one station, off the main thread.
    private func stationStats(for callsign: String) async -> StationStats? {
        guard let store = client.stationStats else { return nil }
        let address = Callsign(callsign)
        let call = address?.base ?? callsign.uppercased()
        let ssid = address?.ssid ?? 0
        return await Task.detached(priority: .userInitiated) {
            try? store.stats(forStation: call, ssid: ssid, now: Date())
        }.value
    }

    /// The coordinate the operator typed in Settings, if it is a coordinate.
    /// Where this station is, and how well that is known.
    ///
    /// The ladder itself lives on `StationPositionResolver` so the two
    /// shells, the settings page and the toolbar chip cannot drift apart
    /// again.
    private var myPosition: StationPosition? {
        StationPositionResolver.ownStation(
            gridSquare: winlinkContext.settings.gridSquare,
            manualLatitude: manualLatitude,
            manualLongitude: manualLongitude,
            usesDeviceLocation: useDeviceLocation,
            deviceLocation: winlinkContext.locationService.lastLocation)
    }

    private var deviceGPSFix: StationLocation? {
        StationPositionResolver.deviceFix(winlinkContext.locationService.lastLocation)
    }

    /// The two ends of the path a station page is about.
    private func terrainPath(
        to profile: NodeProfile
    ) -> (origin: GreatCircle.Point, destination: GreatCircle.Point)? {
        guard let placement = profile.placement, let mine = myPosition else { return nil }
        return (mine.point, placement.position)
    }

    @MainActor
    private func refreshProfileTerrain(for profile: NodeProfile) async {
        profileStats = await stationStats(for: profile.callsign)
        profileTerrain = nil
        let path = terrainPath(to: profile)

        // Judged before anything is computed or offered. A profile over a
        // thousand kilometres draws the earth's curvature and calls it
        // terrain, and downloading thirty tiles to produce that answer is
        // worse than not answering. The map already hides these stations for
        // the same reason; the card was simply never asked.
        profileTerrainOutOfRange = path.flatMap { ends -> Double? in
            guard let placement = profile.placement else { return nil }
            let verdict = StationPlausibility.verdict(
                observer: ends.origin,
                station: ends.destination,
                confidence: placement.confidence)
            guard case .beyondRadioRange(let kilometres) = verdict else { return nil }
            return kilometres
        }
        guard profileTerrainOutOfRange == nil else {
            profileTerrainEstimate = nil
            profileTerrainAreaEstimate = nil
            profileTerrain = nil
            return
        }

        profileTerrainEstimate = path.map {
            elevation.estimate(alongPathFrom: $0.origin, to: $0.destination)
        }
        profileTerrainAreaEstimate = path.map { elevation.estimate(around: $0.origin) }
        // Both ends, because a path from inside coverage to outside it has
        // nothing to fetch for half of itself.
        profileTerrainHasSource = path.map {
            ElevationDownloader.sourceHasCoverage(at: $0.origin)
                && ElevationDownloader.sourceHasCoverage(at: $0.destination)
        } ?? true
        profileLastDirectConnection = await lastDirectConnection(to: profile.callsign)
        let computed = await terrainProfile(to: profile)
        profileTerrainHeightAssumed = computed?.assumedFarHeight ?? false
        profileTerrain = computed?.profile
    }

    private func terrainProfile(
        to profile: NodeProfile
    ) async -> (profile: TerrainProfile, assumedFarHeight: Bool)? {
        // Deliberately not gated on `hasTerrain`: with no tiles the profile
        // comes back as an honest "unknown", and that is the state that
        // offers to fetch the one or two tiles this path needs. Gating here
        // meant the card simply did not appear, which is how the feature came
        // to depend on having already downloaded a region from the map page.
        guard let store = elevation.store,
              let placement = profile.placement,
              let observer = Maidenhead.center(of: winlinkContext.settings.gridSquare)
                  .map(GreatCircle.Point.init)
        else { return nil }

        // A height the operator recorded for this station beats the assumed
        // one: a node on a tower is the case the forecast most often gets
        // wrong, and it is the case they are most likely to have noted.
        // Off the main thread for the same reason as `lastDirectConnection`:
        // a table read while a profile sheet is opening.
        let noteStore = client.stationNotes
        let noted = await Task.detached(priority: .userInitiated) {
            (try? noteStore?.antennaHeights())?[profile.callsign.uppercased()]
        }.value
        let mine = winlinkContext.settings.antennaHeightMetres
        let theirs = noted ?? winlinkContext.settings.assumedRemoteHeightMetres
        let destination = placement.position
        let frequencyHz = StationsMapView.vhfCalculationFrequency

        let computed = await Task.detached(priority: .userInitiated) {
            TerrainProfile.between(
                origin: observer, destination: destination,
                originHeight: mine, destinationHeight: theirs,
                frequencyHz: frequencyHz,
                sampler: StoredElevationSampler(store: store))
        }.value
        return (computed, noted == nil)
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
                Button {
                    showingPacketFilters = true
                } label: {
                    Image(systemName: filters.isDefault
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .help(filters.restrictionSummary.map { "Filtering: \($0)" }
                      ?? "Filter which frames the table shows.")
                .popover(isPresented: $showingPacketFilters, arrowEdge: .bottom) {
                    FilterPopoverView(
                        filters: $filters,
                        hasPackets: !client.packets.isEmpty,
                        hasPinnedPackets: !client.pinnedPacketIDs.isEmpty,
                        onReset: { filters = PacketFilters() })
                }
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
            // Same group, same test: a station with no usable position has a
            // quietly broken map and terrain. Silent unless it has something
            // to say — see PositionStatusChip.
            PositionStatusChip(
                position: myPosition,
                usesDeviceLocation: useDeviceLocation,
                deviceFix: deviceGPSFix,
                gpsError: winlinkContext.locationService.lastGPSError)
            tncToolbarMenu
        }
    }

    /// TNC transport status menu — clickable pill with connect/disconnect actions
    @ViewBuilder
    private var tncToolbarMenu: some View {
        if settings.hasMultipleRadios {
            radiosToolbarMenu
        } else {
            singleRadioToolbarMenu
        }
    }

    /// Several radios: one dot each, the blinkenlights for all of them, a
    /// label that counts, and a menu with a section per radio.
    private var radiosToolbarMenu: some View {
        let radios = client.radioSummaries
        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                Blinkenlight(color: .green, trigger: client.lastRxTime)
                    .help("RX Activity, any radio")
                Blinkenlight(color: .red, trigger: client.lastTxTime)
                    .help("TX Activity, any radio")
            }

            HStack(spacing: 3) {
                ForEach(radios, id: \.id) { radio in
                    Circle()
                        .fill(radioTint(radio.status))
                        .frame(width: 8, height: 8)
                        .help(RadioPresentation.dotHelp(radio))
                }
            }

            Menu {
                ForEach(radios, id: \.id) { radio in
                    Section(radio.name) {
                        switch radio.status {
                        case .connected:
                            Button("Disconnect", role: .destructive) { client.radioManager.close(radio.id) }
                        case .connecting:
                            Button("Cancel") { client.radioManager.close(radio.id) }
                        case .disconnected, .failed:
                            Button("Connect") { client.radioManager.open(radio.id) }
                        }
                        Text(radio.endpoint)
                        if radio.status == .failed, let error = radio.lastError {
                            Text(error)
                        }
                    }
                }

                Divider()

                if radios.contains(where: { $0.status == .connected || $0.status == .connecting }) {
                    Button("Disconnect All", role: .destructive) { client.disconnect(reason: "user disconnect all") }
                }
                if radios.contains(where: { $0.status == .disconnected || $0.status == .failed }) {
                    Button("Connect All") { client.connectUsingSettings() }
                }

                Divider()

                Button("Radio Settings\u{2026}") {
                    SettingsRouter.shared.navigate(to: .radios)
                }
            } label: {
                Text(RadioPresentation.capsuleLabel(radios))
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .help("Radio connection actions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(platform: .platformSeparator).opacity(0.35), lineWidth: 0.5)
        )
    }

    private func radioTint(_ status: ConnectionStatus) -> Color {
        switch RadioPresentation.tint(for: status) {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: Color(platform: .platformTertiaryLabel)
        }
    }

    private var singleRadioToolbarMenu: some View {
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
                    SettingsRouter.shared.navigate(to: .radios, radio: settings.primaryRadio?.id)
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
    
    private var tncLedColor: Color {
        switch client.status {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return Color(platform: .platformTertiaryLabel)
        }
    }

    // MARK: - Computed Properties

    /// One node's claim in the sidebar. Lit while the page shows this
    /// node's table, so the sidebar answers "where am I?" the way the
    /// Views section does (field ask 2026-08-29 06:51: "I am on the
    /// COSCO page, why isn't COSCO highlighted?").
    private func reachableRow(via: String, count: Int) -> some View {
        let isActive = selectedNav == .nodes && nodeRouteFilter == via
        return Button {
            // A filter, not a search. Typing the node's name into the
            // search field matched every entry that mentioned it
            // anywhere and then re-filed those under whichever node
            // listed them last, so this row's count and the page it
            // opened disagreed by two orders of magnitude.
            nodeRouteFilter = via
            nodeQuery = ""
            selectedNav = .nodes
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(via)
                    .font(.system(.subheadline, design: .monospaced))
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isActive ? 0.22 : 0)))
        .help("\(via) published a table listing \(count) "
              + "stations it can connect you through to. Its claim, not a "
              + "route this station has measured, and other nodes may "
              + "list the same ones. Opens its table in Nodes.")
    }

    /// One query across every category the app knows.
    private var universalSearchResults: UniversalSearchResults {
        let aka = nodeAliases.directory.otherNames()
        return UniversalSearchIndex.search(
            searchModel.query,
            stations: client.stations.map {
                ($0.call, aka[$0.call.uppercased()], $0.heardCount,
                 $0.lastHeard ?? .distantPast)
            },
            directory: nodeAliases.directory.allEntries,
            routes: client.netRomIntegration?.currentRoutes() ?? [],
            packets: client.packets.suffix(1500).map {
                ($0.fromDisplay, $0.toDisplay, $0.infoPreview)
            },
            consoleLines: Array(client.consoleLines.suffix(4000)),
            mail: mailSearchIndex,
            now: Date())
    }

    private func loadMailSearchIndex() {
        guard let store = winlinkContext.store else { return }
        let folders = (try? store.folders()) ?? []
        mailSearchIndex = folders.compactMap(\.id).flatMap { id in
            (try? store.messages(inFolder: id)) ?? []
        }
    }

    /// A panel click: land on the thing, with the search still applied
    /// wherever the destination filters by it.
    private func openSearchResult(_ destination: UniversalSearchResults.Destination) {
        searchPanelDismissed = true
        switch destination {
        case .profile(let call):
            profiles.openPage(call)
        case .nodes(let query):
            nodeRouteFilter = nil
            nodeQuery = query
            selectedNav = .nodes
        case .routes:
            selectedNav = .routes
        case .mail:
            selectedNav = .mail
        case .packets:
            selectedNav = .packets
        case .terminal:
            selectedNav = .terminal
        }
    }

    private var searchPlaceholder: String {
        switch selectedNav {
        case .terminal:
            return "Filter terminal output"
        case .packets:
            return "Search packets"
        case .nodes:
            return "Search aliases, callsigns, nodes"
        default:
            return "Search"
        }
    }
    
    private var tncCapsuleLabel: String {
        switch client.status {
        case .connected:
            let host = client.connectedHost ?? settings.primaryRadio?.host ?? AppSettingsStore.defaultHost
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
        switch settings.primaryRadio?.kind ?? .tcp {
        case .serial:
            let path = settings.primaryRadio?.serialDevicePath ?? ""
            let device = path.isEmpty ? "No device" : (path as NSString).lastPathComponent
            return "KISS Serial @ \(device)"
        case .ble:
            let name = settings.primaryRadio?.blePeripheralName ?? ""
            return "KISS Bluetooth @ \(name.isEmpty ? "No peripheral" : name)"
        case .tcp:
            return "KISS TCP @ \(connectionHostPort)"
        case .modem:
            let device = settings.primaryRadio?.audioInputDeviceName ?? ""
            return "Sound modem @ \(device.isEmpty ? "No audio device" : device)"
        }
    }

    private var connectionHostPort: String {
        let primary = settings.primaryRadio
        let hostValue = client.connectedHost ?? primary?.host ?? AppSettingsStore.defaultHost
        let portValue = client.connectedPort.map(String.init) ?? String(primary?.port ?? AppSettingsStore.defaultPort)
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
            stationCall: client.selectedStationCall,
            hiddenRadios: client.hiddenRadioIDs
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
    /// The same aggregation, one answer per radio.
    ///
    /// A delivery probability is a property of a path between two antennas, so
    /// evidence from one radio says nothing about another's channel. This used
    /// to be a single blended figure applied to every transmission on every
    /// radio: a station with a clean UHF link and a marginal VHF one got one
    /// answer that libelled the good channel and flattered the bad one.
    ///
    /// A radio with too little evidence is simply absent — it must never
    /// borrow another's.
    nonisolated static func aggregateLinkQualityPerRadio(
        _ records: [LinkStatRecord], localCallsign: String? = nil
    ) -> [RadioID: (lossRate: Double, etx: Double, scope: AdaptiveAggregateScope)] {
        var out: [RadioID: (lossRate: Double, etx: Double, scope: AdaptiveAggregateScope)] = [:]
        for (radio, subset) in Dictionary(grouping: records, by: \.radioID) {
            if let sample = aggregateLinkQualityForAdaptive(subset, localCallsign: localCallsign) {
                out[radio] = sample
            }
        }
        return out
    }

    /// How many observations a link needs before it is allowed to speak.
    /// Shared so the figure and the explanation for its absence agree about
    /// which links were considered.
    nonisolated static let adaptiveMinObservations = 5

    /// Radios carrying APRS and nothing else, which the tuner cannot learn
    /// from and which are worth naming rather than leaving blank.
    ///
    /// Read from the frames each radio has actually decoded, the same source
    /// as the AX.25 and APRS badges on the radio rows. The first version of
    /// this asked the link statistics instead, counting links with no
    /// connected-mode evidence recorded against them, and it was wrong the
    /// moment it shipped: every link restored from a database written before
    /// that column existed comes back with a zero, so a two-way AX.25 radio
    /// in the middle of a session was announced as hearing only beacons
    /// (2026-09-17). An absent count is not evidence of absence, and a notice
    /// that makes a positive claim needs positive evidence behind it.
    ///
    /// A radio that has heard nothing classifiable is not included. Silence is
    /// a radio that has not started, which is a different thing from one that
    /// cannot learn.
    nonisolated static func radiosCarryingOnlyAPRS(
        families: [RadioID: Set<RadioTrafficFamily>]
    ) -> [RadioID] {
        families.compactMap { radio, carried in
            carried.contains(.aprs) && !carried.contains(.ax25) ? radio : nil
        }
        .sorted(by: RadioID.deterministicOrder)
    }

    nonisolated static func aggregateLinkQualityForAdaptive(_ records: [LinkStatRecord], localCallsign: String? = nil) -> (lossRate: Double, etx: Double, scope: AdaptiveAggregateScope)? {
        let minObs = Self.adaptiveMinObservations

        func aggregate(_ subset: [LinkStatRecord]) -> (lossRate: Double, etx: Double)? {
            // A row qualifies on real forward evidence alone. Requiring BOTH
            // df and dr excluded every one-way transfer: the data sender's row
            // fills df, the acker's row fills dr, and neither passes — so a
            // channel full of healthy BBS traffic read as "no evidence".
            // An unmeasured reverse direction uses the symmetry prior (dr = df),
            // the standard ETX assumption for an unmeasured return path. A
            // MEASURED bad dr still counts against the row.
            //
            // The session-evidence gate is the third condition and the one
            // that matters most on an APRS radio. A link we only ever listen
            // to can report that a frame arrived and can never report that
            // one did not: a beacon we missed leaves no retransmission, no
            // REJ, no gap. Its delivery estimate therefore settles at
            // whatever credit an arrival earns, which for a UI beacon is 0.4
            // and for a NET/ROM broadcast 0.8. Fed to the tuner those read as
            // 60% and 20% loss, the second sitting exactly on the
            // stop-and-wait trigger, and neither is a measurement of
            // anything. Field capture 2026-09-17: the IC-705 on 144.390,
            // beaconing happily and digipeated twice, reported loss=0.60
            // etx=6.21 and was clamped to K=1 paclen=64 with no way out,
            // because every further beacon pushed the figure toward 0.4
            // rather than toward health.
            //
            // A radio with nothing but beacons now produces no sample at all
            // and keeps the operator's configured settings, which is the
            // honest answer to a question its traffic cannot address.
            let valid = subset.filter { r in
                r.observationCount >= minObs
                    && (r.dfEstimate ?? 0) > 0.05
                    && r.sessionEvidenceCount > 0
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
