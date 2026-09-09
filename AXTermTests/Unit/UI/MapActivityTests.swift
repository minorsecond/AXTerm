import XCTest
@testable import AXTerm

/// Which stations the map marks as "just transmitted".
final class MapActivityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    func testAStationHeardSecondsAgoIsActive() {
        XCTAssertTrue(MapActivity.isActive(lastHeard: ago(1), now: now))
        XCTAssertTrue(MapActivity.isActive(lastHeard: ago(MapActivity.window - 0.5), now: now))
    }

    func testAStationHeardBeforeTheWindowIsNot() {
        XCTAssertFalse(MapActivity.isActive(lastHeard: ago(MapActivity.window + 1), now: now))
        XCTAssertFalse(MapActivity.isActive(lastHeard: ago(3600), now: now),
                       "an hour ago is the dot's recency fade to say, not this")
    }

    /// A station that has never been heard has no activity — not "active
    /// since the beginning of time".
    func testNeverHeardIsNotActive() {
        XCTAssertFalse(MapActivity.isActive(lastHeard: nil, now: now))
    }

    /// The database and this process do not share a clock. A timestamp a
    /// little in the future is skew, not a transmission that has not happened
    /// yet, and it must not read as "silent".
    func testASlightlyFutureTimestampIsTreatedAsJustNow() {
        XCTAssertTrue(MapActivity.isActive(lastHeard: now.addingTimeInterval(2), now: now))
        XCTAssertFalse(MapActivity.isActive(lastHeard: now.addingTimeInterval(600), now: now),
                       "wild skew is not activity")
    }

    func testActiveIDsPicksOutOnlyTheRecentOnes() {
        let sites = [
            StationScope.Site(id: "LOUD", label: "LOUD", kilometres: 1, bearingDegrees: 0,
                              signal: .good, subtitle: "", detail: "",
                              lastHeard: ago(2), isStale: false),
            StationScope.Site(id: "QUIET", label: "QUIET", kilometres: 2, bearingDegrees: 0,
                              signal: .fair, subtitle: "", detail: "",
                              lastHeard: ago(600), isStale: false),
            StationScope.Site(id: "UNKNOWN", label: "UNKNOWN", kilometres: 3, bearingDegrees: 0,
                              signal: .unknown, subtitle: "", detail: "",
                              lastHeard: nil, isStale: true),
        ]
        XCTAssertEqual(MapActivity.activeIDs(sites, now: now), ["LOUD"])
    }
}

/// What counts as "the operator changed something", which is what lets a
/// switch bypass the map's batching clock.
final class MapLayerGenerationTests: XCTestCase {

    private func token(switches: [Bool] = [true, false],
                       track: Int = 60, falloff: Int = 0,
                       hidden: Set<RadioID> = []) -> String {
        MapLayerGeneration.token(switches: switches, trackWindowMinutes: track,
                                 falloffMinutes: falloff, hiddenRadios: hidden)
    }

    /// The bug: hiding a radio removes every marker only that radio heard, but
    /// it was not in the token, so the removal waited on the batching clock
    /// and the switch appeared to do nothing until something else forced a
    /// pass.
    func testHidingARadioChangesTheToken() {
        XCTAssertNotEqual(token(hidden: []), token(hidden: [RadioID(rawValue: "uhf")]))
    }

    func testUnhidingReturnsToTheSameToken() {
        let uhf = RadioID(rawValue: "uhf")
        XCTAssertEqual(token(hidden: []), token(hidden: []))
        XCTAssertNotEqual(token(hidden: [uhf]), token(hidden: []))
    }

    /// Order must not matter, or an unrelated re-sort would look like a
    /// deliberate change and force a rebuild.
    func testTheOrderRadiosAreHiddenInDoesNotMatter() {
        let a = RadioID(rawValue: "a"), b = RadioID(rawValue: "b")
        XCTAssertEqual(token(hidden: [a, b]), token(hidden: [b, a]))
    }

    func testEachSwitchAndWindowIsPartOfIt() {
        XCTAssertNotEqual(token(switches: [true, false]), token(switches: [false, false]))
        XCTAssertNotEqual(token(track: 60), token(track: 15))
        XCTAssertNotEqual(token(falloff: 0), token(falloff: 60))
    }

    /// Traffic arriving is not an operator change: nothing here varies with it.
    func testTheTokenIsStableWhenNothingWasSwitched() {
        XCTAssertEqual(token(), token())
    }
}
