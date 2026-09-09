import XCTest
@testable import AXTerm

/// Which movement trails are drawn. Three rules decide it, and a field report
/// of "I am surprised I am not seeing any trails" is what these exist to
/// answer without guessing.
final class MapTrackTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    /// A station with fixes at the given ages, each nudged so it counts as
    /// having moved unless `stationary` is set.
    private func station(_ call: String, minutesAgo: [Double],
                         stationary: Bool = false) -> Station {
        var station = Station(call: call, lastHeard: now, heardCount: minutesAgo.count)
        station.track = minutesAgo.enumerated().map { index, minutes in
            Station.APRSFix(
                latitude: 39.7 + (stationary ? 0 : Double(index) * 0.01),
                longitude: -104.9,
                timestamp: now.addingTimeInterval(-minutes * 60))
        }
        return station
    }

    private func trails(_ stations: [Station], selection: String? = nil,
                        showsAll: Bool = true, windowMinutes: Int = 60) -> [MapTrack] {
        MapTrack.trails(stations: stations,
                        placedIDs: Set(stations.map { $0.call.uppercased() }),
                        selection: selection, showsAll: showsAll,
                        windowMinutes: windowMinutes, now: now)
    }

    // MARK: - Why nothing is drawn

    /// The common case, and the one that looked like a bug: a fixed station
    /// only ever has one fix, because the tracker updates the timestamp in
    /// place rather than appending when the position has not changed.
    func testAStationThatHasNotMovedHasNoTrail() {
        XCTAssertTrue(trails([station("W0HOME", minutesAgo: [30])]).isEmpty)
    }

    func testFixesOutsideTheWindowAreNotDrawn() {
        let rover = station("K0RV0", minutesAgo: [400, 380, 360])
        XCTAssertTrue(trails([rover], windowMinutes: 60).isEmpty,
                      "every fix is over six hours old")
        XCTAssertEqual(trails([rover], windowMinutes: 0).count, 1,
                       "0 means keep everything the station has")
    }

    /// One fix inside the window is a position, not a line.
    func testASingleFixInsideTheWindowIsNotATrail() {
        let rover = station("K0RV0", minutesAgo: [400, 380, 10])
        XCTAssertTrue(trails([rover], windowMinutes: 60).isEmpty)
    }

    /// A station drawn at a looked-up address has no beaconed line to draw.
    func testOnlyStationsAtTheirOwnFixGetATrail() {
        let rover = station("K0RV0", minutesAgo: [30, 20, 10])
        XCTAssertTrue(MapTrack.trails(stations: [rover], placedIDs: [],
                                      selection: nil, showsAll: true,
                                      windowMinutes: 60, now: now).isEmpty)
    }

    // MARK: - What is drawn

    func testAMovingStationInsideTheWindowGetsATrail() throws {
        let rover = station("K0RV0", minutesAgo: [40, 25, 5])
        let drawn = try XCTUnwrap(trails([rover]).first)
        XCTAssertEqual(drawn.id, "K0RV0")
        XCTAssertEqual(drawn.points.count, 3)
    }

    func testTheWindowTrimsTheOlderEndOfATrail() throws {
        let rover = station("K0RV0", minutesAgo: [200, 40, 25, 5])
        let drawn = try XCTUnwrap(trails([rover], windowMinutes: 60).first)
        XCTAssertEqual(drawn.points.count, 3, "the 200-minute fix is outside the window")
    }

    // MARK: - Following the selection

    /// The default. One trail belonging to the station whose card is open
    /// identifies itself; a map full of unlabelled trails cannot be matched to
    /// anything and buries the terrain.
    func testWithoutShowsAllOnlyTheSelectedStationGetsATrail() {
        let stations = [station("K0RV0", minutesAgo: [40, 20, 5]),
                        station("K0RV1", minutesAgo: [40, 20, 5])]
        let drawn = trails(stations, selection: "K0RV1", showsAll: false)
        XCTAssertEqual(drawn.map(\.id), ["K0RV1"])
    }

    func testWithNoSelectionAndNoShowsAllNothingIsDrawn() {
        let stations = [station("K0RV0", minutesAgo: [40, 20, 5])]
        XCTAssertTrue(trails(stations, selection: nil, showsAll: false).isEmpty)
    }

    func testShowsAllDrawsEveryMover() {
        let stations = [station("K0RV0", minutesAgo: [40, 20, 5]),
                        station("K0RV1", minutesAgo: [40, 20, 5]),
                        station("W0HOME", minutesAgo: [30], stationary: true)]
        XCTAssertEqual(Set(trails(stations, showsAll: true).map(\.id)), ["K0RV0", "K0RV1"])
    }
}
