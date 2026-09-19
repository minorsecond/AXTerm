//
//  QuietWindowTimerTests.swift
//  AXTermTests
//
//  The invariant here is the one that failed in the field: however hard the
//  timer is poked, only one scheduled block is ever outstanding. The frozen
//  release build of 2026-09-18 had 101,465 of them.
//

import XCTest
@testable import AXTerm

@MainActor
final class QuietWindowTimerTests: XCTestCase {

    /// A hand-cranked scheduler and clock, so the tests assert on behaviour
    /// rather than on how long a real queue happened to take.
    private final class Harness {
        var now = Date(timeIntervalSince1970: 1_000)
        /// Blocks handed to the scheduler, oldest first, each with the delay it
        /// was scheduled with.
        var scheduled: [(delay: TimeInterval, body: () -> Void)] = []
        /// Every block ever scheduled, so a test can tell "one at a time" from
        /// "one in total".
        var totalScheduled = 0

        func makeTimer(window: TimeInterval) -> QuietWindowTimer {
            QuietWindowTimer(window: window, now: { self.now }) { delay, body in
                self.totalScheduled += 1
                self.scheduled.append((delay, body))
            }
        }

        /// Advance the clock and run the block that was waiting.
        func fireNext(after elapsed: TimeInterval) {
            guard !scheduled.isEmpty else { return XCTFail("nothing scheduled") }
            now = now.addingTimeInterval(elapsed)
            scheduled.removeFirst().body()
        }
    }

    func testRunsActionAfterTheQuietWindow() {
        let harness = Harness()
        let timer = harness.makeTimer(window: 0.12)
        var ran = 0

        timer.poke { ran += 1 }
        XCTAssertEqual(ran, 0, "must not run synchronously")
        XCTAssertEqual(harness.scheduled.first?.delay, 0.12)

        harness.fireNext(after: 0.12)
        XCTAssertEqual(ran, 1)
        XCTAssertFalse(timer.isArmed)
    }

    /// The bug. A thousand pokes with no chance for the queue to drain used to
    /// leave a thousand dispatch sources alive, each holding its capture.
    func testBurstOfPokesSchedulesOneTimer() {
        let harness = Harness()
        let timer = harness.makeTimer(window: 0.12)
        var ran = 0

        for _ in 0..<1_000 { timer.poke { ran += 1 } }

        XCTAssertEqual(harness.totalScheduled, 1, "one timer for the whole burst")
        XCTAssertEqual(harness.scheduled.count, 1)
        XCTAssertEqual(ran, 0)
    }

    /// Poked again while the timer was waiting: re-arm rather than run mid-storm,
    /// and still only one block outstanding at a time.
    func testStillBeingPokedRearmsInsteadOfRunning() {
        let harness = Harness()
        let timer = harness.makeTimer(window: 0.12)
        var ran = 0

        timer.poke { ran += 1 }
        harness.now = harness.now.addingTimeInterval(0.10)
        timer.poke { ran += 1 }          // 0.10s in, inside the window

        harness.fireNext(after: 0.02)     // original timer expires at 0.12
        XCTAssertEqual(ran, 0, "last poke was only 0.02s ago")
        XCTAssertEqual(harness.scheduled.count, 1, "re-armed, not piled up")
        XCTAssertTrue(timer.isArmed)

        harness.fireNext(after: 0.12)
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(harness.totalScheduled, 2, "one re-arm, not one per poke")
    }

    /// A long storm re-arms once per window, not once per poke.
    func testSustainedPokingCostsOneTimerPerWindow() {
        let harness = Harness()
        let timer = harness.makeTimer(window: 0.1)
        var ran = 0

        for _ in 0..<5 {
            // 200 pokes spread over 0.02s, so the timer armed at the top of the
            // window expires 0.08s after the last of them — still inside it.
            for _ in 0..<200 {
                harness.now = harness.now.addingTimeInterval(0.0001)
                timer.poke { ran += 1 }
            }
            harness.fireNext(after: 0.08)
            XCTAssertEqual(harness.scheduled.count, 1, "never more than one outstanding")
        }

        XCTAssertEqual(ran, 0, "the pokes never stopped, so it never ran")
        XCTAssertEqual(harness.totalScheduled, 6, "one per window plus the first")
    }

    /// The most recent action wins, matching the cancel-and-replace behaviour
    /// this type replaced.
    func testLastPokeWins() {
        let harness = Harness()
        let timer = harness.makeTimer(window: 0.1)
        var log: [String] = []

        timer.poke { log.append("first") }
        timer.poke { log.append("second") }
        harness.fireNext(after: 0.1)

        XCTAssertEqual(log, ["second"])
    }

    func testCancelDropsThePendingAction() {
        let harness = Harness()
        let timer = harness.makeTimer(window: 0.1)
        var ran = 0

        timer.poke { ran += 1 }
        timer.cancel()
        harness.fireNext(after: 0.1)

        XCTAssertEqual(ran, 0)
        XCTAssertFalse(timer.isArmed, "the in-flight timer fired and found nothing")
    }

    /// After running, the timer is idle: the next poke schedules again rather
    /// than waiting for a block that will never come.
    func testRearmsAfterRunning() {
        let harness = Harness()
        let timer = harness.makeTimer(window: 0.1)
        var ran = 0

        timer.poke { ran += 1 }
        harness.fireNext(after: 0.1)
        XCTAssertEqual(ran, 1)

        timer.poke { ran += 1 }
        XCTAssertEqual(harness.scheduled.count, 1)
        harness.fireNext(after: 0.1)
        XCTAssertEqual(ran, 2)
    }
}
