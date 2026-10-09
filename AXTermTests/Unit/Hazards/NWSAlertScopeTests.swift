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

    /// Within a radius, an alert with no shape yet cannot be judged and is
    /// not counted as within it: live on Station C, 200 miles reported "24
    /// alerts", 21 of them Texas-coast products whose zones had not loaded
    /// (2026-10-09). They are counted apart as still being placed.
    func testARadiusKeepsWhatComesWithinItAndCountsTheUnplacedApart() {
        func feature(_ id: String, _ geometry: HazardFeature.Geometry?) -> HazardFeature {
            var f = HazardFeature(id: id, kind: .warning, event: "Red Flag Warning", source: "NWS", fetchedAt: Date())
            f.geometry = geometry
            return f
        }
        let features = [feature("here", square(39.55, -104.80)), feature("north", square(40.0, -104.80)),
                        feature("far", square(37.2, -108.5)), feature("unshaped", nil)]
        XCTAssertEqual(NWSAlertScope.within(miles: 10).keeping(features, near: home).map(\.id), ["here"])
        XCTAssertEqual(NWSAlertScope.within(miles: 50).keeping(features, near: home).map(\.id), ["here", "north"])
        XCTAssertEqual(NWSAlertScope.within(miles: 50).unplaced(features), 1)
        XCTAssertEqual(NWSAlertScope.states(["CO"]).unplaced(features), 0, "states keep the unshaped in the list")
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

    // MARK: - Typed codes are checked

    /// Live on Station C, "COC007" typed under States was stored and asked
    /// for as a state, which the NWS rejected (2026-10-09).
    func testStateCodesAreChecked() {
        XCTAssertEqual(NWSAlertScope.entry("co, wy", asStates: true), .success(.states(["CO", "WY"])))
        XCTAssertEqual(NWSAlertScope.entry("COC007", asStates: true),
                       .failure(.looksLikeZones("COC007")), "a zone typed under States says so")
        XCTAssertEqual(NWSAlertScope.entry("CO, XX", asStates: true), .failure(.unknown(["XX"])))
        XCTAssertEqual(NWSAlertScope.entry("  ", asStates: true), .failure(.empty))
    }

    func testZoneCodesAreChecked() {
        XCTAssertEqual(NWSAlertScope.entry("coz039, COC005", asStates: false), .success(.zones(["COZ039", "COC005"])))
        XCTAssertEqual(NWSAlertScope.entry("CO", asStates: false), .failure(.looksLikeStates("CO")))
        XCTAssertEqual(NWSAlertScope.entry("COZ39", asStates: false), .failure(.unknown(["COZ39"])))
    }

    func testTheProblemReadsPlainly() {
        XCTAssertEqual(NWSAlertScope.EntryProblem.looksLikeZones("COC007").message,
                       "COC007 is a zone or county code. Choose Zones to use it.")
        XCTAssertEqual(NWSAlertScope.EntryProblem.unknown(["XX"]).message, "Not a code the NWS uses: XX")
    }

    // MARK: - Counties

    func testCountiesAreStoredAndReadPlainly() {
        let scope = NWSAlertScope.counties(["08005", "08035"])
        XCTAssertEqual(scope.stored, "counties:08005,08035")
        XCTAssertEqual(NWSAlertScope(stored: scope.stored), scope)
        XCTAssertEqual(scope.summary(counties: CountyCenters.bundled), "Arapahoe, Douglas")
        XCTAssertFalse(scope.needsPosition)
    }

    /// Counties are fetched as their states, so zone-based alerts are not
    /// missed, and kept by the counties each alert names.
    func testCountiesFetchTheirStatesAndKeepAlertsNamingThem() {
        let scope = NWSAlertScope.counties(["08005", "56021"])
        XCTAssertEqual(NWSAlertFeed.alertsRequest(scope, at: nil, counties: CountyCenters.bundled)?.url?.absoluteString,
                       "https://api.weather.gov/alerts/active?area=CO,WY")
        func alert(_ id: String, _ same: [String]) -> HazardFeature {
            var f = HazardFeature(id: id, kind: .warning, event: "Red Flag Warning", source: "NWS", fetchedAt: Date())
            let json = try! JSONSerialization.data(withJSONObject: ["SAME": same], options: [])
            f.properties["geocode"] = String(data: json, encoding: .utf8)
            return f
        }
        let kept = scope.keeping([alert("ours", ["008005", "008039"]), alert("theirs", ["008007"])], near: nil)
        XCTAssertEqual(kept.map(\.id), ["ours"])
    }
}
