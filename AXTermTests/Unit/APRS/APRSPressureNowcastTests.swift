import XCTest
@testable import AXTerm

/// The area barometric picture, and what it is allowed to claim.
///
/// The value of this product is that it survives the thing that ruins every
/// other pressure map built from strangers' weather stations: altitude. A
/// station 1500 m up reads ~180 mb below one at sea level, and the APRS
/// reduction to sea level is widely misconfigured — but whatever offset a
/// station carries it carries in both readings, so it subtracts out of the
/// change. These tests pin that, and pin the refusal to over-claim.
final class APRSPressureNowcastTests: XCTestCase {

    private func r(_ call: String, _ perThreeHours: Double) -> APRSPressureNowcast.Reading {
        .init(call: call, perThreeHours: perThreeHours)
    }

    // MARK: - The thing that makes it work at all

    /// The whole argument for tendency over pressure, as a test: two stations
    /// 1500 m apart in altitude, both falling 4 mb, agree completely even
    /// though their absolute readings are ~180 mb apart. An absolute-pressure
    /// field would show a gradient across the state that is purely terrain.
    func testAConstantPerStationOffsetCannotAffectTheVerdict() {
        let sea  = APRSPressureNowcast.build([r("SEA", -4.0), r("SEA2", -4.0), r("SEA3", -4.0)])!
        let high = APRSPressureNowcast.build([r("HIGH", -4.0), r("HIGH2", -4.0), r("HIGH3", -4.0)])!
        XCTAssertEqual(sea.medianPerThreeHours, high.medianPerThreeHours)
        XCTAssertEqual(sea.outlook, high.outlook)
    }

    // MARK: - Refusing to over-claim

    func testOneBarometerIsNotAnArea() {
        let n = APRSPressureNowcast.build([r("BVILLE", -5.0)])!
        XCTAssertFalse(n.isAreaWide)
        XCTAssertEqual(n.stations, 1)
        XCTAssertTrue(n.headline.contains("at one station"), n.headline)
        XCTAssertNotNil(n.caveat)
        // Still surfaced: a steep fall next door is worth seeing even from
        // one station. It just may not say "across the area".
        XCTAssertEqual(n.outlook, .rapidFall)
    }

    func testStationsDisagreeingIsLocalVariationNotASystem() {
        let n = APRSPressureNowcast.build([
            r("A", -3.0), r("B", -2.5), r("C", 2.8), r("D", 3.1)])!
        XCTAssertFalse(n.isAreaWide, "half falling and half rising is not a front")
        XCTAssertEqual(n.caveat?.contains("disagree"), true, n.caveat ?? "nil")
    }

    func testAgreedFallAcrossEnoughStationsIsAnAreaTrend() {
        let n = APRSPressureNowcast.build([
            r("A", -2.0), r("B", -2.4), r("C", -1.8), r("D", -3.0), r("E", -2.2)])!
        XCTAssertTrue(n.isAreaWide)
        XCTAssertNil(n.caveat)
        XCTAssertEqual(n.outlook, .falling)
        XCTAssertTrue(n.headline.contains("across 5 stations"), n.headline)
    }

    // MARK: - Resisting one bad instrument

    /// A barometer stuck at a wild rate is the commonest failure on a channel
    /// of amateur weather stations. It must not be able to invert the area
    /// verdict, which is why the middle station is used and not the average.
    func testAStuckBarometerCannotInvertTheVerdict() {
        let readings = [r("A", -2.0), r("B", -2.2), r("C", -1.9), r("STUCK", 40.0)]
        let n = APRSPressureNowcast.build(readings)!
        XCTAssertEqual(n.outlook, .falling, "the mean here is +8.5 mb/3h, which is nonsense")
        XCTAssertLessThan(n.medianPerThreeHours, 0)
        // It is still named, because a station reporting +40 mb/3h is itself
        // worth an operator's attention.
        XCTAssertEqual(n.steepest?.call, "STUCK")
    }

    // MARK: - Boundaries and empties

    func testNothingReportingIsNotSteady() {
        XCTAssertNil(APRSPressureNowcast.build([]),
                     "no data must not be printed as a steady barometer")
    }

    /// A flat station must not be counted as agreeing with a fall; otherwise
    /// every quiet day reads as a confident system.
    func testAFlatStationDoesNotAgreeWithAFall() {
        let n = APRSPressureNowcast.build([
            r("A", -2.0), r("B", -2.1), r("FLAT", 0.0), r("FLAT2", 0.1)])!
        XCTAssertEqual(n.agreement, 0.5, accuracy: 0.001)
        XCTAssertFalse(n.isAreaWide)
    }

    func testTheThresholdsAreTheStandardOnes() {
        // Standard three-hour synoptic thresholds, via APRSWeatherTrend.
        XCTAssertEqual(APRSPressureNowcast.build([r("A", -0.5)])!.outlook, .steady)
        XCTAssertEqual(APRSPressureNowcast.build([r("A", -2.0)])!.outlook, .falling)
        XCTAssertEqual(APRSPressureNowcast.build([r("A", -4.0)])!.outlook, .rapidFall)
    }
}
