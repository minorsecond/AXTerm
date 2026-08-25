import SwiftUI
import MapKit

/// Every station this receiver has heard, on a map, with what is known
/// about each one.
///
/// The honest shape of this screen is two panes: stations that can be
/// placed, and stations that cannot. A callsign heard four hundred times
/// that nobody can locate is not an omission to hide — it is usually the
/// row worth looking at.
struct StationsMapView: View {

    let stations: [Station]
    /// Raw traffic, for path evidence the station summaries cannot carry —
    /// a completed SABM/UA handshake proves a path end to end, and only the
    /// frames themselves show it.
    var recentPackets: [Packet] = []
    /// Grid squares for RMS gateways, keyed by full callsign with SSID.
    let gatewayGrids: [String: String]
    let observerGrid: String
    /// Excluded from the heard list and used to label the centre marker.
    let myCallsign: String
    @ObservedObject var lookup: CallsignLookupService
    @ObservedObject var aliases: NodeAliasStore
    /// Owned rather than copied so the "no positions" banner can turn
    /// the lookup on itself — burying the fix in a disabled button's
    /// tooltip is how twenty missing stations stay missing.
    @ObservedObject var settings: WinlinkSettings
    /// Where recorded antenna heights live. Nil means every height is the
    /// stated assumption, which the forecast labels say plainly.
    var noteStore: StationNoteStore?


    @State private var selection: String?
    /// Set by another screen to bring a station into view — "Show on Map"
    /// from an identity page. Cleared once honoured so the same request
    /// does not re-select on every redraw.
    @Binding var focusCallsign: String?

    @State private var isLookingUp = false
    @AppStorage("stations.mapMode") private var modeRaw = "Map"
    @AppStorage("stations.basemap") private var basemapRaw = MapBasemap.standard.rawValue
    /// Hiding the list gives the map the whole window — what you want on
    /// a laptop screen in the field.
    @AppStorage("stations.showsList") private var showsList = true
    /// Off by default: on a busy channel the network is a lot of lines, and
    /// an operator opening the map usually wants to know where stations are
    /// before how they connect.
    @AppStorage("stations.showsPaths") private var showsPaths = false
    /// Terrain forecasts for pairs that have never been heard talking.
    /// Separate from `showsPaths` and off by default, because a prediction
    /// is a different kind of claim from an observation and should never
    /// arrive uninvited alongside one.
    @AppStorage("stations.showsPredictedPaths") private var showsPredictedPaths = false
    /// Graph analysis of the observed network: which stations everything
    /// depends on, and which stations cluster together.
    @StateObject private var insights = NetworkInsightModel()
    /// Stored elevation grids. Terrain forecasts read this and nothing else,
    /// so the feature works with the network down, and is honestly
    /// unavailable rather than quietly wrong when nothing is downloaded.
    @StateObject private var elevation = ElevationStorage()
    @StateObject private var offlineMaps = OfflineMapStore()
    /// Stored map tiles, for the basemap that keeps working with the network
    /// down. See Docs/OfflineMaps.md.
    @StateObject private var offlineTiles = OfflineMapStorage()
    /// Boundaries loaded from shapefiles or GeoJSON — county lines, ARES
    /// districts, evacuation zones. Device-local: an overlay is a working
    /// file for one activation, not something to push through sync.
    ///
    /// Owned above this view so a layer that arrives as a Winlink attachment
    /// lands in the same store the map draws from.
    @ObservedObject var overlayStore: MapOverlayStore
    /// Creates a Winlink draft from a layer. Nil hides the send action —
    /// without a mailbox there is nothing to send into.
    var onSendLayer: ((MapOverlayLayer, MapOverlayExport.Format) -> Void)?
    /// Drawing state. Taps become vertices while this is active.
    @State private var drawing = MapDrawingSession()
    /// Geometry waiting to be named — every feature gets a label, so the
    /// prompt is part of finishing the shape rather than an optional extra.
    @State private var pendingGeometry: ShapefileReader.Geometry?
    @State private var drawPrompt: TextEntryPrompt?
    @State private var showingOfflineMaps = false
    @State private var isCapturing = false
    @State private var captureName = ""
    @State private var showingCapture = false
    @State private var captureError: String?

    private var basemap: MapBasemap {
        MapBasemap(rawValue: basemapRaw) ?? .standard
    }

    /// The band terrain is judged against.
    ///
    /// Fresnel geometry depends on wavelength, so a forecast needs a
    /// frequency. Two metres is where packet lives; a path clear at 145 MHz
    /// is clear at 440 MHz too, since the zone only narrows as frequency
    /// rises. Judging the wider zone is the conservative direction.
    static let vhfCalculationFrequency: Double = 145_000_000

    /// Changes when the analysis inputs change, and not on every packet.
    private var insightKey: String {
        let calls = networkPositions.keys.sorted().joined(separator: ",")
        let heights = antennaHeights.keys.sorted()
            .map { "\($0):\(antennaHeights[$0] ?? 0)" }.joined(separator: ",")
        return "\(calls)|\(networkPaths.count)|\(showsPredictedPaths)|\(elevation.tileCount)|\(heights)|\(settings.assumedRemoteHeightMetres)"
    }

    /// What the terrain pass found, in one line.
    ///
    /// Needed because the honest answer is very often "nothing to draw". In
    /// rolling ground at modest antenna heights every untried path can be
    /// genuinely blocked, and a map that then draws nothing is
    /// indistinguishable from a feature that is broken. This says which it
    /// was, and where the nearest miss is \u{2014} the number an operator can
    /// act on, because it is how much mast would open the path.
    private var forecastSummary: String? {
        let snapshot = insights.snapshot
        guard !snapshot.terrainUnavailable else { return nil }
        guard !snapshot.predictions.isEmpty else {
            return insights.isWorking ? "Checking terrain\u{2026}" : nil
        }
        let drawable = snapshot.drawablePredictions.count
        guard drawable == 0 else {
            return "\(drawable) of \(snapshot.predictions.count) untried paths look workable"
        }
        guard let closest = snapshot.closestBlocked,
              let metres = closest.blockedByMetres else {
            return "\(snapshot.predictions.count) untried paths checked, none clear"
        }
        let height = settings.heightUnitIsFeet
            ? String(format: "%.0f ft", metres / 0.3048)
            : String(format: "%.0f m", metres)
        return "None clear \u{2014} closest is \(closest.from)\u{2013}\(closest.to), "
            + "terrain \(height) above the line"
    }

    /// Recorded antenna heights, with the operator's own from settings.
    ///
    /// Their own height is a setting rather than a note because they always
    /// know it; every other station's is a note because they usually do not.
    private var antennaHeights: [String: Double] {
        var heights = (try? noteStore?.antennaHeights()) ?? [:]
        let me = myCallsign.trimmingCharacters(in: .whitespaces).uppercased()
        if !me.isEmpty {
            heights[me] = settings.antennaHeightMetres
        }
        return heights
    }

    private var observer: GreatCircle.Point? {
        Maidenhead.center(of: observerGrid).map(GreatCircle.Point.init)
    }

    private var entries: [HeardStationMap.Entry] {
        let heard = HeardStationMap.entries(
            stations: stations,
            directory: lookup.records,
            gatewayGrids: gatewayGrids,
            excluding: myCallsign)
        // Aliases used in via paths, placed through their operator.
        // Appended rather than merged: a node is its own thing, and its
        // position is a lead rather than a fix.
        let nodes = HeardStationMap.aliasEntries(
            aliases: aliases.directory,
            usedAliases: HeardStationMap.aliasesInUse(stations),
            directory: lookup.records,
            stations: stations)
        return heard + nodes
    }

    private var placed: [HeardStationMap.Entry] { entries.filter(\.isPlaced) }

    /// The network drawn between the pins.
    ///
    /// A list of paths is a table of callsign pairs; the same information
    /// between pins shows the shape of the network — which digipeater
    /// everything funnels through, which stations sit alone, and where a path
    /// crosses ground that explains a poor link.
    private var pathLinks: [MapPathLink] {
        guard showsPaths else { return [] }
        var positions: [String: GreatCircle.Point] = [:]
        for entry in placed {
            positions[entry.callsign.uppercased()] = entry.position
        }
        if let observer, !myCallsign.isEmpty {
            positions[myCallsign.uppercased()] = observer
        }
        return MapPathLink.links(from: networkPaths, positions: positions)
            + MapPathLink.links(fromPredictions: showsPredictedPaths
                                    ? insights.snapshot.predictions : [],
                                positions: positions)
    }

    /// Positions for everything the graph might mention, us included.
    private var networkPositions: [String: GreatCircle.Point] {
        var positions: [String: GreatCircle.Point] = [:]
        for entry in placed {
            positions[entry.callsign.uppercased()] = entry.position
        }
        if let observer, !myCallsign.isEmpty {
            positions[myCallsign.uppercased()] = observer
        }
        return positions
    }

    /// Observed paths plus the ones implied by shared digipeaters.
    private var networkPaths: [NetworkPath] {
        let observed = NetworkPathObserver.paths(in: recentPackets, localCallsign: myCallsign)
        return observed + NetworkPathObserver.transitivePaths(from: observed)
    }
    private var unplaced: [HeardStationMap.Entry] { entries.filter { !$0.isPlaced } }

    private var scope: StationScope {
        guard let observer else { return StationScope.build(observerLabel: "", sites: []) }
        return HeardStationMap.scope(
            observerLabel: observerGrid.uppercased(),
            observer: observer, entries: entries, now: Date())
    }

    /// The same positions the scope uses, fanned so stations sharing a
    /// grid square are individually pickable. Computed by the model so
    /// the map and the scope can never disagree about where a marker is.
    private var coordinates: [String: GreatCircle.Point] {
        HeardStationMap.fannedPositions(placed)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if observer == nil {
                noPosition
            } else {
                if !unplaced.isEmpty { unplacedBanner }
                if showsList {
                    // A draggable split is a Mac affordance; on a touch
                    // screen the same two panes stack, so the map keeps a
                    // usable size instead of being squeezed by a list the
                    // operator cannot resize.
                    #if os(macOS)
                    HSplitView {
                        mapPane
                            .frame(minWidth: 380)
                        stationList
                            .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
                    }
                    #else
                    VStack(spacing: 0) {
                        mapPane
                            .frame(minHeight: 260)
                        Divider()
                        stationList
                            .frame(maxHeight: 260)
                    }
                    #endif
                } else {
                    mapPane
                }
            }
        }
        // Both off the view-update path: `preload` writes @Published
        // state, and the service's flag is set at construction and would
        // otherwise never see the setting being turned on later — which
        // is exactly why "Find Positions" did nothing.
        // Keyed on the *stations*, not just the setting.
        //
        // Keyed on the setting alone this ran once, when the map first
        // appeared — which on iOS is before the packet engine has finished its
        // initial load, so it preloaded an empty list and never ran again.
        // Positions were on disk the whole time and simply never read back,
        // which looks exactly like the map being cleared on every launch.
        //
        // The key is the *set* of callsigns, sorted, so it changes when a new
        // station is heard and not on every packet from one already known.
        // Honoured once, then cleared: a request that stayed set would
        // re-select the same station on every redraw and fight the operator
        // panning away from it.
        // Graph analysis and terrain forecasts, recomputed only when the
        // network or the placed stations actually change. The model
        // fingerprints its inputs, so the map re-rendering on every packet
        // does not restart a terrain pass.
        .task(id: insightKey) {
            insights.elevationStore = elevation.store
            insights.refresh(
                paths: networkPaths,
                positions: networkPositions,
                frequencyHz: Self.vhfCalculationFrequency,
                heights: antennaHeights,
                defaultHeightMetres: settings.assumedRemoteHeightMetres,
                wantsTerrain: showsPredictedPaths && elevation.hasTerrain)
        }
        .onChange(of: focusCallsign) { _, wanted in
            guard let wanted, !wanted.isEmpty else { return }
            selection = entries.first {
                $0.callsign.caseInsensitiveCompare(wanted) == .orderedSame
            }?.callsign
            focusCallsign = nil
        }
        .task(id: preloadKey) {
            lookup.isNetworkEnabled = settings.callsignLookupEnabled
            var wanted = stations.map(\.call)
            wanted += HeardStationMap.aliasesInUse(stations)
                .compactMap { aliases.directory.callsign(for: $0) }
            lookup.preload(wanted)
            await autoLookUpUnplaced()
        }
    }

    /// What the position preload depends on.
    ///
    /// A `Set` reduced to a sorted array: two runs with the same stations in a
    /// different order must compare equal, or the task re-runs for nothing.
    private var preloadKey: PositionPreloadKey {
        PositionPreloadKey(
            networkEnabled: settings.callsignLookupEnabled,
            callsigns: Set(stations.map(\.call)).sorted())
    }

    private struct PositionPreloadKey: Hashable {
        let networkEnabled: Bool
        let callsigns: [String]
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Stations Heard").font(.headline)
                Text(coverageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !unplaced.isEmpty {
                Button {
                    Task { await lookUpUnplaced() }
                } label: {
                    if isLookingUp {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Find Positions", systemImage: "mappin.and.ellipse")
                    }
                }
                .disabled(isLookingUp || !settings.callsignLookupEnabled)
                .help(settings.callsignLookupEnabled
                      ? "Tries the \(HeardStationMap.lookupCandidates(unplaced, aliases: aliases.directory).count) unplaced callsigns again. Lookups run on their own as stations are heard; this is for retrying the ones that failed — after the network came back, say. Answers are cached permanently and keep working offline."
                      : "Turn on \u{201C}Look up callsigns online\u{201D} in Settings \u{2192} Winlink first. It is off by default because a lookup tells a third party which stations you are hearing.")
            }
            if modeRaw == "Map" {
                MapBasemapPicker(basemap: Binding(
                    get: { basemap }, set: { basemapRaw = $0.rawValue }),
                    includesOffline: offlineTiles.hasStoredTiles)

                Button {
                    showingOfflineMaps = true
                } label: {
                    Label(offlineTiles.hasStoredTiles
                          ? "Offline Map (\(offlineTiles.statistics.sizeDescription))"
                          : "Offline Map\u{2026}",
                          systemImage: "square.stack.3d.down.right")
                }
                .help("Store map tiles on this device so the map keeps working with no network — the situation this app exists for. Import a file or download the area you are looking at.")

                MapOverlayControl(store: overlayStore,
                                  markCoordinate: observer?.clCoordinate,
                                  onSendViaWinlink: onSendLayer)
                Button {
                    captureName = defaultCaptureName
                    showingCapture = true
                } label: {
                    Label("Save Offline", systemImage: "square.and.arrow.down")
                }
                .help("Captures the area now on screen as an image you keep. MapKit has no offline-tile API, so this is the supported way to take a map somewhere with no signal \u{2014} do it before you leave.")
            }
            Picker("", selection: $modeRaw) {
                Text("Map").tag("Map")
                Text("Scope").tag("Scope")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Map draws real geography and needs tiles, which need the network. Scope plots bearing and range from positions already cached, and keeps working with everything else down.")
            Menu {
                Toggle("Observed Paths", isOn: $showsPaths)
                    .help("Draw the paths that have been observed between stations. Colour is evidence: green completed a connect end to end, blue arrived through a digipeater, teal was heard direct, and grey dashed is inferred from two stations sharing a digipeater without anything having travelled it. Red means connect attempts went unanswered.")
                Toggle("Predicted Paths", isOn: $showsPredictedPaths)
                    .disabled(!elevation.hasTerrain)
                    .help(elevation.hasTerrain
                          ? "Purple dotted lines between stations that have never been heard talking, drawn where the stored terrain says a signal would get across. A forecast from ground elevation and Fresnel geometry \u{2014} not a measurement, which is why it is drawn differently from everything else."
                          : "Needs terrain data. Download the elevation tiles for this area from the offline maps control first.")
                if !elevation.hasTerrain {
                    Text("No terrain data downloaded")
                }
                if insights.snapshot.terrainUnavailable {
                    Text("No terrain covers these stations")
                }
                if showsPredictedPaths, let summary = forecastSummary {
                    Divider()
                    Text(summary)
                }
            } label: {
                Image(systemName: showsPaths || showsPredictedPaths
                      ? "point.topleft.down.to.point.bottomright.curvepath.fill"
                      : "point.topleft.down.to.point.bottomright.curvepath")
            }
            .help("Choose what the map draws between stations: paths already observed, and paths the terrain says are possible but nobody has tried.")
            Button {
                showsList.toggle()
            } label: {
                Image(systemName: showsList ? "sidebar.right" : "sidebar.trailing")
            }
            .help(showsList ? "Hide the station list and give the map the window."
                            : "Show the station list.")
        }
        .padding(12)
        .sheet(isPresented: $showingCapture) { captureSheet }
        .sheet(isPresented: $showingOfflineMaps) {
            NavigationStack {
                OfflineMapsView(
                    store: offlineTiles,
                    elevation: elevation,
                    observer: observer,
                    suggestedRegion: MapRegionFit.region(
                        covering: [observer].compactMap { $0 } + Array(coordinates.values))?.mkRegion,
                    suggestedRegionName: "this area")
                .navigationTitle("Offline Data")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingOfflineMaps = false }
                    }
                }
            }
            .frame(minWidth: 460, minHeight: 520)
        }
    }

    /// Says plainly how much of what was heard could be placed. A map
    /// showing 12 dots when 23 stations were heard is misleading unless
    /// it says so.
    private var coverageSummary: String {
        guard !entries.isEmpty else { return "Nothing heard yet" }
        if unplaced.isEmpty {
            return "\(placed.count) station\(placed.count == 1 ? "" : "s"), all placed"
        }
        return "\(placed.count) of \(entries.count) placed \u{2014} \(unplaced.count) with no known position"
    }

    /// Twenty stations with no position is the map's most important
    /// fact, so it is stated on the map rather than left to a tooltip on
    /// a greyed-out button.
    @ViewBuilder
    private var unplacedBanner: some View {
        let candidates = HeardStationMap.lookupCandidates(unplaced, aliases: aliases.directory).count
        if !settings.callsignLookupEnabled, candidates > 0 {
            HStack(spacing: 8) {
                Image(systemName: "mappin.slash")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(unplaced.count) stations have no position")
                        .font(.callout.weight(.medium))
                    Text("Gateways get a grid square from the RMS directory. Everyone else needs a callsign lookup \u{2014} it is off by default because it tells a third party which stations you hear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Enable Lookup") {
                    settings.callsignLookupEnabled = true
                    lookup.isNetworkEnabled = true
                    Task { await lookUpUnplaced() }
                }
                .help("Turns on the callsign directory and immediately looks up the \(candidates) unplaced callsigns. Answers are cached permanently and keep working offline.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.10))
            Divider()
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private var mapPane: some View {
        if let observer {
            if placed.isEmpty {
                noPlacedStations
            } else if modeRaw == "Map" {
                mapWithDrawing(observer: observer)
            } else {
                StationScopeView(scope: scope, selection: $selection, legend: .recency)
            }
        }
    }

    private func mapWithDrawing(observer: GreatCircle.Point) -> some View {
        ZStack(alignment: .top) {
            StationMapView(scope: scope, observer: observer,
                               coordinates: coordinates,
                               observerCallsign: myCallsign,
                               basemap: basemap, legend: .recency,
                               pathLinks: pathLinks,
                               tileStore: offlineTiles.hasStoredTiles ? offlineTiles.store : nil,
                               tileSource: offlineTiles.storedSource,
                               overlays: overlayStore.visibleLayers,
                               drawing: $drawing,
                               onDrawTap: handleDrawTap,
                               selection: $selection)

            MapDrawingToolbar(session: $drawing, onComplete: finishShape)
                .padding(.top, 8)
        }
        .textEntryPrompt($drawPrompt)
    }

    /// A tap on the map while drawing.
    ///
    /// A mark completes on the first tap, so it goes straight to naming; a
    /// line or an area accumulates until the operator taps Done.
    private func handleDrawTap(_ coordinate: CLLocationCoordinate2D) {
        guard drawing.addVertex(coordinate) else { return }
        guard let geometry = drawing.geometry() else { return }
        drawing.cancel()
        promptForName(geometry)
    }

    private func finishShape(_ geometry: ShapefileReader.Geometry) {
        drawing.cancel()
        promptForName(geometry)
    }

    /// Every feature is named on creation. An unnamed zone is
    /// indistinguishable from the zone beside it, and the label is what makes
    /// the drawing worth anything to whoever receives it.
    private func promptForName(_ geometry: ShapefileReader.Geometry) {
        let kind: String
        switch geometry {
        case .point: kind = "Mark"
        case .polyline: kind = "Line"
        case .polygon: kind = "Area"
        }
        drawPrompt = TextEntryPrompt(
            id: "drawn",
            title: "Name this \(kind.lowercased())",
            message: "Saved to “\(MapOverlayStore.scratchLayerName)” on this device. The name is what appears on the map and travels with the feature when it is exported or sent.",
            placeholder: kind == "Area" ? "Evacuation Zone C" : "Staging area",
            confirmTitle: "Add") { name in
                overlayStore.addShape(geometry, name: name)
            }
    }

    private var stationList: some View {
        List(selection: $selection) {
            if !placed.isEmpty {
                Section("On the map") {
                    ForEach(placed) { row(for: $0) }
                }
            }
            if !unplaced.isEmpty {
                Section("No known position") {
                    ForEach(unplaced) { row(for: $0) }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(for entry: HeardStationMap.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if entry.isNodeAlias {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .help("A NET/ROM node alias, not a station callsign. Its position is inferred from the operator that announced it.")
                }
                Text(entry.callsign)
                    .font(.body.monospaced())
                if let grid = entry.gridSquare {
                    Text(grid)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(entry.heardCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("\(entry.heardCount) packets heard from this station.")
            }
            HStack(spacing: 6) {
                if let name = entry.name {
                    Text(name).lineLimit(1)
                }
                if let locality = entry.locality {
                    Text(locality).foregroundStyle(.secondary).lineLimit(1)
                }
                if let lastHeard = entry.lastHeard {
                    Text(lastHeard.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            if !entry.lastVia.isEmpty {
                Label(entry.lastVia.joined(separator: " \u{2192} "),
                      systemImage: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.8))
            }
        }
        .padding(.vertical, 1)
        .tag(entry.callsign)
        .help(HeardStationMap.detail(
            for: entry,
            observer: observer ?? .init(latitude: 0, longitude: 0),
            now: Date()))
    }

    // MARK: - Actions

    /// Places whatever the cache could not, without being asked.
    ///
    /// Gated on the operator having turned lookups on — that setting is the
    /// consent, since a lookup tells a third party which stations this
    /// receiver is hearing, and it is off by default for that reason. Given
    /// consent, making the operator press a button to see a map that could
    /// draw itself is friction with no privacy benefit.
    ///
    /// Safe to run on every change of the heard-station set: `resolve`
    /// consults both caches first and records what it has already attempted,
    /// so a station with no directory entry is asked about once rather than
    /// every time it is heard, and `resolveAll` is sequential on purpose —
    /// this is a courtesy query against someone else's free service.
    private func autoLookUpUnplaced() async {
        guard settings.callsignLookupEnabled else { return }
        let candidates = HeardStationMap.lookupCandidates(unplaced, aliases: aliases.directory)
        guard !candidates.isEmpty else { return }
        isLookingUp = true
        defer { isLookingUp = false }
        await lookup.resolveAll(candidates)
    }

    private func lookUpUnplaced() async {
        isLookingUp = true
        defer { isLookingUp = false }
        lookup.isNetworkEnabled = settings.callsignLookupEnabled
        await lookup.resolveAll(HeardStationMap.lookupCandidates(unplaced, aliases: aliases.directory))
    }

    // MARK: - Empty states

    private var noPosition: some View {
        unavailable(
            symbol: "location.slash",
            title: "No position for this station",
            message: "Everything is plotted relative to where you are. Use \u{201C}Use My Current Position\u{201D} in Settings \u{2192} Winlink, or set a grid square.")
    }

    private var noPlacedStations: some View {
        unavailable(
            symbol: "mappin.slash",
            title: "Nothing to plot yet",
            message: entries.isEmpty
                ? "No stations heard so far."
                : "None of the \(entries.count) stations heard has a known position. Gateways get one from the RMS directory; anyone else needs a callsign lookup.")
    }

    private func unavailable(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Offline capture

    private var defaultCaptureName: String {
        let stamp = Date().formatted(.dateTime.month().day())
        return "\(observerGrid.uppercased()) \(stamp)"
    }

    private var captureSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Save Map for Offline Use", systemImage: "square.and.arrow.down")
                .font(.headline)
            Text("Captures the area currently framed as an image and keeps it on disk. Station markers are drawn over it from cached positions, so the whole view keeps working with no network at all.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $captureName, prompt: Text("e.g. Mount Evans"))
                .textFieldStyle(.roundedBorder)
            Text("Basemap: \(basemap.rawValue) \u{2014} captured as shown, so pick the one you want before saving.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let captureError {
                Label(captureError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !offlineMaps.snapshots.isEmpty {
                Divider()
                Text("Saved maps").font(.caption.weight(.semibold))
                ForEach(offlineMaps.snapshots) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(snapshot.name).font(.callout)
                            Text("\(Int(snapshot.kilometresWide)) km wide \u{00B7} \(snapshot.basemap) \u{00B7} \(snapshot.capturedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            offlineMaps.remove(snapshot)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showingCapture = false }
                Button(isCapturing ? "Saving\u{2026}" : "Save") {
                    Task { await capture() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCapturing || captureName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func capture() async {
        guard let observer else { return }
        isCapturing = true
        captureError = nil
        defer { isCapturing = false }

        // Frame the same area the scope covers, so what is saved is what
        // was on screen.
        var points = [observer]
        points.append(contentsOf: coordinates.values)
        guard let fit = MapRegionFit.region(covering: points) else { return }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: fit.centerLatitude, longitude: fit.centerLongitude),
            span: MKCoordinateSpan(
                latitudeDelta: fit.latitudeDelta, longitudeDelta: fit.longitudeDelta))
        do {
            let (snapshot, png) = try await OfflineMapCapture.capture(
                region: region, size: CGSize(width: 1600, height: 1200),
                name: captureName, basemap: basemap)
            try offlineMaps.add(snapshot, png: png)
            showingCapture = false
        } catch {
            captureError = error.localizedDescription
        }
    }
}
