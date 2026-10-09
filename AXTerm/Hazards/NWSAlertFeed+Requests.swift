import Foundation

/// Asking the NWS for alerts and zone outlines, and turning zone-based
/// products into shapes (Docs/HazardLayers.md §2, §4).
extension NWSAlertFeed {

    /// The NWS asks callers to identify themselves. AXTerm gives its name and
    /// the project's address, never the operator's email.
    static let userAgent = "AXTerm (https://github.com/minorsecond/AXTerm)"

    /// Active alerts for a point. Four decimals (about 11 m) is as fine as
    /// the API takes.
    static func alertsRequest(near point: GreatCircle.Point) -> URLRequest {
        let point = String(format: "%.4f,%.4f", point.latitude, point.longitude)
        return request(URL(string: "https://api.weather.gov/alerts/active?point=\(point)")!)
    }

    static func zoneRequest(_ url: URL) -> URLRequest {
        request(url)
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The full address of each zone a product covers. A zone can be a
    /// county, a forecast zone or a fire zone, so the address is kept rather
    /// than rebuilt from the code.
    static func zoneURLs(of feature: HazardFeature) -> [URL] {
        guard let json = feature.properties["affectedZones"]?.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: json) as? [String] else { return [] }
        return list.compactMap(URL.init(string:))
    }

    /// Products without a polygon take the shape of their zones, but only
    /// when every zone is known. A half-drawn warning area looks like the
    /// whole one, and somebody may plan around it.
    static func resolvingZones(_ features: [HazardFeature], outlines: [String: Zone]) -> [HazardFeature] {
        features.map { feature in
            guard feature.geometry == nil, !feature.zoneIDs.isEmpty else { return feature }
            var polygons: [[[GreatCircle.Point]]] = []
            for id in feature.zoneIDs {
                guard case let .polygons(zonePolygons)? = outlines[id]?.geometry else { return feature }
                polygons += zonePolygons
            }
            var resolved = feature
            resolved.geometry = .polygons(polygons)
            return resolved
        }
    }

    /// Zone outlines still to fetch for products without a polygon: those
    /// not cached, each once.
    static func zonesToFetch(for features: [HazardFeature], cached: Set<String>) -> [URL] {
        var seen = cached
        var urls: [URL] = []
        for feature in features where feature.geometry == nil {
            for url in zoneURLs(of: feature) where !seen.contains(url.lastPathComponent) {
                seen.insert(url.lastPathComponent)
                urls.append(url)
            }
        }
        return urls
    }
}
