import Foundation

/// Whether a position falls inside a hazard, for the "Inside: Red Flag
/// Warning until 8:00 pm" line on the map and in car mode.
nonisolated enum HazardContainment {

    /// Inside any polygon's outer ring and none of its holes. A point
    /// hazard contains nothing.
    static func contains(_ geometry: HazardFeature.Geometry, _ point: GreatCircle.Point) -> Bool {
        guard case let .polygons(polygons) = geometry else { return false }
        return polygons.contains { rings in
            guard let outer = rings.first, ringContains(outer, point) else { return false }
            return !rings.dropFirst().contains { ringContains($0, point) }
        }
    }

    /// Even-odd ray casting in degrees. Fine at the size of a warning or a
    /// county; no hazard here crosses the antimeridian or a pole.
    static func ringContains(_ ring: [GreatCircle.Point], _ point: GreatCircle.Point) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude) {
                let crossing = (b.longitude - a.longitude) * (point.latitude - a.latitude)
                    / (b.latitude - a.latitude) + a.longitude
                if point.longitude < crossing { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
