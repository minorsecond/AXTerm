import MapKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A station on the map, drawn as a dot rather than a pin.
///
/// `MKMarkerAnnotationView` draws a balloon roughly 40pt tall with a shadow.
/// A handful of them over a city read as pushpins stuck through a paper map:
/// they dominate the terrain the operator is trying to judge, they cover the
/// ground immediately north of the station they mark, and the balloon's tip —
/// not its body — is the real position, which is easy to misread.
///
/// A dot sits *on* its coordinate, takes about a third of the area, and reuses
/// the colour vocabulary of the legend beside the map so the two read as one
/// thing. Size still carries meaning: this station is drawn larger, because
/// "where am I" is the question every other position is answered relative to.
final class StationDotAnnotationView: MKAnnotationView {

    static let reuseIdentifier = "station-dot"

    /// Diameter of an ordinary station, and of this one.
    private static let size: CGFloat = 15
    private static let observerSize: CGFloat = 19

    /// The view is far larger than the dot it draws.
    ///
    /// A 15pt view is a 15pt tap target, which is a third of the 44pt Apple
    /// asks for and in practice means taps land on the map instead of the
    /// station — the marker looks right and does nothing. The dot stays small
    /// and the *view* is comfortable, with the callsign sharing the space
    /// underneath.
    private static let hitWidth: CGFloat = 96
    private static let hitHeight: CGFloat = 56

    private let fill = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let label = PlatformLabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = true
        // A dot is centred on its coordinate; a pin is anchored at its tip.
        centerOffset = .zero
        // Two stations close together should both stay tappable rather than
        // one being suppressed for overlapping the other's padding.
        collisionMode = .circle
        #if os(macOS)
        wantsLayer = true
        #endif
        host.addSublayer(fill)
        host.addSublayer(ring)
        configureLabel()
        addSubview(label)
    }

    /// The callsign under the dot.
    ///
    /// `MKMarkerAnnotationView` drew this for free; a plain annotation view
    /// draws nothing, which is how the dots ended up anonymous. Rendered with
    /// a dark halo rather than a plate, so it stays readable over both the
    /// light and the dark basemap without boxing in the terrain.
    private func configureLabel() {
        #if os(iOS)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.layer.shadowColor = PlatformColor.black.cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        #else
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.layer?.shadowColor = PlatformColor.black.cgColor
        label.layer?.shadowOpacity = 0.9
        label.layer?.shadowRadius = 2
        label.layer?.shadowOffset = .zero
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `layer` is non-optional on UIKit and optional on AppKit; this hides
    /// the difference so the drawing below reads the same on both.
    private var host: CALayer {
        #if os(iOS)
        return layer
        #else
        if layer == nil { wantsLayer = true }
        return layer ?? CALayer()
        #endif
    }

    /// Applies the station's appearance.
    ///
    /// - Parameter approximate: a grid-square lead rather than a measured fix.
    ///   Drawn hollow and dashed, keeping the scope's convention, so an
    ///   inferred position can never be mistaken for a reported one.
    func configure(tint: PlatformColor, isObserver: Bool, approximate: Bool,
                   callsign: String?) {
        let diameter = isObserver ? Self.observerSize : Self.size
        let ringWidth: CGFloat = isObserver ? 3 : 2

        frame = CGRect(x: 0, y: 0, width: Self.hitWidth, height: Self.hitHeight)
        #if os(iOS)
        clipsToBounds = false
        #endif

        // The dot is centred in the view, and the view is centred on the
        // coordinate, so the dot lands exactly on the position.
        let dotRect = CGRect(
            x: (Self.hitWidth - diameter) / 2,
            y: (Self.hitHeight - diameter) / 2,
            width: diameter, height: diameter)
        let path = CGPath(ellipseIn: dotRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2),
                          transform: nil)
        fill.path = path
        ring.path = path
        fill.frame = bounds
        ring.frame = bounds

        setLabel(callsign, below: dotRect)

        fill.fillColor = approximate
            ? tint.withAlphaComponent(0.22).cgColor
            : tint.cgColor
        ring.fillColor = nil
        ring.strokeColor = approximate
            ? tint.cgColor
            : PlatformColor.white.withAlphaComponent(0.9).cgColor
        ring.lineWidth = ringWidth
        ring.lineDashPattern = approximate ? [3, 2] : nil

        fill.shadowColor = PlatformColor.black.cgColor
        fill.shadowOpacity = 0.3
        fill.shadowRadius = 2
        fill.shadowOffset = .zero

        // Never let MapKit declutter a station away.
        //
        // `.defaultHigh` permits hiding a marker whose collision frame
        // overlaps a neighbour's, and this view's frame is 96×56 to give a
        // finger something to hit — so two stations a few hundred metres
        // apart could collide at city zoom and one would silently vanish.
        // Field report 2026-08-25: N0HI-7 sits close to W0ARP-10 and was
        // simply absent from the map, while the header still counted it as
        // placed.
        //
        // A map of "who did we hear" that quietly omits stations is worse
        // than a crowded one: the omission is invisible, and the count in
        // the header contradicts it. Overlapping labels are a legibility
        // problem the operator can solve by zooming; a hidden station is not.
        displayPriority = .required
    }

    private func setLabel(_ callsign: String?, below dot: CGRect) {
        let text = callsign ?? ""
        #if os(iOS)
        label.text = text
        #else
        label.stringValue = text
        #endif
        label.isHidden = text.isEmpty
        label.frame = CGRect(x: 0, y: dot.maxY + 2,
                             width: Self.hitWidth,
                             height: Self.hitHeight - dot.maxY - 2)
    }
}
