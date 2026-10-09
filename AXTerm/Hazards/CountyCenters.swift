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

    /// "geoid,lat,lon,sqmi" rows after a header line.
    init(csv: String) {
        var table: [String: County] = [:]
        for line in csv.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",")
            guard fields.count == 4, let lat = Double(fields[1]), let lon = Double(fields[2]),
                  let area = Double(fields[3]) else { continue }
            table[String(fields[0])] = County(center: GreatCircle.Point(latitude: lat, longitude: lon),
                                              squareMiles: area)
        }
        counties = table
    }

    var count: Int { counties.count }

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
