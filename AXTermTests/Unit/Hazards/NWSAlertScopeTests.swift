import XCTest
@testable import AXTerm

/// Where the NWS layer fetches for (operator, 2026-10-09: "fetch by an area,
/// point, etc."): the station's point, within a radius of it, chosen states,
/// or chosen zones and counties.
final class NWSAlertScopeTests: XCTestCase {
    private let home = GreatCircle.Point(latitude: 39.6123, longitude: -104.7332)

    // MARK: - Stored as text

    func testTheScopeIsStoredAsText() {
        for scope: NWSAlertScope in [.here, .within(miles: 50), .states(["CO", "WY"]), .zones(["COZ039", "COC005"])] {
            XCTAssertEqual(NWSAlertScope(stored: scope.stored), scope, scope.stored)
        }
        XCTAssertEqual(NWSAlertScope.within(miles: 50).stored, "within:50")
        XCTAssertEqual(NWSAlertScope.states(["co", " wy "]).stored, "states:CO,WY", "cleaned up")
    }

    /// Anything unreadable is the default, the station's point.
    func testUnreadableTextIsWhereIAm() {
        XCTAssertEqual(NWSAlertScope(stored: ""), .here)
        XCTAssertEqual(NWSAlertScope(stored: "within:lots"), .here)
        XCTAssertEqual(NWSAlertScope(stored: "states:"), .here)
    }

    // MARK: - The request

    private func url(_ scope: NWSAlertScope, at point: GreatCircle.Point?) -> String? {
        NWSAlertFeed.alertsRequest(scope, at: point)?.url?.absoluteString
    }

    func testEachScopeAsksTheAPIItsOwnWay() {
        XCTAssertEqual(url(.here, at: home), "https://api.weather.gov/alerts/active?point=39.6123,-104.7332")
        XCTAssertEqual(url(.states(["CO", "WY"]), at: nil), "https://api.weather.gov/alerts/active?area=CO,WY")
        XCTAssertEqual(url(.zones(["COZ039", "COC005"]), at: nil),
                       "https://api.weather.gov/alerts/active?zone=COZ039,COC005")
        XCTAssertTrue(url(.within(miles: 25), at: home)?.hasPrefix("https://api.weather.gov/alerts/active?area=") == true)
    }

    /// The station's point and a radius need a position; states and zones
    /// do not.
    func testOnlyThePositionScopesNeedAPosition() {
        XCTAssertNil(url(.here, at: nil))
        XCTAssertNil(url(.within(miles: 25), at: nil))
        XCTAssertTrue(NWSAlertScope.here.needsPosition)
        XCTAssertTrue(NWSAlertScope.within(miles: 25).needsPosition)
        XCTAssertFalse(NWSAlertScope.states(["CO"]).needsPosition)
        XCTAssertFalse(NWSAlertScope.zones(["COZ039"]).needsPosition)
    }

    // MARK: - Which states a radius touches

    func testARadiusAsksForTheStatesItCouldTouch() {
        XCTAssertEqual(NWSAlertScope.states(near: home, miles: 10), ["CO"])
        let wide = NWSAlertScope.states(near: home, miles: 120)
        XCTAssertTrue(wide.contains("CO"))
        XCTAssertTrue(wide.contains("WY"), "the Wyoming line is about 96 miles north")
        XCTAssertFalse(wide.contains("FL"))
        XCTAssertFalse(wide.contains("UT"), "Utah is more than 200 miles west")
    }

    // MARK: - Keeping only what is within the radius

    private func square(_ lat: Double, _ lon: Double, side: Double = 0.1) -> HazardFeature.Geometry {
        .polygons([[[GreatCircle.Point(latitude: lat, longitude: lon),
                     GreatCircle.Point(latitude: lat, longitude: lon + side),
                     GreatCircle.Point(latitude: lat + side, longitude: lon + side),
                     GreatCircle.Point(latitude: lat + side, longitude: lon)]]])
    }

    func testTheDistanceToAShapeIsZeroInsideAndToItsEdgeOutside() {
        XCTAssertEqual(NWSAlertScope.miles(from: home, to: square(39.55, -104.80)), 0)
        // About 0.4 degrees of latitude north: some 27 miles.
        let north = NWSAlertScope.miles(from: home, to: square(40.0, -104.80))
        XCTAssertEqual(north, 26.8, accuracy: 1.0)
    }

    func testARadiusKeepsWhatComesWithinItAndAnythingUnshaped() {
        func feature(_ id: String, _ geometry: HazardFeature.Geometry?) -> HazardFeature {
            var f = HazardFeature(id: id, kind: .warning, event: "Red Flag Warning", source: "NWS", fetchedAt: Date())
            f.geometry = geometry
            return f
        }
        let features = [feature("here", square(39.55, -104.80)), feature("north", square(40.0, -104.80)),
                        feature("far", square(37.2, -108.5)), feature("unshaped", nil)]
        XCTAssertEqual(NWSAlertScope.within(miles: 10).keeping(features, near: home).map(\.id), ["here", "unshaped"])
        XCTAssertEqual(NWSAlertScope.within(miles: 50).keeping(features, near: home).map(\.id),
                       ["here", "north", "unshaped"])
        XCTAssertEqual(NWSAlertScope.states(["CO"]).keeping(features, near: home).count, 4,
                       "states and zones keep everything the API returned")
    }

    // MARK: - What the control says

    func testTheChoiceReadsPlainly() {
        XCTAssertEqual(NWSAlertScope.here.summary, "Where I am")
        XCTAssertEqual(NWSAlertScope.within(miles: 50).summary, "Within 50 mi")
        XCTAssertEqual(NWSAlertScope.states(["CO", "WY"]).summary, "CO, WY")
        XCTAssertEqual(NWSAlertScope.zones(["COZ039"]).summary, "Zones COZ039")
    }

    /// The radii the control offers.
    func testTheOfferedRadii() {
        XCTAssertEqual(NWSAlertScope.offeredRadii, [10, 25, 50, 100, 200])
    }
}
