import MapKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A folded group of stations, drawn as a small composition dial.
///
/// The first version used `MKMarkerAnnotationView`, which was a mistake this
/// codebase had already written down: see `StationDotAnnotationView`, which
/// rejects the balloon for stations because it dominates the terrain, covers
/// the ground north of the point it marks, and puts the real position at the
/// *tip* rather than the body. Every objection applies at least as strongly to
/// a cluster, which is less important than a station, not more. The balloons
/// also dropped in with MapKit's bounce, on a map whose markers are
/// deliberately animation-free so that a moving marker means the station moved.
///
/// The second version fixed all that and was dull: a flat grey disc with a
/// number, carrying strictly less information than the markers it replaced. A
/// cluster hides between two and fifty stations, and which *kind* they are is
/// exactly what an operator loses when they fold together.
///
/// So the ring is a donut segmented by what is inside — digipeaters, weather,
/// vehicles, fixed stations — in the same four hues the dots and the legend
/// use. A cluster over a ridge full of digipeaters reads indigo; one over a
/// highway reads amber. The body is the colour of paper with the count in
/// ordinary text, so the marker reads as a container of things rather than as
/// a thing, and the number stays legible at every size. That is proportional
/// symbology with a class breakdown, which is how this has been done on paper
/// for a century, and it happens to look considerably better than a grey blob.
final class StationClusterAnnotationView: MKAnnotationView {

    static let reuseIdentifier = "station-cluster"

    private static let minimumDiameter: CGFloat = 22
    private static let maximumDiameter: CGFloat = 40
    /// Thickness of the composition ring.
    private static let ringWidth: CGFloat = 3.5
    /// Comfortable to click without stealing clicks from nearby stations.
    private static let hitSlop: CGFloat = 3

    /// One class present in the cluster, and how many of it.
    struct Slice {
        var color: PlatformColor
        var count: Int
    }

    /// Soft aura, so a group reads as a group without adding weight.
    private let halo = CAShapeLayer()
    /// Paper-coloured body the count sits on.
    private let body = CAShapeLayer()
    /// One arc per class present. Reused across configures.
    private var segments: [CAShapeLayer] = []
    private let count = PlatformLabel()
    private var hitRect: CGRect = .zero

    /// Same reasoning as the station dot: these layers are not view-backed, so
    /// every property change would otherwise animate of its own accord.
    private static let noImplicitAnimations: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(),
        "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(),
        "opacity": NSNull(), "hidden": NSNull(), "transform": NSNull(),
        "shadowOpacity": NSNull(), "shadowRadius": NSNull(), "shadowOffset": NSNull(),
    ]

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        #if os(macOS)
        wantsLayer = true
        layer?.masksToBounds = false
        #else
        clipsToBounds = false
        #endif
        canShowCallout = false
        collisionMode = .circle

        for shape in [halo, body] {
            shape.actions = Self.noImplicitAnimations
            hostLayer?.addSublayer(shape)
        }
        // A soft, low shadow lifts the marker off the terrain without the
        // heavy drop the balloon had.
        body.shadowColor = PlatformColor.black.cgColor
        body.shadowOpacity = 0.18
        body.shadowRadius = 2.5
        body.shadowOffset = CGSize(width: 0, height: 1)

        #if os(macOS)
        count.isBezeled = false
        count.isEditable = false
        count.isSelectable = false
        count.drawsBackground = false
        count.alignment = .center
        #else
        count.textAlignment = .center
        count.adjustsFontSizeToFitWidth = true
        count.minimumScaleFactor = 0.7
        #endif
        addSubview(count)
    }

    private var hostLayer: CALayer? {
        #if os(macOS)
        return layer
        #else
        return self.layer
        #endif
    }

    /// - Parameters:
    ///   - members: how many stations folded in.
    ///   - slices: the class breakdown, in a stable order so the ring does not
    ///     reshuffle between redraws.
    ///   - freshness: 0…1 from the most recently heard member, so a cluster of
    ///     long-silent stations recedes the way a long-silent dot does.
    func configure(members: Int, slices: [Slice], freshness: CGFloat) {
        let diameter = Self.diameter(for: members)
        let inset: CGFloat = 8
        let box = diameter + inset * 2
        frame = CGRect(x: 0, y: 0, width: box, height: box)

        let circle = CGRect(x: inset, y: inset, width: diameter, height: diameter)
        hitRect = circle.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop)

        // Aura in the dominant class's colour, very faint.
        let dominant = slices.max { $0.count < $1.count }?.color
            ?? PlatformColor.platformTertiaryLabel
        halo.frame = bounds
        halo.path = CGPath(ellipseIn: circle.insetBy(dx: -4, dy: -4), transform: nil)
        halo.fillColor = dominant.withAlphaComponent(0.16).cgColor
        halo.strokeColor = nil

        // The body sits inside the ring, so the ring reads as a rim rather
        // than as an outline drawn on top of a disc.
        let bodyRect = circle.insetBy(dx: Self.ringWidth, dy: Self.ringWidth)
        body.frame = bounds
        body.path = CGPath(ellipseIn: bodyRect, transform: nil)
        body.fillColor = Self.bodyColor.cgColor
        body.strokeColor = nil

        layOutSegments(slices: slices, in: circle)

        let text = members > 999 ? "999+" : String(members)
        let pointSize: CGFloat = diameter > 32 ? 13 : (diameter > 26 ? 12 : 10.5)
        #if os(macOS)
        count.stringValue = text
        count.textColor = .labelColor
        count.font = .monospacedDigitSystemFont(ofSize: pointSize, weight: .semibold)
        #else
        count.text = text
        count.textColor = .label
        count.font = .monospacedDigitSystemFont(ofSize: pointSize, weight: .semibold)
        #endif
        // Optical centring: a text baseline sits low in its own box.
        count.frame = CGRect(x: circle.minX, y: circle.midY - pointSize * 0.78,
                             width: circle.width, height: pointSize * 1.6)

        alphaOrAlphaValue = max(0.5, min(1, freshness))
        // Below the stations that stayed out of the cluster: a count is
        // context, and an individual station is the subject.
        displayPriority = .defaultLow
    }

    /// The composition ring. One stroked arc per class, with a hairline gap
    /// between them so two adjacent segments never read as one.
    private func layOutSegments(slices: [Slice], in circle: CGRect) {
        let present = slices.filter { $0.count > 0 }
        while segments.count < present.count {
            let shape = CAShapeLayer()
            shape.actions = Self.noImplicitAnimations
            shape.fillColor = nil
            shape.lineCap = .butt
            hostLayer?.insertSublayer(shape, above: body)
            segments.append(shape)
        }
        for (index, shape) in segments.enumerated() where index >= present.count {
            shape.isHidden = true
        }
        guard !present.isEmpty else { return }

        let total = CGFloat(present.reduce(0) { $0 + $1.count })
        let centre = CGPoint(x: circle.midX, y: circle.midY)
        let radius = (circle.width - Self.ringWidth) / 2
        // A gap only when there is more than one class; a single class draws
        // an unbroken rim.
        let gap: CGFloat = present.count > 1 ? 0.055 : 0
        var start = -CGFloat.pi / 2

        for (index, slice) in present.enumerated() {
            let sweep = (.pi * 2) * CGFloat(slice.count) / total
            let shape = segments[index]
            let path = CGMutablePath()
            path.addArc(center: centre, radius: radius,
                        startAngle: start + gap / 2,
                        endAngle: start + max(gap, sweep) - gap / 2,
                        clockwise: false)
            shape.frame = bounds
            shape.path = path
            shape.strokeColor = slice.color.cgColor
            shape.lineWidth = Self.ringWidth
            shape.isHidden = false
            start += sweep
        }
    }

    /// The colour of paper. Semantic, so it follows light and dark mode
    /// without this view knowing which it is in.
    private static var bodyColor: PlatformColor {
        #if os(macOS)
        return .windowBackgroundColor
        #else
        return .systemBackground
        #endif
    }

    /// Log scale. Fifty stations is more than five and should look it, but not
    /// ten times the ink — the count states the number, the size only ranks it.
    static func diameter(for members: Int) -> CGFloat {
        guard members > 1 else { return minimumDiameter }
        let grown = minimumDiameter + 5 * CGFloat(log2(Double(members)))
        return min(maximumDiameter, grown)
    }

    private var alphaOrAlphaValue: CGFloat {
        get {
            #if os(macOS)
            return alphaValue
            #else
            return alpha
            #endif
        }
        set {
            #if os(macOS)
            alphaValue = newValue
            #else
            alpha = newValue
            #endif
        }
    }

    // MARK: - Hit testing

    /// MapKit picks an annotation by its view's frame, so the frame is kept
    /// tight around the marker and this only trims the corners of that box.
    private func containsHit(_ point: CGPoint) -> Bool {
        hitRect.isEmpty ? bounds.contains(point) : hitRect.contains(point)
    }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard containsHit(local) else { return nil }
        return super.hitTest(point)
    }
    #else
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        containsHit(point)
    }
    #endif
}
