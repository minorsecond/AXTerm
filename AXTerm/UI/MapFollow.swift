import CoreLocation
import Foundation

/// The map following the station: the "show me" button and the
/// navigation-style view (operator, 2026-10-07, after a drive where the
/// iPhone's map never moved). Pure, so both map renderers draw the same
/// camera and the choices can be tested.
nonisolated enum MapFollow {
    enum Mode: String, Equatable, Sendable {
        /// The operator moves the map.
        case free
        /// Centered on the station, north up.
        case follow
        /// Turned with the direction of travel and tilted, like a
        /// navigation app.
        case heading

        /// The button's next state: follow, then heading, then let go.
        var next: Mode {
            switch self {
            case .free: .follow
            case .follow: .heading
            case .heading: .free
            }
        }
    }

    struct Camera: Equatable, Sendable {
        var center: CLLocationCoordinate2D
        var distanceMeters: Double
        var heading: Double
        var pitch: Double

        static func == (a: Camera, b: Camera) -> Bool {
            a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude
                && a.distanceMeters == b.distanceMeters && a.heading == b.heading && a.pitch == b.pitch
        }
    }

    /// How far a navigation view tilts.
    static let navigationPitch: Double = 45

    /// Below this a GPS course is noise: a station standing still or
    /// walking slowly reports one that wanders.
    static let courseNeedsSpeed: Double = 1.5

    /// Where the camera sits and looks. Nil when the operator has the map.
    ///
    /// The view widens with speed, from about a kilometer and a half on foot
    /// to several at highway speed, so what is ahead stays on screen. Heading
    /// mode turns the map with the course, tilts it, and looks ahead, so the
    /// station sits low on the screen with the road above it.
    static func camera(mode: Mode, at point: GreatCircle.Point, courseDegrees: Double?,
                       speedMetersPerSecond: Double?, lastHeading: Double = 0) -> Camera? {
        let speed = max(0, speedMetersPerSecond ?? 0)
        let distance = min(10_000, 1_500 + speed * 150)
        let center = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        switch mode {
        case .free:
            return nil
        case .follow:
            return Camera(center: center, distanceMeters: distance, heading: 0, pitch: 0)
        case .heading:
            let heading: Double
            if let course = courseDegrees, course >= 0, speed >= courseNeedsSpeed {
                heading = course
            } else {
                heading = lastHeading
            }
            // Tilted, the same distance looks much closer, so the camera
            // backs off; and it looks ahead only far enough to keep the
            // station in the lower third (a quarter put it off the bottom
            // edge in the simulator).
            let tilted = distance * 1.5
            return Camera(center: offset(center, meters: tilted * 0.14, bearing: heading),
                          distanceMeters: tilted, heading: heading, pitch: navigationPitch)
        }
    }

    private static func offset(_ c: CLLocationCoordinate2D, meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let radians = bearing * .pi / 180
        let metersPerDegree = 111_320.0
        return CLLocationCoordinate2D(
            latitude: c.latitude + meters * cos(radians) / metersPerDegree,
            longitude: c.longitude + meters * sin(radians) / (metersPerDegree * cos(c.latitude * .pi / 180)))
    }
}
