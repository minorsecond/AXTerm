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
    /// Locators stations beaconed about themselves, per full callsign.
    var announcedGrids: [String: String] = [:]
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
    /// Paths remembered from previous sessions. Nil falls back to whatever
    /// the live packet window shows, which on a quiet morning is nothing.
    var pathStore: NetworkPathStore?
    /// What stations have announced they run. Nil hides the directory rather
    /// than opening an empty one.
    var serviceStore: StationServiceStore?
    /// Opens an identity page from a directory row.
    var onOpenProfile: ((String) -> Void)?
    /// The node-prompt chain a connect to this name would walk, from the
    /// same planner the relay uses. Nil hides the path row.
    var plannedChainFor: ((String) -> [String])?
    /// Starts a connect to this name and carries the operator to the
    /// Terminal. Nil hides the button.
    var onConnect: ((String) -> Void)?


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
    /// Which terrain shading is drawn, if any. Off by default: the map's
    /// first job is where stations are, and a relief wash under everything
    /// is a choice rather than a default.
    @AppStorage("stations.terrainStyle") private var terrainStyleRaw = ""
    /// Sets aside stations too far away to have arrived by radio.
    ///
    /// Off by default. Hiding data is never the right default, and the
    /// heuristic is a heuristic — but one internet-bridged station on the
    /// far coast stretches the map's zoom until every local station is a
    /// cluster of dots, so the toggle earns its place.
    @AppStorage("stations.hidesDistantStations") private var hidesDistantStations = false
    /// The whole node directory on the map — every station the network
    /// claims reachable that can be placed from what is already cached.
    /// Off by default: a harvested directory runs to hundreds of names,
    /// and the map's first job is what was actually heard.
    @AppStorage("stations.showsDirectoryNodes") private var showsDirectoryNodes = false
    /// Measured coverage rings around this station. On by default: they
    /// draw only when at least one station has answered us directly, and
    /// knowing one's own footprint is half of why a coverage map exists.
    @AppStorage("stations.showsCoverageRing") private var showsCoverageRing = true
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
    @State private var showingDirectory = false
    /// A box the operator drew to bound a download. Cleared when the sheet
    /// closes, so the next download offers their own area again rather than
    /// silently reusing a box from an hour ago.
    @State private var downloadRegion: MKCoordinateRegion?
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
        // Nothing drawable is a normal answer in rolling ground, so the line
        // names the one thing that would change it. Assumed height is the
        // knob, and quoting its current value saves the operator hunting for
        // which setting the verdict even depends on.
        let assumed = describe(settings.assumedRemoteHeightMetres)
        guard let closest = snapshot.closestBlocked,
              let metres = closest.blockedByMetres else {
            return "\(snapshot.predictions.count) untried paths checked, "
                + "none clear at \(assumed) assumed"
        }
        return "None clear at \(assumed) assumed \u{2014} closest is "
            + "\(closest.from)\u{2013}\(closest.to), terrain \(describe(metres)) above the line"
    }

    /// A height in whichever unit the operator entered theirs in.
    private func describe(_ metres: Double) -> String {
        settings.heightUnitIsFeet
            ? String(format: "%.0f ft", metres / 0.3048)
            : String(format: "%.0f m", metres)
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

    /// Names the stations the filter affects, rather than only what it does.
    ///
    /// An operator should be able to tell from the tooltip whether the thing
    /// about to disappear is the one they were looking for.
    private var distantFilterTooltip: String {
        let names = distantStations.prefix(4).map(\.callsign).joined(separator: ", ")
        let more = distantStations.count > 4
            ? " and \(distantStations.count - 4) more" : ""
        let action = hidesDistantStations ? "Showing" : "Hiding"
        return "\(action) \(distantStations.count) station"
            + "\(distantStations.count == 1 ? "" : "s") further than "
            + "\(Int(StationPlausibility.defaultRangeKilometres)) km away: \(names)\(more). "
            + "A packet network bridged to the internet puts frames from the "
            + "far side of the country on the same stream as the neighbour "
            + "down the road, and one of them stretches the map until every "
            + "local station is a dot. Nothing is deleted, and a node placed "
            + "at its operator's licence address is never filtered \u{2014} "
            + "that distance would be measuring a mailing address."
    }

    private var terrainStyle: TerrainShading.Style? {
        TerrainShading.Style(rawValue: terrainStyleRaw)
    }

    /// Shaded tiles for whatever is stored.
    ///
    /// Rebuilt only when the style or the stored tile count changes — the
    /// overlays cache their rendered images, and making new ones on every
    /// redraw would throw that away.
    private var terrainOverlays: [ElevationOverlay] {
        guard let terrainStyle, let store = elevation.store,
              elevation.hasTerrain else { return [] }
        return ElevationOverlay.overlays(from: store, style: terrainStyle)
    }

    private var observer: GreatCircle.Point? {
        Maidenhead.center(of: observerGrid).map(GreatCircle.Point.init)
    }

    /// Stations the radio has actually met: heard stations plus the
    /// via-path aliases. These are the entries the *analysis* layers
    /// (paths, terrain, coverage) are allowed to see.
    private var coreEntries: [HeardStationMap.Entry] {
        let heard = HeardStationMap.entries(
            stations: stations,
            directory: lookup.records,
            gatewayGrids: gatewayGrids,
            announcedGrids: announcedGrids,
            excluding: myCallsign)
        // Aliases used in via paths, placed through their operator.
        // Appended rather than merged: a node is its own thing, and its
        // position is a lead rather than a fix.
        let nodes = HeardStationMap.aliasEntries(
            aliases: aliases.directory,
            usedAliases: HeardStationMap.aliasesInUse(stations),
            directory: lookup.records,
            stations: stations)
        guard showsDirectoryNodes else { return heard + nodes }
        // A heard station that IS a node says so, instead of the fold
        // being silent: the ZI* diamonds vanish because K0ZIA-14's dot
        // owns the box — so the dot's detail must carry the node names.
        let badges = HeardStationMap.nodeAliasesByHeardBase(
            aliases: aliases.directory,
            heardCalls: Set(stations.map { $0.call.uppercased() }))
        let annotated = heard.map { entry -> HeardStationMap.Entry in
            guard let names = badges[CallsignQuery.normalize(entry.callsign)]
            else { return entry }
            var entry = entry
            let badge = "Node — \(names.joined(separator: ", "))"
            entry.name = entry.name.map { "\($0) · \(badge)" } ?? badge
            return entry
        }
        return annotated + nodes
    }

    /// The rest of the node directory — placeable entries only, drawn
    /// but deliberately invisible to the analysis layers.
    private func directoryEntries(core: [HeardStationMap.Entry]) -> [HeardStationMap.Entry] {
        guard showsDirectoryNodes else { return [] }
        let shown = Set(core.map { $0.callsign.uppercased() })
            .union(stations.map { $0.call.uppercased() })
        return HeardStationMap.directoryNodeEntries(
            aliases: aliases.directory,
            alreadyShown: shown,
            shownCallsigns: shown,
            directory: lookup.records,
            announcedGrids: announcedGrids,
            stations: stations,
            excluding: myCallsign)
    }

    private var entries: [HeardStationMap.Entry] {
        let core = coreEntries
        return core + directoryEntries(core: core)
    }

    /// How many heard stations carry folded-in node identities.
    private var mergedNodeBoxCount: Int {
        HeardStationMap.nodeAliasesByHeardBase(
            aliases: aliases.directory,
            heardCalls: Set(stations.map { $0.call.uppercased() })).count
    }

    /// How much of the alias directory the map can currently place.
    private var placedDirectoryCount: Int {
        entries.filter { $0.isNodeAlias && $0.isPlaced }.count
    }

    /// Measured coverage, or nil when the toggle is off or nothing has
    /// answered this station directly.
    private var coverageRing: CoverageEstimate.Ring? {
        guard showsCoverageRing, let observer else { return nil }
        return CoverageEstimate.ring(
            paths: networkPaths,
            ownAddresses: [myCallsign],
            positions: networkPositions,
            observer: observer)
    }

    /// Stations set aside as impossible to have heard over the air.
    ///
    /// Computed even when the toggle is off, so the toolbar can say how many
    /// there are rather than the operator discovering the feature by
    /// accident.
    private var distantStations: [HeardStationMap.Entry] {
        StationPlausibility.partition(entries, observer: observer).hidden
    }

    /// Entries after the distance filter, if it is on.
    private var visibleEntries: [HeardStationMap.Entry] {
        guard hidesDistantStations else { return entries }
        return StationPlausibility.partition(entries, observer: observer).shown
    }

    private var placed: [HeardStationMap.Entry] { visibleEntries.filter(\.isPlaced) }

    /// The network drawn between the pins.
    ///
    /// A list of paths is a table of callsign pairs; the same information
    /// between pins shows the shape of the network — which digipeater
    /// everything funnels through, which stations sit alone, and where a path
    /// crosses ground that explains a poor link.
    private var pathLinks: [MapPathLink] {
        // Each layer is gated on its own switch. A single guard on
        // `showsPaths` covering both meant forecasts could only be seen
        // alongside measurements — two independent menu items, one of which
        // silently did nothing on its own.
        guard showsPaths || showsPredictedPaths else { return [] }
        let positions = networkPositions

        let observed = showsPaths
            ? MapPathLink.links(from: networkPaths, positions: positions) : []
        let predicted = showsPredictedPaths
            ? MapPathLink.links(fromPredictions: insights.snapshot.predictions,
                                positions: positions) : []
        return observed + predicted
    }

    /// Positions for everything the graph might mention, us included.
    ///
    /// Built from `coreEntries`, never the directory layer: a directory
    /// placement is an operator's licence address, not a station at a
    /// radio, so terrain forecasts and path links over it would be
    /// analysing a mailing address (the same reason camera framing skips
    /// node sites). This is also what keeps the map responsive — these
    /// keys feed `insightKey`, and when every trickled-in directory
    /// position changed it, each one re-fired the full graph-and-terrain
    /// pass and the main thread never drained (field capture 2026-08-29
    /// 05:59: opening the map froze the app while lookups landed).
    private var networkPositions: [String: GreatCircle.Point] {
        var positions: [String: GreatCircle.Point] = [:]
        let core = hidesDistantStations
            ? StationPlausibility.partition(coreEntries, observer: observer).shown
            : coreEntries
        for entry in core where entry.isPlaced {
            positions[entry.callsign.uppercased()] = entry.position
        }
        if let observer, !myCallsign.isEmpty {
            positions[myCallsign.uppercased()] = observer
        }
        return positions
    }

    /// Everything known about who reaches whom.
    ///
    /// The live window plus what previous sessions recorded, folded together
    /// so a path proven yesterday is not downgraded by a quiet morning. The
    /// transitive inferences are derived *after* the merge, so a digipeater
    /// heard last week can still imply a path today.
    private var networkPaths: [NetworkPath] {
        // Assembled at most once per 15 seconds, NOT per body evaluation.
        // The full assembly is a store read of every remembered path plus
        // a transitive closure — fine when bodies were rare, fatal once
        // the directory trickle started publishing a position every
        // couple of seconds: each publish re-evaluated this, each
        // evaluation outlived the publish interval, and the main thread
        // never came back (field capture 2026-08-29 05:59 — opening the
        // map froze the app). A 15 s lag on a map layer is invisible;
        // a synchronous graph rebuild per redraw is not.
        let now = Date()
        if now.timeIntervalSince(pathCache.loadedAt) > 15 {
            let live = NetworkPathObserver.paths(in: recentPackets, localCallsign: myCallsign)
            let remembered = (try? pathStore?.paths(
                since: now.addingTimeInterval(-SQLiteNetworkPathStore.retention))) ?? []
            let observed = NetworkPath.merging(live + remembered)
            pathCache.paths = observed + NetworkPathObserver.transitivePaths(from: observed)
            pathCache.loadedAt = now
        }
        return pathCache.paths
    }

    /// Reference box so the cache survives body evaluations without being
    /// SwiftUI state — mutating it must never invalidate the view.
    final class PathAssemblyCache {
        var paths: [NetworkPath] = []
        var loadedAt = Date.distantPast
    }
    @State private var pathCache = PathAssemblyCache()
    private var unplaced: [HeardStationMap.Entry] { visibleEntries.filter { !$0.isPlaced } }

    private var scope: StationScope {
        guard let observer else { return StationScope.build(observerLabel: "", sites: []) }
        return HeardStationMap.scope(
            observerLabel: observerGrid.uppercased(),
            observer: observer, entries: visibleEntries, now: Date())
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
                if hidesDistantStations, !distantStations.isEmpty { distantBanner }
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

    /// Hit target for the header's icon-only controls.
    ///
    /// A glyph is about 17pt, which is a fine *pointer* target and far too
    /// small for a finger — Apple's own guidance is 44pt, and on an iPad the
    /// row of bare icons at the end of this bar was noticeably fiddly. The
    /// icon does not change size; the tappable area around it does.
    private var iconHitTarget: CGFloat {
        #if os(iOS)
        return 44
        #else
        return 24
        #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Stations Heard").font(.headline)
                Text(coverageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !unplaced.isEmpty || showsDirectoryNodes {
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
                      ? "Tries the \(HeardStationMap.lookupCandidates(unplaced, aliases: aliases.directory).count) unplaced callsigns again."
                        + (showsDirectoryNodes
                           ? " With the node directory shown, each press also looks up "
                             + "as many as forty directory operators — the ones most nodes "
                             + "vouch for first — so the layer fills in a batch at a time "
                             + "rather than flooding the lookup service."
                           : "")
                        + " Lookups run on their own as stations are heard; this is for retrying the ones that failed — after the network came back, say. Answers are cached permanently and keep working offline."
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
                Divider()
                Toggle("Node Directory", isOn: $showsDirectoryNodes)
                    .help("Draw every station the network has claimed reachable — node tables, ROUTES scrapes, made relay hops — that can be placed from cached positions. Indigo markers, dashed when the position is the operator's address rather than the node's own. Nothing is looked up online for this layer.")
                if showsDirectoryNodes {
                    // Why the layer looks the way it does, stated where
                    // the toggle is: what draws, what folded into heard
                    // stations, and how to grow it — "enabled but
                    // invisible" was reported as a bug twice (2026-08-29
                    // 05:07 and 05:35) before this line said so.
                    Text("\(placedDirectoryCount) drawn · \(mergedNodeBoxCount) folded "
                         + "into heard stations · \(aliases.directory.allEntries.count) known — "
                         + "Find Positions places up to 40 more per press")
                }
                Toggle("Coverage Rings", isOn: $showsCoverageRing)
                    .help("Rings around your station drawn from the stations that answered you directly — a UA, DM or FRMR to your frames proves they decoded you. Inner ring: half of them are closer than this. Outer ring: the farthest answer. Measurements, not a propagation model.")
            } label: {
                Label("Layers", systemImage: showsPaths || showsPredictedPaths || showsDirectoryNodes
                      ? "point.topleft.down.to.point.bottomright.curvepath.fill"
                      : "point.topleft.down.to.point.bottomright.curvepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose what the map draws: paths observed between stations, paths the terrain says are possible, the node directory, and your station's measured coverage.")
            if !distantStations.isEmpty {
                Button {
                    hidesDistantStations.toggle()
                } label: {
                    Image(systemName: hidesDistantStations
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .iconHitTarget(iconHitTarget)
                }
                .help(distantFilterTooltip)
            }
            Menu {
                Picker("Terrain", selection: $terrainStyleRaw) {
                    Text("No Terrain").tag("")
                    ForEach(TerrainShading.Style.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!elevation.hasTerrain)

                Divider()
                // A menu that says "no data" and stops there leaves the
                // operator to guess which of the other controls fetches it.
                // The way to get terrain belongs where its absence is noticed.
                Button {
                    showingOfflineMaps = true
                } label: {
                    Label(elevation.hasTerrain
                          ? "Download More Terrain\u{2026}" : "Download Terrain\u{2026}",
                          systemImage: "arrow.down.circle")
                }
                Button {
                    drawing.begin(.download)
                } label: {
                    Label("Draw an Area to Download\u{2026}", systemImage: "square.dashed")
                }
                if elevation.hasTerrain {
                    Text("\(elevation.tileCount) tile\(elevation.tileCount == 1 ? "" : "s") stored")
                } else {
                    Text("No terrain data yet")
                }
            } label: {
                Label("Terrain", systemImage: terrainStyle == nil ? "mountain.2" : "mountain.2.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Draws the stored elevation data over the basemap. Hillshade lights the ground from the north-west so ridge lines read as ridges \u{2014} the feature that actually blocks a path. Elevation colours absolute height on a fixed scale, so the same colour means the same altitude on every tile. This is the very data the path forecasts are computed from.")

            if serviceStore != nil {
                Button {
                    showingDirectory = true
                } label: {
                    Image(systemName: "text.book.closed")
                        .iconHitTarget(iconHitTarget)
                }
                .help("What the stations around here run \u{2014} nodes, bulletin boards, digipeaters and gateways, as they announced themselves in ID and beacon frames. The network's own directory, which nothing else assembles because nobody publishes one.")
            }
            Button {
                showsList.toggle()
            } label: {
                Image(systemName: showsList ? "sidebar.right" : "sidebar.trailing")
                    .iconHitTarget(iconHitTarget)
            }
            .help(showsList ? "Hide the station list and give the map the window."
                            : "Show the station list.")
        }
        .padding(12)
        .sheet(isPresented: $showingCapture) { captureSheet }
        .sheet(isPresented: $showingDirectory) {
            NavigationStack {
                StationDirectoryView(store: serviceStore) { callsign in
                    showingDirectory = false
                    onOpenProfile?(callsign)
                }
                .navigationTitle("Station Directory")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingDirectory = false }
                    }
                }
            }
            .frame(minWidth: 440, minHeight: 460)
        }
        .sheet(isPresented: $showingOfflineMaps) {
            NavigationStack {
                OfflineMapsView(
                    store: offlineTiles,
                    elevation: elevation,
                    observer: observer,
                    drawnRegion: downloadRegion,
                    suggestedRegion: downloadRegion ?? MapRegionFit.region(
                        covering: [observer].compactMap { $0 } + Array(coordinates.values))?.mkRegion,
                    suggestedRegionName: downloadRegion == nil
                        ? "this area" : "the area you drew")
                .navigationTitle("Offline Data")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showingOfflineMaps = false
                            downloadRegion = nil
                        }
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

    /// Says what the filter took away, and offers it straight back.
    ///
    /// A list that quietly drops rows is how twenty missing stations stay
    /// missing. The count is on screen whenever the filter is on, not buried
    /// in a tooltip on the control that caused it.
    private var distantBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            Text("\(distantStations.count) station\(distantStations.count == 1 ? "" : "s") hidden \u{2014} further than \(Int(StationPlausibility.defaultRangeKilometres)) km, so not heard by radio.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Show") { hidesDistantStations = false }
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
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
                               terrainOverlays: terrainOverlays,
                               tileStore: offlineTiles.hasStoredTiles ? offlineTiles.store : nil,
                               tileSource: offlineTiles.storedSource,
                               overlays: overlayStore.visibleLayers,
                               drawing: $drawing,
                               onDrawTap: handleDrawTap,
                               coverage: coverageRing,
                               selection: $selection)
            .overlay(alignment: .bottomTrailing) { selectionCard }

            MapDrawingToolbar(session: $drawing, onComplete: finishShape)
                .padding(.top, 8)
        }
        .textEntryPrompt($drawPrompt)
    }

    /// A floating card for the selected marker: what the tooltip says, in
    /// a form a click can reach — hover is a pointer affordance, and the
    /// card also carries the way into the full identity page.
    @ViewBuilder
    private var selectionCard: some View {
        if let selected = selection, selected != "__observer__",
           let site = scope.sites.first(where: { $0.id == selected }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if site.isNode {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.purple)
                            .help("A NET/ROM node or directory entry, not a heard station.")
                    }
                    Text(site.label)
                        .font(.system(.headline, design: .monospaced))
                    Spacer(minLength: 12)
                    Button {
                        selection = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                Text(site.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let chain = plannedChainFor?(site.id), !chain.isEmpty {
                    // The whole route, in the card where the decision to
                    // connect is made — same planner the relay drives, so
                    // this cannot promise a path the dial will not take.
                    Label("You › \(chain.joined(separator: " › ")) › \(site.label)",
                          systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("The node-prompt chain a connect would walk: measured "
                              + "routes first, then node directories. Every hop is "
                              + "proven live during the connect before the next is asked.")
                }
                HStack(spacing: 8) {
                    if let onConnect {
                        Button {
                            onConnect(site.id)
                        } label: {
                            Label("Connect", systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Opens the Terminal and starts the connect — relayed "
                              + "through the chain above when one is needed.")
                    }
                    if let onOpenProfile {
                        Button {
                            onOpenProfile(site.id)
                        } label: {
                            Label("Open Profile", systemImage: "person.text.rectangle")
                        }
                        .controlSize(.small)
                        .help("Everything known about \(site.label): identity, roles, links, and the chain a connect would walk.")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 300, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .padding(12)
            .transition(.opacity)
        }
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
        // A download box is a question, not a feature: it gets no name and is
        // never saved to a layer.
        if drawing.mode == .download {
            let region = drawing.region()
            drawing.cancel()
            guard let region else { return }
            downloadRegion = region
            showingOfflineMaps = true
            return
        }
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
        var candidates = HeardStationMap.lookupCandidates(unplaced, aliases: aliases.directory)
        // With the directory layer on, the button also chips away at the
        // unplaced directory — up to forty operators per press, the ones
        // most nodes vouch for first, never automatically. "47 of 51
        // placed" while the layer showed a dozen diamonds was the gap
        // (field capture 2026-08-29 04:55): the layer only draws what the
        // cache can place, and nothing was feeding the cache.
        if showsDirectoryNodes {
            let cached = Set(lookup.records.keys.map { $0.uppercased() })
            let heardBases = Set(stations.map { CallsignQuery.normalize($0.call) })
            for call in HeardStationMap.directoryLookupCandidates(
                aliases: aliases.directory, cachedCallsigns: cached,
                heardBases: heardBases)
            where !candidates.contains(call) {
                candidates.append(call)
            }
        }
        await lookup.resolveAll(candidates)
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
