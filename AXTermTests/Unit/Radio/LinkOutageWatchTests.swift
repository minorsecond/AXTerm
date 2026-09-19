import XCTest
@testable import AXTerm

/// Noticing that the station is off the air.
///
/// Written against the shape of the 2026-09-18 outage: the KISS socket to
/// Direwolf failed once at about 20:20 and never came back, and for the next
/// eight hours the app reported the same symptom over and over — a frame could
/// not be sent — while never once reporting the thing that was actually wrong.
final class LinkOutageWatchTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func watch(_ after: TimeInterval = 600) -> LinkOutageWatch {
        LinkOutageWatch(reportAfter: after)
    }

    // MARK: - Not worth saying

    /// An ordinary reconnect — a TNC power-cycled, a Pi rebooted, the backoff
    /// doing its job — finishes without anybody being told.
    func testAShortOutageIsNeverReported() {
        var w = watch()
        w.observe("pi:8001", isUp: false, now: at(0))
        XCTAssertTrue(w.due(now: at(120)).isEmpty)
        w.observe("pi:8001", isUp: true, now: at(130))
        XCTAssertTrue(w.due(now: at(9999)).isEmpty, "it came back; there is no outage")
    }

    func testALinkThatIsUpIsNeverReported() {
        var w = watch()
        w.observe("pi:8001", isUp: true, now: at(0))
        XCTAssertTrue(w.due(now: at(100_000)).isEmpty)
    }

    // MARK: - Worth saying, once

    func testAnOutageThatOutlastsTheWindowIsReportedWithItsLength() {
        var w = watch()
        w.observe("pi:8001", isUp: false, now: at(0))

        let due = w.due(now: at(601))
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.key, "pi:8001")
        XCTAssertEqual(due.first?.down ?? 0, 601, accuracy: 0.001)
    }

    /// The whole point. A node broadcasting NODES every half hour into a dead
    /// socket produced sixteen reports that night; it should produce one.
    func testItIsReportedOnceAndNotAgain() {
        var w = watch()
        w.observe("pi:8001", isUp: false, now: at(0))

        XCTAssertEqual(w.due(now: at(601)).count, 1)
        XCTAssertTrue(w.due(now: at(1800)).isEmpty)
        XCTAssertTrue(w.due(now: at(28_800)).isEmpty, "eight hours later, still once")
    }

    /// Coming back and going down again is a new outage and deserves a new
    /// report — otherwise a link that flaps daily is reported only the first
    /// time the app ever ran.
    func testARecoveryArmsTheNextOutage() {
        var w = watch()
        w.observe("pi:8001", isUp: false, now: at(0))
        XCTAssertEqual(w.due(now: at(601)).count, 1)

        w.observe("pi:8001", isUp: true, now: at(700))
        w.observe("pi:8001", isUp: false, now: at(800))
        XCTAssertEqual(w.due(now: at(1401)).count, 1)
    }

    /// Repeated failures without a recovery in between do not restart the
    /// clock. A socket that fails, retries, and fails again has been down the
    /// whole time.
    func testRetryingDoesNotRestartTheClock() {
        var w = watch()
        w.observe("pi:8001", isUp: false, now: at(0))
        for t in stride(from: 30.0, through: 570.0, by: 30.0) {
            w.observe("pi:8001", isUp: false, now: at(t))
        }
        XCTAssertEqual(w.due(now: at(601)).count, 1, "down since t0, not since t570")
    }

    // MARK: - Sleep

    /// A sleeping machine has every link down by definition. Counting that
    /// time toward an outage would hand the operator an alert about their own
    /// lid, so the wake restarts the clocks instead.
    func testWakingRestartsTheClocksInsteadOfReporting() {
        var w = watch()
        w.observe("pi:8001", isUp: false, now: at(0))

        // Eight hours asleep.
        w.reset(now: at(28_800))

        XCTAssertTrue(w.due(now: at(28_900)).isEmpty)
        XCTAssertEqual(w.due(now: at(29_401)).count, 1,
                       "still down ten minutes after waking, which is a real outage")
    }

    // MARK: - Housekeeping

    /// A link the operator closed is not an outage.
    func testForgettingALinkStopsItBeingReported() {
        var w = watch()
        w.observe("pi:8001", isUp: false, now: at(0))
        w.forget("pi:8001")
        XCTAssertTrue(w.due(now: at(9999)).isEmpty)
    }

    /// Two links falling due in one pass report in a fixed order rather than
    /// a dictionary's whim (CLAUDE.md section 13).
    func testTwoLinksDueTogetherReportDeterministically() {
        var w = watch()
        w.observe("zed:8001", isUp: false, now: at(0))
        w.observe("alpha:8001", isUp: false, now: at(0))

        let keys = w.due(now: at(601)).map(\.key)
        XCTAssertEqual(keys, ["alpha:8001", "zed:8001"])
    }

    /// The default is long enough to sit out a normal reconnect and short
    /// enough to notice inside one NET/ROM broadcast interval.
    func testTheDefaultWindowIsMinutesNotHours() {
        XCTAssertGreaterThanOrEqual(LinkOutageWatch.defaultReportAfter, 5 * 60)
        XCTAssertLessThanOrEqual(LinkOutageWatch.defaultReportAfter, 30 * 60)
    }
}
