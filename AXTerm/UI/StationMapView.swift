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
    @Binding var selection: String?

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
        } else if drawing != nil || !overlays.isEmpty {
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
            drawing: drawing ?? .constant(MapDrawingSession()),
            onDrawTap: onDrawTap,
            selection: $selection,
            region: MapRegionFit.region(covering: [observer] + Array(coordinates.values))?.mkRegion)
        .overlay(alignment: .bottomLeading) {
            MapLegend(kind: legend, overDarkBasemap: false)
                .padding(10)
        }
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
        .overlay(alignment: .bottomLeading) {
            MapLegend(kind: legend, overDarkBasemap: basemap.isDark)
                .padding(10)
                // The map ignores the safe area so the terrain runs to the
                // edges; anything floating on top of it must put the inset
                // back, or the legend sits on the home indicator.
                .padding(.bottom, safeAreaBottomInset)
        }
        .onAppear(perform: frameEverything)
        .onChange(of: scope.sites.count) { _, _ in frameEverything() }
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

    /// Frame the observer *and* every station, so nothing sits off the
    /// edge on open.
    private func frameEverything() {
        var points = [observer]
        points.append(contentsOf: scope.sites.compactMap { coordinates[$0.id] })
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
                Image(systemName: "location.north.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tint)
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
    private static let markerFootprint: CGFloat = 34
    private static let markerDiameter: CGFloat = 17

    private func marker(for site: StationScope.Site) -> some View {
        let isSelected = site.id == selection
        let tint = color(for: site.signal)
        let diameter = Self.markerDiameter

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
                // Selection is shown by a ring drawn inside the fixed
                // footprint, never by resizing it.
                Circle()
                    .stroke(isSelected ? Color.primary : .clear, lineWidth: 2)
                    .frame(width: diameter + 10, height: diameter + 10)
            }
            .frame(width: Self.markerFootprint, height: Self.markerFootprint)

            Text(site.label)
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
        .help(site.detail)
    }

    private func color(for signal: StationScope.Signal) -> Color {
        switch signal {
        case .good: .green
        case .fair: .yellow
        case .poor: .orange
        case .unknown: .secondary
        }
    }
}

extension GreatCircle.Point {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
