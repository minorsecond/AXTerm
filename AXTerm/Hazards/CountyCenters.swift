import Foundation

/// Every US county's center and size, built into the app
/// (`Resources/us-county-centers.csv`, from the US Census Bureau's 2024
/// Gazetteer counties file, public domain: GEOID, internal point latitude
/// and longitude, land plus water area).
///
/// NWS alerts name the counties they cover by SAME code. With this table a
/// radius can tell that an alert on the Texas coast is far away without
/// downloading its zones' outlines. Live, 200 miles cost 116 outline
/// downloads, mostly to rule out the coast (Docs/HazardLayers.md §2).
nonisolated struct CountyCenters: Sendable {

    struct County: Equatable, Sendable {
        let center: GreatCircle.Point
        let squareMiles: Double
        /// As the Census names it, e.g. "Arapahoe County".
        var name = ""
        /// Two-letter state code.
        var state = ""

        /// "Arapahoe": the name without County, Parish, Borough and the like.
        var shortName: String {
            for suffix in [" County", " Parish", " Borough", " Census Area", " Municipality",
                           " City and Borough", " Municipio"] where name.hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
            }
            return name
        }

        /// Roughly how far from its center its edge lies.
        var radiusMiles: Double { (squareMiles / .pi).squareRoot() }
    }

    /// A county in a list, with how far its edge is from the station.
    struct Entry: Equatable, Sendable {
        let geoid: String
        let county: County
        /// To the county's edge, roughly; zero when the station is inside.
        let miles: Double
        var hasPosition = true

        /// For the list. Close in, the circle estimate cannot tell inside
        /// from next door, so it says close rather than a number.
        var distanceText: String {
            guard hasPosition else { return "" }
            return miles < 8 ? "Nearby" : "\(Int(miles.rounded())) mi"
        }
    }

    /// Whether an alert could come within a radius, judged by its counties.
    enum Reach: Equatable, Sendable {
        case near
        /// Every county it names is clearly outside the radius.
        case far
        /// It names no county the table knows; its outline decides.
        case unknown
    }

    private let counties: [String: County]

    /// The table built into the app; nil only if the resource is missing.
    static let bundled: CountyCenters? = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "us-county-centers", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return CountyCenters(csv: text)
    }()

    private final class BundleToken {}

    /// "geoid,lat,lon,sqmi,state,name" rows after a header line.
    init(csv: String) {
        var table: [String: County] = [:]
        for line in csv.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4, let lat = Double(fields[1]), let lon = Double(fields[2]),
                  let area = Double(fields[3]) else { continue }
            table[String(fields[0])] = County(center: GreatCircle.Point(latitude: lat, longitude: lon),
                                              squareMiles: area,
                                              name: fields.count > 5 ? String(fields[5]) : "",
                                              state: fields.count > 4 ? String(fields[4]) : "")
        }
        counties = table
    }

    var count: Int { counties.count }

    /// The state the station is in: that of the county it is nearest the
    /// edge of.
    func state(at point: GreatCircle.Point) -> String? {
        nearest(to: point, limit: 1).first?.county.state
    }

    /// Counties nearest first, by distance to each county's edge, so the
    /// county the station is in leads even when a neighbor's center is nearer.
    func nearest(to point: GreatCircle.Point, limit: Int) -> [Entry] {
        Array(entries(near: point).prefix(limit))
    }

    /// Counties whose name contains `text`, nearest first when there is a
    /// position, else by name. Nothing for an empty search.
    func search(_ text: String, near point: GreatCircle.Point?) -> [Entry] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let matches = counties.filter { $0.value.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        guard let point else {
            return matches.map { Entry(geoid: $0.key, county: $0.value, miles: 0, hasPosition: false) }
                .sorted { ($0.county.name, $0.county.state) < ($1.county.name, $1.county.state) }
        }
        return matches.map { entry(geoid: $0.key, county: $0.value, from: point) }.sorted { $0.miles < $1.miles }
    }

    /// One county as a list entry, with its distance when there is a
    /// position.
    func entry(_ geoid: String, from point: GreatCircle.Point?) -> Entry? {
        guard let county = counties[geoid] else { return nil }
        guard let point else { return Entry(geoid: geoid, county: county, miles: 0, hasPosition: false) }
        return entry(geoid: geoid, county: county, from: point)
    }

    private func entries(near point: GreatCircle.Point) -> [Entry] {
        counties.map { entry(geoid: $0.key, county: $0.value, from: point) }
            .sorted { ($0.miles, $0.geoid) < ($1.miles, $1.geoid) }
    }

    private func entry(geoid: String, county: County, from point: GreatCircle.Point) -> Entry {
        let centerMiles = GreatCircle.kilometres(from: point, to: county.center) * 0.621371
        return Entry(geoid: geoid, county: county, miles: max(0, centerMiles - county.radiusMiles))
    }

    func county(_ geoid: String) -> County? { counties[geoid] }

    /// A SAME code is a 0 and the county's five-digit Census code.
    static func geoid(fromSAME same: String) -> String? {
        guard same.count == 6, same.allSatisfy(\.isNumber), same.hasPrefix("0") else { return nil }
        return String(same.dropFirst())
    }

    /// Near when any county it names could come within the radius, allowing
    /// each county half again its own radius: a county's edge can be much
    /// nearer than its center, and a miss here hides a warning.
    func reach(of feature: HazardFeature, from point: GreatCircle.Point, miles: Double) -> Reach {
        let known = Self.sameCodes(of: feature).compactMap(Self.geoid(fromSAME:)).compactMap { counties[$0] }
        guard !known.isEmpty else { return .unknown }
        let near = known.contains { county in
            let centerMiles = GreatCircle.kilometres(from: point, to: county.center) * 0.621371
            let slack = (county.squareMiles / .pi).squareRoot() * 1.5
            return centerMiles - slack <= miles
        }
        return near ? .near : .far
    }

    /// The alert's `geocode.SAME` list, as the NWS feed gives it.
    static func sameCodes(of feature: HazardFeature) -> [String] {
        guard let json = feature.properties["geocode"]?.data(using: .utf8),
              let geocode = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        return geocode["SAME"] as? [String] ?? []
    }
}
