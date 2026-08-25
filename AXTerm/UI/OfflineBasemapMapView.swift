import SwiftUI
import MapKit

#if os(macOS)
import AppKit
typealias PlatformTapGestureRecognizer = NSClickGestureRecognizer
typealias PlatformGestureRecognizer = NSGestureRecognizer
typealias PlatformGestureRecognizerDelegate = NSGestureRecognizerDelegate
#else
import UIKit
typealias PlatformTapGestureRecognizer = UITapGestureRecognizer
typealias PlatformGestureRecognizer = UIGestureRecognizer
typealias PlatformGestureRecognizerDelegate = UIGestureRecognizerDelegate
#endif

/// A map drawn entirely from stored tiles.
///
/// SwiftUI's `Map` has no way to add an `MKTileOverlay`, and a tile overlay
/// with `canReplaceMapContent` is the only thing that makes MapKit draw
/// something when there is no network. So the offline basemap is an
/// `MKMapView` underneath — the rest of the app keeps SwiftUI's `Map` for the
/// online styles, where it is the better tool.
///
/// The markers are drawn by the same `StationScope` model as everywhere else,
/// so a station's colour and shape mean the same thing offline as online: a
/// hollow marker is still a lead rather than a fix.
struct OfflineBasemapMapView {

    let scope: StationScope
    let observer: GreatCircle.Point
    let coordinates: [String: GreatCircle.Point]
    var observerCallsign: String = ""
    /// Stored tiles. Nil draws Apple's basemap instead — the same view serves
    /// every basemap so drawing and overlays behave identically whichever one
    /// the operator picked.
    var store: MapTileStore?
    var source: MapTileSource = .imported
    /// Apple basemap to fall back to when `store` is nil.
    var basemap: MapBasemap = .standard
    /// Boundaries and other vector data drawn over the basemap.
    var overlays: [MapOverlayLayer] = []
    /// Observed paths between stations, drawn as great-circle lines so the
    /// geometry matches how the signal actually travelled.
    var pathLinks: [MapPathLink] = []
    /// Shaded elevation tiles. Empty draws none, so a map with no terrain
    /// stored looks exactly as it did.
    var terrainOverlays: [ElevationOverlay] = []
    /// In-progress drawing. Taps add vertices while this is active.
    @Binding var drawing: MapDrawingSession
    /// Called when a tap lands on the map in a drawing mode.
    var onDrawTap: (CLLocationCoordinate2D) -> Void = { _ in }
    @Binding var selection: String?
    /// Region to show. Changes here move the camera; the operator panning
    /// does not write back, so the map does not fight them.
    var region: MKCoordinateRegion?

    // MARK: - Annotations

    /// One station, carried into MapKit.
    final class SiteAnnotation: NSObject, MKAnnotation {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let title: String?
        let subtitle: String?
        let signal: StationScope.Signal
        let isApproximate: Bool
        let isObserver: Bool

        init(id: String, coordinate: CLLocationCoordinate2D, title: String?,
             subtitle: String?, signal: StationScope.Signal,
             isApproximate: Bool, isObserver: Bool) {
            self.id = id
            self.coordinate = coordinate
            self.title = title
            self.subtitle = subtitle
            self.signal = signal
            self.isApproximate = isApproximate
            self.isObserver = isObserver
        }
    }

    /// A vertex of the shape being drawn, numbered so the operator can see
    /// the order they tapped.
    final class VertexAnnotation: NSObject, MKAnnotation {
        let coordinate: CLLocationCoordinate2D
        let index: Int
        var title: String? { "\(index)" }

        init(coordinate: CLLocationCoordinate2D, index: Int) {
            self.coordinate = coordinate
            self.index = index
        }
    }

    /// A finished feature's label.
    ///
    /// Every feature gets one. A zone with no name on it is indistinguishable
    /// from the zone beside it, and telling them apart is the entire reason
    /// for drawing boundaries during an activation.
    final class FeatureLabelAnnotation: NSObject, MKAnnotation {
        let coordinate: CLLocationCoordinate2D
        let title: String?
        let subtitle: String?
        let colorName: String
        /// True for a point feature, which is drawn as a pin rather than a
        /// floating label over a shape.
        let isPoint: Bool

        init(coordinate: CLLocationCoordinate2D, title: String?, subtitle: String?,
             colorName: String, isPoint: Bool) {
            self.coordinate = coordinate
            self.title = title
            self.subtitle = subtitle
            self.colorName = colorName
            self.isPoint = isPoint
        }
    }

    /// Labels for every visible feature that has a name.
    private func featureLabels() -> [FeatureLabelAnnotation] {
        overlays.flatMap { layer in
            layer.features.compactMap { feature -> FeatureLabelAnnotation? in
                guard !feature.name.isEmpty,
                      let anchor = MapFeatureLabel.anchor(for: feature.geometry)
                else { return nil }
                let isPoint: Bool
                if case .point = feature.geometry { isPoint = true } else { isPoint = false }
                return FeatureLabelAnnotation(
                    coordinate: anchor, title: feature.name,
                    subtitle: layer.name, colorName: layer.colorName, isPoint: isPoint)
            }
        }
    }

    private func annotations() -> [SiteAnnotation] {
        var result = [SiteAnnotation(
            id: "__observer__",
            coordinate: observer.clCoordinate,
            title: observerCallsign.isEmpty ? scope.observerLabel : observerCallsign.uppercased(),
            subtitle: "This station",
            signal: .good, isApproximate: false, isObserver: true)]

        for site in scope.sites {
            guard let position = coordinates[site.id] else { continue }
            result.append(SiteAnnotation(
                id: site.id,
                coordinate: position.clCoordinate,
                title: site.label,
                subtitle: site.subtitle,
                signal: site.signal,
                isApproximate: site.isApproximate,
                isObserver: false))
        }
        return result
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, PlatformGestureRecognizerDelegate {
        var parent: OfflineBasemapMapView
        var overlay: OfflineTileOverlay?
        /// Layer ids currently installed, so overlays are rebuilt only when
        /// the set actually changes.
        var installedOverlayIDs: [String] = []
        /// Set while the code is moving the camera, so the resulting delegate
        /// callback is not mistaken for the operator panning.
        var isProgrammaticMove = false

        weak var mapView: MKMapView?
        /// Overlays making up the in-progress shape, so they can be replaced
        /// on each tap without disturbing the finished layers.
        var previewOverlays: [MKOverlay] = []
        var previewAnnotations: [MKAnnotation] = []
        /// Basemap currently installed, so it is only swapped when it changes.
        var installedBasemap: String?

        init(_ parent: OfflineBasemapMapView) { self.parent = parent }

        /// A tap in a drawing mode becomes a vertex; otherwise MapKit's own
        /// selection handling is left alone.
        @objc func handleTap(_ recognizer: PlatformTapGestureRecognizer) {
            guard parent.drawing.isDrawing, let mapView else { return }
            let point = recognizer.location(in: mapView)
            // Ignore taps that landed on a station marker: the operator meant
            // to look at the station, not to place a vertex on top of it.
            for annotationView in mapView.annotations.compactMap({ mapView.view(for: $0) })
            where annotationView.frame.contains(point) {
                return
            }
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onDrawTap(coordinate)
        }

        /// Runs alongside MapKit's own recognisers rather than replacing them,
        /// so panning and pinch-zoom keep working while drawing.
        func gestureRecognizer(_ gestureRecognizer: PlatformGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: PlatformGestureRecognizer) -> Bool {
            true
        }

        /// Colour for each vector overlay, by the object MapKit hands back.
        /// Keyed on identity because MapKit gives no other way to tell which
        /// layer an overlay came from at render time.
        var overlayColors: [ObjectIdentifier: PlatformColor] = [:]
        /// Links keep their evidence so the renderer can dash the ones that
        /// have never actually been travelled.
        var linkStyles: [ObjectIdentifier: MapPathLink] = [:]
        var installedTerrainIDs: [String] = []

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if overlay is ElevationOverlay {
                return ElevationOverlayRenderer(overlay: overlay)
            }

            let color = overlayColors[ObjectIdentifier(overlay)] ?? .systemBlue

            switch overlay {
            case let polygon as MKPolygon:
                let renderer = MKPolygonRenderer(polygon: polygon)
                // A fill light enough to read the terrain through: the
                // boundary matters, and hiding the ridge under it would
                // defeat the basemap it is drawn on.
                renderer.fillColor = color.withAlphaComponent(0.12)
                renderer.strokeColor = color.withAlphaComponent(0.9)
                renderer.lineWidth = 1.5
                return renderer
            case let line as MKPolyline:
                let renderer = MKPolylineRenderer(polyline: line)
                if let link = linkStyles[ObjectIdentifier(line)] {
                    renderer.strokeColor = color.withAlphaComponent(
                        link.isPrediction ? 0.5
                            : (link.evidence == .transitive ? 0.45 : 0.85))
                    // Dashed where nothing has been observed travelling it.
                    // A solid line for a guess would read as a route.
                    if link.isPrediction {
                        renderer.lineDashPattern = [2, 6]
                    } else if link.evidence == .transitive {
                        renderer.lineDashPattern = [4, 5]
                    }
                    // A proven path is worth more ink than an overheard one.
                    renderer.lineWidth = link.evidence == .sessionEstablished ? 3 : 1.8
                    return renderer
                }
                renderer.strokeColor = color.withAlphaComponent(0.9)
                renderer.lineWidth = 2
                return renderer
            case let multi as MKMultiPolyline:
                let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
                renderer.strokeColor = color.withAlphaComponent(0.9)
                renderer.lineWidth = 2
                return renderer
            case let circle as MKCircle:
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = color.withAlphaComponent(0.5)
                renderer.strokeColor = color
                renderer.lineWidth = 1
                return renderer
            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let vertex = annotation as? VertexAnnotation {
                let identifier = "vertex"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.markerTintColor = .platformAccent
                view.glyphText = "\(vertex.index)"
                view.canShowCallout = false
                // Above everything: the operator is placing these right now.
                view.displayPriority = .required
                return view
            }

            if let label = annotation as? FeatureLabelAnnotation {
                let identifier = label.isPoint ? "featurePin" : "featureLabel"
                let color = OfflineBasemapMapView.platformColor(named: label.colorName)

                if label.isPoint {
                    let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                        as? MKMarkerAnnotationView
                        ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view.annotation = annotation
                    view.markerTintColor = color
                    view.glyphImage = nil
                    view.canShowCallout = true
                    view.displayPriority = .defaultLow
                    return view
                }

                // A shape's label floats over it with no pin — a marker in
                // the middle of a county reads as a station, which is exactly
                // the confusion the separate palette exists to avoid.
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.canShowCallout = true
                view.image = nil
                view.displayPriority = .defaultLow
                view.collisionMode = .circle
                return view
            }

            guard let site = annotation as? SiteAnnotation else { return nil }
            let identifier = StationDotAnnotationView.reuseIdentifier
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? StationDotAnnotationView
                ?? StationDotAnnotationView(annotation: annotation, reuseIdentifier: identifier)

            view.annotation = annotation
            view.configure(tint: Self.tint(for: site),
                           isObserver: site.isObserver,
                           approximate: site.isApproximate,
                           callsign: site.title)
            // The callout has to earn the tap: a bubble carrying only the
            // callsign already on the label says nothing the map did not.
            view.detailCalloutAccessoryView = Self.calloutDetail(for: site)
            return view
        }

        /// The line under the callsign in a callout.
        ///
        /// `subtitle` already carries what is known — last heard, grid, range
        /// — so the accessory exists to give it room to wrap instead of
        /// truncating to one line in a narrow bubble.
        private static func calloutDetail(for site: SiteAnnotation) -> PlatformView? {
            guard let subtitle = site.subtitle, !subtitle.isEmpty else { return nil }
            let label = PlatformLabel()
            #if os(iOS)
            label.text = subtitle
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            // Bounded rather than unlimited, and given an explicit width.
            // A `numberOfLines = 0` label inside a callout accessory has no
            // width to resolve against and can drive Auto Layout in circles —
            // a hang whose stack trace never mentions the map.
            label.numberOfLines = 3
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 220).isActive = true
            #else
            label.stringValue = subtitle
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabelColor
            label.isBezeled = false
            label.isEditable = false
            label.drawsBackground = false
            label.preferredMaxLayoutWidth = 220
            #endif
            return label
        }

        private static func tint(for site: SiteAnnotation) -> PlatformColor {
            if site.isObserver { return .systemBlue }
            switch site.signal {
            case .good: return .systemGreen
            case .fair: return .systemYellow
            case .poor: return .systemOrange
            case .unknown: return .systemGray
            }
        }

        /// True while `updateMapView` is swapping annotations, so the
        /// deselection MapKit reports as a side effect is not mistaken for the
        /// operator dismissing a selection.
        var isRebuildingAnnotations = false

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !isRebuildingAnnotations,
                  let site = view.annotation as? SiteAnnotation else { return }
            let next = site.isObserver ? nil : site.id
            // Written only when it changes: an unconditional write feeds a
            // SwiftUI update back into the map, which re-selects, which calls
            // this again.
            guard parent.selection != next else { return }
            parent.selection = next
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard !isRebuildingAnnotations else { return }
            guard parent.selection != nil else { return }
            parent.selection = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Shared make/update

    fileprivate func makeMapView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        context.coordinator.mapView = mapView
        // MapKit's own basemap is switched off: the whole point is that what
        // renders is what is stored locally, and leaving Apple's layer on
        // would show a blank map offline and hide missing tiles online.
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = true
        mapView.showsScale = true

        applyBasemap(to: mapView, coordinator: context.coordinator)
        applyVectorOverlays(to: mapView, coordinator: context.coordinator)

        // A tap recogniser rather than MapKit's own selection handling: in a
        // drawing mode the tap must become a vertex, and MapKit gives no way
        // to intercept that. Set not to cancel other touches, so panning and
        // zooming still work while drawing.
        let tap = PlatformTapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

        if let region {
            mapView.setRegion(region, animated: false)
        }
        mapView.addAnnotations(annotations())
        mapView.addAnnotations(featureLabels())
        return mapView
    }

    /// Installs the tile overlay for stored tiles, or Apple's basemap.
    ///
    /// One view for every basemap so drawing, overlays and labels behave the
    /// same whichever the operator picked. `canReplaceMapContent` on the tile
    /// overlay is what makes the offline mode genuinely offline; without a
    /// store, MapKit draws its own.
    private func applyBasemap(to mapView: MKMapView, coordinator: Coordinator) {
        let key = store == nil ? "apple:\(basemap.rawValue)" : "tiles:\(source.id)"
        guard coordinator.installedBasemap != key else { return }
        coordinator.installedBasemap = key

        if let existing = coordinator.overlay {
            mapView.removeOverlay(existing)
            coordinator.overlay = nil
        }

        if let store {
            let overlay = OfflineTileOverlay(store: store, source: source)
            coordinator.overlay = overlay
            mapView.addOverlay(overlay, level: .aboveLabels)
        } else {
            mapView.mapType = basemap.mkMapType
        }
    }

    /// Draws the shape being tapped out, replaced on every vertex.
    ///
    /// Dashed and in the accent colour so it never reads as a finished
    /// boundary — an operator glancing at a half-drawn zone must be able to
    /// tell it is not one.
    private func applyDrawingPreview(to mapView: MKMapView, coordinator: Coordinator) {
        mapView.removeOverlays(coordinator.previewOverlays)
        mapView.removeAnnotations(coordinator.previewAnnotations)
        coordinator.previewOverlays = []
        coordinator.previewAnnotations = []

        let vertices = drawing.previewVertices()
        guard vertices.count >= 2 else {
            // A single vertex has no line to draw, but the operator still
            // needs to see it landed.
            if let only = vertices.first {
                let pin = VertexAnnotation(coordinate: only, index: 1)
                coordinator.previewAnnotations = [pin]
                mapView.addAnnotations([pin])
            }
            return
        }

        let line = MKPolyline(coordinates: vertices, count: vertices.count)
        coordinator.overlayColors[ObjectIdentifier(line)] = .platformAccent
        coordinator.previewOverlays = [line]
        mapView.addOverlay(line, level: .aboveLabels)

        let pins = drawing.vertices.enumerated().map {
            VertexAnnotation(coordinate: $0.element, index: $0.offset + 1)
        }
        coordinator.previewAnnotations = pins
        mapView.addAnnotations(pins)
    }

    /// Rebuilds the vector overlays when the visible set changes.
    ///
    /// Compared by layer identity rather than rebuilt every update: MapKit
    /// re-renders every overlay it is given, and a county boundary with
    /// thousands of vertices redrawn on each pan is visibly slow.
    private func applyVectorOverlays(to mapView: MKMapView, coordinator: Coordinator) {
        // Links are part of the identity so a new path appearing redraws,
        // and panning with an unchanged network does not.
        // Terrain is diffed on its own key. Shading a tile costs a few
        // million floating-point operations, and rebuilding it because a
        // path link appeared would make every new packet stutter the map.
        let terrainChanged = applyTerrain(to: mapView, coordinator: coordinator)

        let wanted = overlays.map(\.id) + pathLinks.map(\.id)
        // Order within a level is insertion order, so terrain added *after*
        // the network would cover it. Re-adding the vectors whenever terrain
        // changes keeps them on top no matter which was toggled first.
        guard terrainChanged || coordinator.installedOverlayIDs != wanted else { return }
        coordinator.installedOverlayIDs = wanted

        let existing = mapView.overlays.filter {
            !($0 is MKTileOverlay) && !($0 is ElevationOverlay)
        }
        mapView.removeOverlays(existing)
        coordinator.overlayColors.removeAll()
        coordinator.linkStyles.removeAll()

        for layer in overlays {
            let color = Self.platformColor(named: layer.colorName)
            for overlay in layer.mapKitOverlays() {
                coordinator.overlayColors[ObjectIdentifier(overlay)] = color
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
        }

        // Below the labels: the network is context for the stations, and a
        // web of lines over the place names would bury what they connect.
        for link in pathLinks {
            let line = link.polyline
            coordinator.overlayColors[ObjectIdentifier(line)] = Self.linkColor(for: link)
            coordinator.linkStyles[ObjectIdentifier(line)] = link
            mapView.addOverlay(line, level: .aboveRoads)
        }
    }

    /// Adds or removes shaded elevation tiles.
    ///
    /// Drawn below everything else the map puts on top: terrain is the ground
    /// the network sits on, and a hillshade over the station markers would
    /// bury the thing the map is actually for.
    @discardableResult
    private func applyTerrain(to mapView: MKMapView, coordinator: Coordinator) -> Bool {
        let wanted = terrainOverlays.map(\.id)
        guard coordinator.installedTerrainIDs != wanted else { return false }
        coordinator.installedTerrainIDs = wanted

        mapView.removeOverlays(mapView.overlays.compactMap { $0 as? ElevationOverlay })
        for overlay in terrainOverlays {
            mapView.addOverlay(overlay, level: .aboveRoads)
        }
        return true
    }

    /// Evidence decides the colour, so the map reads at a glance: green has
    /// been proven end to end, grey has only been inferred.
    static func linkColor(for link: MapPathLink) -> PlatformColor {
        // A forecast is not a measurement, so it never borrows a colour that
        // means one.
        if link.isPrediction { return .systemPurple }
        if link.isSuspect { return .systemRed }
        switch link.evidence {
        case .sessionEstablished: return .systemGreen
        case .heardDigipeated: return .systemBlue
        case .heardDirect: return .systemTeal
        case .transitive: return .systemGray
        }
    }

    static func platformColor(named name: String) -> PlatformColor {
        switch name {
        case "purple": .systemPurple
        case "teal": .systemTeal
        case "indigo": .systemIndigo
        case "brown": .systemBrown
        case "pink": .systemPink
        default: .systemBlue
        }
    }

    fileprivate func updateMapView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // `applyBasemap` owns the tile overlay's lifecycle and swaps it only
        // when the basemap actually changes — rebuilding it on every update
        // would discard MapKit's in-flight tile requests and flicker while
        // panning.
        applyBasemap(to: mapView, coordinator: context.coordinator)
        applyVectorOverlays(to: mapView, coordinator: context.coordinator)
        applyDrawingPreview(to: mapView, coordinator: context.coordinator)

        // Compared as *sets*: `mapView.annotations` is unordered, so an
        // ordered comparison reported a difference on almost every pass and
        // tore down every annotation for nothing — including the selected
        // one, which is what turned a tap into an infinite loop.
        let existing = mapView.annotations.compactMap { $0 as? SiteAnnotation }
        let wanted = annotations()
        if Set(existing.map(\.id)) != Set(wanted.map(\.id)) {
            // Rebuilding annotations deselects whatever was selected, and
            // MapKit reports that as a user deselection. Suppressed, or the
            // delegate writes `selection = nil` straight back into the state
            // that caused the rebuild.
            context.coordinator.isRebuildingAnnotations = true
            mapView.removeAnnotations(existing)
            mapView.addAnnotations(wanted)
            context.coordinator.isRebuildingAnnotations = false
        }

        // Feature labels are rebuilt with the overlays they belong to, keyed
        // on the same layer identity so panning does not churn them.
        let existingLabels = mapView.annotations.compactMap { $0 as? FeatureLabelAnnotation }
        let wantedLabels = featureLabels()
        if Set(existingLabels.map { $0.title ?? "" }) != Set(wantedLabels.map { $0.title ?? "" }) {
            mapView.removeAnnotations(existingLabels)
            mapView.addAnnotations(wantedLabels)
        }

        if let selection,
           let match = mapView.annotations.compactMap({ $0 as? SiteAnnotation })
               .first(where: { $0.id == selection }),
           mapView.selectedAnnotations.first !== match {
            mapView.selectAnnotation(match, animated: true)
        }
    }
}

#if os(macOS)
extension OfflineBasemapMapView: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMapView(context: context) }
    func updateNSView(_ nsView: MKMapView, context: Context) { updateMapView(nsView, context: context) }
}
#else
extension OfflineBasemapMapView: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMapView(context: context) }
    func updateUIView(_ uiView: MKMapView, context: Context) { updateMapView(uiView, context: context) }
}
#endif
