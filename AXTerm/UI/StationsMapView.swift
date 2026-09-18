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
    /// Objects and items heard on the air — fires, closures, shelters, aid
    /// stations. Placed by other operators about somewhere other than
    /// themselves, so they are drawn as their own markers with their reporter
    /// named on the card.
    var objects: APRSObjectStore = APRSObjectStore()
    /// NWS watches and warnings relayed onto APRS. Internet-fed upstream, so
    /// each one is shown with the time it was heard rather than on its own.
    var alerts: APRSWeatherAlertStore = APRSWeatherAlertStore()
    /// The "who can hear me" probe, so a position request can be sent from the
    /// map itself — the page where you are already looking at who is out there
    /// and wondering which of them can hear you. Observed, so the control
    /// follows the probe's own status rather than going stale.
    @ObservedObject var probe: APRSReachabilityProbe
    /// Raw traffic, for path evidence the station summaries cannot carry —
    /// a completed SABM/UA handshake proves a path end to end, and only the
    /// frames themselves show it.
    var recentPackets: [Packet] = []
    /// Grid squares for RMS gateways, keyed by full callsign with SSID.
    let gatewayGrids: [String: String]
    /// Locators stations beaconed about themselves, per full callsign.
    var announcedGrids: [String: String] = [:]
    let observerGrid: String
    /// Where this station actually is, when something better than the grid
    /// square is known. The grid string stays for the label and the cache
    /// key; this is what gets plotted and measured from.
    var observerPosition: StationPosition?
    /// Excluded from the heard list and used to label the centre marker.
    let myCallsign: String
    /// Every address this station transmits as — the beacon callsign plus
    /// whatever else it answers to. These are the markers the centre already
    /// is; any *other* SSID on the same licence is a different radio and
    /// belongs on the map like anyone else's.
    var ownCallsigns: Set<String> = []
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
    /// Start an APRS message to this station. Nil hides the action.
    var onMessage: ((String) -> Void)?
    /// Send this station one directed query. Nil hides the action.
    ///
    /// One closure for the whole catalogue rather than a `ping` and a
    /// `version` and a `trace`: which question is asked is the operator's
    /// choice, and the transmit side does the same thing with all of them.
    var onQuery: ((APRSStationQuery) -> Void)?
    /// What became of the last ping to a station, for the card to report.
    /// Nil leaves the card silent about it.
    var pingState: ((String) -> APRSPingTracker.Ping?)?
    /// Who has decoded us and who we have decoded, per radio family. Both
    /// directions of coverage are measured from these.
    var coverageEvidence: MapCoverageEvidence = MapCoverageEvidence()

    /// Builds the channel-and-path report on demand. A closure rather than a
    /// value: measuring the channel means walking the recent packet history,
    /// which is not worth doing on every redraw for a panel that is usually
    /// closed.
    var channelReport: (() -> APRSChannelReport)?

    /// What we have heard from a station, for judging how far to ask it.
    /// A closure rather than the station list itself: this view already takes
    /// its sites from a projection, and handing it the tracker would let it
    /// reach for anything.
    var reachAdvice: ((String) -> APRSReachAdvice)? = nil

    /// What the Ping button promises, spelled out.
    ///
    /// A function rather than an inline expression because the concatenation
    /// is long enough to defeat the type checker inside a `ViewBuilder`, and
    /// because it is the sentence worth testing: it is where the operator
    /// learns the reach was overridden and why.
    static func pingHelp(label: String, reach: APRSProbeReach,
                         advice: APRSReachAdvice, selected: APRSProbeReach) -> String {
        var text = "Send \(label) a position request (?APRSP) \u{2014} a targeted "
        text += "\u{201C}can you hear me\u{201D}. "
        text += reach == .wide
            ? "Digipeated on this radio's APRS path, so an answer proves the station is "
            + "reachable, not that it hears you."
            : "Sent direct, so an answer proves it hears this station."
        // Silence about an override would be the worst of both: the operator
        // picked one reach and a different one goes out.
        if advice.disagrees(with: selected), let caution = advice.caution {
            text += " \u{2014} " + caution
        } else if let caution = advice.caution {
            text += " " + caution
        }
        return text + " The menu has the other six queries and the reach."
    }
    /// When this station last put one of our own frames back on the air.
    ///
    /// Separate from `pingState` because it answers the question the operator
    /// actually has \u{2014} *can it hear me* \u{2014} and outlives any single
    /// ping. A station that repeats our traffic and never answers a query is
    /// a common and perfectly healthy configuration.
    var repeatsUs: ((String) -> Date?)?


    /// Published to the sidebar, which owns the layer toggles now.
    @ObservedObject var layerStatus: MapLayerStatus
    /// Live traffic for the strip along the bottom. Held as a plain reference,
    /// **not** `@ObservedObject`: observing it here would re-render the whole
    /// map on every frame. Only `MapTrafficChin` observes it.
    var traffic: MapTrafficFeed?
    /// The radios whose traffic the strip may show — enabled, and not hidden
    /// on the map. Empty leaves the strip unscoped.
    var trafficRadios: [MapTrafficRadio] = []
    /// The radios switched off in the sidebar. The map is handed stations
    /// already filtered by them, so it cannot see the switch itself — but it
    /// has to know one was thrown, or removing the markers waits on the
    /// batching clock and the toggle looks broken.
    var hiddenRadios: Set<RadioID> = []

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
    @AppStorage("stations.showsPaths") private var showsPaths = MapLayerDefaults.showsPaths
    /// Terrain forecasts for pairs that have never been heard talking.
    /// Separate from `showsPaths` and off by default, because a prediction
    /// is a different kind of claim from an observation and should never
    /// arrive uninvited alongside one.
    @AppStorage("stations.showsPredictedPaths") private var showsPredictedPaths = MapLayerDefaults.showsPredictedPaths
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
    @AppStorage("stations.hidesDistantStations") private var hidesDistantStations = MapLayerDefaults.hidesDistantStations
    /// The whole node directory on the map — every station the network
    /// claims reachable that can be placed from what is already cached.
    /// Off by default: a harvested directory runs to hundreds of names,
    /// and the map's first job is what was actually heard.
    @AppStorage("stations.showsDirectoryNodes") private var showsDirectoryNodes = MapLayerDefaults.showsDirectoryNodes
    /// Measured coverage rings around this station. On by default: they
    /// draw only when at least one station has answered us directly, and
    /// knowing one's own footprint is half of why a coverage map exists.
    @AppStorage("stations.showsCoverageRing") private var showsCoverageRing = MapLayerDefaults.showsCoverageRing
    @AppStorage("stations.showsAPRSCoverageRing") private var showsAPRSCoverageRing = MapLayerDefaults.showsAPRSCoverageRing
    /// Whether to place a station at its own transmitted APRS fix (on) or at
    /// its licence/registry point (off). Only matters for stations that have
    /// both; the default prefers the station's own beacon.
    @AppStorage("stations.preferTransmittedPosition") private var prefersTransmittedPosition = MapLayerDefaults.preferTransmittedPosition

    // APRS-mode per-type visibility. Each hides one class of *transmitted*
    // APRS station (a station drawn at its beaconed fix, which is the only
    // kind that has a type). Address dots and nodes carry no APRS class and
    // are never touched by these. Default on; only surfaced while Transmitted
    // Positions is on, and mirrored in MapLayerRows under the same keys.
    @AppStorage("stations.showsObjects") private var showsObjects = MapLayerDefaults.showsObjects
    @AppStorage("stations.clustersStations") private var clustersStations = MapLayerDefaults.clustersStations
    @AppStorage("stations.falloffMinutes") private var falloffMinutes = MapLayerDefaults.falloffMinutes
    @AppStorage("stations.showsTracks") private var showsTracks = MapLayerDefaults.showsTracks
    /// Every rover's trail, not just the selected station's.
    ///
    /// On by default because that is what an APRS operator expects: aprs.fi,
    /// YAAC and Xastir all draw everyone's track, and a map that quietly drew
    /// none until something was selected read as broken rather than as a
    /// setting. Turn it off to narrow to whatever is selected, which is worth
    /// doing on a busy channel where the trails bury the terrain.
    @AppStorage("stations.showsAllTracks") private var showsAllTracks = MapLayerDefaults.showsAllTracks
    @AppStorage("stations.trackWindowMinutes") private var trackWindowMinutes = MapLayerDefaults.trackWindowMinutes
    @AppStorage("stations.showsWeatherField") private var showsWeatherField = MapLayerDefaults.showsWeatherField
    @AppStorage("stations.weatherFieldParameter") private var weatherFieldParameter =
        APRSWeatherField.Parameter.temperature.rawValue
    @AppStorage("stations.showsTypeDigipeater") private var showsTypeDigipeater = MapLayerDefaults.showsTypeDigipeater
    @AppStorage("stations.showsTypeWeather") private var showsTypeWeather = MapLayerDefaults.showsTypeWeather
    @AppStorage("stations.showsTypeVehicle") private var showsTypeVehicle = MapLayerDefaults.showsTypeVehicle
    @AppStorage("stations.showsTypeFixed") private var showsTypeFixed = MapLayerDefaults.showsTypeFixed

    /// What the trail layer is actually drawing, and why it is not drawing
    /// more. A layer that can legitimately draw nothing has to say so or it is
    /// indistinguishable from a broken one — and this one draws nothing most
    /// of the time, because a trail needs a station that *moved* between two
    /// beacons inside the window, which fixed stations never do.
    private var trackCaption: String? {
        guard showsTracks else { return nil }
        let drawn = tracks.count
        if drawn > 0 {
            return drawn == 1 ? "1 trail" : "\(drawn) trails"
        }
        if !showsAllTracks {
            return selection == nil
                ? "Select a station to see its trail"
                : "That station has not moved in this window"
        }
        let movers = stations.filter { $0.track.count >= 2 }.count
        return movers == 0
            ? "No station has moved since AXTerm started"
            : "No station has moved within this window"
    }

    /// Whether a station has been heard recently enough to still be drawn.
    ///
    /// Separate from the recency *fade*, which never removes anything. On a
    /// busy channel a day of accumulated stations buries the handful that are
    /// actually on the air, and in the situation this map is for, "who is up
    /// right now" is the whole question. An entry with no heard time at all is
    /// a directory lead rather than a heard station and is governed by its own
    /// layer, not by this.
    private func withinFalloff(_ entry: HeardStationMap.Entry) -> Bool {
        guard falloffMinutes > 0 else { return true }
        guard let lastHeard = entry.lastHeard else { return true }
        return Date().timeIntervalSince(lastHeard) <= Double(falloffMinutes) * 60
    }

    /// How many placed stations the fall-off is currently holding back, so the
    /// switch can say what it is doing rather than silently thinning the map.
    private var falloffHiddenCount: Int {
        guard falloffMinutes > 0 else { return 0 }
        return visibleEntries.filter { $0.isPlaced && !withinFalloff($0) }.count
    }

    /// Everything the operator can switch that changes which markers exist.
    /// Used to bypass the annotation throttle on a deliberate change.
    private var layerGeneration: String {
        MapLayerGeneration.token(
            switches: [prefersTransmittedPosition, showsTypeDigipeater, showsTypeWeather,
                       showsTypeVehicle, showsTypeFixed, showsObjects, showsDirectoryNodes,
                       hidesDistantStations, showsTracks, showsAllTracks, clustersStations],
            trackWindowMinutes: trackWindowMinutes,
            falloffMinutes: falloffMinutes,
            hiddenRadios: hiddenRadios)
            + "|own:" + ownObjectToken
    }

    /// The markers the operator may drag: our own live objects only.
    ///
    /// Dragging is the gesture people reach for, and it is safe here only
    /// because the drop opens the confirm sheet rather than transmitting.
    /// Withheld entirely when this map cannot place at all, so a read-only
    /// map has no gesture that implies it can.
    private var draggableSiteIDs: Set<String> {
        guard onPlaceObject != nil, showsObjects else { return [] }
        return Set(objects.live()
            .filter { APRSObjectPlacement.mayRemove($0, ourAddresses: ownCallsigns) }
            .map { Self.objectSiteID($0.report.key) })
    }

    private var ownObjectToken: String {
        MapLayerGeneration.ownObjectToken(objects.live(), ours: ownCallsigns)
    }

    /// Which families each radio has heard, from the traffic itself. The map's
    /// APRS layers apply only to radios that actually carry APRS; on a packet
    /// channel of nodes and sessions they would otherwise hide everything.
    private var radioFamilies: [RadioID: Set<RadioTrafficFamily>] {
        RadioTrafficClassifier.families(from: stations)
    }

    /// Callsigns heard on at least one radio that carries APRS. A station
    /// nobody heard on an APRS channel is outside the APRS layers' remit.
    ///
    /// A radio that has heard nothing classifiable yet counts as APRS, so a
    /// fresh session behaves exactly as it did before any evidence arrived
    /// rather than briefly drawing a different map.
    private var callsOnAPRSChannels: Set<String> {
        let families = radioFamilies
        var result: Set<String> = []
        for station in stations {
            let onAPRS = station.perRadio.keys.contains { radio in
                guard let known = families[radio], !known.isEmpty else { return true }
                return known.contains(.aprs)
            }
            if onAPRS || station.perRadio.isEmpty { result.insert(station.call.uppercased()) }
        }
        return result
    }

    private func isOnAPRSChannel(_ entry: HeardStationMap.Entry) -> Bool {
        callsOnAPRSChannels.contains(entry.callsign.uppercased())
    }

    /// Whether a placed entry survives the per-type filter. Only a
    /// transmitted-APRS station carries a symbol to classify; everything else
    /// passes untouched.
    private func typeVisible(_ entry: HeardStationMap.Entry) -> Bool {
        guard let code = entry.aprsSymbol?.code else { return true }
        switch APRSTypeBucket.of(code: code) {
        case .digipeater: return showsTypeDigipeater
        case .weather:    return showsTypeWeather
        case .vehicle:    return showsTypeVehicle
        case .fixed:      return showsTypeFixed
        }
    }

    private var positionPreference: HeardStationMap.PositionPreference {
        prefersTransmittedPosition ? .transmitted : .licence
    }
    @StateObject private var insights = NetworkInsightModel()
    /// Stored elevation grids. Terrain forecasts read this and nothing else,
    /// so the feature works with the network down, and is honestly
    /// unavailable rather than quietly wrong when nothing is downloaded.
    /// Owned by the shell so the station pages can read the same store —
    /// two handles to one elevation database would be two caches warming
    /// separately for the same tiles.
    @ObservedObject var elevation: ElevationStorage
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
    /// Our own APRS symbol, when the map is scoped to a radio that beacons an
    /// APRS position. The observer marker wears it so viewing the map through
    /// a radio using APRS shows us as the symbol we put on the air. Nil draws
    /// the plain home marker.
    var ownAPRSSymbol: APRSMapSymbol? = nil
    /// Put this station's own position on the air now, on every radio that
    /// beacons. The map is where an operator is looking when they think about
    /// their own position, and until now the only way to key a beacon was
    /// three levels into Settings.
    var onBeacon: (() -> Void)?
    /// Transmit an object, or the kill that removes one. Returns a problem to
    /// show the operator, or nil when the frame went out.
    var onPlaceObject: ((_ name: String, _ live: Bool,
                         _ latitude: Double, _ longitude: Double,
                         _ symbolTable: Character, _ symbolCode: Character,
                         _ comment: String) -> String?)?
    /// Why that would do nothing — no radio with a beacon on, no fix yet, a
    /// path that does not validate. Nil when the beacon can go out.
    var beaconObstacle: (() -> String?)?
    /// Drawing state. Taps become vertices while this is active.
    @State private var drawing = MapDrawingSession()
    /// The station the Ask sheet is open for. A wrapper rather than a bare
    /// string so `sheet(item:)` re-presents when the operator picks another
    /// station without closing first.
    @State private var askTarget: AskTarget?
    /// How far a directed query travels. Shared with `APRSAskStationSheet` so
    /// the quick menu and the dialog cannot disagree about what the operator
    /// last chose.
    /// Where a secondary click landed, while the compose sheet is up.
    /// A struct rather than a bare coordinate so `sheet(item:)` can drive it.
    /// The Find Positions button's tooltip.
    ///
    /// Hoisted out of the `.help` modifier it used to live in. Inline it was
    /// a ternary wrapped around two concatenations, one of which held another
    /// ternary and a call inside a string interpolation — and the type
    /// checker gave up on it outright, which failed the whole target rather
    /// than just this view. Written as statements it costs the compiler
    /// nothing and reads better besides.
    private var findPositionsHelp: String {
        guard settings.callsignLookupEnabled else {
            return "Turn on \u{201C}Look up callsigns online\u{201D} in Settings \u{2192} Winlink first. "
                 + "It is off by default because a lookup tells a third party which stations you are hearing."
        }
        let candidates = HeardStationMap.lookupCandidates(unplaced, aliases: aliases.directory).count
        var text = "Tries the \(candidates) unplaced callsigns again."
        if showsDirectoryNodes {
            text += " With the node directory shown, each press also looks up "
                  + "as many as forty directory operators — the ones most nodes "
                  + "vouch for first — so the layer fills in a batch at a time "
                  + "rather than flooding the lookup service."
        }
        text += " Lookups run on their own as stations are heard; this is for retrying the ones"
              + " that failed — after the network came back, say. Answers are cached permanently"
              + " and keep working offline."
        return text
    }

    @ViewBuilder
    private var movingBanner: some View {
        if let moving = movingObject {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                Text("Drag \u{201C}\(moving.report.name)\u{201D}, or secondary-click where it should go")
                    .font(.callout)
                Button("Cancel") { movingObject = nil }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    struct PendingObject: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        /// Set when this is a move rather than a new placement.
        var moving: APRSObjectStore.Placed?
    }
    @State private var pendingObject: PendingObject?
    /// The object waiting for somewhere to go.
    ///
    /// Moving is armed from the object's own card and finished with the same
    /// secondary click that places a new one, rather than by dragging the
    /// marker. A drag that transmits is one slipped trackpad away from moving
    /// somebody's road closure by accident, and there is no undo on a channel.
    @State private var movingObject: APRSObjectStore.Placed?

    @AppStorage("aprs.ask.reach") private var askReachRaw: String = APRSProbeReach.direct.rawValue

    private var askReach: APRSProbeReach {
        APRSProbeReach(rawValue: askReachRaw) ?? .direct
    }

    struct AskTarget: Identifiable, Equatable {
        var callsign: String
        var id: String { callsign }
    }

    /// Geometry waiting to be named — every feature gets a label, so the
    /// prompt is part of finishing the shape rather than an optional extra.
    @State private var pendingGeometry: ShapefileReader.Geometry?
    @State private var drawPrompt: TextEntryPrompt?
    @State private var showingOfflineMaps = false
    @State private var showingDirectory = false
    @State private var showingChannelReport = false
    @State private var latestChannelReport: APRSChannelReport?
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
        // Bound once. `antennaHeights` is computed and reads the note table,
        // so referring to it inside the closure was a full read per station
        // every time this key was evaluated, which is every redraw.
        let recorded = antennaHeights
        let heights = recorded.keys.sorted()
            .map { "\($0):\(recorded[$0] ?? 0)" }.joined(separator: ",")
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


    private var terrainStyle: TerrainShading.Style? {
        TerrainShading.Style(rawValue: terrainStyleRaw)
    }

    /// Shaded tiles for whatever is stored.
    ///
    /// Rebuilt only when the style or the stored tile count changes — the
    /// overlays cache their rendered images, and making new ones on every
    /// redraw would throw that away.
    ///
    /// The doc comment above was true of the overlays MapKit *installs* and
    /// false of this property, which the map's update pass reads every time
    /// it runs. `ElevationOverlay.overlays(from:style:)` queries the tile
    /// store, so the map was doing a synchronous SQLite read and allocating
    /// an overlay per stored tile on every pass — a couple of times a second
    /// on a busy channel, on the main thread, where it costs frames. The
    /// installed set never changed as a result, because the ids matched;
    /// only the work was wasted, and dropped frames are the kind of thing
    /// that reads as the map stuttering.
    private var terrainOverlays: [ElevationOverlay] {
        guard let terrainStyle, let store = elevation.store,
              elevation.hasTerrain else {
            terrainCache.key = ""
            terrainCache.overlays = []
            return []
        }
        let key = "\(terrainStyle.rawValue)|\(elevation.tileCount)"
        if terrainCache.key != key {
            terrainCache.overlays = ElevationOverlay.overlays(from: store, style: terrainStyle)
            terrainCache.key = key
        }
        return terrainCache.overlays
    }

    /// Reference box, same pattern as `PathAssemblyCache`: mutating it
    /// during a body evaluation must never invalidate the view.
    nonisolated final class TerrainCache {
        var key = ""
        var overlays: [ElevationOverlay] = []
    }
    @State private var terrainCache = TerrainCache()

    /// Our own coordinate: the resolved position when there is one, the
    /// grid centre otherwise.
    ///
    /// This drives our pin, the coverage rings, the plausibility partition
    /// and the framing, so taking the grid square when a GPS fix existed put
    /// the whole map up to 4.3 km from where the toolbar said the station
    /// was — two parts of the app disagreeing about the operator's own
    /// location, with nothing on screen to say which was right.
    private var observer: GreatCircle.Point? {
        guard let live = observerPosition?.point
            ?? Maidenhead.center(of: observerGrid).map(GreatCircle.Point.init)
        else {
            observerAnchor.point = nil
            return nil
        }
        // Anchored against GPS noise. Successive fixes land a few metres
        // apart (the toolbar chip reports ±20 m), and every one of them used
        // to become a new observer coordinate — which slid our pin, moved
        // the endpoint of every path line radiating from this station, and
        // re-centred the coverage rings, roughly once a second. On screen
        // that was the whole network around our dot twitching in place. The
        // drawn position only follows the fix once it has moved further
        // than the noise floor; a base station holds still, and a rover
        // driving at any real speed crosses the threshold every couple of
        // seconds anyway.
        if let held = observerAnchor.point,
           GreatCircle.kilometres(from: held, to: live) * 1000
               < Self.observerJitterFloorMetres {
            return held
        }
        observerAnchor.point = live
        return live
    }

    /// How far a fresh fix must move before the map redraws around it.
    /// Above any plausible GPS wobble for a stationary antenna, far below
    /// anything that matters at map zoom.
    static let observerJitterFloorMetres = 25.0

    /// Reference box, same pattern as `PathAssemblyCache`: mutating it
    /// during a body evaluation must never invalidate the view.
    nonisolated final class ObserverAnchor {
        var point: GreatCircle.Point?
    }
    @State private var observerAnchor = ObserverAnchor()

    /// Stations the radio has actually met: heard stations plus the
    /// via-path aliases. These are the entries the *analysis* layers
    /// (paths, terrain, coverage) are allowed to see.
    /// Falls back to the beacon callsign alone when the caller has not said
    /// what else this station answers to.
    private var ownAddresses: Set<String> {
        ownCallsigns.isEmpty ? [myCallsign.uppercased()] : ownCallsigns
    }

    private var coreEntries: [HeardStationMap.Entry] {
        let heard = HeardStationMap.entries(
            stations: stations,
            directory: lookup.records,
            gatewayGrids: gatewayGrids,
            announcedGrids: announcedGrids,
            preference: positionPreference,
            excluding: ownAddresses)
        // Aliases used in via paths, placed through their operator.
        // Appended rather than merged: a node is its own thing, and its
        // position is a lead rather than a fix.
        // Placed through the same step the directory layer uses. An alias
        // crosses between the two layers as via paths change, and if only
        // one of them could place it, it appeared and vanished with the
        // traffic rather than staying put.
        let nodes = HeardStationMap.aliasEntries(
            aliases: aliases.directory,
            usedAliases: HeardStationMap.aliasesInUse(stations),
            directory: lookup.records,
            stations: stations)
            .map {
                HeardStationMap.placingFromAnnouncedGrid(
                    $0, aliases: aliases.directory, announcedGrids: announcedGrids)
            }
        guard showsDirectoryNodes else {
            return HeardStationMap.addingAliases(nodes, toHeard: heard)
        }
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
        return HeardStationMap.addingAliases(nodes, toHeard: annotated)
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

    /// One derivation of the entry pipeline per ~15 seconds, not one per
    /// computed property per body evaluation. A live sample of the frozen
    /// app (field capture 2026-08-29 06:19) showed the main thread
    /// spending an entire layout pass inside this view's body: the
    /// header, coverage chip, banners, map pane and station list each
    /// re-derived the full alias-directory walk and plausibility
    /// partition, and one body evaluation outgrew the frame budget so
    /// far the window never finished laying out. Marker recency and
    /// counts lagging up to 15 s is invisible; a body evaluation that
    /// takes seconds is a frozen app.
    // nonisolated: a MainActor-isolated class aborts if deallocated off
    // the main actor, and SwiftUI tears views down wherever it likes —
    // the module's known deinit trap. This is a plain value box; it
    // needs no isolation.
    nonisolated final class EntriesCache {
        var key = ""
        var core: [HeardStationMap.Entry] = []
        var coreVisible: [HeardStationMap.Entry] = []
        var all: [HeardStationMap.Entry] = []
        var shown: [HeardStationMap.Entry] = []
        var hidden: [HeardStationMap.Entry] = []
    }
    @State private var entriesCache = EntriesCache()

    private var entries: [HeardStationMap.Entry] {
        // Counts change when anything structural changes; the time
        // bucket bounds staleness for everything else (recency tints,
        // last-heard text). Deliberately NOT per-packet: that cadence is
        // what this cache exists to absorb.
        let bucket = Int(Date().timeIntervalSince1970 / 15)
        let key = "\(stations.count)|\(lookup.records.count)|"
            + "\(aliases.directory.allEntries.count)|\(showsDirectoryNodes)|"
            + "\(hidesDistantStations)|\(myCallsign)|\(observerGrid)|\(bucket)"
            // The resolved origin, or a fix arriving would not redraw.
            + "|\(observer?.latitude ?? 0),\(observer?.longitude ?? 0)"
            // Flipping the position-source toggle must re-derive placements.
            + "|\(prefersTransmittedPosition)"
        if entriesCache.key != key {
            let core = coreEntries
            let all = core + directoryEntries(core: core)
            let partition = StationPlausibility.partition(all, observer: observer)
            entriesCache.core = core
            entriesCache.coreVisible = hidesDistantStations
                ? StationPlausibility.partition(core, observer: observer).shown
                : core
            entriesCache.all = all
            entriesCache.shown = partition.shown
            entriesCache.hidden = partition.hidden
            entriesCache.key = key
        }
        return entriesCache.all
    }

    /// Cheap fingerprint of everything the sidebar's captions depend on.
    private var layerStatusKey: String {
        [String(elevation.tileCount),
         String(showsDirectoryNodes), String(showsPredictedPaths),
         String(stations.count), String(aliases.directory.allEntries.count),
         String(insights.isWorking), String(insights.snapshot.predictions.count),
         String(insights.snapshot.terrainUnavailable)].joined(separator: "|")
    }

    private func publishLayerStatus() {
        layerStatus.hasTerrain = elevation.hasTerrain
        layerStatus.forecastSummary = showsPredictedPaths ? forecastSummary : nil
        layerStatus.distantCount = distantStations.count
        layerStatus.directoryCaption = showsDirectoryNodes
            ? "\(placedDirectoryCount) drawn \u{b7} \(mergedNodeBoxCount) folded into heard "
              + "stations \u{b7} \(aliases.directory.allEntries.count) known"
            : nil
        let live = objects.live()
        let hazards = live.filter { $0.report.urgency == .hazard }.count
        layerStatus.falloffHiddenCount = falloffHiddenCount
        layerStatus.trackCaption = trackCaption
        layerStatus.objectCaption = live.isEmpty ? nil
            : (hazards > 0
               ? "\(hazards) hazard\(hazards == 1 ? "" : "s") \u{b7} \(live.count) placed"
               : "\(live.count) placed")
        // Say why it cannot be drawn, rather than greying out a switch and
        // leaving the operator to guess. Two stations reporting the chosen
        // reading is the floor: one is a reading, not a field.
        // Barometric tendency, which is the one predictive thing RF carries.
        // Built from every station reporting one, not only those inside the
        // weather field's coverage radius: a fall two counties away is still
        // the thing arriving here in three hours.
        layerStatus.pressure = APRSPressureNowcast.build(
            stations.compactMap { station in
                APRSWeatherTrend.pressureTendency(station.weatherHistory, now: Date())
                    .map { .init(call: station.call, perThreeHours: $0.perThreeHours) }
            })
        if let field = weatherField {
            layerStatus.weatherFieldCaption = field.summary(
                inFahrenheit: settings.distanceUnitIsMiles)
            layerStatus.weatherFieldUnavailableReason = nil
        } else {
            layerStatus.weatherFieldCaption = nil
            let parameter = APRSWeatherField.Parameter(rawValue: weatherFieldParameter)
                ?? .temperature
            let reporting = weatherObservations(for: parameter).count
            // "None heard" and "heard, but their readings have gone stale" are
            // completely different situations and the first was being printed
            // for the second — with weather stations plainly on the map. A
            // field is built only from readings under an hour old, and the
            // reason has to say so rather than denying the stations exist.
            let everHeard = stations.filter {
                $0.weather.flatMap(parameter.value(from:)) != nil
            }.count
            layerStatus.weatherFieldUnavailableReason = {
                if everHeard == 0 { return "No weather station heard yet" }
                if reporting == 0 {
                    return everHeard == 1
                        ? "1 station heard, its reading is over an hour old"
                        : "\(everHeard) stations heard, readings over an hour old"
                }
                return "Needs 2 current readings \u{b7} 1 so far"
            }()
        }
        // Which parameters could be drawn right now, so the picker can grey
        // out the ones no station is reporting rather than offering an empty
        // map. A humidity field needs two stations with hygrometers, which is
        // a different question from whether any weather station was heard.
        layerStatus.availableWeatherParameters = Set(
            APRSWeatherField.Parameter.allCases.filter {
                weatherObservations(for: $0).count >= 2
            })
    }

    // MARK: - Inferred weather field

    /// The weather stations that can contribute to the field: heard, placed,
    /// currently reporting a temperature, and recent enough to still mean it.
    ///
    /// A station placed at a licence address is deliberately allowed in. Its
    /// thermometer is real even when its dot is a lookup, and excluding it
    /// would throw away half the readings on a channel where few stations
    /// beacon a position.
    private func weatherObservations(
        for parameter: APRSWeatherField.Parameter) -> [APRSWeatherField.Observation] {
        let now = Date()
        let placedByCall = Dictionary(
            placed.map { ($0.callsign.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return stations.compactMap { station -> APRSWeatherField.Observation? in
            let call = station.call.uppercased()
            guard let weather = station.weather,
                  let value = parameter.value(from: weather),
                  let heard = station.weatherHeard,
                  now.timeIntervalSince(heard) <= HeardStationMap.weatherFreshWindow,
                  let entry = placedByCall[call],
                  let position = entry.position
            else { return nil }
            return APRSWeatherField.Observation(
                callsign: call, position: position, value: value,
                elevationMetres: elevationSampler?.elevation(at: position))
        }
    }

    private var weatherField: APRSWeatherField? {
        let parameter = APRSWeatherField.Parameter(rawValue: weatherFieldParameter)
            ?? .temperature
        return APRSWeatherField.build(
            observations: weatherObservations(for: parameter), parameter: parameter)
    }

    /// The wash itself, or nothing when the layer is off or too few stations
    /// have been heard to infer one.
    private var weatherFieldOverlays: [WeatherFieldOverlay] {
        guard showsWeatherField, let field = weatherField else { return [] }
        // The sampler is a value type over a locked cache, so the render
        // closure can take it to a background queue. Nil when no elevation is
        // stored, which drops the field to a plain horizontal blend — honest,
        // and the layer's help says so.
        let sampler = elevationSampler
        return [WeatherFieldOverlay.overlay(
            for: field,
            elevation: sampler.map { s in { point in s.elevation(at: point) } },
            isDark: basemap.isDark)].compactMap { $0 }
    }

    /// Bilinear elevation over the stored tiles, or nil when none are stored.
    private var elevationSampler: StoredElevationSampler? {
        elevation.store.map(StoredElevationSampler.init(store:))
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

    /// The coverage rings to draw: the connected-mode footprint, the APRS
    /// one, both, or neither, according to the switches under each radio.
    ///
    /// Each is computed only when its switch is on. Both are measurements of
    /// this station's own transmitter, from different evidence, so they are
    /// kept apart rather than pooled into one ring that would answer neither
    /// question.
    private var coverageRings: [CoverageEstimate.Ring] {
        guard let observer else { return [] }
        let answered = showsCoverageRing
            ? CoverageEstimate.ring(
                paths: networkPaths,
                ownAddresses: [myCallsign],
                positions: networkPositions,
                observer: observer)
            : nil
        let digipeated = showsAPRSCoverageRing
            ? CoverageEstimate.digipeatRing(
                repeaters: coverageEvidence.repeatedUsAPRS,
                positions: networkPositions,
                observer: observer)
            : nil
        // Hearing is the other direction and it is measured per family: a
        // station heard direct on 2 m APRS says nothing about what the packet
        // radio on another band can hear.
        var received: [CoverageEstimate.Ring] = []
        if showsCoverageRing,
           let ax25 = CoverageEstimate.receiveRing(
            heardDirect: coverageEvidence.heardDirectAX25,
            positions: networkPositions, observer: observer) {
            received.append(ax25)
        }
        if showsAPRSCoverageRing,
           let aprs = CoverageEstimate.receiveRing(
            heardDirect: coverageEvidence.heardDirectAPRS,
            positions: networkPositions, observer: observer) {
            received.append(aprs)
        }
        return CoverageRingSelection.rings(
            answered: answered, showsAnswered: showsCoverageRing,
            digipeated: digipeated, showsDigipeated: showsAPRSCoverageRing,
            received: received, showsReceived: true)
    }

    /// Stations set aside as impossible to have heard over the air.
    ///
    /// Computed even when the toggle is off, so the toolbar can say how many
    /// there are rather than the operator discovering the feature by
    /// accident.
    private var distantStations: [HeardStationMap.Entry] {
        _ = entries
        return entriesCache.hidden
    }

    /// Entries after the distance filter, if it is on.
    private var visibleEntries: [HeardStationMap.Entry] {
        guard hidesDistantStations else { return entries }
        _ = entries
        return entriesCache.shown
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
        _ = entries
        for entry in entriesCache.coreVisible where entry.isPlaced {
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
    nonisolated final class PathAssemblyCache {
        var paths: [NetworkPath] = []
        var loadedAt = Date.distantPast
    }
    @State private var pathCache = PathAssemblyCache()
    private var unplaced: [HeardStationMap.Entry] { visibleEntries.filter { !$0.isPlaced } }

    private var scope: StationScope {
        guard let observer else { return StationScope.build(observerLabel: "", sites: []) }
        // Showing transmitted positions means showing *only* stations at their
        // own beaconed fix — a licence/registry guess is not a transmitted
        // position, so those heard stations are dropped from the map (nodes and
        // still-unplaced entries are left alone). Off, every placeable station
        // shows at whatever point it has.
        let entriesForMap = prefersTransmittedPosition
            ? visibleEntries.filter { entry in
                // Unplaced entries feed the analysis layers, not the map, and
                // are left alone. A placed station shows only at its own
                // transmitted fix (a node alias, placed through its operator,
                // counts) — and in APRS mode a per-type toggle can hide its
                // whole class.
                guard entry.isPlaced else { return true }
                guard withinFalloff(entry) else { return false }
                // An APRS layer only governs APRS stations. A station heard
                // only on a radio that carries no APRS — a packet channel of
                // nodes and sessions — has no beaconed fix to prefer and must
                // not be hidden for lacking one, which emptied the whole map
                // whenever such a radio was the one being shown.
                guard entry.isNodeAlias || entry.origin == .transmittedAPRS
                        || !isOnAPRSChannel(entry) else { return false }
                return typeVisible(entry)
            }
            : visibleEntries.filter { !$0.isPlaced || withinFalloff($0) }
        let stationScope = HeardStationMap.scope(
            observerLabel: observerGrid.uppercased(),
            observer: observer, entries: entriesForMap, now: Date(),
            distanceInMiles: settings.distanceUnitIsMiles)
        guard showsObjects else { return stationScope }
        // Objects sit alongside stations rather than replacing them: a fire
        // and the station reporting it are two different points and an
        // operator needs both.
        return StationScope.build(
            observerLabel: stationScope.observerLabel,
            sites: stationScope.sites + objectSites(observer: observer))
    }

    /// One of our own live objects, by the site id the card was built from.
    /// Nil for a station, for somebody else's object, and for one that has
    /// aged out — a stand-down for something no longer live would transmit a
    /// kill for an object nobody is showing.
    private func ourObject(siteID: String) -> APRSObjectStore.Placed? {
        objects.live().first {
            Self.objectSiteID($0.report.key) == siteID
                && APRSObjectPlacement.mayRemove($0, ourAddresses: ownCallsigns)
        }
    }

    /// The heard objects as map sites. Ids are prefixed so an object named
    /// after a callsign can never collide with the station of that name.
    private func objectSites(observer: GreatCircle.Point) -> [StationScope.Site] {
        let now = Date()
        return objects.live(now: now).map { placed in
            let position = placed.position
            return StationScope.Site(
                id: Self.objectSiteID(placed.report.key),
                label: placed.report.name,
                kilometres: GreatCircle.kilometres(from: observer, to: position),
                bearingDegrees: GreatCircle.bearingDegrees(from: observer, to: position),
                signal: placed.report.urgency == .hazard ? .poor : .good,
                subtitle: placed.report.symbolLabel,
                detail: Self.objectDetail(placed, observer: observer, now: now,
                                          inMiles: settings.distanceUnitIsMiles),
                isStale: now.timeIntervalSince(placed.heard) > HeardStationMap.activeWindow,
                aprsSymbol: APRSMapSymbol(table: placed.report.symbolTable,
                                          code: placed.report.symbolCode),
                supportsConnect: false,
                supportsAPRSContact: false)
        }
    }

    static func objectSiteID(_ key: String) -> String { "object:" + key }

    /// What the card says about an object. Attribution first: an object is a
    /// claim by a person, and who made it is the first thing that decides
    /// how much weight it carries.
    static func objectDetail(_ placed: APRSObjectStore.Placed,
                             observer: GreatCircle.Point, now: Date,
                             inMiles: Bool) -> String {
        var lines = [placed.report.name]
        lines.append(placed.report.symbolLabel
                     + (placed.report.kind == .item ? " \u{b7} item" : " \u{b7} object"))
        if !placed.report.comment.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(placed.report.comment.trimmingCharacters(in: .whitespaces))
        }
        let kilometres = GreatCircle.kilometres(from: observer, to: placed.position)
        let bearing = GreatCircle.bearingDegrees(from: observer, to: placed.position)
        lines.append(String(format: "%@ at %.0f\u{00b0} (%@)",
                            DistanceDisplay.string(kilometres: kilometres, inMiles: inMiles),
                            bearing, GreatCircle.compassPoint(bearing)))
        lines.append("")
        lines.append("Reported by \(placed.reportedBy)")
        lines.append("Heard \(placed.heard.formatted(.relative(presentation: .named)))"
                     + (placed.timesHeard > 1 ? " \u{b7} repeated \(placed.timesHeard) times" : ""))
        if placed.timesHeard == 1 {
            lines.append("Heard once and not repeated \u{2014} treat as unconfirmed.")
        }
        return lines.joined(separator: "\n")
    }

    /// The same positions the scope uses, fanned so stations sharing a
    /// grid square are individually pickable. Computed by the model so
    /// the map and the scope can never disagree about where a marker is.
    private var coordinates: [String: GreatCircle.Point] {
        var result = HeardStationMap.fannedPositions(placed)
        // Objects are sites too. Without their coordinates here both renderers
        // silently drop them — the scope listed a fire and the map drew
        // nothing, which is the worst possible way for this layer to fail.
        guard showsObjects else { return result }
        for placed in objects.live() {
            result[Self.objectSiteID(placed.report.key)] = placed.position
        }
        return result
    }

    /// The APRS symbol each heard station beaconed, keyed by the same id its
    /// marker carries (the uppercased callsign). Only stations that are
    /// actually placed on the map are included; a symbol with nowhere to sit
    /// is nothing to draw.
    private var aprsSymbols: [String: APRSMapSymbol] {
        // Only stations actually placed at their transmitted APRS fix wear
        // their symbol. When the operator is showing licence points, or a
        // station happens to be placed by a lookup, it is a plain dot — the
        // symbol must not imply a live position the marker is not showing.
        let aprsPlaced = Set(placed.filter { $0.origin == .transmittedAPRS }.map(\.id))
        var result: [String: APRSMapSymbol] = [:]
        for station in stations {
            guard let aprs = station.aprs else { continue }
            let id = station.call.uppercased()
            guard aprsPlaced.contains(id) else { continue }
            result[id] = APRSMapSymbol(table: aprs.symbolTable, code: aprs.symbolCode)
        }
        return result
    }

    /// Movement trails from the fixes stations beaconed, keyed by callsign.
    ///
    /// Three separate complaints, one answer. Every rover's trail drawn at
    /// once buried the map; a trail with no label could not be matched to the
    /// station that made it; and an unbounded trail showed where something was
    /// this morning as though it mattered now.
    ///
    /// So trails follow the **selection** by default. One trail, belonging to
    /// the station whose card is open, needs no legend to identify it and adds
    /// no noise. Showing every trail is still a switch away for when the whole
    /// picture is the point, and either way the trail is cut to a time window
    /// the operator sets.
    private var tracks: [MapTrack] {
        guard showsTracks else { return [] }
        return MapTrack.trails(
            stations: stations,
            placedIDs: Set(placed.filter { $0.origin == .transmittedAPRS }.map(\.id)),
            selection: selection,
            showsAll: showsAllTracks,
            windowMinutes: trackWindowMinutes)
    }


    var body: some View {
        VStack(spacing: 0) {
            // The Mac has a control row above the map. iOS has a navigation
            // bar, and that is where its controls go — see `mapToolbar`.
            #if os(macOS)
            header
            Divider()
            #endif
            if observer == nil {
                noPosition
            } else {
                // Above every other banner: a hazard or a live warning is the
                // reason someone opens this page in an emergency, and it must
                // not sit below a note about callsign lookups.
                emergencyBanner
                if showsUnplacedBanner { unplacedBanner }
                if hidesDistantStations, !distantStations.isEmpty { distantBanner }
                // A draggable split is a Mac affordance. On a touch screen
                // the list is a sheet over the map — the way Maps shows its
                // results — so the map keeps the whole screen instead of
                // being squeezed by a pane the operator cannot resize.
                #if os(macOS)
                if showsList {
                    HSplitView {
                        mapPane
                            .frame(minWidth: 380)
                        stationList
                            .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
                    }
                } else {
                    mapPane
                }
                #else
                mapPane
                #endif
            }
        }
        .sheet(isPresented: $showingCapture) { captureSheet }
        .sheet(isPresented: $showingChannelReport) {
            // Named apart from the state it reads. Shadowing it with an
            // `if let` of the same name inside a closure that also captures it
            // crashes the type checker outright (Xcode 26, TypeCheckDecl.cpp
            // assertion), rather than diagnosing anything.
            if let report = latestChannelReport {
                APRSChannelPathView(report: report,
                                    onRefresh: { latestChannelReport = channelReport?() })
            }
        }
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
        #if os(iOS)
        .toolbar { mapToolbar }
        .sheet(isPresented: $showingStationList) { stationListSheet }
        // Picking a row is the end of the errand: the sheet goes and the
        // map shows the selection card where the sheet was.
        .onChange(of: selection) { _, picked in
            if picked != nil { showingStationList = false }
        }
        #endif
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
        // The sidebar owns the layer toggles, but the captions and the
        // terrain gate come from caches only this view has. Pushed on a
        // change to cheap inputs — counts and flags — so the expensive
        // captions are built when something moves rather than on every
        // sidebar render.
        .task(id: layerStatusKey) { publishLayerStatus() }
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
            // The node layer's operators too, when it is on. This is a read
            // of this app's own cache, not a fetch — the bulk-fetch rule the
            // layer obeys is about other people's servers. Without it the
            // layer could only draw what some *other* screen had happened to
            // ask about, which at launch is nothing.
            if showsDirectoryNodes {
                wanted += HeardStationMap.directoryOperatorCallsigns(
                    aliases: aliases.directory)
            }
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
            showsDirectory: showsDirectoryNodes,
            directorySize: aliases.directory.allEntries.count,
            callsigns: Set(stations.map(\.call)).sorted())
    }

    private struct PositionPreloadKey: Hashable {
        let networkEnabled: Bool
        /// Turning the layer on has to fetch its operators out of the cache,
        /// or it draws nothing until the heard list next changes.
        let showsDirectory: Bool
        /// New aliases bring new operators to place.
        let directorySize: Int
        let callsigns: [String]
    }

    // MARK: - Header

    /// Hit target for the header's icon-only controls.
    ///
    /// A glyph is about 17pt; the tappable area around it is grown to a
    /// comfortable pointer target without the icon itself changing size.
    /// Mac only — on iOS these controls are navigation-bar items, which the
    /// system already sizes for a finger.
    private let iconHitTarget: CGFloat = 24

    #if os(macOS)
    /// The map's control row.
    ///
    /// A Mac window is wide enough for every control at once. iOS is not —
    /// on an iPhone this row ran to more than 402 points and on an iPad it
    /// ran off the right edge of the screen — so there the same controls
    /// are navigation-bar items and menus instead (`mapToolbar`).
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Stations Heard").font(.headline)
                Text(coverageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            probeMenu

            if modeRaw == "Map" {
                MapBasemapPicker(
                    basemap: Binding(get: { basemap }, set: { basemapRaw = $0.rawValue }),
                    includesOffline: offlineTiles.hasStoredTiles,
                    title: "Style") {
                        terrainMenuSection
                    }

                MapOverlayControl(store: overlayStore,
                                  markCoordinate: observer?.clCoordinate,
                                  onSendViaWinlink: onSendLayer)
            }
            Picker("", selection: $modeRaw) {
                Text("Map").tag("Map")
                Text("Scope").tag("Scope")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Map draws real geography and needs tiles, which need the network. Scope plots bearing and range from positions already cached, and keeps working with everything else down.")
            // The layer toggles live in the sidebar's Layers section and
            // there is deliberately no second copy here.

            // Everything that is an errand rather than a setting. These were
            // seven separate controls in this row, two of them bare icons
            // sitting side by side that read as one control duplicated.
            Menu {
                mapActionsMenuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .iconHitTarget(iconHitTarget)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Offline data, the station directory, and retrying callsign lookups.")

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
    }

    /// Terrain shading, as a section of the Style menu.
    ///
    /// Basemap and terrain both answer "how is the ground drawn", so they are
    /// one button. Kept a `@ViewBuilder` section rather than folded into the
    /// basemap list because terrain is a separate axis: satellite with
    /// hillshade is a real combination, and a single list of options could
    /// not express it.
    @ViewBuilder
    private var terrainMenuSection: some View {
        Divider()
        Picker("Terrain", selection: $terrainStyleRaw) {
            Text("No Terrain").tag("")
            ForEach(TerrainShading.Style.allCases) { style in
                Text(style.label).tag(style.rawValue)
            }
        }
        .pickerStyle(.inline)
        .disabled(!elevation.hasTerrain)

        // A menu that says "no data" and stops there leaves the operator to
        // guess which of the other controls fetches it. The way to get
        // terrain belongs where its absence is noticed.
        if elevation.hasTerrain {
            Text("\(elevation.tileCount) terrain tile\(elevation.tileCount == 1 ? "" : "s") stored")
        } else {
            Text("No terrain data yet")
        }
        Button {
            showingOfflineMaps = true
        } label: {
            Label(elevation.hasTerrain
                  ? "Download More Terrain\u{2026}" : "Download Terrain\u{2026}",
                  systemImage: "arrow.down.circle")
        }
    }

    /// The map's errands: offline data, the directory, and the lookup retry.
    ///
    /// Each of these was its own control in the row. They have nothing in
    /// common with each other except that none of them is a setting the
    /// operator changes while reading the map, which is the test for whether
    /// something has earned permanent space.
    @ViewBuilder
    private var mapActionsMenuItems: some View {
        if modeRaw == "Map" {
            // Two different things with two confusable names. "Offline Map"
            // stores real tiles, so the map still pans and zooms with the
            // network down. "Save Map Image" takes a picture of what is on
            // screen. The old label for the second was "Save Offline", and
            // its help text claimed MapKit had no offline-tile API. That was
            // written before the tile store existed and left standing after,
            // so the two buttons contradicted each other about what the app
            // could do.
            Button {
                showingOfflineMaps = true
            } label: {
                Label(offlineTiles.hasStoredTiles
                      ? "Offline Map (\(offlineTiles.statistics.sizeDescription))"
                      : "Offline Map\u{2026}",
                      systemImage: "square.stack.3d.down.right")
            }
            .help("Stores map tiles on this device so the map keeps working with no network \u{2014} the situation this app exists for. Import a file or download the area you are looking at.")
            Button {
                drawing.begin(.download)
            } label: {
                Label("Draw an Area to Download\u{2026}", systemImage: "square.dashed")
            }
            Button {
                captureName = defaultCaptureName
                showingCapture = true
            } label: {
                Label("Save Map Image\u{2026}", systemImage: "photo")
            }
            .help("Takes a picture of the area now on screen and saves it as an image file. A picture, not a map: it does not pan or zoom. For a map that still works offline, use Offline Map above.")
            Divider()
        }

        if channelReport != nil {
            Button {
                latestChannelReport = channelReport?()
                showingChannelReport = true
            } label: {
                Label("Channel & Path\u{2026}", systemImage: "chart.bar.doc.horizontal")
            }
            .help("How busy the channel is and whether your beacon path suits it. Measured from what has actually been heard, with the workings shown.")
        }

        if serviceStore != nil {
            Button {
                showingDirectory = true
            } label: {
                Label("Station Directory\u{2026}", systemImage: "text.book.closed")
            }
            .help("What the stations around here run \u{2014} nodes, bulletin boards, digipeaters and gateways, as they announced themselves in ID and beacon frames. The network's own directory, which nothing else assembles because nobody publishes one.")
        }

        // Kept, against the first instinct to delete it as redundant.
        // Lookups do run on their own as stations are heard, so the button is
        // not how positions normally arrive. It is still the only way to
        // retry the ones that failed, which is what you want after the network
        // comes back, and the only way to fill the directory layer in batches.
        // Redundant in the ordinary case is not the same as redundant.
        if !unplaced.isEmpty || showsDirectoryNodes {
            Divider()
            Button {
                Task { await lookUpUnplaced() }
            } label: {
                Label(isLookingUp ? "Finding Positions\u{2026}" : "Retry Position Lookups",
                      systemImage: "mappin.and.ellipse")
            }
            .disabled(isLookingUp || !settings.callsignLookupEnabled)
            .help(findPositionsHelp)
        }
    }
    #endif

    /// The APRS general queries: one unaddressed transmission that the whole
    /// channel answers on its own.
    ///
    /// Named "Ask the Channel" because that is what it does. "Who can hear me"
    /// described only one of these questions — the position flood — and this
    /// menu also asks for weather, status and objects, which are not about
    /// hearing at all.
    ///
    /// Deliberately **not** disabled while a previous query is still
    /// listening. Asking a second question during the reply window is a normal
    /// thing to want, the results fold into the same list either way, and a
    /// control that greys out for two minutes after every use reads as broken.
    /// Starting a new query supersedes the old one, and there is an explicit
    /// way to stop.
    ///
    /// Its own property because the Mac header is one long expression and the
    /// type checker gives up when it grows.
    @ViewBuilder
    private var probeMenu: some View {
        Menu {
            Section("Ask every station for") {
                ForEach(APRSGeneralQuery.allCases) { query in
                    Button {
                        probe.start(query: query, scope: probe.scope, reach: probeReach)
                    } label: {
                        Label(query.label, systemImage: query.systemImage)
                    }
                    .help(query.help)
                }
            }
            Section("Ask") {
                Picker("", selection: Binding(
                    get: { probeReach },
                    set: { probeReachRaw = $0.rawValue })) {
                    ForEach(APRSProbeReach.allCases) { reach in
                        Text(reach.label).tag(reach)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }
            Section("Show replies from") {
                Picker("", selection: Binding(
                    get: { probe.scope },
                    set: { probe.scope = $0 })) {
                    ForEach(APRSProbeScope.allCases) { scope in
                        Text(Self.probeLabel(scope)).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }
            // The other half of a shared channel, and the reason this menu is
            // not called "Ask": announcing our own position is the same act
            // from the other side, and an operator looking at the map is
            // exactly the operator who wants to send one. It was reachable
            // only from Settings > Radios before.
            if let onBeacon {
                Section("Tell the channel") {
                    Button {
                        onBeacon()
                    } label: {
                        Label("Beacon my position now", systemImage: "dot.radiowaves.up.forward")
                    }
                    .help("Transmit an APRS position report on every radio whose beacon is on, "
                          + "staggered so two radios on one frequency do not key together. The "
                          + "scheduled beacon carries on unchanged.")
                    // Shown rather than hidden behind a disabled control: a
                    // button that does nothing and will not say why is the
                    // complaint this whole area started with.
                    if let blocked = beaconObstacle?() {
                        Text(blocked)
                    }
                }
            }
            if probe.status == .listening {
                Divider()
                Button(role: .cancel) {
                    probe.cancel()
                } label: {
                    Label("Stop listening", systemImage: "stop.circle")
                }
            }
        } label: {
            Label(probe.status == .listening ? "Listening\u{2026}" : "Ask the Channel",
                  systemImage: "antenna.radiowaves.left.and.right")
        }
        .fixedSize()
        .help("One unaddressed APRS query that every station in earshot answers on its own "
              + "\u{2014} the flood broadcast, not a poll. Forty directed queries would be "
              + "forty transmissions on a shared channel; this is one. Plain AX.25 nodes are "
              + "not listening for these and are never bothered. Replies keep arriving for two "
              + "minutes, and you can ask another question while they do.")
    }

    /// How far the next question is asked. Remembered, because it is a
    /// property of the station's situation — a hilltop and a basement want
    /// different answers — not of one query.
    @AppStorage("aprs.probe.reach") private var probeReachRaw: String = APRSProbeReach.direct.rawValue

    private var probeReach: APRSProbeReach {
        APRSProbeReach(rawValue: probeReachRaw) ?? .direct
    }

    /// Wording for a probe scope on the map, where "Infrastructure" and
    /// "Moving" need to say what they mean without the surrounding page.
    static func probeLabel(_ scope: APRSProbeScope) -> String {
        switch scope {
        case .all: return "Every station"
        case .infrastructure: return "Digipeaters & gateways"
        case .moving: return "Vehicles & trackers"
        }
    }

    #if os(iOS)
    // MARK: - iOS controls

    /// The station list, as a sheet. A separate flag from `showsList`, which
    /// is the Mac's remembered pane: a sheet that re-presented itself on
    /// every launch would be a modal the operator did not ask for.
    @State private var showingStationList = false
    /// What the boundaries submenu is in the middle of — see
    /// `MapOverlayInteraction`. The rows live in a menu and cannot present
    /// anything themselves; `mapWithDrawing` attaches the presentations.
    @StateObject private var overlayInteraction = MapOverlayInteraction()

    /// The map's controls, as navigation-bar items.
    ///
    /// Three glyphs: the station list, what the map draws, and what can be
    /// done to it. Everything the Mac's control row spells out in words is
    /// behind one of these — the platform idiom for a screen whose content
    /// is the whole screen, and the only shape that fits an iPhone's bar.
    /// On an iPad the same three sit at the trailing end of the tab bar.
    @ToolbarContentBuilder
    private var mapToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showingStationList = true
            } label: {
                Label("Stations", systemImage: "list.bullet")
            }
            .accessibilityHint("Every station heard, with or without a position")

            Menu {
                layersMenu
            } label: {
                Label("Layers", systemImage: "square.3.layers.3d")
            }
            .accessibilityHint("Basemap, terrain, and which layers the map draws")

            Menu {
                actionsMenu
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    /// What the map draws: view, basemap, terrain, layers, boundaries.
    ///
    /// Pickers rather than inline rows, so each shows its current value on
    /// one line and opens to the choices — the menu stays short enough to
    /// read at a glance on a phone.
    @ViewBuilder
    private var layersMenu: some View {
        Picker("View", selection: $modeRaw) {
            Label("Map", systemImage: "map").tag("Map")
            Label("Scope", systemImage: "scope").tag("Scope")
        }
        .pickerStyle(.menu)

        if modeRaw == "Map" {
            Picker("Basemap", selection: $basemapRaw) {
                ForEach(MapBasemap.allCases.filter {
                    $0 != .none && ($0 != .offline || offlineTiles.hasStoredTiles)
                }) { option in
                    Label(option.rawValue, systemImage: option.systemImage)
                        .tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)

            Picker("Terrain", selection: $terrainStyleRaw) {
                Text("None").tag("")
                ForEach(TerrainShading.Style.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.menu)
            .disabled(!elevation.hasTerrain)
            if !elevation.hasTerrain {
                Text("No terrain downloaded")
            }

            Divider()
            Toggle("Observed Paths", isOn: $showsPaths)
            Toggle("Predicted Paths", isOn: $showsPredictedPaths)
                .disabled(!elevation.hasTerrain)
            if showsPredictedPaths, let summary = forecastSummary {
                Text(summary)
            }
            Toggle("Node Directory", isOn: $showsDirectoryNodes)
            if showsDirectoryNodes {
                Text("\(placedDirectoryCount) drawn · \(mergedNodeBoxCount) folded "
                     + "into heard stations · \(aliases.directory.allEntries.count) known")
            }
            Toggle("Coverage Rings", isOn: $showsCoverageRing)
            Toggle("APRS Coverage Rings", isOn: $showsAPRSCoverageRing)

            Divider()
            Menu {
                MapOverlayMenuItems(store: overlayStore, interaction: overlayInteraction,
                                    markCoordinate: observer?.clCoordinate,
                                    onSendViaWinlink: onSendLayer)
            } label: {
                Label(overlayStore.visibleLayers.isEmpty
                      ? "Boundaries"
                      : "Boundaries (\(overlayStore.visibleLayers.count))",
                      systemImage: "square.on.square.dashed")
            }
        }

        if !distantStations.isEmpty {
            Divider()
            Toggle("Hide Distant Stations", isOn: $hidesDistantStations)
            Text("\(distantStations.count) further than "
                 + "\(Int(StationPlausibility.defaultRangeKilometres)) km")
        }
    }

    /// What can be done to the map: lookups, drawing, offline data, and the
    /// station directory.
    @ViewBuilder
    private var actionsMenu: some View {
        #if os(iOS)
        // The Mac places by secondary-clicking a spot. A touch screen has no
        // such gesture — a long press already means something else — and this
        // view does not track the map's centre, so inventing a crosshair here
        // would be guessing at where the operator meant. Our own position is
        // the one point on the map this screen knows exactly, and it is also
        // the field case: you are standing at the aid station when you mark it.
        Button {
            guard let here = observer else { return }
            pendingObject = PendingObject(
                coordinate: CLLocationCoordinate2D(latitude: here.latitude,
                                                   longitude: here.longitude))
        } label: {
            Label("Place Object Here", systemImage: "mappin.and.ellipse")
        }
        .disabled(observer == nil || onPlaceObject == nil)
        if observer == nil {
            Text("No position yet \u{2014} set a grid square or wait for a fix")
        }
        Divider()
        #endif

        if !unplaced.isEmpty || showsDirectoryNodes {
            Button {
                Task { await lookUpUnplaced() }
            } label: {
                Label(isLookingUp ? "Finding Positions\u{2026}" : "Find Positions",
                      systemImage: "mappin.and.ellipse")
            }
            .disabled(isLookingUp || !settings.callsignLookupEnabled)
        }

        probeMenu

        if modeRaw == "Map" {
            // Drawing starts here rather than from a permanent strip over
            // the map. The strip appears once a tool is active.
            Menu {
                ForEach([MapDrawingMode.point, .line, .area]) { mode in
                    Button {
                        drawing.begin(mode)
                    } label: {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                }
            } label: {
                Label("Add to Map", systemImage: "plus")
            }

            Divider()
            Button {
                showingOfflineMaps = true
            } label: {
                Label(offlineTiles.hasStoredTiles
                      ? "Offline Map (\(offlineTiles.statistics.sizeDescription))"
                      : "Offline Map\u{2026}",
                      systemImage: "square.stack.3d.down.right")
            }
            Button {
                drawing.begin(.download)
            } label: {
                Label("Draw an Area to Download\u{2026}", systemImage: "square.dashed")
            }
            Button {
                captureName = defaultCaptureName
                showingCapture = true
            } label: {
                Label("Save Map for Offline Use\u{2026}", systemImage: "square.and.arrow.down")
            }
        }

        if serviceStore != nil {
            Divider()
            Button {
                showingDirectory = true
            } label: {
                Label("Station Directory", systemImage: "text.book.closed")
            }
        }
    }

    /// The station list as a sheet, half-height by default so the map stays
    /// in view above it, the way Maps shows a result list.
    private var stationListSheet: some View {
        NavigationStack {
            stationList
                .navigationTitle("Stations Heard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingStationList = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    /// The coverage summary the Mac's header states in words, as a chip on
    /// the map — shown only while there is something to say. "All placed"
    /// is the map itself; "3 of 20" is a fact the map cannot show, and the
    /// chip opens the list where the missing three are named.
    @ViewBuilder
    private var coverageChip: some View {
        if !unplaced.isEmpty, !showsUnplacedBanner, !drawing.isDrawing {
            Button {
                showingStationList = true
            } label: {
                Label("\(placed.count) of \(entries.count) placed",
                      systemImage: "mappin.slash")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.primary.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }
    #endif

    /// Live hazards and current NWS warnings, across the top of the map.
    ///
    /// Deliberately loud and deliberately narrow: only objects whose symbol
    /// says something is wrong, and only alerts still being repeated. A banner
    /// that appears for ordinary traffic is one an operator learns to ignore,
    /// which is exactly the failure that matters here.
    @ViewBuilder
    private var emergencyBanner: some View {
        let hazards = objects.hazards()
        let warnings = alerts.current().filter { $0.severity == .warning }
        if showsObjects, !hazards.isEmpty || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(warnings, id: \.identifier) { alert in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.text).font(.caption.weight(.semibold))
                            Text(alert.provenance())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
                ForEach(hazards) { hazard in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(hazard.report.name) \u{b7} \(hazard.report.symbolLabel)")
                                .font(.caption.weight(.semibold))
                            Text("Reported by \(hazard.reportedBy), heard "
                                 + hazard.heard.formatted(.relative(presentation: .named))
                                 + (hazard.timesHeard == 1 ? " \u{2014} unconfirmed" : ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .onTapGesture { selection = Self.objectSiteID(hazard.report.key) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
    }

    /// Whether the "no position" banner is up, so nothing else says the
    /// same thing at the same time.
    private var showsUnplacedBanner: Bool {
        !unplaced.isEmpty
            && !settings.callsignLookupEnabled
            && HeardStationMap.lookupCandidates(unplaced, aliases: aliases.directory).count > 0
    }

    /// Says plainly how much of what was heard could be placed. A map
    /// showing 12 dots when 23 stations were heard is misleading unless
    /// it says so.
    private var coverageSummary: String {
        guard !entries.isEmpty else { return "Nothing heard yet" }
        // How many dots are the station's own beaconed fix versus a lookup
        // about the callsign, so the operator can trust the map at a glance
        // rather than clicking each dot to read its source.
        let beaconed = placed.filter { $0.origin == .transmittedAPRS }.count
        let addressPlaced = placed.count - beaconed
        // In transmitted mode the address-placed heard stations are hidden, so
        // say so rather than counting points that are not on the map.
        if prefersTransmittedPosition {
            let hidden = placed.filter {
                !$0.isNodeAlias && $0.origin != .transmittedAPRS && isOnAPRSChannel($0)
            }.count
            let tail = hidden > 0 ? " \u{b7} \(hidden) address-only hidden" : ""
            return "\(beaconed) from beacons\(tail)"
        }
        let suffix = beaconed > 0
            ? " \u{b7} \(beaconed) from beacons, \(addressPlaced) from address"
            : (placed.isEmpty ? "" : " \u{b7} all from address lookups")
        if unplaced.isEmpty {
            return "\(placed.count) station\(placed.count == 1 ? "" : "s"), all placed\(suffix)"
        }
        return "\(placed.count) of \(entries.count) placed \u{2014} \(unplaced.count) with no known position\(suffix)"
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
                StationScopeView(scope: scope, selection: $selection, legend: .recency,
                                 distanceInMiles: settings.distanceUnitIsMiles)
            }
        }
    }

    /// Whether the traffic strip is open. Remembered, because an operator who
    /// wants to watch the channel wants to watch it every time.
    @AppStorage("map.traffic.expanded") private var trafficExpanded = false

    /// The live traffic strip, when the app supplied a feed.
    @ViewBuilder
    private var trafficChin: some View {
        if let traffic {
            MapTrafficChin(feed: traffic, radios: trafficRadios,
                           isExpanded: $trafficExpanded) { call in
                selection = call
            }
        }
    }

    private func mapWithDrawing(observer: GreatCircle.Point) -> some View {
        VStack(spacing: 0) {
            mapStack(observer: observer)
            // Below the map, not over it: the map's own bottom-corner
            // overlays (the legend, the selection card) keep their space.
            trafficChin
        }
        .textEntryPrompt($drawPrompt)
    }

    private func mapStack(observer: GreatCircle.Point) -> some View {
        ZStack(alignment: .top) {
            StationMapView(scope: scope, distanceInMiles: settings.distanceUnitIsMiles,
                           observer: observer,
                               coordinates: coordinates,
                               observerCallsign: myCallsign,
                               basemap: basemap, legend: .recency,
                               pathLinks: pathLinks,
                               aprsSymbols: aprsSymbols,
                               ownAPRSSymbol: ownAPRSSymbol,
                               tracks: tracks,
                               terrainOverlays: terrainOverlays,
                               weatherFieldOverlays: weatherFieldOverlays,
                               layerGeneration: layerGeneration,
                               clustersStations: clustersStations,
                               tileStore: offlineTiles.hasStoredTiles ? offlineTiles.store : nil,
                               tileSource: offlineTiles.storedSource,
                               overlays: overlayStore.visibleLayers,
                               drawing: $drawing,
                               onDrawTap: handleDrawTap,
                               onSecondaryClick: { coordinate in
                                   // Only where placing is possible at all.
                                   guard onPlaceObject != nil else { return }
                                   pendingObject = PendingObject(coordinate: coordinate,
                                                                 moving: movingObject)
                                   movingObject = nil
                               },
                               draggableSiteIDs: draggableSiteIDs,
                               onObjectDragged: { siteID, coordinate in
                                   // The drop stages a move and nothing more.
                                   guard let placed = ourObject(siteID: siteID) else { return }
                                   pendingObject = PendingObject(coordinate: coordinate,
                                                                 moving: placed)
                                   movingObject = nil
                               },
                               coverageRings: coverageRings,
                               selection: $selection)
            .overlay(alignment: .bottomTrailing) { selectionCard }
            .sheet(item: $pendingObject) { pending in
                APRSPlaceObjectSheet(
                    coordinate: pending.coordinate,
                    liveObjects: objects.live(),
                    ourAddresses: ownCallsigns,
                    moving: pending.moving,
                    distanceInMiles: settings.distanceUnitIsMiles,
                    onTransmit: { name, table, code, comment in
                        onPlaceObject?(name, true,
                                       pending.coordinate.latitude,
                                       pending.coordinate.longitude,
                                       table, code, comment)
                    },
                    onCancel: { pendingObject = nil })
            }
            .sheet(item: $askTarget) { target in
                APRSAskStationSheet(
                    callsign: target.callsign,
                    subtitle: askSubtitle(target.callsign),
                    ping: pingState?(target.callsign),
                    onSend: { onQuery?($0) })
            }
            #if os(iOS)
            .overlay(alignment: .topLeading) { coverageChip }
            .modifier(MapOverlayPresentation(store: overlayStore, interaction: overlayInteraction))
            #endif

            MapDrawingToolbar(session: $drawing, onComplete: finishShape,
                              showsModePicker: showsDrawingModePicker)
                .padding(.top, 8)

            // Last in the stack, so it draws over the drawing strip rather
            // than under it — where it was invisible, which made Move look
            // like a button that did nothing. Armed state has to be visible
            // and escapable: a mode you cannot see is a mode you cancel by
            // clicking something else, and here clicking something else
            // transmits.
            movingBanner
                .padding(.top, 52)
        }
    }

    /// The Mac keeps the drawing tools in view; a touch screen starts them
    /// from the More menu and shows the strip only while one is active.
    private var showsDrawingModePicker: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var selectionCardIsFullWidth: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    /// The station line the Ask sheet shows under the callsign — the same
    /// detail the card is already showing, so the dialog does not open with
    /// less context than the card it came from.
    private func askSubtitle(_ callsign: String) -> String? {
        scope.sites.first { $0.id == callsign }?.detail
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
                // A weather station's readings, laid out rather than printed.
                // Below the identity lines, because you look up which station
                // this is before you read what its sensors say.
                if let weather = site.weather {
                    Divider().padding(.vertical, 1)
                    APRSWeatherSummaryView(
                        weather: weather, heard: site.weatherHeard,
                        history: site.weatherHistory,
                        inImperial: settings.distanceUnitIsMiles)
                }
                // Whatever else this station measures. Rare, and the entire
                // reason to look at the station when it is there: a creek
                // gauge and a battery bank both arrive this way.
                if !site.telemetry.isEmpty {
                    Divider().padding(.vertical, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.telemetryTitle ?? "Telemetry")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(site.telemetry, id: \.channel) { reading in
                            HStack(spacing: 4) {
                                Text(reading.name ?? "Channel \(reading.channel + 1)")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(reading.text)
                                    .monospacedDigit()
                                    .foregroundStyle(reading.isCalibrated ? .primary : .secondary)
                            }
                            .font(.caption)
                        }
                    }
                    .help("Sent by the station itself. A value marked (raw) is the count as "
                          + "transmitted \u{2014} the station has not published the equation "
                          + "that turns it into a measurement, so AXTerm will not guess one.")
                }
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
                // Wrapping, and only the actions that can actually reach this
                // site. Four fixed-width buttons in an HStack ran off the edge
                // of the card and lost their labels.
                FlowingButtons {
                    if let onConnect, site.supportsConnect {
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
                    if let onMessage, site.supportsAPRSContact {
                        Button {
                            onMessage(site.id)
                        } label: {
                            Label("Message", systemImage: "message")
                        }
                        .controlSize(.small)
                        .help("Send \(site.label) an APRS text message.")
                    }
                    // Standing down an object we placed. Offered only for
                    // our own: APRS honours a kill from anyone, which is
                    // exactly why the button is withheld — an operator who
                    // can stand down another agency's road closure with one
                    // click will eventually do it by accident.
                    if let placed = ourObject(siteID: site.id), onPlaceObject != nil {
                        // APRS has no move: re-sending under a name we already
                        // own is the move, which is why `problem` treats our
                        // own name as no collision. Dragging the marker does
                        // the same thing and is what people reach for first;
                        // this button is the discoverable path to it, and the
                        // precise one when the marker is under a cluster.
                        #if os(macOS)
                        // Armed state is shown on the card as well as in the
                        // banner. The card is what the operator is already
                        // looking at, and a button that appears to do nothing
                        // is worse than no button.
                        if movingObject?.report.key == placed.report.key {
                            Text("Drag it, or secondary-click the new spot")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Cancel") { movingObject = nil }
                                .controlSize(.small)
                        } else {
                            Button {
                                movingObject = placed
                            } label: {
                                Label("Move\u{2026}",
                                      systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                            }
                            .controlSize(.small)
                            .help("Drag \u{201C}\(placed.report.name)\u{201D} to the new spot, or"
                                  + " secondary-click it. Either way you confirm before it goes out,"
                                  + " and it moves on every station that hears it.")
                        }
                        #else
                        // No secondary click to arm, so nothing to arm: the
                        // move goes to where the operator is standing, which
                        // is the reason to move one from a phone.
                        Button {
                            guard let here = observer else { return }
                            pendingObject = PendingObject(
                                coordinate: CLLocationCoordinate2D(latitude: here.latitude,
                                                                   longitude: here.longitude),
                                moving: placed)
                        } label: {
                            Label("Move Here", systemImage: "mappin.and.ellipse")
                        }
                        .controlSize(.small)
                        .disabled(observer == nil)
                        #endif
                    }
                    if let placed = ourObject(siteID: site.id), let onPlaceObject {
                        Button(role: .destructive) {
                            _ = onPlaceObject(placed.report.name, false,
                                              placed.report.latitude, placed.report.longitude,
                                              placed.report.symbolTable, placed.report.symbolCode,
                                              "")
                        } label: {
                            Label("Stand Down", systemImage: "xmark.circle")
                        }
                        .controlSize(.small)
                        .help(APRSObjectPlacement.removalExplanation(placed))
                    }
                    if let onQuery, site.supportsAPRSContact {
                        // The operator's standing preference, overridden only
                        // where the evidence contradicts it — and never
                        // silently: the label, the help and a line in the menu
                        // all say which reach is about to be used and why.
                        let advice = reachAdvice?(site.id) ?? .inEarshot
                        let reach = advice.suggestedReach ?? askReach
                        // Built here rather than inline: the concatenation
                        // below defeated the type checker as one expression.
                        let pingHelp = Self.pingHelp(label: site.label, reach: reach,
                                                     advice: advice, selected: askReach)
                        // A split button: the click most operators want stays
                        // one click, and the other six queries are one more.
                        // Burying ?APRSP in a menu would slow the commonest
                        // action down to serve the rarer ones.
                        Menu {
                            Section("Ask for") {
                                ForEach(APRSDirectedQuery.allCases) { query in
                                    Button {
                                        onQuery(APRSStationQuery(
                                            callsign: site.id, kind: query, reach: reach))
                                    } label: {
                                        Label(query.label, systemImage: query.systemImage)
                                    }
                                    .help(query.help)
                                }
                            }
                            Divider()
                            // How far a directed query travels, chosen where
                            // it is sent. It was only ever settable inside
                            // "Ask…", and the quick Ping then silently used
                            // whatever that had last been left at — so an
                            // operator who wanted one station asked over the
                            // digipeaters had no way to say so from here, and
                            // no way to see which they were about to get.
                            if let caution = advice.caution {
                                Section { Text(caution) }
                            }
                            Picker("Reach", selection: Binding(
                                get: { askReach },
                                set: { askReachRaw = $0.rawValue })) {
                                ForEach(APRSProbeReach.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .pickerStyle(.inline)
                            Divider()
                            Button {
                                askTarget = AskTarget(callsign: site.id)
                            } label: {
                                Label("Ask\u{2026}", systemImage: "questionmark.bubble")
                            }
                            .help("Pick a query, see what each one actually replies with, and "
                                  + "choose how far it travels.")
                        } label: {
                            Label("Ping", systemImage: reach == .wide
                                  ? "dot.radiowaves.forward"
                                  : "dot.radiowaves.left.and.right")
                        } primaryAction: {
                            onQuery(APRSStationQuery(
                                callsign: site.id, kind: .position, reach: reach))
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help(pingHelp)
                    }
                }
                if let ping = pingState?(site.id) {
                    pingRow(ping)
                }
                if let at = repeatsUs?(site.id) {
                    repeatsRow(at)
                }
            }
            .padding(12)
            // A card on a phone is the width of the screen, the way a place
            // card is; on anything wider it floats at the corner.
            .frame(maxWidth: selectionCardIsFullWidth ? .infinity : 300, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .padding(12)
            .transition(.opacity)
        }
    }

    /// What became of the ping, in one line.
    ///
    /// A ping used to end at the transmission: one frame went out and the
    /// operator watched a channel with no way to tell an answer from the next
    /// beacon. The distinction between *answered* and *replied* is the whole
    /// point — a station that addressed us has proved it heard us, while a
    /// station that merely transmitted has proved nothing unless its own
    /// cadence makes the timing improbable.
    @ViewBuilder
    private func pingRow(_ ping: APRSPingTracker.Ping) -> some View {
        HStack(spacing: 6) {
            Image(systemName: APRSPingPresentation.icon(ping))
                .foregroundStyle(APRSPingPresentation.tint(ping))
            Text(APRSPingPresentation.line(ping))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(APRSPingPresentation.help(ping))
    }

    /// "It hears us", stated as a fact rather than as the absence of one.
    ///
    /// A digipeat is the strongest reception evidence APRS offers short of a
    /// message: the station received our frame and put it back on the air. It
    /// is shown whether or not a ping is outstanding, because it is what the
    /// operator wants to know and a silent ping does not disprove it.
    private func repeatsRow(_ at: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.green)
            Text("Repeats our traffic \u{00B7} \(at.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("This station has put one of our own frames back on the air, so it receives us "
              + "\u{2014} whatever it does about queries. Only a query sent through a "
              + "digipeater path can produce this evidence; a direct one has no path to repeat.")
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
            now: Date(),
            distanceInMiles: settings.distanceUnitIsMiles))
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
