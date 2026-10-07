import Foundation

/// Where the map draws this station, against GPS noise.
///
/// Standing still, successive fixes wander a few meters, and redrawing at
/// each one twitched the whole network around our dot, so the drawn
/// position holds until a fix moves past the noise floor. Moving, that
/// rounding made the arrow step 25 m at a time out of time with the camera,
/// so a moving station is drawn where it is (operator, 2026-10-07).
nonisolated enum OwnPositionAnchor {
    static let noiseFloorMetres = 25.0

    static func drawn(held: GreatCircle.Point?, live: GreatCircle.Point, speed: Double?) -> GreatCircle.Point {
        guard let held, (speed ?? 0) < MapFollow.courseNeedsSpeed else { return live }
        return GreatCircle.kilometres(from: held, to: live) * 1000 < noiseFloorMetres ? held : live
    }
}
