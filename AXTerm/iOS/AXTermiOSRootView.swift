#if os(iOS)
import SwiftUI
import Combine

/// The iOS shell.
///
/// A `TabView` rather than the Mac's sidebar-and-detail: on a handheld the
/// sections are peers the operator flips between one-handed, and on iPad each
/// tab gets the room to show a split view inside itself. Recreating the Mac's
/// window layout on a phone would fit neither.
///
/// The tabs are the same `NavigationItem` cases the Mac sidebar uses, and
/// each hosts the same view the Mac hosts — `TerminalView`,
/// `AnalyticsDashboardView`, `NetRomRoutesView`, `PacketTableView`. The port
/// is not a reimplementation; only the shell around them is written twice,
/// because only the shell genuinely differs.
struct AXTermiOSRootView: View {

    @ObservedObject var context: WinlinkContext
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine

    @ObservedObject private var sessionCoordinator: SessionCoordinator
    @StateObject private var connectCoordinator = ConnectCoordinator()
    @StateObject private var analyticsViewModel: AnalyticsDashboardViewModel
    @StateObject private var callsignLookup: CallsignLookupService
    @StateObject private var searchModel = AppToolbarSearchModel()
    /// Learns node aliases (DRLNOD, HORSE) from ID beacons already arriving,
    /// so via-path hops can be placed on the map.
    @StateObject private var nodeAliases = NodeAliasStore()
    /// Owns the terminal's view model across tab switches.
    @State private var terminalModels = TerminalModelBox()
    @StateObject private var nodeCapabilities = NodeCapabilityStore()
    /// Locators stations announce in their own beacons; the placement
    /// source for callsigns no directory covers.
    @StateObject private var announcedGrids = AnnouncedGridStore()
    /// Reads BPQ ROUTES tables out of session transcripts — same wiring as
    /// the Mac shell; the iPad learns routes from its own sessions too.
    @State private var routesScraper = BpqRoutesScraper()
    /// One door to the identity view, wherever a callsign is named.
    @StateObject private var profiles = NodeProfileCoordinator()
    @State private var profileMenuTarget: String?
    /// "Show on Map" hands the map a station to select.
    @State private var mapFocusCallsign: String?
    /// Written by the map. iOS keeps its layer toggles in the map's own
    /// toolbar — there is no sidebar here to move them to — so nothing
    /// reads this yet; it exists so the map has one owner on both
    /// platforms rather than a shared instance nobody watches.
    @StateObject private var mapLayerStatus = MapLayerStatus()
    /// Downloaded terrain, owned by the shell for the same reason as on the
    /// Mac: one handle, one warm tile cache.
    @StateObject private var elevation = ElevationStorage()
    @State private var homeTerrainOffer: ElevationStorage.Estimate?
    /// The callsign a directory lookup is running for, so the profile can say
    /// it is working rather than say it found nothing.
    @State private var lookingUpCallsign: String?
    /// Map overlays, owned here so a layer arriving as a Winlink attachment
    /// and a layer the operator drew end up in the same place.
    @StateObject private var overlayStore = MapOverlayStore()
    /// Holds the screen on while something would break if the device slept.
    @StateObject private var keepAwake = KeepAwakeController()
    @Environment(\.scenePhase) private var scenePhase

    /// Restored across launches: an operator who lives in the terminal should
    /// not land somewhere else every time.
    @AppStorage("ios.selectedTab") private var selection: NavigationItem = .terminal

    @State private var packetSelection = Set<Packet.ID>()
    @State private var inspectedPacket: Packet?

    /// Where the More tab is pushed to, so "Open Settings" can land on the
    /// screen that holds the setting rather than on a menu.
    @State private var settingsPath: [SettingsDestination] = []

    /// Says what the station is currently set up as, so the section is not
    /// four nouns the operator has to open one at a time to check.
    private var stationFooter: String {
        let call = settings.myCallsign.isEmpty ? "No callsign set" : settings.myCallsign
        return "\(call) · \(settings.host):\(settings.port)"
    }

    /// Views of the network, reachable from the traffic they describe.
    fileprivate enum NetworkDestination: Hashable {
        case analytics, routes, otherStations
    }

    /// The settings screens this shell can be sent to.
    ///
    /// The macOS `Settings` scene has tabs; a handheld has a pushed stack. The
    /// router speaks in `SettingsTab`, so the mapping lives here rather than
    /// asking every caller to know which shell it is talking to.
    fileprivate enum SettingsDestination: Hashable {
        case identity, winlink, connection, transmission, diagnostics

        init(_ tab: SettingsTab) {
            switch tab {
            case .general, .advanced: self = .identity
            case .winlink: self = .winlink
            case .network: self = .connection
            case .transmission: self = .transmission
            case .notifications, .linkDebug: self = .diagnostics
            // No mailbox UI on a handheld yet; the closest thing it has is
            // the station's own identity.
            case .bbs: self = .identity
            }
        }
    }

    init(context: WinlinkContext, settings: AppSettingsStore, client: PacketEngine) {
        self.context = context
        self.settings = settings
        self.client = client
        // The Mac wires the coordinator to the station's identity and to the
        // radio in `ContentView.init`; this shell has to do the same or the
        // transmit path runs with neither. Field capture 2026-08-25: a connect
        // to W0ARP-10 went out as `src=NOCALL` and every T1 retry logged
        // "Skipping sendFrame - packetEngine not set". The gateway answered
        // `UA F=1` — the link was up on its side — but with no packet
        // subscription the UA never reached the state machine, so the session
        // sat in `connecting` until N2 and the gateway eventually sent DISC.
        // Both halves are required: the callsign to be addressable, the
        // subscription to hear the answer.
        let coordinator: SessionCoordinator
        if let existing = SessionCoordinator.shared {
            coordinator = existing
        } else {
            coordinator = SessionCoordinator()
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
        }
        coordinator.applyLocalCallsign(settings.myCallsign)
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: client)
        self.sessionCoordinator = coordinator

        _analyticsViewModel = StateObject(wrappedValue: AnalyticsDashboardViewModel(
            settingsStore: settings,
            netRomIntegration: client.netRomIntegration,
            databaseAggregationProvider: { interval, bucket, calendar, options in
                await client.aggregateAnalytics(in: interval, bucket: bucket,
                                                calendar: calendar, options: options)
            },
            captureEventsProvider: { interval in
                guard let events = await client.captureConnectionEvents(around: interval) else { return nil }
                let isLive = await MainActor.run { client.status == .connected }
                return (events.connects, events.disconnects, isLive)
            }))

        _callsignLookup = StateObject(wrappedValue: CallsignLookupService(
            store: context.store,
            isNetworkEnabled: context.settings.callsignLookupEnabled))
    }

    var body: some View {
        VStack(spacing: 0) {
            // A callsign collision breaks every link this station has, and its
            // symptoms look like a dozen unrelated faults until named. Above
            // the tabs so it is visible wherever the operator is.
            if let collision = client.identityCollision {
                IdentityCollisionBanner(collision: collision) {
                    client.dismissIdentityCollision()
                }
            }
            tabs
        }
        .animation(.default, value: client.identityCollision)
        // Re-evaluated whenever anything that feeds the decision changes, so
        // the hold is taken and released as the station's state moves rather
        // than being set once and forgotten.
        // Settings can change the callsign after launch; without this the
        // coordinator keeps transmitting under the one it was born with.
        .onChange(of: settings.myCallsign) { _, newValue in
            sessionCoordinator.applyLocalCallsign(newValue)
        }
        .onChange(of: settings.keepAwakePolicy) { _, _ in applyKeepAwake() }
        .onChange(of: client.status) { _, _ in applyKeepAwake() }
        .onChange(of: sessionCoordinator.transfers.isEmpty) { _, _ in applyKeepAwake() }
        .onChange(of: context.settings.p2pListenEnabled) { _, _ in applyKeepAwake() }
        .onChange(of: scenePhase) { _, phase in
            // A backgrounded app has no business holding the display on, and
            // iOS ignores the flag there anyway — leaving it set would only
            // confuse the next foreground pass.
            if phase == .active { applyKeepAwake() } else { keepAwake.release() }
        }
        .task { applyKeepAwake() }
        // Same as the Mac: offered once per grid square, never taken
        // silently. Tens of megabytes from a US government service is not a
        // decision to make on someone's behalf at launch.
        .task(id: context.settings.gridSquare) {
            guard let here = Maidenhead.center(of: context.settings.gridSquare)
                .map(GreatCircle.Point.init) else { return }
            homeTerrainOffer = elevation.homeTerrainOffer(
                around: here, gridSquare: context.settings.gridSquare)
        }
        .sheet(item: $homeTerrainOffer) { offer in
            HomeTerrainConsentSheet(
                estimate: offer,
                gridSquare: context.settings.gridSquare,
                onAccept: {
                    if let here = Maidenhead.center(of: context.settings.gridSquare)
                        .map(GreatCircle.Point.init) {
                        elevation.acceptHomeTerrain(
                            around: here, gridSquare: context.settings.gridSquare)
                    }
                    homeTerrainOffer = nil
                },
                onDecline: {
                    elevation.declineHomeTerrain(gridSquare: context.settings.gridSquare)
                    homeTerrainOffer = nil
                })
        }
        .task {
            // Without this, every "Open Settings" button in the shared views
            // is dead on iOS: the action is supplied by the macOS Settings
            // scene, which has no iOS equivalent.
            //
            // Switching to the More tab alone is barely better than nothing —
            // it drops the operator on a menu, and does visibly nothing at all
            // if they are already there. So the requested tab is honoured and
            // the matching screen is pushed.
            SettingsRouter.shared.openAction = {
                let destination = SettingsDestination(SettingsRouter.shared.selectedTab)
                selection = .analytics
                settingsPath = [destination]
            }
        }
    }

    private func applyKeepAwake() {
        keepAwake.update(
            policy: settings.keepAwakePolicy,
            isConnected: client.status == .connected,
            isTransferring: !sessionCoordinator.transfers.isEmpty
                || (context.runner?.isRunning ?? false),
            isListening: context.settings.p2pListenEnabled)
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            terminal
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(NavigationItem.terminal)

            packets
                .tabItem { Label("Packets", systemImage: "list.bullet.rectangle") }
                .tag(NavigationItem.packets)

            mail
                .tabItem { Label("Mail", systemImage: "envelope") }
                .badge(context.unreadCount)
                .tag(NavigationItem.mail)

            map
                .tabItem { Label("Map", systemImage: "map") }
                .tag(NavigationItem.map)

            more
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(NavigationItem.analytics)
        }
        // On the TabView rather than in each tab: the link is a property of
        // the station, not of whichever screen is open, and a dropped TNC
        // looks exactly like a quiet channel from the map or the mailbox.
        //
        // Bottom edge, not top: iPadOS floats the tab bar over the top of the
        // content, so a top inset sits underneath it and hides the tabs. The
        // bottom is free on iPad and lands just above the tab bar on iPhone.
        .task {
            // Analytics owns the derivation; the context owns the decision
            // to publish. Wired here because this is the one place holding
            // both, and it keeps the store from reaching up into analytics
            // for packets and inferred roles.
            analyticsViewModel.onStationDirectoryChanged = { [weak context] directory in
                context?.publishLocalActivity(directory, callsign: settings.myCallsign)
            }
        }
        // Identity, from anywhere: a peek on tap, a page on demand, and a
        // menu on long press. Attached to the root rather than to each tab so
        // the terminal, the Stations list and a map callout all land here.
        .sheet(item: $profiles.presented) { presentation in
            NavigationStack {
                let profile = resolver.profile(for: presentation.callsign)
                NodeProfileView(
                    profile: profile,
                    localCallsign: settings.myCallsign,
                    lookupEnabled: context.settings.callsignLookupEnabled,
                    isLookingUp: lookingUpCallsign == presentation.callsign,
                    noteStore: client.stationNotes,
                    presentation: presentation.isPage ? .page : .sheet,
                    onOpenFullPage: presentation.isPage
                        ? nil : { profiles.promoteSheetToPage() },
                    onConnect: connectAction(to: presentation.callsign),
                    onShowOnMap: { showOnMap(presentation.callsign) },
                    onOpenCallsign: { profiles.peek($0) })
                    .navigationTitle(presentation.isPage ? presentation.callsign : "Station")
                    .navigationBarTitleDisplayMode(presentation.isPage ? .large : .inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { profiles.dismiss() }
                        }
                    }
                    // Opening a profile is the moment to ask who this is. The
                    // resolver only ever read the lookup cache, so a callsign
                    // never seen on the map stayed blank even with lookup on.
                    .task(id: presentation.callsign) {
                        // The station behind the name, not the name tapped —
                        // an alias like ALBBBS fails the plausibility gate
                        // and the station behind it stayed nameless.
                        await lookUp(profile.baseCallsign)
                    }
            }
            .presentationDetents(presentation.isPage ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(profileMenuTarget ?? "",
                            isPresented: Binding(
                                get: { profileMenuTarget != nil },
                                set: { if !$0 { profileMenuTarget = nil } }),
                            titleVisibility: .visible) {
            if let target = profileMenuTarget {
                Button("Full Profile") { profiles.openPage(target) }
                Button("Quick Look") { profiles.peek(target) }
                if let connect = connectAction(to: target) {
                    Button("Prepare Connect") { connect() }
                }
                Button("Copy Callsign") { ClipboardWriter.copy(target) }
                Button("Cancel", role: .cancel) {}
            }
        }
        // Any view can ask for an identity page without threading a callback
        // through four levels of navigation.
        .environmentObject(profiles)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TNCStatusStrip(status: client.status,
                           host: settings.host,
                           port: settings.port)
        }
        // Keep the alias store learning wherever the operator happens to be:
        // aliases are heard in ID beacons, not in the tab that shows them.
        .onReceive(client.$packets.throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)) { packets in
            let recent = Array(packets.suffix(200))
            nodeAliases.ingest(packets: recent)
            nodeCapabilities.ingest(packets: recent)
            // The network's own directory, harvested as it arrives: what
            // stations announced, and which digipeaters actually repeated a
            // frame while we listened.
            announcedGrids.ingest(packets: recent)
            if let services = client.stationServices {
                try? services.record(
                    StationServiceHarvester.declarations(in: recent)
                        + StationServiceHarvester.demonstratedDigipeaters(in: recent))
            }
            // Paths, kept across launches so the graph does not start every
            // session convinced the network is empty. Only what was actually
            // observed — a transitive path is re-derived on demand, and
            // storing an inference would let it harden into a fact that
            // outlives its evidence.
            if let store = client.networkPaths {
                try? store.record(
                    NetworkPathObserver.paths(in: Array(packets.suffix(600)),
                                              localCallsign: settings.myCallsign),
                    now: Date())
            }
        }
        .task(id: context.settings.callsignLookupEnabled) {
            callsignLookup.isNetworkEnabled = context.settings.callsignLookupEnabled
        }
    }

    // MARK: - Tabs

    private var terminal: some View {
        NavigationStack {
            TerminalView(
                client: client,
                settings: settings,
                sessionCoordinator: sessionCoordinator,
                connectCoordinator: connectCoordinator,
                nodeAliases: nodeAliases,
                nodeCapabilities: nodeCapabilities,
                // Same reason as the Mac shell: a tab the operator switches
                // away from must not take the live session's state with it.
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
                    // Same harvest as the Mac shell: aliases, software
                    // fingerprints, and ROUTES rows all arrive because the
                    // operator went there, so all are read. This hook was
                    // missing on iOS — the iPad scraped packets only.
                    nodeAliases.ingest(text: text, source: peer)
                    nodeCapabilities.ingest(line: text, peer: peer)
                    if let row = routesScraper.ingest(line: text, peer: peer, at: Date()) {
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
                    }
                },
                searchModel: searchModel,
                locationService: context.locationService,
                onIdentity: { profiles.peek($0) },
                onIdentityMenu: { profileMenuTarget = $0.uppercased() }
            )
        }
    }

    private var packets: some View {
        NavigationStack {
            PacketTableView(
                packets: client.packets,
                selection: $packetSelection,
                onInspectSelection: {
                    inspectedPacket = client.packets.first { packetSelection.contains($0.id) }
                },
                onCopyInfo: { ClipboardWriter.copy($0.infoText ?? "") },
                onCopyRawHex: { ClipboardWriter.copy(PayloadFormatter.hexString($0.rawAx25)) })
            .navigationTitle("Packets")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: NetworkDestination.self, destination: networkScreen)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let sync = context.sync { SyncStatusIndicator(sync: sync) }
                }
                // Analytics and routing live with the traffic they are
                // derived from, not in Settings. They are views of the
                // network, and filing them under Settings made that tab a
                // drawer of leftovers rather than a place to configure the
                // station.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink(value: NetworkDestination.analytics) {
                            Label("Analytics", systemImage: "chart.xyaxis.line")
                        }
                        NavigationLink(value: NetworkDestination.routes) {
                            Label("NET/ROM Routes",
                                  systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        // What other stations heard is packet observation,
                        // not mail. Filed under the mailbox it read as a
                        // Winlink feature and made no sense there.
                        NavigationLink(value: NetworkDestination.otherStations) {
                            Label("Other Stations",
                                  systemImage: "dot.radiowaves.left.and.right")
                        }
                    } label: {
                        Label("Network", systemImage: "chart.xyaxis.line")
                    }
                }
            }
            .sheet(item: $inspectedPacket) { packet in
                NavigationStack {
                    PacketInspectorView(packet: packet)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { inspectedPacket = nil }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var mail: some View {
        // No NavigationStack around the mailbox: it is a NavigationSplitView,
        // which has to be the root of its own hierarchy. Nested inside a
        // stack it renders the folder list as a floating card over the
        // message list instead of as a column.
        if context.store != nil {
            WinlinkMailboxScreen(context: context,
                                 client: client,
                                 appSettings: settings,
                                 sessionCoordinator: sessionCoordinator,
                                 myCallsign: settings.myCallsign,
                                 onAddToMap: addSpatialAttachmentToMap)
        } else {
            NavigationStack { storeUnavailable }
        }
    }

    private var map: some View {
        NavigationStack {
            StationsMapView(
                stations: client.stations,
                recentPackets: Array(client.packets.suffix(600)),
                gatewayGrids: gatewayGrids,
                observerGrid: context.settings.gridSquare,
                myCallsign: settings.myCallsign,
                lookup: callsignLookup,
                aliases: nodeAliases,
                settings: context.settings,
                noteStore: client.stationNotes,
                pathStore: client.networkPaths,
                serviceStore: client.stationServices,
                onOpenProfile: { profiles.openPage($0) },
                layerStatus: mapLayerStatus,
                focusCallsign: $mapFocusCallsign,
                elevation: elevation,
                overlayStore: overlayStore)
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Everything that does not earn a permanent tab on a five-tab bar.
    ///
    /// Analytics, routes and settings are all things an operator opens
    /// deliberately rather than lives in, so they sit one tap deeper rather
    /// than pushing the terminal or the mailbox off the bar.
    private var more: some View {
        NavigationStack(path: $settingsPath) {
            List {
                Section {
                    // First, and present at all: without this the callsign
                    // could not be entered anywhere on iOS, so every transmit
                    // gate sent the operator to a screen that did not exist.
                    NavigationLink(value: SettingsDestination.identity) {
                        Label("Identity", systemImage: "person.text.rectangle")
                    }
                    .accessibilityHint("Your callsign and the details forms ask for")

                    NavigationLink(value: SettingsDestination.winlink) {
                        Label("Winlink", systemImage: "envelope.badge.shield.half.filled")
                    }

                    NavigationLink(value: SettingsDestination.connection) {
                        Label("Connection", systemImage: "cable.connector")
                    }

                    NavigationLink(value: SettingsDestination.transmission) {
                        Label("Transmission", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Station")
                } footer: {
                    Text(stationFooter)
                }

                Section {
                    Picker("Keep screen on", selection: $settings.keepAwakePolicy) {
                        ForEach(KeepAwakePolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }

                    if let reason = keepAwake.reason {
                        Label(reason, systemImage: "sun.max.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Device")
                } footer: {
                    // The consequence belongs under the control, where iOS
                    // puts it, rather than behind a tap on an ⓘ. It is one
                    // sentence and it is the whole reason the setting exists.
                    Text(settings.keepAwakePolicy.detail)
                }

                Section {
                    NavigationLink(value: SettingsDestination.diagnostics) {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("Connection history and decode errors, for working out why a session failed.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsDestination.self, destination: settingsScreen)
        }
    }

    @ViewBuilder
    private func networkScreen(_ destination: NetworkDestination) -> some View {
        switch destination {
        case .analytics:
            AnalyticsDashboardView(packetEngine: client, settings: settings,
                                   viewModel: analyticsViewModel,
                                   connectCoordinator: connectCoordinator)
                .navigationTitle("Analytics")
                .navigationBarTitleDisplayMode(.inline)
        case .routes:
            NetRomRoutesView(integration: client.netRomIntegration,
                             packetEngine: client, settings: settings,
                             connectCoordinator: connectCoordinator)
                .navigationTitle("Routes")
                .navigationBarTitleDisplayMode(.inline)
        case .otherStations:
            NetworkHistoryView(observations: remoteObservations)
                .navigationTitle("Other Stations")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func settingsScreen(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .identity:
            GeneralSettingsView(settings: settings, client: client,
                                winlinkSettings: context.settings)
                .navigationTitle("Identity")
                .navigationBarTitleDisplayMode(.inline)
        case .winlink:
            WinlinkSettingsTab(settings: context.settings,
                               profile: context.profile,
                               stationCallsign: settings.myCallsign,
                               locationService: context.locationService,
                               stationDistanceMiles: { callsign, hz in
                                   // Read straight from the cache: Settings has
                                   // no station view model, and the answer is a
                                   // caption rather than a decision.
                                   guard let all = try? context.store?.stations() else { return nil }
                                   return all.first {
                                       $0.callsign.caseInsensitiveCompare(callsign) == .orderedSame
                                           && (hz == nil || $0.frequencyHz == hz)
                                   }?.distanceMiles
                               },
                               sync: context.sync)
                .navigationTitle("Winlink")
                .navigationBarTitleDisplayMode(.inline)
        case .connection:
            ConnectionSettingsView(settings: settings, packetEngine: client)
                .navigationTitle("Connection")
                .navigationBarTitleDisplayMode(.inline)
        case .transmission:
            TransmissionSettingsView(settings: settings, client: client)
                .navigationTitle("Transmission")
                .navigationBarTitleDisplayMode(.inline)
        case .diagnostics:
            DiagnosticsView(settings: settings, eventStore: nil)
                .navigationTitle("Diagnostics")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Imports a spatial attachment onto the map and switches to it.
    ///
    /// Switching tabs is the point: an operator who asked to put a boundary
    /// on the map wants to see it, and leaving them in the mailbox wondering
    /// whether it worked is the same failure as a silent save.
    private func addSpatialAttachmentToMap(_ attachment: WinlinkB2Message.Attachment,
                                           from sender: String) {
        let added = overlayStore.addFromAttachment(
            data: attachment.data, filename: attachment.name, senderCallsign: sender)
        if added != nil { selection = .map }
    }

    // MARK: - Support

    /// Grid squares for RMS gateways, keyed by callsign with SSID — a
    /// gateway's position is known from the CMS even when its licensee has
    /// never been looked up.
    /// Everything the identity view needs, gathered from where it actually
    /// lives. Rebuilt per presentation — a profile is a reading, not a
    /// subscription, and these sources are already in memory.
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

    private var resolver: NodeProfileResolver {
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
            maxChainLength: settings.autoRouteMaxChainLength,
            localCallsign: settings.myCallsign,
            aliases: nodeAliases.directory,
            heardEntries: heard + aliasEntries,
            directory: callsignLookup.records,
            linkQuality: context.mapLinkQuality,
            observer: Maidenhead.center(of: context.settings.gridSquare)
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
            historyStore: client.linkQualityHistory)
    }

    /// Prefills the terminal's connect bar. Never keys the radio.
    ///
    /// A profile is somewhere an operator lands from a tap on a log line, so
    /// `executeImmediately` is false on purpose: the last step stays a
    /// deliberate press of Connect. The difference between a mis-tap and a
    /// transmission is worth one extra tap.
    ///
    /// Mode comes from `preferredMode`, which remembers what worked for this
    /// station before and prefers NET/ROM where a route exists. A previously
    /// heard digipeater path is reused, because a path that worked is better
    /// evidence than an empty one — and the connect bar shows it before the
    /// operator commits.
    private func connectAction(to callsign: String) -> (() -> Void)? {
        let normalized = CallsignValidator.normalize(callsign)
        guard !normalized.isEmpty,
              normalized != CallsignValidator.normalize(settings.myCallsign) else { return nil }

        let profile = resolver.profile(for: callsign)
        let hasRoute = profile.netrom?.reachedVia != nil
            || profile.netrom?.neighbourQuality != nil

        return {
            let mode = connectCoordinator.preferredMode(
                for: normalized, hasNetRomRoute: hasRoute)

            let digis = (profile.activity?.lastVia ?? [])
                .compactMap { CallsignSSID($0) }
            let kind: ConnectKind
            switch mode {
            case .netrom:
                kind = .netrom(nextHopOverride: nil)
            case .ax25ViaDigi where !digis.isEmpty:
                kind = .ax25ViaDigis(digis)
            case .ax25, .ax25ViaDigi:
                kind = digis.isEmpty ? .ax25Direct : .ax25ViaDigis(digis)
            }

            let intent = ConnectIntent(
                kind: kind,
                to: normalized,
                sourceContext: .stations,
                suggestedRoutePreview: digis.isEmpty
                    ? nil : digis.map(\.description).joined(separator: ", "),
                validationErrors: [],
                routeHint: nil,
                note: digis.isEmpty
                    ? nil
                    : "Digipeater path reused from the last time this station was heard.")

            profiles.dismiss()
            selection = .terminal
            connectCoordinator.activeContext = .terminal
            connectCoordinator.requestConnect(ConnectRequest(
                intent: intent, mode: mode, executeImmediately: false))
        }
    }

    /// Asks the directory who holds a callsign, once, when its profile opens.
    private func lookUp(_ callsign: String) async {
        guard context.settings.callsignLookupEnabled else { return }
        // The directory is keyed by base callsign — K0NTS-1 and K0NTS-10 are
        // one licensee — and tactical aliases are rejected by the service's
        // own plausibility check rather than here.
        lookingUpCallsign = callsign
        defer { lookingUpCallsign = nil }
        await callsignLookup.resolve(callsign)
    }

    private func showOnMap(_ callsign: String) {
        profiles.dismiss()
        mapFocusCallsign = callsign
        selection = .map
    }

    /// Read on demand: another device may sync between screens.
    private var remoteObservations: [StationActivityPayload] {
        (try? context.activityStore?.remoteStationActivity()) as? [StationActivityPayload] ?? []
    }

    private var gatewayGrids: [String: String] {
        guard let store = context.store else { return [:] }
        let stations = (try? store.stations()) ?? []
        return Dictionary(stations.map { ($0.callsign.uppercased(), $0.gridSquare) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// A database that would not open is a real failure and says so, rather
    /// than showing an empty mailbox that looks like no mail.
    private var storeUnavailable: some View {
        ContentUnavailableView(
            "Mailbox unavailable",
            systemImage: "externaldrive.badge.xmark",
            description: Text("The message database could not be opened, so mail cannot be read or stored on this device."))
    }
}
#endif
