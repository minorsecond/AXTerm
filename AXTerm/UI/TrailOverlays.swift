import MapKit

/// One piece of a movement trail as `TrailPlan` laid it out, carrying its
/// style so the renderer needs no lookup.
final class TrailPieceLine: MKPolyline {
    var color: PlatformColor = .systemGray
    var startAlpha: CGFloat = 1
    var endAlpha: CGFloat = 1
    var width: CGFloat = 3
    var dashed = false

    static func make(_ piece: TrailPlan.Piece, color: PlatformColor) -> TrailPieceLine {
        let coordinates = piece.points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        let line = TrailPieceLine(coordinates: coordinates, count: coordinates.count)
        line.color = color
        line.startAlpha = piece.startAlpha
        line.endAlpha = piece.endAlpha
        line.width = piece.width
        line.dashed = piece.dashed
        return line
    }
}

/// The selected station's beacon fixes, drawn as small dots of a constant
/// size on screen at any zoom.
final class TrailFixesOverlay: NSObject, MKOverlay {
    let points: [MKMapPoint]
    let color: PlatformColor
    let boundingMapRect: MKMapRect
    var coordinate: CLLocationCoordinate2D { boundingMapRect.origin.coordinate }

    init(points: [GreatCircle.Point], color: PlatformColor) {
        self.points = points.map {
            MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
        self.color = color
        let xs = self.points.map(\.x), ys = self.points.map(\.y)
        let rect = MKMapRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                             width: (xs.max() ?? 0) - (xs.min() ?? 0),
                             height: (ys.max() ?? 0) - (ys.min() ?? 0))
        // Padded so a dot on the edge is not clipped by the tile it sits on.
        boundingMapRect = rect.insetBy(dx: -rect.width * 0.05 - 2000, dy: -rect.height * 0.05 - 2000)
        super.init()
    }
}

final class TrailFixesRenderer: MKOverlayRenderer {
    private let fixes: TrailFixesOverlay

    init(fixes: TrailFixesOverlay) {
        self.fixes = fixes
        super.init(overlay: fixes)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // About 3.5 points across on screen, with a white rim so a dot reads
        // on the trail it sits on.
        let radius = 3.5 / zoomScale
        for point in fixes.points {
            let center = self.point(for: point)
            let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(PlatformColor.white.cgColor)
            context.fillEllipse(in: dot.insetBy(dx: -radius * 0.4, dy: -radius * 0.4))
            context.setFillColor(fixes.color.cgColor)
            context.fillEllipse(in: dot)
        }
    }
}
