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
    /// Measured coverage rings around the observer. Nil draws none.
    var coverage: CoverageEstimate.Ring?

    // MARK: - Annotations

    /// How often the map accepts structural mutations — annotation
    /// arrivals and departures, line rebuilds. Anything inserted makes
    /// MapKit re-resolve its label layer, which reads as the basemap's
    /// own dots and shields rippling; on a busy channel someone new is
    /// placed every few seconds, so unpaced mutations kept that ripple
    /// running continuously (field video 2026-09-01 11:28). Deferred
    /// changes are re-derived and applied by a later pass.
    static let structuralMutationInterval: TimeInterval = 10

    /// One station, carried into MapKit.
    ///
    /// Mutable, deliberately: the object *is* the marker's identity. A
    /// station that persists across updates keeps its annotation, and a
    /// changed position is written into `coordinate` — KVO-compliant, so
    /// MapKit slides that one view — instead of the whole layer being torn
    /// down and rebuilt because one field of one station moved.
    final class SiteAnnotation: NSObject, MKAnnotation {
        let id: String
        @objc dynamic var coordinate: CLLocationCoordinate2D
        @objc dynamic var title: String?
        @objc dynamic var subtitle: String?
        var signal: StationScope.Signal
        var isApproximate: Bool
        let isObserver: Bool
        var isNode: Bool

        init(id: String, coordinate: CLLocationCoordinate2D, title: String?,
             subtitle: String?, signal: StationScope.Signal,
             isApproximate: Bool, isObserver: Bool, isNode: Bool = false) {
            self.id = id
            self.coordinate = coordinate
            self.title = title
            self.subtitle = subtitle
            self.signal = signal
            self.isApproximate = isApproximate
            self.isObserver = isObserver
            self.isNode = isNode
        }

        /// Folds a rebuilt annotation's values into this one, returning
        /// whether anything the *view* draws — tint, glyph, label — changed
        /// and it therefore needs reconfiguring. The coordinate is written
        /// only when it moved, so MapKit is not KVO-poked on every pass.
        func absorb(_ next: SiteAnnotation) -> Bool {
            if coordinate.latitude != next.coordinate.latitude
                || coordinate.longitude != next.coordinate.longitude {
                #if DEBUG
                let metres = GreatCircle.kilometres(
                    from: GreatCircle.Point(latitude: coordinate.latitude,
                                            longitude: coordinate.longitude),
                    to: GreatCircle.Point(latitude: next.coordinate.latitude,
                                          longitude: next.coordinate.longitude)) * 1000
                print(String(format: "[MAPDIAG] move %@ %.2f m", id, metres))
                #endif
                coordinate = next.coordinate
            }
            if subtitle != next.subtitle { subtitle = next.subtitle }
            let redraws = title != next.title
                || signal != next.signal
                || isApproximate != next.isApproximate
                || isNode != next.isNode
            if redraws {
                title = next.title
                signal = next.signal
                isApproximate = next.isApproximate
                isNode = next.isNode
            }
            return redraws
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

        var seen: Set<String> = [result[0].id]
        for site in scope.sites {
            guard let position = coordinates[site.id],
                  seen.insert(site.id).inserted else { continue }
            result.append(SiteAnnotation(
                id: site.id,
                coordinate: position.clCoordinate,
                title: site.label,
                subtitle: site.subtitle,
                signal: site.signal,
                isApproximate: site.isApproximate,
                isObserver: false,
                isNode: site.isNode))
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
        /// Coverage circles currently on the map, and which of them is the
        /// dashed outer ring.
        var coverageCircles: [MKCircle] = []
        var dashedCoverageIDs: Set<ObjectIdentifier> = []
        var installedCoverage: CoverageEstimate.Ring?

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
        /// Installed path lines by link id, with the signature of what each
        /// was built from. A line whose signature is unchanged is left
        /// exactly where it is; one whose evidence or endpoints changed is
        /// rebuilt alone, instead of every line on the map being torn down
        /// because one path was heard again.
        var linkLines: [String: MKPolyline] = [:]
        var linkSignatures: [String: String] = [:]
        /// When the map was last structurally mutated — an annotation added
        /// or removed, a line rebuilt. Inserting anything makes MapKit
        /// re-resolve its own label layer: an animated ripple of the city
        /// dots and road shields. One new station every few seconds meant
        /// that ripple ran continuously, so mutations are batched on this
        /// clock — the first after a quiet spell applies at once, the ones
        /// behind it coalesce into the next pass.
        var lastStructuralMutation = Date.distantPast
        /// One decision per update pass, taken before any section runs, so
        /// annotations and lines mutate in the same batch instead of one
        /// section stamping the clock and starving the other.
        var structuralMutationsAllowed = true
        var structuralMutationDidOccur = false
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
                // Coverage rings: measured footprint, drawn quietly under
                // the network. Inner ring filled faintly; outer dashed.
                if coverageCircles.contains(where: { $0 === circle }) {
                    let renderer = MKCircleRenderer(circle: circle)
                    let dashed = dashedCoverageIDs.contains(ObjectIdentifier(circle))
                    renderer.strokeColor = PlatformColor.systemBlue
                        .withAlphaComponent(dashed ? 0.6 : 0.8)
                    renderer.lineWidth = 2.5
                    renderer.fillColor = dashed
                        ? nil : PlatformColor.systemBlue.withAlphaComponent(0.08)
                    if dashed { renderer.lineDashPattern = [6, 5] }
                    return renderer
                }
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
                           isNode: site.isNode,
                           callsign: site.title)
            view.setOverDarkBasemap(parent.store == nil && parent.basemap.isDark)
            view.setLabelVisible(
                labelsVisible || site.isObserver || site.id == parent.selection)
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

        static func tint(for site: SiteAnnotation) -> PlatformColor {
            if site.isObserver { return .systemBlue }
            // Infrastructure wears one colour so it reads apart from
            // traffic; recency still shows through the label and callout.
            if site.isNode { return .systemPurple }
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
        /// Set while the map is being driven to match `selection` rather than
        /// by the operator, so the callbacks that causes are not mistaken for
        /// a fresh choice and written back into SwiftUI.
        var isApplyingSelection = false

        /// Whether callsign labels are shown at the current zoom — see
        /// MapLabelPolicy. The observer's and the selection's labels stay
        /// regardless: "where am I" and "what did I just click" are the
        /// two names worth ink at any zoom.
        var labelsVisible = true

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let shows = MapLabelPolicy.showsLabels(
                latitudeDelta: mapView.region.span.latitudeDelta)
            guard shows != labelsVisible else { return }
            labelsVisible = shows
            applyLabelVisibility(on: mapView)
        }

        func applyLabelVisibility(on mapView: MKMapView) {
            for annotation in mapView.annotations {
                guard let site = annotation as? SiteAnnotation,
                      let view = mapView.view(for: annotation) as? StationDotAnnotationView
                else { continue }
                view.setLabelVisible(
                    labelsVisible || site.isObserver || site.id == parent.selection)
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !isRebuildingAnnotations, !isApplyingSelection,
                  let site = view.annotation as? SiteAnnotation else { return }
            // A selected station's name is always worth ink, even zoomed out.
            (view as? StationDotAnnotationView)?.setLabelVisible(true)
            let next = site.isObserver ? nil : site.id
            // Written only when it changes: an unconditional write feeds a
            // SwiftUI update back into the map, which re-selects, which calls
            // this again.
            guard parent.selection != next else { return }
            parent.selection = next
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard !isRebuildingAnnotations, !isApplyingSelection else { return }
            if let site = view.annotation as? SiteAnnotation {
                (view as? StationDotAnnotationView)?.setLabelVisible(
                    labelsVisible || site.isObserver)
            }
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
        applyCoverage(to: mapView, coordinator: context.coordinator)

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
            // The modern configuration rather than mapType: muted emphasis
            // pulls Apple's palette back to greys, so the recency colours,
            // node diamonds and coverage rings own the map's colour.
            mapView.preferredConfiguration = basemap.mkConfiguration
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

        // Boundaries rebuild only when the layer set itself changes — not,
        // as before, whenever a path link appeared. The two were keyed
        // together, so every newly heard path tore down every county
        // boundary and every line on the map at once, and on a busy channel
        // that was a visible flicker of the whole network every few seconds.
        //
        // Order within a level is insertion order, so terrain added *after*
        // the network would cover it. A terrain change therefore forces both
        // sections to re-add on top of it — the one remaining wholesale
        // rebuild, and it happens only when the operator toggles terrain.
        let wantedVectors = overlays.map(\.id)
        if terrainChanged || coordinator.installedOverlayIDs != wantedVectors {
            #if DEBUG
            print("[MAPDIAG] vector rebuild terrainChanged=\(terrainChanged)")
            #endif
            coordinator.installedOverlayIDs = wantedVectors

            let coverageIDs = Set(coordinator.coverageCircles.map(ObjectIdentifier.init))
            let linkIDs = Set(coordinator.linkLines.values.map(ObjectIdentifier.init))
            let existing = mapView.overlays.filter {
                !($0 is MKTileOverlay) && !($0 is ElevationOverlay)
                    && !coverageIDs.contains(ObjectIdentifier($0))
                    && !linkIDs.contains(ObjectIdentifier($0))
            }
            mapView.removeOverlays(existing)
            for id in coordinator.overlayColors.keys where !linkIDs.contains(id) {
                coordinator.overlayColors.removeValue(forKey: id)
            }

            for layer in overlays {
                let color = Self.platformColor(named: layer.colorName)
                for overlay in layer.mapKitOverlays() {
                    coordinator.overlayColors[ObjectIdentifier(overlay)] = color
                    mapView.addOverlay(overlay, level: .aboveLabels)
                }
            }

            if terrainChanged {
                // Sweep the lines so they re-add above the fresh terrain.
                mapView.removeOverlays(Array(coordinator.linkLines.values))
                for (_, line) in coordinator.linkLines {
                    coordinator.overlayColors.removeValue(forKey: ObjectIdentifier(line))
                    coordinator.linkStyles.removeValue(forKey: ObjectIdentifier(line))
                }
                coordinator.linkLines.removeAll()
                coordinator.linkSignatures.removeAll()
            }
        }

        // Links reconciled one by one, below the labels: the network is
        // context for the stations, and a web of lines over the place names
        // would bury what they connect. A line is touched only when the
        // link it draws actually changed — new, gone, restyled, or moved.
        let wantedLinks = Dictionary(pathLinks.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        // Same batching clock as the annotations, same reasoning: a line
        // inserted or removed ripples the basemap's label layer. Deferred
        // work is re-derived by a later pass, never lost.
        let mayMutateLinks = coordinator.structuralMutationsAllowed
        for (id, line) in coordinator.linkLines where wantedLinks[id] == nil {
            guard mayMutateLinks else { break }
            mapView.removeOverlay(line)
            coordinator.overlayColors.removeValue(forKey: ObjectIdentifier(line))
            coordinator.linkStyles.removeValue(forKey: ObjectIdentifier(line))
            coordinator.linkLines.removeValue(forKey: id)
            coordinator.linkSignatures.removeValue(forKey: id)
            coordinator.structuralMutationDidOccur = true
        }
        for (id, link) in wantedLinks {
            let signature = Self.linkSignature(link)
            if coordinator.linkSignatures[id] == signature {
                // Same pixels, but the label may have new numbers in it —
                // it feeds the tap card, and the card should not read stale.
                if let line = coordinator.linkLines[id] {
                    coordinator.linkStyles[ObjectIdentifier(line)] = link
                }
                continue
            }
            guard mayMutateLinks else { continue }
            #if DEBUG
            print("[MAPDIAG] link rebuild \(id)")
            #endif
            if let stale = coordinator.linkLines[id] {
                mapView.removeOverlay(stale)
                coordinator.overlayColors.removeValue(forKey: ObjectIdentifier(stale))
                coordinator.linkStyles.removeValue(forKey: ObjectIdentifier(stale))
            }
            let line = link.polyline
            coordinator.overlayColors[ObjectIdentifier(line)] = Self.linkColor(for: link)
            coordinator.linkStyles[ObjectIdentifier(line)] = link
            coordinator.linkLines[id] = line
            coordinator.linkSignatures[id] = signature
            mapView.addOverlay(line, level: .aboveRoads)
            coordinator.structuralMutationDidOccur = true
        }
    }

    /// Everything that feeds a link's geometry or renderer, folded to a
    /// string. Two links with the same signature draw identically, so the
    /// installed line can be left alone. The label is deliberately absent —
    /// it feeds the tap card, not the pixels, and `linkStyles` is refreshed
    /// with the link either way.
    private static func linkSignature(_ link: MapPathLink) -> String {
        String(format: "%.6f,%.6f|%.6f,%.6f|", link.from.latitude, link.from.longitude,
               link.to.latitude, link.to.longitude)
            + "\(link.evidence.rawValue)|\(link.isSuspect)|\(link.isPrediction)"
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
        #if DEBUG
        print("[MAPDIAG] terrain rebuild \(coordinator.installedTerrainIDs.count) -> \(wanted.count)")
        #endif
        coordinator.installedTerrainIDs = wanted

        mapView.removeOverlays(mapView.overlays.compactMap { $0 as? ElevationOverlay })
        for overlay in terrainOverlays {
            mapView.addOverlay(overlay, level: .aboveRoads)
        }
        return true
    }

    /// Adds or replaces the coverage rings when the estimate changes.
    private func applyCoverage(to mapView: MKMapView, coordinator: Coordinator) {
        // Self-healing: if anything swept the circles off — a basemap
        // swap, an overlay path this function does not own — re-add
        // rather than trusting the bookkeeping. Field capture 2026-08-29
        // 05:37: the chip said ~48 mi while the map drew nothing.
        if !coordinator.coverageCircles.isEmpty,
           !coordinator.coverageCircles.allSatisfy({ circle in
               mapView.overlays.contains { $0 === circle }
           }) {
            coordinator.installedCoverage = nil
        }
        guard coordinator.installedCoverage != coverage else { return }
        #if DEBUG
        print("[MAPDIAG] coverage rebuild")
        #endif
        coordinator.installedCoverage = coverage
        mapView.removeOverlays(coordinator.coverageCircles)
        coordinator.coverageCircles = []
        coordinator.dashedCoverageIDs = []
        guard let coverage else { return }
        let inner = MKCircle(center: observer.clCoordinate,
                             radius: coverage.typicalKm * 1000)
        let outer = MKCircle(center: observer.clCoordinate,
                             radius: coverage.reachKm * 1000)
        coordinator.coverageCircles = [inner, outer]
        coordinator.dashedCoverageIDs = [ObjectIdentifier(outer)]
        mapView.addOverlay(inner, level: .aboveRoads)
        mapView.addOverlay(outer, level: .aboveRoads)
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
        context.coordinator.structuralMutationsAllowed = Date().timeIntervalSince(
            context.coordinator.lastStructuralMutation) >= Self.structuralMutationInterval
        context.coordinator.structuralMutationDidOccur = false

        // `applyBasemap` owns the tile overlay's lifecycle and swaps it only
        // when the basemap actually changes — rebuilding it on every update
        // would discard MapKit's in-flight tile requests and flicker while
        // panning.
        applyBasemap(to: mapView, coordinator: context.coordinator)
        applyVectorOverlays(to: mapView, coordinator: context.coordinator)
        applyCoverage(to: mapView, coordinator: context.coordinator)
        applyDrawingPreview(to: mapView, coordinator: context.coordinator)

        // Reconciled station by station, never wholesale. This used to
        // compare id-sets and, on any difference, remove every annotation
        // and add them all back — so each newly placed station (every few
        // seconds on a busy channel) made the entire marker layer blink and
        // resettle. The operator saw the map pulse. Now a station that
        // persists keeps its annotation object: a moved position slides that
        // one dot via KVO, a changed signal reconfigures that one view, and
        // only genuinely new or departed stations are added or removed.
        // Keeping identity also means the selected annotation survives
        // updates instead of being torn down and re-selected.
        let existing = mapView.annotations.compactMap { $0 as? SiteAnnotation }
        // Tolerant of duplicate ids, not trusting that upstream never emits
        // one: `Dictionary(uniqueKeysWithValues:)` traps on a repeat, and a
        // trap in a map update is a crash the operator sees (field capture
        // 2026-09-01 11:03 — DRLNOD arrived as both a heard station and a
        // via alias). The first annotation keeps the id; the surplus copies
        // are swept off the map with the departed.
        var existingByID: [String: SiteAnnotation] = [:]
        var surplus: [SiteAnnotation] = []
        for annotation in existing {
            if existingByID[annotation.id] == nil {
                existingByID[annotation.id] = annotation
            } else {
                surplus.append(annotation)
            }
        }
        let wanted = annotations()
        let wantedIDs = Set(wanted.map(\.id))

        let departed = surplus + existing.filter {
            existingByID[$0.id] === $0 && !wantedIDs.contains($0.id)
        }

        // The batching clock. Structural changes are deferred, not dropped:
        // the body re-evaluates with every packet, so a deferred arrival is
        // re-derived and applied by a pass a few seconds later.
        let mayMutate = context.coordinator.structuralMutationsAllowed
        #if DEBUG
        if !departed.isEmpty {
            print("[MAPDIAG] departed\(mayMutate ? "" : " (deferred)") \(departed.map(\.id).joined(separator: ","))")
        }
        #endif
        if !departed.isEmpty, mayMutate {
            // Removing a selected annotation fires `didDeselect`; suppressed,
            // or the delegate writes `selection = nil` straight back into the
            // state that caused this update.
            context.coordinator.isRebuildingAnnotations = true
            mapView.removeAnnotations(departed)
            context.coordinator.isRebuildingAnnotations = false
            context.coordinator.structuralMutationDidOccur = true
        }

        var arrived: [SiteAnnotation] = []
        for annotation in wanted {
            if let current = existingByID[annotation.id] {
                if current.absorb(annotation),
                   let view = mapView.view(for: current) as? StationDotAnnotationView {
                    #if DEBUG
                    print("[MAPDIAG] reconfigure \(current.id)")
                    #endif
                    view.configure(tint: Coordinator.tint(for: current),
                                   isObserver: current.isObserver,
                                   approximate: current.isApproximate,
                                   isNode: current.isNode,
                                   callsign: current.title)
                }
            } else {
                arrived.append(annotation)
            }
        }
        if !arrived.isEmpty, mayMutate {
            #if DEBUG
            print("[MAPDIAG] arrived \(arrived.map(\.id).joined(separator: ","))")
            #endif
            mapView.addAnnotations(arrived)
            context.coordinator.structuralMutationDidOccur = true
        }

        // Feature labels are rebuilt with the overlays they belong to, keyed
        // on the same layer identity so panning does not churn them.
        let existingLabels = mapView.annotations.compactMap { $0 as? FeatureLabelAnnotation }
        let wantedLabels = featureLabels()
        if Set(existingLabels.map { $0.title ?? "" }) != Set(wantedLabels.map { $0.title ?? "" }) {
            #if DEBUG
            print("[MAPDIAG] feature labels rebuild")
            #endif
            mapView.removeAnnotations(existingLabels)
            mapView.addAnnotations(wantedLabels)
        }

        if let selection,
           let match = mapView.annotations.compactMap({ $0 as? SiteAnnotation })
               .first(where: { $0.id == selection }),
           mapView.selectedAnnotations.first !== match {
            // Not inline. `selectAnnotation` deselects whatever was selected
            // first, and MapKit delivers `didDeselect` synchronously — which
            // writes `parent.selection`, and this runs inside the SwiftUI
            // view update. Writing state mid-update is undefined behaviour
            // and the runtime says as much in the log; it also fed the write
            // straight back in as another update.
            //
            // So hop off the update before touching the map, and flag the
            // round trip so the callbacks it causes are read as "the map
            // catching up with the selection" rather than as the operator
            // picking something new.
            let coordinator = context.coordinator
            coordinator.isApplyingSelection = true
            DispatchQueue.main.async {
                mapView.selectAnnotation(match, animated: true)
                coordinator.isApplyingSelection = false
            }
        }

        if context.coordinator.structuralMutationDidOccur {
            context.coordinator.lastStructuralMutation = Date()
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
