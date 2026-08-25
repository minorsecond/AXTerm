import Foundation

/// Distance and bearing between two points on the earth.
///
/// One implementation, used by everything that needs it: the link-quality
/// placement rules, the station scope, and anything else that asks "how
/// far and which way". Spherical rather than ellipsoidal — the error is
/// well under a percent, which is far tighter than any antenna pattern
/// this is used to reason about.
nonisolated enum GreatCircle {

    /// Mean earth radius.
    static let earthRadiusKm = 6371.0

    struct Point: Equatable, Sendable {
        var latitude: Double
        var longitude: Double

        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        init(_ coordinate: Maidenhead.Coordinate) {
            self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    /// Haversine distance in kilometres.
    static func kilometres(from origin: Point, to destination: Point) -> Double {
        let dLat = radians(destination.latitude - origin.latitude)
        let dLon = radians(destination.longitude - origin.longitude)
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(radians(origin.latitude)) * cos(radians(destination.latitude))
            * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// Initial **true** bearing in degrees, 0 = north, clockwise.
    ///
    /// The initial bearing, not the average: on a long path the great
    /// circle curves, and the direction you point the antenna is the one
    /// at your end.
    static func bearingDegrees(from origin: Point, to destination: Point) -> Double {
        let lat1 = radians(origin.latitude)
        let lat2 = radians(destination.latitude)
        let dLon = radians(destination.longitude - origin.longitude)

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = degrees(atan2(y, x))
        // atan2 returns −180…180; compass bearings are 0…360.
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Compass point for a bearing: "NNE", "SW". Sixteen-point rose —
    /// finer than that reads as precision the estimate does not have.
    static func compassPoint(_ bearingDegrees: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                     "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let normalized = (bearingDegrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let index = Int((normalized / 22.5).rounded()) % names.count
        return names[index]
    }

    static func miles(fromKilometres kilometres: Double) -> Double {
        kilometres / 1.609344
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

extension GreatCircle {

    /// Mean Earth radius in metres, as used for the great-circle maths above.
    static let earthRadiusMetres = 6_371_008.8

    /// A point a fraction of the way along the great circle from one point to
    /// another.
    ///
    /// Spherical interpolation rather than linear: over a 100 km VHF path the
    /// two differ by hundreds of metres, and a terrain profile sampled along
    /// the wrong line is a profile of the wrong ridge.
    static func interpolate(from origin: Point, to destination: Point,
                            fraction: Double) -> Point {
        let lat1 = radians(origin.latitude), lon1 = radians(origin.longitude)
        let lat2 = radians(destination.latitude), lon2 = radians(destination.longitude)

        let deltaLat = lat2 - lat1, deltaLon = lon2 - lon1
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let angle = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))

        // Coincident points have no defined bearing between them; returning
        // the origin is correct and avoids dividing by sin(0).
        guard angle > 1e-12 else { return origin }

        let scaleA = sin((1 - fraction) * angle) / sin(angle)
        let scaleB = sin(fraction * angle) / sin(angle)

        let x = scaleA * cos(lat1) * cos(lon1) + scaleB * cos(lat2) * cos(lon2)
        let y = scaleA * cos(lat1) * sin(lon1) + scaleB * cos(lat2) * sin(lon2)
        let z = scaleA * sin(lat1) + scaleB * sin(lat2)

        return Point(latitude: degrees(atan2(z, sqrt(x * x + y * y))),
                     longitude: degrees(atan2(y, x)))
    }

    /// Evenly spaced points along the path, inclusive of both ends.
    static func samplePath(from origin: Point, to destination: Point,
                           count: Int) -> [Point] {
        guard count >= 2 else { return [origin, destination] }
        return (0..<count).map {
            interpolate(from: origin, to: destination,
                        fraction: Double($0) / Double(count - 1))
        }
    }
}
