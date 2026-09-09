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
    let coordinates: [String: GreatCircle.Point]
    /// The operator's own callsign, for the centre marker. A grid
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
    /// Measured coverage around the observer, drawn as two rings. Nil
    /// draws nothing — no evidence, no ring.
    var coverage: CoverageEstimate.Ring?
    @Binding var selection: String?

    private var hasNodeSites: Bool { scope.sites.contains(where: \.isNode) }

    private var observerLabel: String {
        observerCallsign.isEmpty ? scope.observerLabel : observerCallsign.uppercased()
    }

    @State private var camera: MapCameraPosition = .automatic

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
            selection: $selection,
            region: MapRegionFit.region(covering: framingPoints)?.mkRegion,
            coverage: coverage)
        .modifier(MapTopBleed())
        .overlay(alignment: .bottomLeading) {
            if !legendGivesWayToSelection {
                MapLegend(kind: legend, overDarkBasemap: store == nil && basemap.isDark,
                          showsCoverage: coverage != nil, showsNodes: hasNodeSites,
                          showsPositionSource: !aprsSymbols.isEmpty)
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) { coverageChip }
        .overlay(alignment: .bottomTrailing) {
            Text(store == nil ? "" : tileSource.attribution)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
                .help("Required by the map data licence. Offline tiles are still someone's work.")
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
            if let coverage {
                MapCircle(center: observer.clCoordinate,
                          radius: coverage.typicalKm * 1000)
                    .foregroundStyle(.tint.opacity(0.08))
                    .stroke(.tint.opacity(0.55), lineWidth: 1.5)
                MapCircle(center: observer.clCoordinate,
                          radius: coverage.reachKm * 1000)
                    .foregroundStyle(.clear)
                    .stroke(.tint.opacity(0.4),
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

            Annotation("", coordinate: observer.clCoordinate, anchor: .center) {
                observerMarker
            }
            .annotationTitles(.hidden)
            .tag("__observer__")

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
            MapCompass()
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
            if !legendGivesWayToSelection {
                MapLegend(kind: legend, overDarkBasemap: basemap.isDark,
                          showsCoverage: coverage != nil, showsNodes: hasNodeSites,
                          showsPositionSource: !aprsSymbols.isEmpty)
                    .padding(10)
                    // The map ignores the safe area so the terrain runs to
                    // the edges; anything floating on top of it must put the
                    // inset back, or the legend sits on the home indicator.
                    .padding(.bottom, safeAreaBottomInset)
            }
        }
        .overlay(alignment: .topTrailing) { coverageChip }
        .onAppear(perform: frameEverything)
        .onChange(of: scope.sites.count) { _, _ in frameEverything() }
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
        if let coverage {
            Label("Coverage ~" + DistanceDisplay.string(
                    kilometres: coverage.reachKm, inMiles: distanceInMiles),
                  systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
                .help(coverage.summary(inMiles: distanceInMiles))
                .accessibilityLabel(coverage.summary)
        }
    }

    /// What the camera frames: the observer and the *heard* stations.
    ///
    /// The directory layer must not drive the camera — a harvested node
    /// table legitimately reaches stations half a continent away, and
    /// framing them shrank the operator's own network to a dot cluster
    /// (field capture 2026-08-28 19:36). The nodes stay on the map; the
    /// camera just does not chase them. When only nodes are placed, they
    /// are all there is to frame.
    private var framingPoints: [GreatCircle.Point] {
        let stationPoints = scope.sites.filter { !$0.isNode }
            .compactMap { coordinates[$0.id] }
        if stationPoints.isEmpty {
            return [observer] + scope.sites.compactMap { coordinates[$0.id] }
        }
        return [observer] + stationPoints
    }

    /// Frame the observer *and* every station, so nothing sits off the
    /// edge on open.
    private func frameEverything() {
        let points = framingPoints
        guard let region = MapRegionFit.region(covering: points) else { return }
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: region.centerLatitude, longitude: region.centerLongitude),
            span: MKCoordinateSpan(
                latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta)))
    }

    // MARK: - Markers

    private var observerMarker: some View {
        VStack(spacing: 1) {
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
                    Image(systemName: APRSSymbolGlyph.systemImage(
                        table: ownAPRSSymbol.table, code: ownAPRSSymbol.code))
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tint)
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
        .help("Your station \u{2014} \(observerLabel) at \(scope.observerLabel)")
    }

    /// A marker's footprint is **constant**, selected or not.
    ///
    /// An annotation is positioned by the centre of its content, so
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
        // A node is infrastructure, not traffic: one colour for all of
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
                    // recency colour, because the symbol is the whole point of
                    // an APRS marker.
                    Image(systemName: APRSSymbolGlyph.systemImage(
                        table: symbol.table, code: symbol.code))
                        .font(.system(size: diameter * 0.72, weight: .black))
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

    /// A trail's colour matches its station's dot, so the line and the marker
    /// read as one. Falls back to grey when the station is not in the scope.
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
