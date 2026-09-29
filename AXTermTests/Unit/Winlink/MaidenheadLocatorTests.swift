import XCTest
@testable import AXTerm

/// Encoding tests. The decoder (`center(of:)`) is the reference: a
/// round trip through both must land back in the same square, which
/// catches sign errors and off-by-one boundaries that a handful of
/// memorised locators would not.
final class MaidenheadLocatorTests: XCTestCase {

    // MARK: - Known values

    /// The canonical worked example: the origin sits at the corner of
    /// field J, square 0, subsquare a.
    func testOriginIsJJ00aa() {
        XCTAssertEqual(Maidenhead.locator(latitude: 0, longitude: 0), "JJ00aa")
    }

    /// This operator's own square, from the position stamped on their
    /// session logs.
    func testDenverAreaLandsInDM79() {
        XCTAssertEqual(Maidenhead.locator(latitude: 39.7, longitude: -105.0, precision: 4), "DM79")
    }

    func testPrecisionControlsLength() {
        XCTAssertEqual(Maidenhead.locator(latitude: 39.7, longitude: -105.0, precision: 4)?.count, 4)
        XCTAssertEqual(Maidenhead.locator(latitude: 39.7, longitude: -105.0, precision: 6)?.count, 6)
        XCTAssertEqual(Maidenhead.locator(latitude: 39.7, longitude: -105.0, precision: 8)?.count, 8)
    }

    func testShorterPrecisionsArePrefixesOfLongerOnes() throws {
        let six = try XCTUnwrap(Maidenhead.locator(latitude: 51.5, longitude: -0.12, precision: 6))
        let eight = try XCTUnwrap(Maidenhead.locator(latitude: 51.5, longitude: -0.12, precision: 8))
        let four = try XCTUnwrap(Maidenhead.locator(latitude: 51.5, longitude: -0.12, precision: 4))
        XCTAssertTrue(six.hasPrefix(four))
        XCTAssertTrue(eight.hasPrefix(six))
    }

    // MARK: - Round trip

    /// Encode → decode → encode must be stable across both hemispheres
    /// in each axis, which is where a sign error hides.
    func testRoundTripsAcrossAllQuadrants() throws {
        let positions: [(Double, Double)] = [
            (39.7392, -104.9903),   // Denver
            (51.5074, -0.1278),     // London
            (-33.8688, 151.2093),   // Sydney
            (-22.9068, -43.1729),   // Rio de Janeiro
            (35.6762, 139.6503),    // Tokyo
            (64.1466, -21.9426),    // Reykjavík
            (0, 0),
        ]
        for (latitude, longitude) in positions {
            let grid = try XCTUnwrap(
                Maidenhead.locator(latitude: latitude, longitude: longitude),
                "\(latitude),\(longitude)")
            XCTAssertTrue(Maidenhead.isValid(grid), grid)

            let center = try XCTUnwrap(Maidenhead.center(of: grid), grid)
            let again = try XCTUnwrap(
                Maidenhead.locator(latitude: center.latitude, longitude: center.longitude), grid)
            XCTAssertEqual(again, grid, "round trip drifted for \(latitude),\(longitude)")
        }
    }

    /// The decoded centre must be within half a subsquare of the input —
    /// about 4 km east–west and 2.3 km north–south at the equator.
    func testDecodedCentreIsCloseToTheInput() throws {
        let latitude = 39.7392
        let longitude = -104.9903
        let grid = try XCTUnwrap(Maidenhead.locator(latitude: latitude, longitude: longitude))
        let center = try XCTUnwrap(Maidenhead.center(of: grid))
        XCTAssertEqual(center.latitude, latitude, accuracy: 1.0 / 48)
        XCTAssertEqual(center.longitude, longitude, accuracy: 2.0 / 48)
    }

    // MARK: - Edges

    /// The extremes must land inside the last square rather than one
    /// past it — the classic off-by-one in this conversion.
    func testExtremesStayInsideTheGrid() throws {
        for (latitude, longitude) in [(90.0, 180.0), (-90.0, -180.0)] {
            let grid = try XCTUnwrap(
                Maidenhead.locator(latitude: latitude, longitude: longitude),
                "\(latitude),\(longitude)")
            XCTAssertTrue(Maidenhead.isValid(grid), grid)
        }
    }

    func testOutOfRangePositionsAreRejected() {
        XCTAssertNil(Maidenhead.locator(latitude: 91, longitude: 0))
        XCTAssertNil(Maidenhead.locator(latitude: 0, longitude: 181))
        XCTAssertNil(Maidenhead.locator(latitude: -91, longitude: 0))
    }

    func testUnsupportedPrecisionIsRejected() {
        XCTAssertNil(Maidenhead.locator(latitude: 0, longitude: 0, precision: 5))
        XCTAssertNil(Maidenhead.locator(latitude: 0, longitude: 0, precision: 2))
    }

    /// Six characters is the default because four carries 60 km of
    /// uncertainty, which the link-quality rules will not call "here".
    func testDefaultPrecisionIsSixCharacters() {
        XCTAssertEqual(Maidenhead.locator(latitude: 39.7, longitude: -105.0)?.count, 6)
    }
}
