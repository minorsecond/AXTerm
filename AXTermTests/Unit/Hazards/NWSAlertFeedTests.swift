import XCTest
@testable import AXTerm

/// NWS alerts from api.weather.gov, read into hazard features
/// (Docs/HazardLayers.md §2-§4). Fixtures are real responses from
/// 2026-10-09, with long description text shortened.
final class NWSAlertFeedTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_791_590_000)

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: NWSAlertFeedTests.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// A storm-based warning carries its own polygon.
    func testAPolygonWarningIsReadWithItsShapeAndTimes() throws {
        let features = try NWSAlertFeed.parse(try fixture("nws-alerts-polygon"), fetchedAt: fetchedAt)
        let warning = try XCTUnwrap(features.first)
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(warning.kind, .warning)
        XCTAssertEqual(warning.event, "Tropical Storm Warning")
        XCTAssertEqual(warning.source, "NWS Mobile AL")
        XCTAssertEqual(warning.issued, date("2026-10-09T13:02:00-05:00"))
        XCTAssertEqual(warning.expires, date("2026-10-09T21:15:00-05:00"))
        XCTAssertEqual(warning.fetchedAt, fetchedAt)
        guard case let .polygons(polygons) = warning.geometry else {
            return XCTFail("expected a polygon, got \(String(describing: warning.geometry))")
        }
        XCTAssertEqual(polygons.first?.first?.first,
                       GreatCircle.Point(latitude: 31.831, longitude: -86.907),
                       "GeoJSON is [longitude, latitude]")
        XCTAssertTrue(warning.zoneIDs.isEmpty == false, "the zones are kept too, for the list")
    }

    /// A zone-based product has no polygon of its own; it names the zones,
    /// whose outlines are fetched once and cached.
    func testAZoneBasedProductNamesItsZones() throws {
        let features = try NWSAlertFeed.parse(try fixture("nws-alerts-zones"), fetchedAt: fetchedAt)
        let outlook = try XCTUnwrap(features.first)
        XCTAssertEqual(outlook.event, "Hydrologic Outlook")
        XCTAssertEqual(outlook.kind, .statement)
        XCTAssertNil(outlook.geometry)
        XCTAssertEqual(outlook.zoneIDs.count, 18)
        XCTAssertEqual(outlook.zoneIDs.first, "COC007")
    }

    /// Everything the source returned is kept, even what the UI does not show.
    func testEveryPropertyIsKept() throws {
        let outlook = try XCTUnwrap(try NWSAlertFeed.parse(try fixture("nws-alerts-zones"), fetchedAt: fetchedAt).first)
        XCTAssertNotNil(outlook.properties["urgency"])
        XCTAssertNotNil(outlook.properties["areaDesc"])
    }

    func testAZoneOutlineIsRead() throws {
        let zone = try NWSAlertFeed.parseZone(try fixture("nws-zone-COC007"))
        XCTAssertEqual(zone.id, "COC007")
        XCTAssertEqual(zone.name, "Archuleta")
        guard case let .polygons(polygons) = zone.geometry else { return XCTFail("expected a polygon") }
        XCTAssertGreaterThan(polygons.first?.first?.count ?? 0, 10)
    }

    func testTheKindIsReadFromTheEventName() {
        XCTAssertEqual(NWSAlertFeed.kind(of: "Red Flag Warning"), .warning)
        XCTAssertEqual(NWSAlertFeed.kind(of: "Tornado Watch"), .watch)
        XCTAssertEqual(NWSAlertFeed.kind(of: "Wind Advisory"), .advisory)
        XCTAssertEqual(NWSAlertFeed.kind(of: "Special Weather Statement"), .statement)
        XCTAssertEqual(NWSAlertFeed.kind(of: "Hydrologic Outlook"), .statement)
    }

    func testNotGeoJSONIsAnError() {
        XCTAssertThrowsError(try NWSAlertFeed.parse(Data("<html>".utf8), fetchedAt: fetchedAt))
    }
}

/// Whether a point falls inside a hazard: the "Inside: Red Flag Warning"
/// line on the map and in car mode.
final class HazardContainmentTests: XCTestCase {
    private func p(_ lat: Double, _ lon: Double) -> GreatCircle.Point {
        GreatCircle.Point(latitude: lat, longitude: lon)
    }

    private var squareWithHole: HazardFeature.Geometry {
        .polygons([[
            [p(39, -105), p(39, -104), p(40, -104), p(40, -105)],
            [p(39.4, -104.6), p(39.4, -104.4), p(39.6, -104.4), p(39.6, -104.6)],
        ]])
    }

    func testInsideOutsideAndInTheHole() {
        XCTAssertTrue(HazardContainment.contains(squareWithHole, p(39.2, -104.8)))
        XCTAssertFalse(HazardContainment.contains(squareWithHole, p(41, -104.8)))
        XCTAssertFalse(HazardContainment.contains(squareWithHole, p(39.5, -104.5)), "a hole is not inside")
    }

    func testAPointIsNeverInsideAnything() {
        XCTAssertFalse(HazardContainment.contains(.point(p(39.5, -104.5)), p(39.5, -104.5)))
    }

    func testExpiredIsByTheSourcesOwnTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var feature = HazardFeature(id: "x", kind: .warning, event: "Red Flag Warning", source: "NWS Boulder CO",
                                    fetchedAt: now.addingTimeInterval(-60))
        feature.expires = now.addingTimeInterval(-1)
        XCTAssertTrue(feature.isExpired(at: now))
        feature.expires = now.addingTimeInterval(60)
        XCTAssertFalse(feature.isExpired(at: now))
        feature.expires = nil
        XCTAssertFalse(feature.isExpired(at: now), "no expiry given is not expired")
    }
}
