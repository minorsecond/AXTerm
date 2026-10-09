import Foundation

/// NWS watches, warnings and advisories from `api.weather.gov/alerts`
/// (Docs/HazardLayers.md §2).
///
/// A storm-based warning carries its own polygon. A zone-based product (Red
/// Flag, Winter Storm, Wind) has none and lists the zones it covers; their
/// outlines come from `/zones` once and are cached.
nonisolated enum NWSAlertFeed {

    enum ParseError: Error, Equatable {
        case notGeoJSON
    }

    /// A zone's outline, from `/zones/{type}/{id}`.
    struct Zone: Equatable, Sendable {
        let id: String
        let name: String
        let geometry: HazardFeature.Geometry?
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> [HazardFeature] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw ParseError.notGeoJSON }
        return features.compactMap { feature(from: $0, fetchedAt: fetchedAt) }
    }

    static func parseZone(_ data: Data) throws -> Zone {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = root["properties"] as? [String: Any],
              let id = properties["id"] as? String else { throw ParseError.notGeoJSON }
        return Zone(id: id, name: properties["name"] as? String ?? id,
                    geometry: geometry(from: root["geometry"]))
    }

    /// Warning, watch or advisory by the event's last word; everything else
    /// the NWS issues (statements, outlooks, messages) is a statement.
    static func kind(of event: String) -> HazardFeature.Kind {
        let last = event.split(separator: " ").last.map { $0.lowercased() } ?? ""
        switch last {
        case "warning": return .warning
        case "watch": return .watch
        case "advisory": return .advisory
        default: return .statement
        }
    }

    // MARK: - Reading

    private static func feature(from json: [String: Any], fetchedAt: Date) -> HazardFeature? {
        guard let p = json["properties"] as? [String: Any],
              let id = (p["id"] as? String) ?? (json["id"] as? String),
              let event = p["event"] as? String else { return nil }
        var feature = HazardFeature(id: id, kind: kind(of: event), event: event,
                                    source: p["senderName"] as? String ?? "NWS", fetchedAt: fetchedAt)
        feature.headline = p["headline"] as? String
        feature.severity = p["severity"] as? String
        feature.issued = (p["sent"] as? String).flatMap(date)
        feature.expires = ((p["ends"] as? String) ?? (p["expires"] as? String)).flatMap(date)
        feature.geometry = geometry(from: json["geometry"])
        feature.zoneIDs = (p["affectedZones"] as? [String] ?? []).compactMap { $0.split(separator: "/").last.map(String.init) }
        feature.properties = p.compactMapValues(text)
        return feature
    }

    /// GeoJSON Polygon and MultiPolygon; coordinates are [longitude, latitude].
    static func geometry(from json: Any?) -> HazardFeature.Geometry? {
        guard let g = json as? [String: Any], let type = g["type"] as? String else { return nil }
        switch type {
        case "Polygon":
            guard let rings = g["coordinates"] as? [[[Double]]] else { return nil }
            return .polygons([rings.map(points)])
        case "MultiPolygon":
            guard let polygons = g["coordinates"] as? [[[[Double]]]] else { return nil }
            return .polygons(polygons.map { $0.map(points) })
        case "Point":
            guard let c = g["coordinates"] as? [Double], c.count >= 2 else { return nil }
            return .point(GreatCircle.Point(latitude: c[1], longitude: c[0]))
        default:
            return nil
        }
    }

    private static func points(_ ring: [[Double]]) -> [GreatCircle.Point] {
        ring.compactMap { $0.count >= 2 ? GreatCircle.Point(latitude: $0[1], longitude: $0[0]) : nil }
    }

    private static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    /// A property as text: strings as they are, anything else as JSON.
    private static func text(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(data: data, encoding: .utf8)
        }
        return "\(value)"
    }
}
