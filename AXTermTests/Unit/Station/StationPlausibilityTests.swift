import XCTest
@testable import AXTerm

/// Telling a neighbour from a station that arrived down a wire.
final class StationPlausibilityTests: XCTestCase {

    private let denver = GreatCircle.Point(latitude: 39.74, longitude: -104.98)
    private let boulder = GreatCircle.Point(latitude: 40.015, longitude: -105.27)
    private let maryland = GreatCircle.Point(latitude: 39.29, longitude: -76.61)

    private func entry(_ callsign: String, at position: GreatCircle.Point?,
                       confidence: HeardStationMap.PositionConfidence = .gridSquare)
        -> HeardStationMap.Entry {
        var entry = HeardStationMap.Entry(callsign: callsign, heardCount: 1,
                                          lastVia: [])
        entry.position = position
        entry.confidence = confidence
        return entry
    }

    // MARK: - Verdicts

    func testANeighbourIsPlausible() {
        XCTAssertEqual(
            StationPlausibility.verdict(observer: denver, station: boulder,
                                        confidence: .gridSquare),
            .plausible)
    }

    /// The case that prompted this: a Maryland station on a Colorado screen.
    func testTheFarSideOfTheCountryIsBeyondRadioRange() {
        let verdict = StationPlausibility.verdict(
            observer: denver, station: maryland, confidence: .exact)
        guard case .beyondRadioRange(let km) = verdict else {
            return XCTFail("expected beyondRadioRange, got \(verdict)")
        }
        XCTAssertGreaterThan(km, 2000)
    }

    /// A node on a Colorado hilltop whose licensee lives in Virginia is real
    /// and common. The distance would be measuring a mailing address.
    func testAPositionInferredFromAnOperatorIsNeverFiltered() {
        XCTAssertEqual(
            StationPlausibility.verdict(observer: denver, station: maryland,
                                        confidence: .inferredFromOperator),
            .plausible)
    }

    /// An unplaced station is usually the one most worth looking at.
    func testAnUnplacedStationIsNeverFiltered() {
        XCTAssertEqual(
            StationPlausibility.verdict(observer: denver, station: nil,
                                        confidence: .gridSquare),
            .unknown)
        XCTAssertFalse(StationPlausibility.Verdict.unknown.isImplausible)
    }

    func testWithNoObserverNothingCanBeJudged() {
        XCTAssertEqual(
            StationPlausibility.verdict(observer: nil, station: maryland,
                                        confidence: .exact),
            .unknown)
    }

    /// The threshold is generous on purpose — real packet links run to a
    /// couple of hundred kilometres from good sites.
    func testALongButRealPathIsNotFiltered() {
        // Roughly 250 km north of Denver.
        let wyoming = GreatCircle.Point(latitude: 42.0, longitude: -104.98)
        XCTAssertEqual(
            StationPlausibility.verdict(observer: denver, station: wyoming,
                                        confidence: .gridSquare),
            .plausible)
    }

    func testTheThresholdIsConfigurable() {
        let verdict = StationPlausibility.verdict(
            observer: denver, station: boulder,
            confidence: .gridSquare, rangeKilometres: 10)
        XCTAssertTrue(verdict.isImplausible)
    }

    // MARK: - Partitioning

    func testPartitionKeepsLocalsAndSetsAsideTheRest() {
        let (shown, hidden) = StationPlausibility.partition([
            entry("K0EPI-7", at: boulder),
            entry("W3FAR-1", at: maryland, confidence: .exact),
            entry("NOWHERE", at: nil),
        ], observer: denver)

        XCTAssertEqual(shown.map(\.callsign), ["K0EPI-7", "NOWHERE"])
        XCTAssertEqual(hidden.map(\.callsign), ["W3FAR-1"])
    }

    /// Nothing is removed from the world — both halves come back, so the UI
    /// can say how many it set aside.
    func testEveryStationEndsUpInExactlyOneHalf() {
        let entries = [
            entry("A", at: boulder), entry("B", at: maryland, confidence: .exact),
            entry("C", at: nil), entry("D", at: denver),
        ]
        let (shown, hidden) = StationPlausibility.partition(entries, observer: denver)
        XCTAssertEqual(shown.count + hidden.count, entries.count)
    }

    func testWithNoObserverEverythingIsShown() {
        let entries = [entry("A", at: maryland, confidence: .exact)]
        let (shown, hidden) = StationPlausibility.partition(entries, observer: nil)
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(hidden.isEmpty)
    }
}
