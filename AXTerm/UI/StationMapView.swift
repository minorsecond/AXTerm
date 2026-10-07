import SwiftUI
#if os(iOS)
import UIKit
#endif
import MapKit

/// A real geographic map of stations around this one.
///
/// Reusable alongside `StationScopeView` and driven by the same
/// `StationScope` model, so anything that can build a scope gets both
/// renderings. They answer different questions: the map shows *where*
/// against terrain and roads, the scope shows *bearing and range* and
/// keeps working when there is no network to fetch tiles.
struct StationMapView: View {

    let scope: StationScope
    /// Distances read in the operator's unit; miles when unset.
    var distanceInMiles: Bool = true
    /// Needed to place markers — the scope model carries range and
    /// bearing, but a map wants coordinates.
    let observer: GreatCircle.Point
    /// False when `observer` is only where the map is centered, because this
    /// station has no position: then there is no pin of our own to draw.
    var showsObserver: Bool = true
    let coordinates: [String: GreatCircle.Point]
    /// The operator's own callsign, for the center marker. A grid
    /// reference is not what someone looking for themselves scans for.
    var observerCallsign: String = ""
    var basemap: MapBasemap = .standard
    var legend: MapLegend.Kind = .recency
    /// Observed paths between stations. Empty draws nothing, so a map with no
    /// topology yet looks exactly as it did.
    var pathLinks: [MapPathLink] = []
    /// APRS symbols to draw over station dots, keyed by site id. Empty leaves
    /// the dots plain.
    var aprsSymbols: [String: APRSMapSymbol] = [:]
    /// Our own APRS symbol, drawn on the observer marker when the map is
    /// scoped to a radio that beacons an APRS position. Nil draws the plain
    /// home arrow.
    var ownAPRSSymbol: APRSMapSymbol? = nil
    /// Movement trails, one per station that has beaconed more than one fix.
    var tracks: [MapTrack] = []
    /// Shaded elevation, drawn under the network. Non-empty forces the
    /// MKMapView path, which is the only one that can host an overlay.
    var terrainOverlays: [ElevationOverlay] = []
    /// The inferred temperature wash. Non-empty forces the MKMapView path,
    /// which is the only one that can host an overlay.
    var weatherFieldOverlays: [WeatherFieldOverlay] = []
    /// Fingerprint of the layer switches, so a deliberate change skips the
    /// annotation throttle.
    var layerGeneration: String = ""
    /// Whether ordinary stations fold together when zoomed out.
    var clustersStations: Bool = true
    /// Stored tiles and the provider they came from. Nil means offline mode
    /// is unavailable — the picker hides it rather than offering a basemap
    /// that would draw nothing.
    var tileStore: MapTileStore?
    var tileSource: MapTileSource = .imported
    /// Boundaries and other vector data drawn over the basemap.
    var overlays: [MapOverlayLayer] = []
    /// In-progress drawing. Non-nil switches the map to the MKMapView path,
    /// which is the only one that can host overlays and intercept taps.
    var drawing: Binding<MapDrawingSession>?
    var onDrawTap: (CLLocationCoordinate2D) -> Void = { _ in }
    /// Secondary click on open map — see `OfflineBasemapMapView`.
    var onSecondaryClick: (CLLocationCoordinate2D) -> Void = { _ in }
    var draggableSiteIDs: Set<String> = []
    var onObjectDragged: ((String, CLLocationCoordinate2D) -> Void)?

    /// Measured coverage around the observer, an inner and outer ring per
    /// entry. Empty draws nothing: no evidence, no ring.
    var coverageRings: [CoverageEstimate.Ring] = []
    @Binding var selection: String?
    /// The legend, the coverage chips and the "show me" button. Car mode
    /// leaves them out (`CarMode`).
    var showsChrome: Bool = true
    /// Following the station (`MapFollow`): the "show me" button's state.
    var followMode: Binding<MapFollow.Mode> = .constant(.free)
    /// Where the station is now, unrounded, and which way and how fast it
    /// moves, for the follow camera. Nil follows `observer`.
    var followPoint: GreatCircle.Point? = nil
    var followCourse: Double? = nil
    var followSpeed: Double? = nil

    private var hasNodeSites: Bool { scope.sites.contains(where: \.isNode) }

    private var observerLabel: String {
        observerCallsign.isEmpty ? scope.observerLabel : observerCallsign.uppercased()
    }

    @State private var camera: MapCameraPosition = .automatic
    /// The heading the follow camera last used, kept while the station
    /// stands still and its course means nothing.
    @State private var lastFollowHeading: Double = 0

    private var followCamera: MapFollow.Camera? {
        guard showsObserver else { return nil }
        return MapFollow.camera(mode: followMode.wrappedValue, at: followPoint ?? observer,
                                courseDegrees: followCourse, speedMetersPerSecond: followSpeed,
                                lastHeading: lastFollowHeading)
    }

    private func applyFollow(_ follow: MapFollow.Camera?) {
        guard let follow else { return }
        lastFollowHeading = follow.heading
        withAnimation(.easeInOut(duration: 0.8)) {
            camera = .camera(MapCamera(centerCoordinate: follow.center, distance: follow.distanceMeters,
                                       heading: follow.heading, pitch: follow.pitch))
        }
    }

    /// The "show me" button: follow, then turn with travel, then let go.
    @ViewBuilder
    private var followButton: some View {
        if showsObserver {
            let mode = followMode.wrappedValue
            Button {
                followMode.wrappedValue = mode.next
            } label: {
                Image(systemName: mode == .free ? "location"
                      : mode == .follow ? "location.fill" : "location.north.line.fill")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(mode == .free ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            .help(mode == .free ? "Show your station and follow it."
                  : mode == .follow ? "Turn the map with your direction of travel."
                  : "Stop following and move the map yourself.")
            .accessibilityLabel(mode == .free ? "Show My Location"
                                : mode == .follow ? "Follow With Heading" : "Stop Following")
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }

    /// The coverage chips and, under them, the "show me" button.
    @ViewBuilder
    private var trailingControls: some View {
        if showsChrome {
            VStack(alignment: .trailing, spacing: 0) {
                coverageChip
                followButton
            }
        }
    }

    var body: some View {
        // The MKMapView path whenever there is anything to draw over the
        // basemap or anything to draw *onto* it. SwiftUI's `Map` can host
        // neither a tile overlay nor a vector one, so overlays and drawing
        // would silently do nothing on Apple's basemaps otherwise — which is
        // exactly where an operator would first try them.
        if basemap.isOffline, let tileStore {
            mapKitMap(store: tileStore)
        } else if drawing != nil || !overlays.isEmpty || !terrainOverlays.isEmpty
                    || !weatherFieldOverlays.isEmpty {
            mapKitMap(store: nil)
        } else {
            appleMap
        }
    }

    /// Drawn by an MKMapView: the only path that can host a tile overlay, draw
    /// vector layers, and turn a tap into a vertex. Used for the offline
    /// basemap always, and for Apple's basemaps whenever there are overlays or
    /// drawing in play.
    private func mapKitMap(store: MapTileStore?) -> some View {
        OfflineBasemapMapView(
            scope: scope,
            observer: observer,
            showsObserver: showsObserver,
            coordinates: coordinates,
            observerCallsign: observerLabel,
            store: store,
            source: tileSource,
            basemap: basemap,
            overlays: overlays,
            pathLinks: pathLinks,
            aprsSymbols: aprsSymbols,
            observerSymbol: ownAPRSSymbol,
            tracks: tracks,
            terrainOverlays: terrainOverlays,
            weatherFieldOverlays: weatherFieldOverlays,
            layerGeneration: layerGeneration,
            clustersStations: clustersStations,
            drawing: drawing ?? .constant(MapDrawingSession()),
            onDrawTap: onDrawTap,
            onSecondaryClick: onSecondaryClick,
            draggableSiteIDs: draggableSiteIDs,
            onObjectDragged: onObjectDragged,
            selection: $selection,
            region: openingRegion,
            onRegionChanged: { MapStartRegion.save($0) },
            coverageRings: coverageRings,
            followCamera: followCamera,
            onOperatorMoved: { followMode.wrappedValue = .free },
            observerCourse: followCourse,
            observerSpeed: followSpeed)
        .modifier(MapTopBleed())
        .overlay(alignment: .bottomLeading) {
            if showsChrome, !legendGivesWayToSelection {
                MapLegend(kind: legend, overDarkBasemap: store == nil && basemap.isDark,
                          showsCoverage: !coverageRings.isEmpty,
                          coverageRings: coverageRings,
                          showsNodes: hasNodeSites,
                          showsPositionSource: !aprsSymbols.isEmpty)
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) { trailingControls }
        .overlay(alignment: .bottomTrailing) {
            Text(store == nil ? "" : tileSource.attribution)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
                .help("Required by the map data license. Offline tiles are still someone's work.")
        }
    }

    private var appleMap: some View {
        // Every label was drawn twice: once by the marker view, once by
        // MapKit's own annotation title underneath it. Empty titles and
        // `.annotationTitles(.hidden)` on each annotation suppress the
        // second copy.
        Map(position: $camera, selection: $selection) {
            // Coverage rings under everything: measured footprint, drawn
            // from the stations that answered us direct. Inner ring is
            // the median answered distance, outer the farthest.
            ForEach(Array(coverageRings.enumerated()), id: \.offset) { _, ring in
                let tint = ring.evidence.ringColor
                MapCircle(center: observer.clCoordinate,
                          radius: ring.typicalKm * 1000)
                    .foregroundStyle(tint.opacity(0.08))
                    .stroke(tint.opacity(0.55), lineWidth: 1.5)
                MapCircle(center: observer.clCoordinate,
                          radius: ring.reachKm * 1000)
                    .foregroundStyle(.clear)
                    .stroke(tint.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }

            // Movement trails under the markers: the road a rover drove,
            // drawn in the same recency tint its dot carries.
            ForEach(tracks) { track in
                MapPolyline(coordinates: track.points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(trailColor(for: track.id).opacity(0.7),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            if showsObserver {
                Annotation("", coordinate: observer.clCoordinate, anchor: .center) {
                    observerMarker
                }
                .annotationTitles(.hidden)
                .tag("__observer__")
            }

            ForEach(scope.sites) { site in
                if let position = coordinates[site.id] {
                    Annotation("", coordinate: position.clCoordinate) {
                        marker(for: site)
                    }
                    .annotationTitles(.hidden)
                    .tag(site.id)
                }
            }
        }
        .mapStyle(basemap.mapStyle)
        .mapControls {
            // In heading mode the map turns itself with the travel; a
            // compass there would only invite a tap that is undone at once.
            if followMode.wrappedValue != .heading {
                MapCompass()
            }
            MapScaleView()
            // A zoom stepper is a pointer control. On a touch screen the
            // pinch gesture is the zoom, and a stepper would only take room
            // from the map.
            #if os(macOS)
            MapZoomStepper()
            #endif
        }
        .modifier(MapTopBleed())
        .overlay(alignment: .bottomLeading) {
            if showsChrome, !legendGivesWayToSelection {
                MapLegend(kind: legend, overDarkBasemap: basemap.isDark,
                          showsCoverage: !coverageRings.isEmpty,
                          coverageRings: coverageRings,
                          showsNodes: hasNodeSites,
                          showsPositionSource: !aprsSymbols.isEmpty)
                    .padding(10)
                    // The map ignores the safe area so the terrain runs to
                    // the edges; anything floating on top of it must put the
                    // inset back, or the legend sits on the home indicator.
                    .padding(.bottom, safeAreaBottomInset)
            }
        }
        .overlay(alignment: .topTrailing) { trailingControls }
        .onAppear(perform: frameEverything)
        .onChange(of: scope.sites.count) { _, _ in frameEverything() }
        .onChange(of: followCamera) { _, follow in applyFollow(follow) }
        .onMapCameraChange(frequency: .continuous) { context in mapHeading = context.camera.heading }
        // A pan or pinch of the operator's own lets go of following.
        .onChange(of: camera.positionedByUser) { _, byUser in
            if byUser, followMode.wrappedValue != .free { followMode.wrappedValue = .free }
        }
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Whether the legend steps aside for the selection card.
    ///
    /// On a phone the card is the width of the screen and sits where the
    /// legend does, so the two overlapped and neither could be read. The
    /// legend is the permanent fixture and the card is the errand, so the
    /// legend yields for the moment and is back when the card is dismissed
    /// — the way a place card covers Maps' own controls. Anywhere wider,
    /// both fit and both stay.
    private var legendGivesWayToSelection: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
            && selection != nil && selection != "__observer__"
        #else
        false
        #endif
    }

    /// Bottom safe-area inset, or zero where there is no such thing.
    ///
    /// Read from the window rather than a `GeometryReader`: the legend is an
    /// overlay on a full-bleed map, so a reader would report the map's own
    /// bounds, which is exactly the inset being compensated for.
    private var safeAreaBottomInset: CGFloat {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes
        let window = scenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets.bottom ?? 0
        #else
        return 0
        #endif
    }

    /// The rings' own explanation — a map overlay cannot carry a tooltip,
    /// so the chip does, and states the derivation. Shared by both map
    /// paths so the offline basemap explains itself the same way.
    @ViewBuilder
    private var coverageChip: some View {
        // One chip per ring. With both on the map an unqualified "Coverage"
        // would name two different measurements, so each says which evidence
        // it came from as soon as there is more than one.
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(coverageRings, id: \.legendID) { ring in
                Label(coverageChipText(ring), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .help(ring.summary(inMiles: distanceInMiles))
                    .accessibilityLabel(ring.summary)
            }
        }
        .padding(8)
    }

    private func coverageChipText(_ ring: CoverageEstimate.Ring) -> String {
        let reach = DistanceDisplay.string(kilometres: ring.reachKm, inMiles: distanceInMiles)
        return CoverageRingSelection.chipLabel(for: ring, among: coverageRings) + " ~" + reach
    }

    /// What the camera frames: the observer and the *heard* stations.
    ///
    /// The directory layer must not drive the camera — a harvested node
    /// table legitimately reaches stations half a continent away, and
    /// framing them shrank the operator's own network to a dot cluster
    /// (field capture 2026-08-28 19:36). The nodes stay on the map; the
    /// camera just does not chase them. When only nodes are placed, they
    /// are all there is to frame.
    /// Where to open: the last place the operator looked, then their own
    /// position at a span that suits VHF packet, and only then the framing
    /// that fits everything heard — which on a wide channel is three states.
    private var openingRegion: MKCoordinateRegion? {
        let fit = MapRegionFit.region(covering: framingPoints).map {
            MapStartRegion(latitude: $0.centerLatitude, longitude: $0.centerLongitude,
                           latitudeDelta: $0.latitudeDelta, longitudeDelta: $0.longitudeDelta)
        }
        let start = MapStartRegion.opening(saved: MapStartRegion.load(),
                                           observerLatitude: observer.latitude,
                                           observerLongitude: observer.longitude,
                                           fitEverything: fit)
        return start.map {
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                span: MKCoordinateSpan(latitudeDelta: $0.latitudeDelta,
                                       longitudeDelta: $0.longitudeDelta))
        }
    }

    private var framingPoints: [GreatCircle.Point] {
        let stationPoints = scope.sites.filter { !$0.isNode }
            .compactMap { coordinates[$0.id] }
        let own = showsObserver ? [observer] : []
        if stationPoints.isEmpty {
            return own + scope.sites.compactMap { coordinates[$0.id] }
        }
        return own + stationPoints
    }

    /// Frame the observer *and* every station, so nothing sits off the
    /// edge on open.
    private func frameEverything() {
        // Following the station, the camera is the follow's.
        guard followMode.wrappedValue == .free else { return }
        let points = framingPoints
        guard let region = MapRegionFit.region(covering: points) else { return }
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: region.centerLatitude, longitude: region.centerLongitude),
            span: MKCoordinateSpan(
                latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta)))
    }

    // MARK: - Markers

    /// The map's rotation, for turning the own marker's arrow against it.
    @State private var mapHeading: Double = 0

    private var observerArrowRotation: Double? {
        OwnMarkerArrow.rotation(courseDegrees: followCourse, speed: followSpeed, mapHeading: mapHeading)
    }

    private var observerMarker: some View {
        VStack(spacing: 1) {
            if let rotation = observerArrowRotation {
                OwnArrowShape()
                    .fill(.tint)
                    .overlay(OwnArrowShape().stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round)))
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(rotation))
                    .animation(.easeInOut(duration: 0.3), value: rotation)
                    .frame(width: 30, height: 30)
            } else {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.25))
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(.background)
                    .frame(width: 18, height: 18)
                if let ownAPRSSymbol {
                    // Our beaconed APRS symbol, so the home marker shows the
                    // very glyph we put on the air. The tinted ring still
                    // reads as "you".
                    APRSSymbolView(table: ownAPRSSymbol.table, code: ownAPRSSymbol.code, size: 13)
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tint)
                }
            }
            }
            Text(observerLabel)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.tint, in: Capsule())
                .foregroundStyle(.white)
        }
        .shadow(radius: 2)
        .help("Your station: \(observerLabel) at \(scope.observerLabel)")
    }

    /// A marker's footprint is **constant**, selected or not.
    ///
    /// An annotation is positioned by the center of its content, so
    /// anything that changes the content's size moves the marker: growing
    /// the dot on selection shifted the whole thing under the cursor, and
    /// clicking around a cluster made them all appear to bounce. Only
    /// what is drawn *inside* the fixed frame changes.
    private static let markerFootprint: CGFloat = 40
    private static let markerDiameter: CGFloat = 17
    /// A station beaconing an APRS symbol gets a larger dot so the glyph is
    /// legible and a live transmitted fix stands apart from an address dot.
    private static let aprsMarkerDiameter: CGFloat = 28

    private func marker(for site: StationScope.Site) -> some View {
        let isSelected = site.id == selection
        // A node is infrastructure, not traffic: one color for all of
        // them, so the eye separates the network's fixtures from the
        // stations moving through it. Recency still shows through the
        // stale fade.
        let tint = site.isNode ? Color.purple : color(for: site.signal)
        // A drawable beaconed symbol earns the larger marker; a node or an
        // inferred lead keeps the ordinary dot.
        let hasAPRSGlyph = !site.isNode && !site.isApproximate && site.aprsSymbol != nil
        let diameter = hasAPRSGlyph ? Self.aprsMarkerDiameter : Self.markerDiameter

        return VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(tint.opacity(site.isApproximate ? 0.12 : 0.28))
                    .frame(width: diameter + 12, height: diameter + 12)
                // Hollow and dashed when the position is inferred from a
                // *different* entity — a node placed at its operator's
                // address. It is a lead, not a fix, and must not look
                // like one.
                if site.isApproximate {
                    Circle()
                        .fill(.background.opacity(0.85))
                        .frame(width: diameter, height: diameter)
                    Circle()
                        .strokeBorder(tint, style: StrokeStyle(lineWidth: 2.5, dash: [3, 2]))
                        .frame(width: diameter, height: diameter)
                } else {
                    Circle()
                        .fill(tint)
                        .frame(width: diameter, height: diameter)
                    Circle()
                        .stroke(.white, lineWidth: 2.5)
                        .frame(width: diameter, height: diameter)
                }
                if site.isNode {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(site.isApproximate ? tint : .white)
                } else if !site.isApproximate, let symbol = site.aprsSymbol {
                    // The APRS glyph the station beaconed, over its dot — a
                    // car, a digipeater, a weather station. Sized to fill the
                    // dot and given a dark edge so it reads white on any
                    // recency color, because the symbol is the whole point of
                    // an APRS marker.
                    APRSSymbolView(table: symbol.table, code: symbol.code,
                                   size: diameter * 0.78)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                }
                // Selection is shown by a ring drawn inside the fixed
                // footprint, never by resizing it.
                Circle()
                    .stroke(isSelected ? Color.primary : .clear, lineWidth: 2)
                    .frame(width: diameter + 10, height: diameter + 10)
            }
            .frame(width: Self.markerFootprint, height: Self.markerFootprint)

            // The callsign, and for a weather station its current temperature
            // after it in a lighter weight — one pill, so the reading reads as
            // something about this station rather than as part of its name.
            (Text(site.label)
             + Text(site.weatherBadge.map { "  \($0)" } ?? "")
                .fontWeight(.regular))
                // Weight and size are fixed too: a bolder label is wider,
                // and a wider label moves the marker for the same reason.
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(tint.opacity(site.isApproximate ? 0.55 : 0.92), in: Capsule())
                .overlay(Capsule().stroke(
                    isSelected ? Color.primary : Color.white.opacity(0.7),
                    lineWidth: isSelected ? 1 : 0.5))
                .fixedSize()
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .opacity(site.isStale ? 0.75 : 1)
        .help(site.tooltip)
    }

    private func color(for signal: StationScope.Signal) -> Color {
        switch signal {
        case .good: .green
        case .fair: .yellow
        case .poor: .orange
        case .unknown: .secondary
        }
    }

    /// A trail's color matches its station's dot, so the line and the marker
    /// read as one. Falls back to gray when the station is not in the scope.
    private func trailColor(for id: String) -> Color {
        guard let site = scope.sites.first(where: { $0.id == id }) else { return .secondary }
        return site.isNode ? .purple : color(for: site.signal)
    }
}

extension GreatCircle.Point {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Runs the map under the bar above it.
///
/// On iOS the navigation bar — and on iPad the tab bar — floats over
/// content that reaches the top edge, the way Maps draws its own map under
/// its controls. A map that stopped at the bar's bottom edge left a solid
/// band across the top of the screen with nothing in it. Only the top edge
/// bleeds: the bottom meets the TNC strip, which is not a safe-area inset.
///
/// Applied to the map itself and not to its overlays, which follow in the
/// chain: the modifier reports the safe-area frame to its parent, so the
/// legend and the chips align to the visible map and stay out from under
/// the bar. The Mac has no bar to run under and gets the map unchanged.
private struct MapTopBleed: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.ignoresSafeArea(.container, edges: .top)
        #else
        content
        #endif
    }
}

/// The own marker's arrow (`OwnMarkerArrow.path`), pointing up.
private struct OwnArrowShape: Shape {
    func path(in rect: CGRect) -> Path { Path(OwnMarkerArrow.path(in: rect)) }
}
