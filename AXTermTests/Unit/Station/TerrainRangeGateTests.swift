import XCTest
@testable import AXTerm

/// When a terrain profile is worth drawing at all.
///
/// Field report, 2026-08-31: the card offered a verdict for a station 2,317 km
/// away and reported "Blocked, terrain costs about 53 dB, terrain 78,225 m
/// above the line". Nothing was broken. Over that distance the earth's own
/// curvature stands 79 km above the line between two antennas, so the chart
/// drew a parabola of planet and the model dutifully measured it.
///
/// The number was right and the question was wrong.
final class TerrainRangeGateTests: XCTestCase {

    private let here = GreatCircle.Point(latitude: 39.60, longitude: -104.71)

    /// The reported case. A station in Maryland cannot be worked from
    /// Colorado on VHF, so the position is what needs explaining, not the
    /// ground.
    func testAContinentAwayIsOutOfRange() {
        let brunswick = GreatCircle.Point(latitude: 39.3145, longitude: -77.6179)
        let verdict = StationPlausibility.verdict(
            observer: here, station: brunswick, confidence: .exact)

        guard case .beyondRadioRange(let kilometres) = verdict else {
            return XCTFail("2,300 km should not be treated as a radio path")
        }
        XCTAssertEqual(kilometres, 2317, accuracy: 20)
    }

    /// Ordinary paths keep their profile. The gate has to catch the absurd
    /// case without taking the feature away from the cases it is for.
    func testRealPathsAreStillProfiled() {
        let nearby = [
            GreatCircle.Point(latitude: 39.74, longitude: -104.99),  // Denver, ~30 km
            GreatCircle.Point(latitude: 38.83, longitude: -104.82),  // Colorado Springs
            GreatCircle.Point(latitude: 40.58, longitude: -105.08),  // Fort Collins
        ]
        for station in nearby {
            XCTAssertFalse(
                StationPlausibility.verdict(observer: here, station: station,
                                            confidence: .exact).isImplausible,
                "\(station) is an ordinary VHF path")
        }
    }

    /// The bulge is what the chart was drawing. Stated as a test because it
    /// is the reason the gate exists: at 2,300 km the earth alone is four
    /// orders of magnitude past anything terrain contributes.
    func testTheEarthAloneExplainsTheNumberThatWasReported() {
        let total = 2_317_100.0
        let half = total / 2
        let bulge = half * half / (2 * TerrainProfile.refractionFactor * 6_371_000)

        XCTAssertEqual(bulge, 79_000, accuracy: 2_000)
        XCTAssertGreaterThan(bulge, 10_000,
                             "no mountain on earth is in this range, which is the point")
    }

    /// A station with no position cannot be judged, and must not be gated out
    /// on a guess: an unplaced station is often the one most worth looking at.
    func testAnUnplacedStationIsNotGated() {
        XCTAssertFalse(
            StationPlausibility.verdict(observer: here, station: nil,
                                        confidence: .exact).isImplausible)
    }

    /// A node placed at its operator's licence address is never called
    /// implausible: a Colorado hilltop node licensed to someone in Virginia is
    /// a real and common thing. The distance would be measuring the mailing
    /// address, not the radio.
    func testAnOperatorAddressIsNeverJudgedByDistance() {
        let virginia = GreatCircle.Point(latitude: 37.4, longitude: -78.6)
        XCTAssertFalse(
            StationPlausibility.verdict(observer: here, station: virginia,
                                        confidence: .inferredFromOperator).isImplausible)
    }
}
