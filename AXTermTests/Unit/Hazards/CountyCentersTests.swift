import XCTest
@testable import AXTerm

/// Every US county's center and size, built into the app from the Census
/// Gazetteer (2024), so a radius can judge an NWS alert by the counties it
/// names before downloading any outline (Docs/HazardLayers.md §2).
final class CountyCentersTests: XCTestCase {
    private let home = GreatCircle.Point(latitude: 39.6123, longitude: -104.7332)

    func testTheBuiltInTableHasEveryCounty() throws {
        let table = try XCTUnwrap(CountyCenters.bundled)
        XCTAssertEqual(table.count, 3222)
        let arapahoe = try XCTUnwrap(table.county("08005"))
        XCTAssertEqual(arapahoe.center.latitude, 39.6446, accuracy: 1e-4)
        XCTAssertEqual(arapahoe.center.longitude, -104.3317, accuracy: 1e-4)
        XCTAssertEqual(arapahoe.squareMiles, 806)
    }

    /// An alert's SAME codes are a 0 and the county's Census code.
    func testASAMECodeIsACounty() {
        XCTAssertEqual(CountyCenters.geoid(fromSAME: "008007"), "08007")
        XCTAssertNil(CountyCenters.geoid(fromSAME: "8007"))
        XCTAssertNil(CountyCenters.geoid(fromSAME: "00800X"))
    }

    private func alert(counties: [String]) -> HazardFeature {
        var feature = HazardFeature(id: "a", kind: .statement, event: "Hydrologic Outlook",
                                    source: "NWS Grand Junction CO", fetchedAt: Date())
        let geocode = ["SAME": counties, "UGC": []]
        let json = try! JSONSerialization.data(withJSONObject: geocode, options: [.sortedKeys])
        feature.properties["geocode"] = String(data: json, encoding: .utf8)
        return feature
    }

    /// Far only when every county it names is clearly outside the radius,
    /// allowing for each county's size: a county's edge can be much nearer
    /// than its center.
    func testAnAlertIsJudgedByTheCountiesItNames() throws {
        let table = try XCTUnwrap(CountyCenters.bundled)
        let archuleta = alert(counties: ["008007"])
        XCTAssertEqual(table.reach(of: archuleta, from: home, miles: 50), .far)
        XCTAssertEqual(table.reach(of: archuleta, from: home, miles: 300), .near)
        let arapahoe = alert(counties: ["008005"])
        XCTAssertEqual(table.reach(of: arapahoe, from: home, miles: 10), .near, "home is in Arapahoe County")
        XCTAssertEqual(table.reach(of: alert(counties: ["008007", "008005"]), from: home, miles: 10), .near,
                       "one near county is enough")
    }

    /// With no counties the table knows, the outline decides, as before.
    func testNoKnownCountiesIsUnknown() throws {
        let table = try XCTUnwrap(CountyCenters.bundled)
        XCTAssertEqual(table.reach(of: alert(counties: []), from: home, miles: 50), .unknown)
        XCTAssertEqual(table.reach(of: alert(counties: ["099999"]), from: home, miles: 50), .unknown)
    }

    // MARK: - Choosing counties without typing (2026-10-09)

    func testACountyHasItsNameAndState() throws {
        let arapahoe = try XCTUnwrap(CountyCenters.bundled?.county("08005"))
        XCTAssertEqual(arapahoe.name, "Arapahoe County")
        XCTAssertEqual(arapahoe.state, "CO")
        XCTAssertEqual(arapahoe.shortName, "Arapahoe")
    }

    func testTheStationsStateIsKnown() throws {
        XCTAssertEqual(try XCTUnwrap(CountyCenters.bundled).state(at: home), "CO")
    }

    /// Nearest first by distance to the county's edge, so the county the
    /// station is in leads: home is nearer Denver County's center than
    /// Arapahoe's, but inside Arapahoe.
    func testCountiesAreListedNearestFirst() throws {
        let nearest = try XCTUnwrap(CountyCenters.bundled).nearest(to: home, limit: 5)
        XCTAssertEqual(nearest.first?.geoid, "08005")
        XCTAssertEqual(nearest.count, 5)
        XCTAssertTrue(nearest.map(\.geoid).contains("08035"), "Douglas County is among the nearest")
    }

    /// Search by name, nearest first.
    func testACountyCanBeFoundByName() throws {
        let found = try XCTUnwrap(CountyCenters.bundled).search("douglas", near: home)
        XCTAssertEqual(found.first?.geoid, "08035", "Colorado's Douglas County, the nearest")
        XCTAssertGreaterThan(found.count, 5, "there are Douglas Counties in many states")
        XCTAssertTrue(try XCTUnwrap(CountyCenters.bundled).search("", near: home).isEmpty)
    }
}

/// State names for the States checklist.
final class USStatesTests: XCTestCase {
    func testEveryStateCodeHasAName() {
        XCTAssertEqual(USStates.name("CO"), "Colorado")
        XCTAssertEqual(USStates.name("PR"), "Puerto Rico")
        for code in NWSAlertScope.stateBoxes.keys {
            XCTAssertNotNil(USStates.name(code), code)
        }
    }

    func testTheListIsAlphabeticalByName() {
        let names = USStates.all.map(\.name)
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(USStates.all.first?.code, "AL")
    }
}
