import XCTest
@testable import AXTerm

final class MaidenheadTests: XCTestCase {

    func testValidGrids() {
        for grid in ["FN31", "FN31pr", "JO59jw", "DM79", "dm79lr", "FN31pr21"] {
            XCTAssertTrue(Maidenhead.isValid(grid), grid)
        }
    }

    func testInvalidGrids() {
        for grid in ["", "F", "FN3", "FN311", "ZZ99", "F131", "FNaa", "FN31zz", "FN31p!"] {
            XCTAssertFalse(Maidenhead.isValid(grid), grid)
        }
    }

    func testKnownCenters() throws {
        // W1AW (Newington, CT) is in FN31pr: ~41.71 N, 72.73 W.
        let fn31pr = try XCTUnwrap(Maidenhead.center(of: "FN31pr"))
        XCTAssertEqual(fn31pr.latitude, 41.729, accuracy: 0.05)
        XCTAssertEqual(fn31pr.longitude, -72.708, accuracy: 0.05)

        // 4-character square centers on the square.
        let jo59 = try XCTUnwrap(Maidenhead.center(of: "JO59"))
        XCTAssertEqual(jo59.latitude, 59.5, accuracy: 0.001)
        XCTAssertEqual(jo59.longitude, 11.0, accuracy: 0.001)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(Maidenhead.center(of: "fn31PR"), Maidenhead.center(of: "FN31pr"))
    }

    func testDistanceKnownPair() throws {
        // FN31pr (Newington CT) to JO59jw (Oslo area): roughly 5,900 km.
        let distance = try XCTUnwrap(Maidenhead.distanceKm(from: "FN31pr", to: "JO59jw"))
        XCTAssertEqual(distance, 5900, accuracy: 200)
    }

    func testDistanceToSelfIsZero() throws {
        let distance = try XCTUnwrap(Maidenhead.distanceKm(from: "DM79lr", to: "DM79lr"))
        XCTAssertEqual(distance, 0, accuracy: 0.001)
    }

    func testBearingEastward() throws {
        // From DM79 (Colorado) to FN31 (Connecticut) is roughly east-northeast.
        let bearing = try XCTUnwrap(Maidenhead.bearingDegrees(from: "DM79", to: "FN31"))
        XCTAssertGreaterThan(bearing, 45)
        XCTAssertLessThan(bearing, 105)
    }
}
