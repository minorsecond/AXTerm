import CoreGraphics

/// Whether a proposed frame for the map is a real change or layout noise.
///
/// MapKit re-projects on every presented frame and re-anchors every
/// annotation view to pixel boundaries as it goes
/// (`-[MKAnnotationView _updateAnchorPosition:alignToPixels:]`, reached from
/// `mapLayerDidDraw:`). So a map whose size wobbles by a fraction of a point
/// moves every marker on it, by up to a point, for as long as the wobble
/// lasts — a jitter with no cause visible anywhere in the app's own data,
/// because there isn't one: the data is still, and the projection is not.
///
/// A change smaller than a point cannot be seen. It is not worth a
/// re-projection, and swallowing it is what keeps the markers still.
///
/// Rounding instead of ignoring does not work, and measurably makes it
/// worse: a width alternating between 1200.0 and 1200.5 rounds to 1200 and
/// 1201, which is the same oscillation a point wider.
nonisolated enum MapFrameStability {

    /// Below this, a change is layout noise rather than a resize.
    static let threshold: CGFloat = 1

    static func isRealChange(_ proposed: CGFloat, current: CGFloat) -> Bool {
        abs(proposed - current) >= threshold
    }

    static func isRealResize(width: CGFloat, height: CGFloat,
                             currentWidth: CGFloat, currentHeight: CGFloat) -> Bool {
        isRealChange(width, current: currentWidth)
            || isRealChange(height, current: currentHeight)
    }

    static func isRealMove(x: CGFloat, y: CGFloat,
                           currentX: CGFloat, currentY: CGFloat) -> Bool {
        isRealChange(x, current: currentX) || isRealChange(y, current: currentY)
    }

    /// Whole points, always down. Combined with the threshold above, a size
    /// that drifts inside one point resolves to a single stable value rather
    /// than flipping between two.
    static func settled(_ value: CGFloat) -> CGFloat { value.rounded(.down) }
}
