//
//  TurnaroundEvidenceTests.swift
//  AXTermTests
//
//  The hint for replies lost to the other station's transmitter tail. On the
//  air on 2026-09-30 the IC-705, keyed through Warbler, stayed on the air
//  about 0.7 s after each frame. K0EPI-3's TNC4 answered inside that window,
//  K0EPI-2 missed the start of the reply, and the retries, which came seconds
//  later, got through. Raising K0EPI-3's TX delay to 800 ms fixed it.
//
//  AXTerm leaves TX delay to the operator. It says what it sees: I-frames sent
//  right after hearing the station go unheard far more often than ones sent
//  later. Plain loss, spread evenly over both, must never raise the hint.
//

import XCTest
@testable import AXTerm

final class TurnaroundEvidenceTests: XCTestCase {

    private var evidence = TurnaroundEvidence()
    private var clock: TimeInterval = 1_000
    private var ns = 0
    private var changes: [TurnaroundEvidence.Change] = []

    override func setUp() {
        super.setUp()
        evidence = TurnaroundEvidence()
        clock = 1_000
        ns = 0
        changes = []
    }

    // MARK: - Helpers

    private func record(_ change: TurnaroundEvidence.Change?) {
        if let change { changes.append(change) }
    }

    private func nextNS() -> Int {
        defer { ns = (ns + 1) % 8 }
        return ns
    }

    private var appearances: Int {
        changes.filter { if case .appeared = $0 { return true } else { return false } }.count
    }

    private var clearances: Int {
        changes.filter { if case .cleared = $0 { return true } else { return false } }.count
    }

    /// One I-frame, alone in its burst, sent `gap` seconds after the last frame
    /// heard from the station. A missed one is sent again 1.5 s after a later
    /// frame from the peer, which is between the two timing classes and so is
    /// not a sample itself; that keeps each call to exactly one sample.
    private func send(after gap: TimeInterval, missed: Bool) {
        clock += 20
        record(evidence.noteHeard(at: clock))
        let n = nextNS()
        record(evidence.noteSent(ns: n, at: clock + gap))
        if missed {
            clock += gap + 5
            record(evidence.noteHeard(at: clock))
            record(evidence.noteSent(ns: n, at: clock + 1.5))
        }
        record(evidence.noteAcknowledged(ns: n))
    }

    private func turnaround(missed: Bool) { send(after: 0.05, missed: missed) }
    private func later(missed: Bool) { send(after: 6, missed: missed) }

    /// The 2026-09-30 exchange as it happens on the link: the peer's frame,
    /// our reply 50 ms later, and when that is missed, our T1 retry four
    /// seconds on, with nothing heard from the peer in between.
    private func fieldExchange(replyMissed: Bool, retriesMissed: Int = 0) {
        clock += 10
        record(evidence.noteHeard(at: clock))
        let n = nextNS()
        var sentAt = clock + 0.05
        record(evidence.noteSent(ns: n, at: sentAt))
        if replyMissed {
            for _ in 0...retriesMissed {
                sentAt += 4
                record(evidence.noteSent(ns: n, at: sentAt))
            }
        }
        clock = sentAt
        record(evidence.noteAcknowledged(ns: n))
    }

    // MARK: - The pattern from the field

    func testRepliesMissedRightAfterTheStationWhileRetriesGetThroughShowTheHint() {
        // Three replies in five missed, every retry heard.
        let pattern = [true, true, false, true, false]
        for i in 0..<40 {
            fieldExchange(replyMissed: pattern[i % pattern.count])
        }
        XCTAssertTrue(evidence.isShowing, "tally: \(evidence.tally)")
        XCTAssertEqual(appearances, 1, "the hint appears once and stays, it does not repeat")
        XCTAssertEqual(clearances, 0)
        XCTAssertGreaterThanOrEqual(evidence.tally.turnaroundMissed, 12)
        XCTAssertEqual(evidence.tally.laterMissed, 0)
    }

    func testTheSamePatternMadeOfSingleSamplesShowsTheHint() {
        for i in 0..<20 {
            turnaround(missed: i % 3 != 2)
            if i % 2 == 0 { later(missed: false) }
        }
        XCTAssertTrue(evidence.isShowing, "tally: \(evidence.tally)")
    }

    // MARK: - Loss spread evenly

    func testEvenlySpreadLossNeverShowsTheHint() {
        // Two in five missed in both classes, interleaved two to one.
        let pattern = [true, false, false, true, false]
        for i in 0..<300 {
            let missed = pattern[i % pattern.count]
            if i % 3 == 2 { later(missed: missed) } else { turnaround(missed: missed) }
        }
        XCTAssertEqual(appearances, 0, "tally: \(evidence.tally)")
        XCTAssertFalse(evidence.isShowing)
    }

    func testRandomEvenLossNeverShowsTheHint() {
        for seed in UInt64(1)...6 {
            for lossRate in [0.1, 0.3, 0.5, 0.7] {
                setUp()
                var random = SplitMix64(seed: seed)
                for _ in 0..<300 {
                    let missed = random.nextDouble() < lossRate
                    if random.nextDouble() < 0.7 { turnaround(missed: missed) } else { later(missed: missed) }
                }
                XCTAssertEqual(appearances, 0,
                               "seed \(seed), loss \(lossRate): \(evidence.tally)")
            }
        }
    }

    /// The same even loss through the real exchange shape, where every missed
    /// reply produces a retry and the retry can be missed too.
    func testEvenLossThroughRetriesNeverShowsTheHint() {
        for seed in UInt64(11)...16 {
            for lossRate in [0.2, 0.4, 0.6] {
                setUp()
                var random = SplitMix64(seed: seed)
                for _ in 0..<200 {
                    let replyMissed = random.nextDouble() < lossRate
                    var retriesMissed = 0
                    while replyMissed, retriesMissed < 6, random.nextDouble() < lossRate {
                        retriesMissed += 1
                    }
                    fieldExchange(replyMissed: replyMissed, retriesMissed: retriesMissed)
                }
                XCTAssertEqual(appearances, 0,
                               "seed \(seed), loss \(lossRate): \(evidence.tally)")
            }
        }
    }

    // MARK: - Enough evidence first

    func testTooFewTurnaroundSamplesDoNotShowTheHint() {
        for _ in 0..<11 { turnaround(missed: true) }
        for _ in 0..<20 { later(missed: false) }
        XCTAssertFalse(evidence.isShowing, "11 replies are too few to judge")
        turnaround(missed: true)
        XCTAssertTrue(evidence.isShowing, "the twelfth meets the minimum")
    }

    func testTooFewLaterSamplesDoNotShowTheHint() {
        for _ in 0..<20 { turnaround(missed: true) }
        for _ in 0..<7 { later(missed: false) }
        XCTAssertFalse(evidence.isShowing, "seven later frames cannot show that retries get through")
        later(missed: false)
        XCTAssertTrue(evidence.isShowing, "the eighth meets the minimum")
    }

    func testRetriesThatAlsoFailDoNotShowTheHint() {
        // Everything is lost. That is a bad link, not a turnaround problem.
        for _ in 0..<30 { turnaround(missed: true) }
        for _ in 0..<15 { later(missed: true) }
        XCTAssertFalse(evidence.isShowing)
    }

    // MARK: - Clearing

    func testTheHintClearsWhenRepliesGetThroughAgain() {
        for _ in 0..<12 { turnaround(missed: true) }
        for _ in 0..<8 { later(missed: false) }
        XCTAssertTrue(evidence.isShowing)

        // TX delay raised: replies right after the station are heard now.
        for _ in 0..<40 { turnaround(missed: false) }
        XCTAssertFalse(evidence.isShowing, "tally: \(evidence.tally)")
        XCTAssertEqual(appearances, 1)
        XCTAssertEqual(clearances, 1, "cleared once, with no flicker on the way")
    }

    func testOldEvidenceAgesOut() {
        for _ in 0..<12 { turnaround(missed: true) }
        for _ in 0..<8 { later(missed: false) }
        XCTAssertTrue(evidence.isShowing)

        clock += 31 * 60
        record(evidence.noteHeard(at: clock))
        XCTAssertFalse(evidence.isShowing, "half an hour old evidence says nothing about now")
        XCTAssertEqual(evidence.tally.turnaroundSent, 0)
        XCTAssertEqual(evidence.tally.laterSent, 0)
        XCTAssertEqual(clearances, 1)
    }

    func testResetForgetsTheEvidenceButNotWhenTheStationWasLastHeard() {
        for _ in 0..<12 { turnaround(missed: true) }
        for _ in 0..<8 { later(missed: false) }
        XCTAssertTrue(evidence.isShowing)
        let heard = evidence.lastHeardAt

        record(evidence.reset())
        XCTAssertFalse(evidence.isShowing)
        XCTAssertEqual(evidence.tally.turnaroundSent, 0)
        XCTAssertEqual(evidence.tally.laterSent, 0)
        XCTAssertEqual(evidence.lastHeardAt, heard,
                       "the UA that opens a link is heard just before the reset")
        XCTAssertEqual(clearances, 1)
    }

    // MARK: - What counts as a sample

    func testOnlyTheFirstFrameOfABurstIsASample() {
        // Four frames handed over together go out in one transmission. Only
        // the first sits right behind the station's own transmission; the
        // others follow it on the air and fail with it under go-back-N.
        clock += 20
        record(evidence.noteHeard(at: clock))
        for n in 0..<4 { record(evidence.noteSent(ns: n, at: clock + 0.05)) }
        clock += 5
        for n in 0..<4 { record(evidence.noteSent(ns: n, at: clock)) }
        for n in 0..<4 { record(evidence.noteAcknowledged(ns: n)) }

        XCTAssertEqual(evidence.tally.turnaroundSent, 1)
        XCTAssertEqual(evidence.tally.turnaroundMissed, 1)
        XCTAssertEqual(evidence.tally.laterSent, 1)
        XCTAssertEqual(evidence.tally.laterMissed, 0)
    }

    func testFramesBetweenTheTwoClassesAreNotSamples() {
        send(after: 1.5, missed: true)
        send(after: 1.0, missed: false)
        XCTAssertEqual(evidence.tally.turnaroundSent, 0)
        XCTAssertEqual(evidence.tally.laterSent, 0)
    }

    func testFramesBeforeAnythingIsHeardAreNotSamples() {
        record(evidence.noteSent(ns: 0, at: clock))
        record(evidence.noteAcknowledged(ns: 0))
        XCTAssertEqual(evidence.tally.turnaroundSent, 0)
        XCTAssertEqual(evidence.tally.laterSent, 0)
    }

    func testAFrameStillOutstandingIsNotYetASample() {
        clock += 20
        record(evidence.noteHeard(at: clock))
        record(evidence.noteSent(ns: 0, at: clock + 0.05))
        XCTAssertEqual(evidence.tally.turnaroundSent, 0)
        evidence.forgetOutstanding()
        record(evidence.noteAcknowledged(ns: 0))
        XCTAssertEqual(evidence.tally.turnaroundSent, 0,
                       "a link reset leaves nothing to judge the frame by")
    }

    // MARK: - Determinism

    func testTheSameEvidenceGivesTheSameResult() {
        func run() -> (TurnaroundEvidence, [TurnaroundEvidence.Change]) {
            setUp()
            var random = SplitMix64(seed: 42)
            for _ in 0..<120 {
                fieldExchange(replyMissed: random.nextDouble() < 0.6)
            }
            return (evidence, changes)
        }
        let first = run()
        let second = run()
        XCTAssertEqual(first.0, second.0)
        XCTAssertEqual(first.1, second.1)
        XCTAssertFalse(first.1.isEmpty, "the run should have raised the hint at least once")
    }

    // MARK: - The words

    func testTheHintNamesTheStationAndTheTXDelay() {
        let text = TurnaroundHint.message(station: "K0EPI-2", txDelayMs: 300)
        XCTAssertTrue(text.contains("K0EPI-2"), text)
        XCTAssertTrue(text.contains("300 ms"), text)
        XCTAssertTrue(text.contains("TX delay"), text)
    }

    func testTheHintLeavesOutATXDelayItDoesNotKnow() {
        let text = TurnaroundHint.message(station: "K0EPI-2", txDelayMs: nil)
        XCTAssertTrue(text.contains("K0EPI-2"), text)
        XCTAssertTrue(text.contains("TX delay"), text)
        XCTAssertFalse(text.contains("now"), text)
        XCTAssertFalse(text.contains("ms"), text)
    }

    func testTheTooltipGivesTheCounts() {
        for _ in 0..<9 { turnaround(missed: true) }
        for _ in 0..<5 { turnaround(missed: false) }
        later(missed: true)
        for _ in 0..<7 { later(missed: false) }
        let help = TurnaroundHint.help(station: "K0EPI-2", tally: evidence.tally)
        XCTAssertTrue(help.contains("14"), help)
        XCTAssertTrue(help.contains("9"), help)
        XCTAssertTrue(help.contains("8"), help)
        XCTAssertTrue(help.contains("K0EPI-2"), help)
        XCTAssertTrue(help.contains("1 had to be sent again"), help)
    }
}

private extension SplitMix64 {
    /// Uniform in [0, 1), so "random" loss is the same on every run.
    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
