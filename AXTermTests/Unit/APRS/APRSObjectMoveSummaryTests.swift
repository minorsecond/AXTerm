import XCTest
@testable import AXTerm

final class APRSObjectMoveSummaryTests: XCTestCase {

    private let denver = GreatCircle.Point(latitude: 39.6117, longitude: -104.7317)

    func testAWestwardMoveReadsInMilesAndCompassPoints() {
        // Same latitude, well to the west: due west, hundreds of miles.
        let out = APRSObjectMove.summary(
            from: denver,
            to: GreatCircle.Point(latitude: 39.6117, longitude: -108.2915),
            inMiles: true)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.hasSuffix(" mi W"), out!)
        // No decimal at this range — a tenth of a mile in 190 is noise.
        XCTAssertFalse(out!.contains("."), out!)
    }

    func testAShortMoveKeepsOneDecimal() {
        // Roughly a kilometre north.
        let out = APRSObjectMove.summary(
            from: denver,
            to: GreatCircle.Point(latitude: 39.6207, longitude: -104.7317),
            inMiles: true)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.hasSuffix(" mi N"), out!)
        XCTAssertTrue(out!.contains("."), out!)
    }

    func testKilometresWhenThatIsTheOperatorsUnit() {
        let out = APRSObjectMove.summary(
            from: denver,
            to: GreatCircle.Point(latitude: 39.6207, longitude: -104.7317),
            inMiles: false)
        XCTAssertNotNil(out, "a kilometre is well past the resting threshold")
        XCTAssertTrue(out!.hasSuffix(" km N"), out!)
    }

    /// A drop a few metres from where the object already sits is a slipped
    /// hand, and saying "0.0 mi N" would read as a bug rather than a warning.
    func testABarelyMovedObjectHasNoSummary() {
        let nudged = GreatCircle.Point(latitude: denver.latitude + 0.0001,
                                       longitude: denver.longitude)
        XCTAssertLessThan(GreatCircle.kilometres(from: denver, to: nudged) * 1000,
                          APRSObjectMove.restingMetres)
        XCTAssertNil(APRSObjectMove.summary(from: denver, to: nudged, inMiles: true))
    }

    func testNotMovedAtAllHasNoSummary() {
        XCTAssertNil(APRSObjectMove.summary(from: denver, to: denver, inMiles: true))
    }
}
