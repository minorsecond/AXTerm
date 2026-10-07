import CoreGraphics
import Foundation

/// The station's own marker as an arrow pointing the way it travels
/// (operator, 2026-10-07): along the GPS course, turned against the map's
/// rotation, so in the heading view it points straight up. Standing still
/// a GPS course is noise, so the marker stays a dot.
nonisolated enum OwnMarkerArrow {
    /// Degrees clockwise to turn the arrow on screen; nil draws the dot.
    static func rotation(courseDegrees: Double?, speed: Double?, mapHeading: Double) -> Double? {
        guard let course = courseDegrees, course >= 0,
              (speed ?? 0) >= MapFollow.courseNeedsSpeed else { return nil }
        let turn = (course - mapHeading).truncatingRemainder(dividingBy: 360)
        return turn < 0 ? turn + 360 : turn
    }

    /// A navigation arrow in a square of `size`, pointing up: a tip, two
    /// swept-back wings and a notch between them.
    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        path.move(to: point(0.5, 0.04))
        path.addLine(to: point(0.9, 0.92))
        path.addLine(to: point(0.5, 0.7))
        path.addLine(to: point(0.1, 0.92))
        path.closeSubpath()
        return path
    }
}
