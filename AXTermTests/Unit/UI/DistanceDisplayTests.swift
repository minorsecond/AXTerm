import XCTest
@testable import AXTerm

final class DistanceDisplayTests: XCTestCase {

    func testTheSameDistanceReadsInEitherUnit() {
        XCTAssertEqual(DistanceDisplay.string(kilometres: 100, inMiles: false), "100 km")
        XCTAssertEqual(DistanceDisplay.string(kilometres: 100, inMiles: true), "62 mi")
    }

    func testCallersKeepTheirPrecision() {
        XCTAssertEqual(
            DistanceDisplay.string(kilometres: 1.609344, inMiles: true, format: "%.1f"),
            "1.0 mi")
    }

    func testUnitNamesForScaleBars() {
        XCTAssertEqual(DistanceDisplay.unitName(inMiles: true), "miles")
        XCTAssertEqual(DistanceDisplay.unitName(inMiles: false), "km")
    }
}
