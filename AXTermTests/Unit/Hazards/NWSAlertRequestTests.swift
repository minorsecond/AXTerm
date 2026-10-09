import XCTest
@testable import AXTerm

/// Asking the NWS for alerts, and turning zone-based products into shapes
/// (Docs/HazardLayers.md §2, §4).
final class NWSAlertRequestTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_791_590_000)

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: NWSAlertRequestTests.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    // MARK: - The request

    /// Alerts for a point, rounded to four decimals (about 11 m), which is as
    /// fine as the API takes.
    func testAlertsAreAskedForAtThePointRoundedToFourDecimals() throws {
        let request = NWSAlertFeed.alertsRequest(near: GreatCircle.Point(latitude: 39.6123451780266,
                                                                         longitude: -104.73324202119228))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.weather.gov/alerts/active?point=39.6123,-104.7332")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/geo+json")
    }

    /// The NWS asks callers to identify themselves. AXTerm gives its name and
    /// the project's address, never the operator's email.
    func testTheRequestNamesAXTermAndCarriesNoEmail() throws {
        let agent = try XCTUnwrap(NWSAlertFeed.alertsRequest(
            near: GreatCircle.Point(latitude: 39.6, longitude: -104.7)).value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(agent, "AXTerm (https://github.com/minorsecond/AXTerm)")
        XCTAssertFalse(agent.contains("@"))
    }

    func testAZoneIsAskedForAtItsOwnAddressWithTheSameIdentity() {
        let url = URL(string: "https://api.weather.gov/zones/county/COC007")!
        let request = NWSAlertFeed.zoneRequest(url)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"),
                       "AXTerm (https://github.com/minorsecond/AXTerm)")
    }

    // MARK: - Zones

    /// A zone can be a county, a forecast zone or a fire zone, so its full
    /// address is kept rather than rebuilt from the code.
    func testAZoneBasedProductsZoneAddressesAreKept() throws {
        let outlook = try XCTUnwrap(try NWSAlertFeed.parse(try fixture("nws-alerts-zones"), fetchedAt: fetchedAt).first)
        let urls = NWSAlertFeed.zoneURLs(of: outlook)
        XCTAssertEqual(urls.count, 18)
        XCTAssertEqual(urls.first?.absoluteString, "https://api.weather.gov/zones/county/COC007")
    }

    private func zone(_ id: String, _ lat: Double) -> NWSAlertFeed.Zone {
        let ring = [GreatCircle.Point(latitude: lat, longitude: -105),
                    GreatCircle.Point(latitude: lat, longitude: -104),
                    GreatCircle.Point(latitude: lat + 1, longitude: -104)]
        return NWSAlertFeed.Zone(id: id, name: id, geometry: .polygons([[ring]]))
    }

    private func zoneBased(_ zones: [String]) -> HazardFeature {
        var feature = HazardFeature(id: "z", kind: .warning, event: "Red Flag Warning",
                                    source: "NWS Boulder CO", fetchedAt: fetchedAt)
        feature.zoneIDs = zones
        return feature
    }

    /// Every zone known: the product is drawn as all of them.
    func testAZoneBasedProductTakesTheShapeOfItsZones() {
        let resolved = NWSAlertFeed.resolvingZones(
            [zoneBased(["COZ001", "COZ002"])],
            outlines: ["COZ001": zone("COZ001", 39), "COZ002": zone("COZ002", 40)])
        guard case let .polygons(polygons) = resolved.first?.geometry else { return XCTFail("expected a shape") }
        XCTAssertEqual(polygons.count, 2)
    }

    /// One zone missing: no shape at all. A half-drawn warning area looks
    /// like the whole one, and somebody may plan around it.
    func testAMissingZoneLeavesTheProductUndrawn() {
        let resolved = NWSAlertFeed.resolvingZones(
            [zoneBased(["COZ001", "COZ002"])], outlines: ["COZ001": zone("COZ001", 39)])
        XCTAssertNil(resolved.first?.geometry)
    }

    /// A warning with its own polygon keeps it; the zones are only a fallback.
    func testAWarningWithItsOwnPolygonKeepsIt() throws {
        let warning = try XCTUnwrap(try NWSAlertFeed.parse(try fixture("nws-alerts-polygon"), fetchedAt: fetchedAt).first)
        let resolved = NWSAlertFeed.resolvingZones([warning], outlines: [:])
        XCTAssertEqual(resolved.first?.geometry, warning.geometry)
    }

    /// The zones still to fetch: those not cached, each once.
    func testOnlyUncachedZonesAreFetched() throws {
        let outlook = try XCTUnwrap(try NWSAlertFeed.parse(try fixture("nws-alerts-zones"), fetchedAt: fetchedAt).first)
        let missing = NWSAlertFeed.zonesToFetch(for: [outlook, outlook], cached: ["COC007"])
        XCTAssertEqual(missing.count, 17)
        XCTAssertFalse(missing.contains { $0.lastPathComponent == "COC007" })
    }
}
