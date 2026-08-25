import Foundation
import CoreLocation

/// Writes the geometry model back out as GeoJSON.
///
/// `MKGeoJSONDecoder` reads GeoJSON; nothing in the system writes it. This is
/// the other half, and it earns its place three times over: it is how overlay
/// layers persist between launches, how an operator exports what they drew,
/// and — because it is plain text and compresses well — the only sane format
/// for putting a handful of marked positions over the air.
///
/// RFC 7946 order: **longitude first, then latitude**. The same trap as the
/// shapefile reader, from the opposite direction. A file written the wrong way
/// round loads back with every feature in the wrong hemisphere, and nothing
/// about it looks malformed.
nonisolated enum GeoJSONWriter {

    /// Coordinate precision.
    ///
    /// Six decimal places is about 11 cm — far finer than any position this
    /// app handles, and the point at which more digits are noise. It matters
    /// because those digits are bytes, and these files go over 1200 baud:
    /// full `Double` precision roughly doubles the size of a point for
    /// accuracy nobody has.
    static let coordinateDecimals = 6

    static func data(for layer: MapOverlayLayer, pretty: Bool = false) throws -> Data {
        let collection: [String: Any] = [
            "type": "FeatureCollection",
            "features": layer.features.map(feature(for:)),
        ]
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: collection, options: options)
    }

    static func feature(for feature: MapOverlayFeature) -> [String: Any] {
        var properties: [String: Any] = feature.attributes
        if !feature.name.isEmpty { properties["name"] = feature.name }
        return [
            "type": "Feature",
            "properties": properties,
            "geometry": geometry(for: feature.geometry),
        ]
    }

    static func geometry(for geometry: ShapefileReader.Geometry) -> [String: Any] {
        switch geometry {
        case .point(let coordinate):
            return ["type": "Point", "coordinates": pair(coordinate)]

        case .polyline(let parts):
            if parts.count == 1 {
                return ["type": "LineString", "coordinates": parts[0].map(pair)]
            }
            return ["type": "MultiLineString",
                    "coordinates": parts.map { $0.map(pair) }]

        case .polygon(let rings):
            // GeoJSON requires every ring closed — first point equal to last.
            // A shapefile ring usually is, but not always, and a reader that
            // is strict about it would reject a file this app wrote.
            return ["type": "Polygon", "coordinates": rings.map { closed($0).map(pair) }]
        }
    }

    /// `[longitude, latitude]`, per RFC 7946.
    ///
    /// Emitted as `NSDecimalNumber` rather than `Double`. Rounding a binary
    /// float to six decimals does not give a value six decimals can
    /// represent — `(39.0252556 * 1e6).rounded() / 1e6` is
    /// `39.02525600000001`, and `JSONSerialization` prints every digit of it.
    /// The rounding would then *cost* bytes instead of saving them, on files
    /// that go over 1200 baud. Going through a decimal string guarantees the
    /// printed form is the rounded one.
    static func pair(_ coordinate: CLLocationCoordinate2D) -> [NSDecimalNumber] {
        [decimal(coordinate.longitude), decimal(coordinate.latitude)]
    }

    static func decimal(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(coordinateDecimals)f", value))
    }

    static func closed(_ ring: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let first = ring.first, let last = ring.last, ring.count >= 3 else { return ring }
        let isClosed = abs(first.latitude - last.latitude) < 1e-12
            && abs(first.longitude - last.longitude) < 1e-12
        return isClosed ? ring : ring + [first]
    }

}
