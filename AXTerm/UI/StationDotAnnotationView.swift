import MapKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// When callsign labels are worth their ink.
///
/// At metro zoom every marker's label is legible and wanted; zoomed out
/// to a state, thirty labels pile onto a few square centimetres and bury
/// both each other and the place names under them (field capture
/// 2026-08-29: "the cartography is pretty rough"). Below the threshold
/// the dots alone carry the picture — colour and shape still read — and
/// the labels return as the operator zooms in.
nonisolated enum MapLabelPolicy {
    /// Roughly a 50-mile-tall viewport. Wider than that, labels come off.
    static let labelSpanThresholdDegrees = 0.7

    static func showsLabels(latitudeDelta: Double) -> Bool {
        latitudeDelta < labelSpanThresholdDegrees
    }
}

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

    /// Implicit animation is the default for a bare `CALayer`, and it is
    /// never wanted here. These layers are not view-backed, so setting a
    /// path or a colour on one starts a quarter-second animation of its
    /// own accord — a marker whose recency tint changes should snap to the
    /// new colour, and one MapKit repositions should arrive where it was
    /// put rather than easing toward it.
    private static let noImplicitAnimations: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(),
        "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(),
        "lineDashPattern": NSNull(), "shadowOpacity": NSNull(),
        "shadowRadius": NSNull(), "shadowOffset": NSNull(),
        "transform": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
        "contents": NSNull()
    ]

    #if DEBUG
    /// Counts how often MapKit repositions a marker on screen, which is the
    /// phenomenon actually being reported. Every other mutation the map
    /// makes is already logged and none of them fire while the points move,
    /// so the movement is either MapKit's or nobody's.
    private static var moveCount = 0
    private static var moveWindow = Date.distantPast
    private static var moveMax = 0.0
    private static var stackWindows = 0
    private static var wantsStack = false
    private static var lastRect: MKMapRect?
    private static var rectChanges = 0
    private static var rectMaxDrift = 0.0
    private static var rectMaxZoom = 0.0

    /// The map this view is inside, found by walking up rather than being
    /// handed down, so the diagnostic needs no wiring.
    private var enclosingMap: MKMapView? {
        var candidate = superview
        while let view = candidate {
            if let map = view as? MKMapView { return map }
            candidate = view.superview
        }
        return nil
    }

    private static func noteMove(_ distance: Double, mapRect: MKMapRect?) {
        guard distance > 0.01 else { return }
        moveCount += 1
        moveMax = max(moveMax, distance)

        // The discriminator. If the visible rect is identical between two
        // moves, the camera is still and MapKit is re-snapping to pixels for
        // its own reasons. If it drifts, something is re-projecting the map,
        // and the size hypothesis was only one way that could happen.
        if let rect = mapRect {
            if let last = lastRect {
                let dx = abs(rect.origin.x - last.origin.x)
                let dy = abs(rect.origin.y - last.origin.y)
                let dw = abs(rect.size.width - last.size.width)
                if dx > 0 || dy > 0 || dw > 0 { rectChanges += 1 }
                rectMaxDrift = max(rectMaxDrift, max(dx, dy))
                rectMaxZoom = max(rectMaxZoom, dw)
            }
            lastRect = rect
        }

        // Who is actually calling. Every theory about *what* moves these
        // markers has been wrong, and the stack does not need a theory —
        // captured once per window, since symbolicating on every move would
        // itself be the load.
        if wantsStack {
            wantsStack = false
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(14)
                .map { line -> String in
                    // Keep the symbol, drop the address columns.
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    return parts.count > 3 ? parts[1...].joined(separator: " ") : line
                }
            print("[MAPDIAG] marker move stack:\n  " + frames.joined(separator: "\n  "))
        }

        let elapsed = Date().timeIntervalSince(moveWindow)
        guard elapsed >= 5 else { return }
        if moveWindow != .distantPast {
            print(String(format: "[MAPDIAG] MapKit moved markers %d times in %.1fs (max %.1f pt); visible rect changed %d times (max drift %.3f, zoom %.3f)",
                         moveCount, elapsed, moveMax,
                         rectChanges, rectMaxDrift, rectMaxZoom))
        }
        moveCount = 0
        moveMax = 0
        rectChanges = 0
        rectMaxDrift = 0
        rectMaxZoom = 0
        moveWindow = Date()
        // One stack per window, and skip the first: that window is the
        // initial layout, which is legitimate and not what is being chased.
        stackWindows += 1
        wantsStack = stackWindows >= 2 && stackWindows <= 4
    }
    #endif

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // No MapKit callout: selecting a station opens the selection
        // card, which carries the full detail, planned route and
        // Connect. The built-in bubble showed beside it as a second,
        // poorer popup (field capture 2026-08-29 06:48).
        canShowCallout = false
        // A dot is centred on its coordinate; a pin is anchored at its tip.
        centerOffset = .zero
        // Two stations close together should both stay tappable rather than
        // one being suppressed for overlapping the other's padding.
        collisionMode = .circle
        #if os(macOS)
        wantsLayer = true
        #endif
        fill.actions = Self.noImplicitAnimations
        ring.actions = Self.noImplicitAnimations
        host.addSublayer(fill)
        host.addSublayer(ring)
        configureLabel()
        addSubview(label)
    }

    /// The callsign under the dot.
    ///
    /// `MKMarkerAnnotationView` drew this for free; a plain annotation view
    /// draws nothing, which is how the dots ended up anonymous. A halo
    /// rather than a plate, so a dense cluster of callsigns does not box in
    /// the terrain they sit on.
    private func configureLabel() {
        #if os(iOS)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = 1.5
        label.layer.shadowOffset = .zero
        #else
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.layer?.shadowOpacity = 1
        label.layer?.shadowRadius = 1.5
        label.layer?.shadowOffset = .zero
        #endif
        setOverDarkBasemap(false)
    }

    /// Matches the label to the basemap under it.
    ///
    /// This used to be white with a black glow on every basemap, on the
    /// theory that one halo would carry both. It does not: a blurred shadow
    /// is not an outline, so white-on-light-grey left the callsigns — the
    /// operator's own among them — barely legible on the standard map. Ink
    /// takes the basemap's contrast and the halo takes the opposite, which
    /// is how a paper map has always done it.
    func setOverDarkBasemap(_ isDark: Bool) {
        let halo: PlatformColor = isDark ? .black : .white
        #if os(iOS)
        label.textColor = isDark ? .white : .label
        label.layer.shadowColor = halo.cgColor
        #else
        label.textColor = isDark ? .white : .labelColor
        label.layer?.shadowColor = halo.cgColor
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
    /// - Parameter isNode: NET/ROM infrastructure rather than a heard
    ///   station — drawn as a diamond, so the network's fixtures read apart
    ///   from the traffic at any zoom.
    func configure(tint: PlatformColor, isObserver: Bool, approximate: Bool,
                   isNode: Bool = false, callsign: String?) {
        // A diamond reads at a slightly smaller size than a circle of the
        // same box, and infrastructure should sit quietly under traffic.
        let diameter = isObserver ? Self.observerSize : (isNode ? 13 : Self.size)
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
        let shapeRect = dotRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2)
        let path = isNode
            ? Self.diamondPath(in: shapeRect)
            : CGPath(ellipseIn: shapeRect, transform: nil)
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

    #if os(macOS)
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        #if DEBUG
        Self.noteMove(hypot(newOrigin.x - frame.origin.x, newOrigin.y - frame.origin.y),
                      mapRect: enclosingMap?.visibleMapRect)
        #endif
        super.setFrameOrigin(newOrigin)
    }
    #else
    override var center: CGPoint {
        didSet {
            #if DEBUG
            Self.noteMove(hypot(center.x - oldValue.x, center.y - oldValue.y),
                          mapRect: enclosingMap?.visibleMapRect)
            #endif
        }
    }
    #endif

    /// A rotated square, point-up — the node marker's silhouette.
    private static func diamondPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    /// Whether this marker has a label at all — distinct from whether the
    /// zoom level currently shows it.
    private var hasLabelText = false

    /// Zoom-driven visibility: the dot stays, the label comes and goes.
    func setLabelVisible(_ visible: Bool) {
        label.isHidden = !visible || !hasLabelText
    }

    private func setLabel(_ callsign: String?, below dot: CGRect) {
        let text = callsign ?? ""
        hasLabelText = !text.isEmpty
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
