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
    /// Roughly a 20-mile-tall viewport — district zoom. Wider than that,
    /// every callsign at once just collides into an unreadable scatter, so
    /// labels come off and only the observer's and the selected station's
    /// names stay (the two worth ink at any zoom). Zoom in to read the rest.
    static let labelSpanThresholdDegrees = 0.3

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
    private static let size: CGFloat = 13
    private static let observerSize: CGFloat = 18
    /// A station beaconing an APRS symbol is drawn larger than a plain
    /// address dot: the glyph is the whole point of the marker, so it has to
    /// read as a symbol and not a speck, and the extra size also tells a
    /// live transmitted fix apart from a looked-up address at a glance.
    private static let aprsSize: CGFloat = 22

    /// How far outside the dot a click still counts.
    ///
    /// **This is the view's frame, not a hit-test override.** MapKit picks an
    /// annotation by its view's frame and never consults `hitTest`, so an
    /// override there does nothing — the frame has to *be* the target. The
    /// view used to be a fixed 96×56 so the callsign had room underneath, and
    /// the whole of that box selected the station: a click an inch away
    /// selected it, and on a crowded map it selected the wrong one.
    ///
    /// The label now hangs outside the frame instead, which costs nothing
    /// because a label was never meant to be clickable.
    ///
    /// A pointer is precise and a fingertip is not, so the two platforms get
    /// different padding: four points on the Mac, enough for a comfortable
    /// target on a touch screen.
    private static var hitPadding: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 4
        #endif
    }
    /// Width reserved for the callsign, which is drawn below the frame.
    private static let labelWidth: CGFloat = 96
    private static let labelHeight: CGFloat = 15

    private let fill = CAShapeLayer()
    private let ring = CAShapeLayer()
    /// An accent halo shown only while this station is the selection. Sits
    /// behind the dot so it reads as a ring around it, and carries a soft
    /// glow of the same colour so a selected marker is obvious even in a
    /// dense cluster.
    private let selectionHalo = CAShapeLayer()
    /// The dot's rect from the last configure, so the halo can be sized
    /// when selection flips without a full reconfigure.
    private var lastDotRect: CGRect = .zero
    /// A thin ring shown while the station has transmitted within
    /// `MapActivity.window` — "on the air just now".
    ///
    /// A ring, and deliberately **not** a pulse. Markers on this map are
    /// animation-free on purpose (see `noImplicitAnimations` below, and the
    /// same reasoning in `StationClusterAnnotationView`): a marker that moves
    /// means the station moved, and nothing else on the map is allowed to
    /// twitch. An animated "transmitting" pulse would spend that hard-won
    /// stillness on decoration, and on a channel carrying a frame every few
    /// seconds it would leave the map permanently blinking. A ring that is
    /// simply present or absent says the same thing and stays legible when a
    /// dozen of them are lit.
    private let activityRing = CAShapeLayer()
    /// The APRS glyph drawn over the dot — a car, a digipeater, a weather
    /// station. A plain `CALayer` whose `contents` is a white template image,
    /// kept separate from the two shape layers so the jitter-tuned dot
    /// geometry is never disturbed by it. Hidden for stations that beacon no
    /// symbol, for the observer, and for nodes.
    private let glyph = CALayer()
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
    private static var lastWindowOrigin: CGPoint?
    private static var windowMoves = 0
    private static var windowMaxDrift = 0.0
    private static var windowFraction = 0.0

    /// Where the map sits in the window, which is what pixel alignment is
    /// actually relative to. The map's own frame can read a constant 0,0
    /// inside its parent while an ancestor slides it a fraction of a point
    /// across the screen — and that is enough to flip every marker between
    /// two adjacent pixels.
    private var mapOriginInWindow: CGPoint? {
        guard let map = enclosingMap else { return nil }
        #if os(macOS)
        return map.convert(NSPoint.zero, to: nil)
        #else
        return map.convert(CGPoint.zero, to: nil)
        #endif
    }

    private static func noteMove(_ distance: Double, mapRect: MKMapRect?,
                                 windowOrigin: CGPoint?) {
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

        if let origin = windowOrigin {
            if let last = lastWindowOrigin {
                let dx = abs(origin.x - last.x), dy = abs(origin.y - last.y)
                if dx > 0 || dy > 0 { windowMoves += 1 }
                windowMaxDrift = max(windowMaxDrift, max(dx, dy))
            }
            lastWindowOrigin = origin
            windowFraction = max(windowFraction,
                                 max(origin.x - origin.x.rounded(.down),
                                     origin.y - origin.y.rounded(.down)))
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
                         rectChanges, rectMaxDrift, rectMaxZoom)
                  + String(format: "; map in window moved %d times (max %.4f pt, fraction %.4f)",
                           windowMoves, windowMaxDrift, windowFraction))
        }
        moveCount = 0
        moveMax = 0
        rectChanges = 0
        rectMaxDrift = 0
        rectMaxZoom = 0
        windowMoves = 0
        windowMaxDrift = 0
        windowFraction = 0
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
        glyph.actions = Self.noImplicitAnimations
        glyph.contentsGravity = .resizeAspect
        // A dark halo so the white glyph reads on any recency colour.
        glyph.shadowColor = PlatformColor.black.cgColor
        glyph.shadowOpacity = 0.45
        glyph.shadowRadius = 1
        glyph.shadowOffset = .zero
        glyph.isHidden = true
        selectionHalo.actions = Self.noImplicitAnimations
        activityRing.actions = Self.noImplicitAnimations
        activityRing.fillColor = nil
        activityRing.isHidden = true
        selectionHalo.fillColor = nil
        selectionHalo.isHidden = true
        host.addSublayer(selectionHalo)   // behind fill/ring/glyph
        host.addSublayer(activityRing)    // outside the dot, under it
        host.addSublayer(fill)
        host.addSublayer(ring)
        host.addSublayer(glyph)
        configureLabel()
        addSubview(label)
    }

    /// The callsign under the dot.
    ///
    /// `MKMarkerAnnotationView` drew this for free; a plain annotation view
    /// draws nothing, which is how the dots ended up anonymous. A halo
    /// rather than a plate, so a dense cluster of callsigns does not box in
    /// the terrain they sit on.
    /// The tint from the last `configure`, so the activity ring can be lit or
    /// cleared on its own without a full reconfigure.
    private var lastTint: PlatformColor = .clear

    /// Light update for the "just transmitted" ring alone.
    ///
    /// Exists so the ring can expire on a timer without touching anything else
    /// about the marker. A reconfigure would rebuild the paths, the label and
    /// the glyph, and this map pays real attention to not doing that: the
    /// whole annotation layer re-lays out when markers are rewritten, which is
    /// what made the dots shuffle on a timer before.
    func setActive(_ isActive: Bool) {
        setActivity(isActive, tint: lastTint, around: lastDotRect)
    }

    /// Draw (or clear) the "just transmitted" ring around the dot.
    ///
    /// It sits a little outside the marker so it never covers the APRS glyph
    /// or the recency tint, both of which carry their own meaning. The colour
    /// is the station's own tint rather than one alarm colour for everybody:
    /// the ring says *when*, and the map already says *what* — a second hue
    /// here would claim a meaning it does not have.
    private func setActivity(_ isActive: Bool, tint: PlatformColor, around dotRect: CGRect) {
        guard isActive else {
            activityRing.isHidden = true
            activityRing.path = nil
            return
        }
        let inset: CGFloat = -3
        let rect = dotRect.insetBy(dx: inset, dy: inset)
        activityRing.frame = bounds
        activityRing.path = CGPath(ellipseIn: rect, transform: nil)
        activityRing.strokeColor = tint.cgColor
        activityRing.lineWidth = 1.5
        activityRing.isHidden = false
    }

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
        overDarkBasemap = isDark
        applyLabelColours()
    }

    /// Remembered so the halo can be re-resolved when the appearance flips.
    private var overDarkBasemap = false

    /// Ink follows the basemap; the halo is the ink's opposite.
    ///
    /// Over imagery the ink is white and the halo black, whatever the
    /// system appearance. Over the standard map the ink is the system label
    /// colour — black in light mode, white in dark — and the halo has to be
    /// the system *background*, not a fixed white: in dark mode a white halo
    /// around white ink was a glow with no edge, and the callsigns were
    /// barely legible over the dark map. A shadow colour is a plain CGColor,
    /// resolved once, so it is re-applied on every appearance change.
    private func applyLabelColours() {
        #if os(iOS)
        let ink: UIColor = overDarkBasemap ? .white : .label
        let halo: UIColor = overDarkBasemap ? .black : .systemBackground
        label.textColor = ink
        label.layer.shadowColor = halo.resolvedColor(with: traitCollection).cgColor
        #else
        let ink: NSColor = overDarkBasemap ? .white : .labelColor
        let halo: NSColor = overDarkBasemap ? .black : .windowBackgroundColor
        label.textColor = ink
        effectiveAppearance.performAsCurrentDrawingAppearance {
            label.layer?.shadowColor = halo.cgColor
        }
        #endif
    }

    #if os(iOS)
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyLabelColours()
    }
    #else
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLabelColours()
    }
    #endif

    /// The selection accent — the system's own, so it matches every other
    /// selected control on the platform.
    private static var selectionColour: PlatformColor {
        #if os(macOS)
        return .controlAccentColor
        #else
        return .tintColor
        #endif
    }

    /// Sizes and shows/hides the selection halo from the current `isSelected`.
    /// A selected marker also rises above its neighbours so its halo is never
    /// clipped by a dot drawn later.
    private func updateSelectionHalo() {
        let expanded = lastDotRect.insetBy(dx: -4, dy: -4)
        selectionHalo.path = CGPath(ellipseIn: expanded, transform: nil)
        selectionHalo.frame = bounds
        selectionHalo.lineWidth = 3
        selectionHalo.strokeColor = Self.selectionColour.cgColor
        selectionHalo.shadowColor = Self.selectionColour.cgColor
        selectionHalo.shadowOpacity = isSelected ? 0.55 : 0
        selectionHalo.shadowRadius = 3
        selectionHalo.shadowOffset = .zero
        selectionHalo.isHidden = !isSelected
        host.zPosition = isSelected ? 2 : 0
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        updateSelectionHalo()
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
    /// - Parameter weatherBadge: one current reading to draw after the
    ///   callsign — a weather station's temperature. Already formatted; the
    ///   marker only places it.
    /// - Parameter isActive: the station transmitted within
    ///   `MapActivity.window`, so it wears the "just now" ring.
    func configure(tint: PlatformColor, isObserver: Bool, approximate: Bool,
                   isNode: Bool = false, callsign: String?,
                   aprsSymbol: APRSMapSymbol? = nil,
                   weatherBadge: String? = nil,
                   isActive: Bool = false) {
        // A station — or our own station — that carries a drawable APRS
        // symbol wears a larger marker so the glyph is legible; everything
        // else keeps the ordinary dot. A node keeps its diamond. Resolve the
        // glyph image up front, because whether one exists decides the size.
        let glyphImage: CGImage? = (!isNode && !approximate)
            ? aprsSymbol.flatMap {
                APRSGlyphRasterizer.image(table: $0.table, code: $0.code,
                                          diameter: Self.aprsSize)
            }
            : nil

        // A diamond reads at a slightly smaller size than a circle of the
        // same box, and infrastructure should sit quietly under traffic.
        let diameter = isObserver ? (glyphImage != nil ? Self.aprsSize : Self.observerSize)
            : isNode ? 12
            : glyphImage != nil ? Self.aprsSize
            : Self.size
        let ringWidth: CGFloat = isObserver ? 2.5 : 1.5

        // The frame is the dot plus a little slop, because the frame is what
        // MapKit uses to decide what a click hit. The callsign is drawn
        // outside it.
        let box = diameter + Self.hitPadding * 2
        frame = CGRect(x: 0, y: 0, width: box, height: box)
        #if os(iOS)
        clipsToBounds = false
        #else
        layer?.masksToBounds = false
        #endif

        // The dot is centred in the view, and the view is centred on the
        // coordinate, so the dot lands exactly on the position.
        let dotRect = CGRect(x: Self.hitPadding, y: Self.hitPadding,
                             width: diameter, height: diameter)
        let shapeRect = dotRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2)
        let path = isNode
            ? Self.diamondPath(in: shapeRect)
            : CGPath(ellipseIn: shapeRect, transform: nil)
        fill.path = path
        ring.path = path
        fill.frame = bounds
        ring.frame = bounds
        lastTint = tint
        setActivity(isActive, tint: tint, around: dotRect)

        setLabel(callsign, badge: weatherBadge, below: dotRect)

        // The APRS glyph, centred on the dot. Only for a heard station that
        // beaconed a symbol — never the observer, never a node (its diamond
        // and connector glyph already say what it is), never an inferred
        // lead (a symbol would assert a precision the position does not have).
        if let glyphImage {
            glyph.contents = glyphImage
            glyph.frame = dotRect
            glyph.isHidden = false
        } else {
            glyph.isHidden = true
            glyph.contents = nil
        }

        fill.fillColor = approximate
            ? tint.withAlphaComponent(0.22).cgColor
            : tint.cgColor
        ring.fillColor = nil
        ring.strokeColor = approximate
            ? tint.cgColor
            : PlatformColor.white.cgColor
        ring.lineWidth = ringWidth
        ring.lineDashPattern = approximate ? [3, 2] : nil

        fill.shadowColor = PlatformColor.black.cgColor
        fill.shadowOpacity = 0.22
        fill.shadowRadius = 2.5
        fill.shadowOffset = .zero

        lastDotRect = dotRect
        updateSelectionHalo()

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

    // The bouncing, finally pinned by the diagnostics above: with the camera
    // and the map's window position stone still, MapKit still re-runs
    // `_updateAnnotationViews` on every `mapLayerDidDraw` and re-snaps each
    // dot ~1.3pt between two neighbouring pixels — its own pixel-alignment
    // wobble, ~200 times a second. Nothing we draw causes it and nothing we
    // draw can stop it upstream, so we refuse it here: a re-position smaller
    // than a couple of points is dropped *unless the visible rect actually
    // moved since we last let one through*. A real pan or zoom changes the
    // rect every frame and its steps are far larger, so it tracks exactly;
    // an idle map simply stops shivering.
    /// The map this view is inside, found by walking up rather than being
    /// handed a reference, so neither the stabilizer nor the diagnostic needs
    /// wiring.
    private var enclosingMap: MKMapView? {
        var candidate = superview
        while let view = candidate {
            if let map = view as? MKMapView { return map }
            candidate = view.superview
        }
        return nil
    }

    private var lastAppliedRect: MKMapRect?

    /// True when this re-position is MapKit's idle pixel shiver, not motion:
    /// a sub-threshold hop while the camera has not moved since the last one
    /// we honoured. The threshold and the rule live in `MapFrameStability`
    /// beside the map-frame gate, and are pinned by `MapStabilityTests`.
    private func isIdleShiver(distance: CGFloat) -> Bool {
        guard let rect = enclosingMap?.visibleMapRect else { return false }
        let rectUnchanged = lastAppliedRect.map { last in
            rect.origin.x == last.origin.x && rect.origin.y == last.origin.y
                && rect.size.width == last.size.width && rect.size.height == last.size.height
        } ?? false
        if MapFrameStability.isAnnotationShiver(distance: distance, rectUnchanged: rectUnchanged) {
            return true
        }
        // The camera moved (or we have no reference yet): honour this move and
        // remember where the camera was when we did.
        lastAppliedRect = rect
        return false
    }

    #if os(macOS)
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let distance = hypot(newOrigin.x - frame.origin.x, newOrigin.y - frame.origin.y)
        if isIdleShiver(distance: distance) { return }
        #if DEBUG
        Self.noteMove(distance, mapRect: enclosingMap?.visibleMapRect,
                      windowOrigin: mapOriginInWindow)
        #endif
        super.setFrameOrigin(newOrigin)
    }
    #else
    override var center: CGPoint {
        get { super.center }
        set {
            let distance = hypot(newValue.x - super.center.x, newValue.y - super.center.y)
            if isIdleShiver(distance: distance) { return }
            #if DEBUG
            Self.noteMove(distance, mapRect: enclosingMap?.visibleMapRect,
                          windowOrigin: mapOriginInWindow)
            #endif
            super.center = newValue
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

    /// The callsign, plus one current reading after it when there is one.
    /// Kept as plain text rather than an attributed string: the label's colour
    /// is re-applied on every basemap change, and attributed runs would either
    /// fight that or have to duplicate it.
    private func setLabel(_ callsign: String?, badge: String?, below dot: CGRect) {
        var text = callsign ?? ""
        if !text.isEmpty, let badge, !badge.isEmpty {
            text += "  \(badge)"
        }
        hasLabelText = !text.isEmpty
        #if os(iOS)
        label.text = text
        #else
        label.stringValue = text
        #endif
        label.isHidden = text.isEmpty
        // Below the frame, not inside it: the frame is the click target and a
        // callsign is not a thing you click. Drawing outside the bounds is
        // fine because clipping is off on both platforms.
        label.frame = CGRect(x: (bounds.width - Self.labelWidth) / 2,
                             y: dot.maxY + 2,
                             width: Self.labelWidth,
                             height: Self.labelHeight)
    }


}
