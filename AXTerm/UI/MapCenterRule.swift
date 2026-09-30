import Foundation

/// Where the station map is drawn around.
///
/// Around this station when its position is known. Without one the map
/// used to show only "No position for this station" and hide every heard
/// station. Now it centers on the heard stations instead and leaves out the
/// distances, which would be measured from nowhere real. Only with neither
/// is there nothing to draw.
nonisolated enum MapCenterRule {
    enum Center: Equatable, Sendable {
        /// This station's own position: distances and bearings are real.
        case ownStation(GreatCircle.Point)
        /// The middle of the heard stations: somewhere to draw around, and
        /// nothing to measure from.
        case heardStations(GreatCircle.Point)

        var point: GreatCircle.Point {
            switch self {
            case .ownStation(let point), .heardStations(let point): return point
            }
        }

        /// Whether distances and bearings may be shown.
        var showsDistances: Bool {
            if case .ownStation = self { return true }
            return false
        }
    }

    static func center(own: GreatCircle.Point?, heard: [GreatCircle.Point]) -> Center? {
        if let own { return .ownStation(own) }
        return centroid(of: heard).map(Center.heardStations)
    }

    /// The middle of a set of points, averaged as unit vectors so stations
    /// either side of the antimeridian do not average to the far side of the
    /// planet. Nil for no points.
    static func centroid(of points: [GreatCircle.Point]) -> GreatCircle.Point? {
        guard !points.isEmpty else { return nil }
        var x = 0.0, y = 0.0, z = 0.0
        for point in points {
            let lat = point.latitude * .pi / 180
            let lon = point.longitude * .pi / 180
            x += cos(lat) * cos(lon)
            y += cos(lat) * sin(lon)
            z += sin(lat)
        }
        let count = Double(points.count)
        x /= count; y /= count; z /= count
        let lon = atan2(y, x)
        let lat = atan2(z, (x * x + y * y).squareRoot())
        return GreatCircle.Point(latitude: lat * 180 / .pi, longitude: lon * 180 / .pi)
    }
}
