import XCTest
@testable import AXTerm

/// The dashboard's two derived panels: directional link health and the
/// session-cap projection. Both exist to answer questions a single
/// aggregate number hides, so the arithmetic has to be exact.
final class ExchangeDashboardTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Directional health

    private func snapshot(
        framesSent: Int = 0,
        framesReceived: Int = 0,
        retransmissions: Int = 0,
        rejSent: Int = 0
    ) -> LinkWindowSnapshot {
        LinkWindowSnapshot(
            peer: "W0ARP-10", context: "inbound-I",
            vs: 0, va: 0, vr: 0, outstanding: 0, windowSize: 2, retryCount: 0,
            sendBufferSeq: [], rto: 4, srtt: 2, rttvar: 0.5, date: start,
            framesSent: framesSent,
            framesReceived: framesReceived,
            retransmissions: retransmissions,
            rejSent: rejSent)
    }

    /// The field case the panel was built for: we are the quiet end, so a
    /// forward-only reading calls a struggling link perfect.
    func testDownloadWithReverseLossShowsTheAsymmetry() {
        let snap = snapshot(framesSent: 20, framesReceived: 344, rejSent: 16)

        XCTAssertEqual(snap.df ?? 0, 1.0, accuracy: 0.0001, "our own frames all landed")
        XCTAssertEqual(snap.dr ?? 0, 1 - 16.0 / 360.0, accuracy: 0.0001)
        XCTAssertGreaterThan(snap.etx ?? 0, 1.0,
                             "the inbound loss must be visible in ETX")
    }

    func testCleanLinkReadsAsPerfectInBothDirections() {
        let snap = snapshot(framesSent: 40, framesReceived: 40)
        XCTAssertEqual(snap.df ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(snap.dr ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(snap.etx ?? 0, 1.0, accuracy: 0.0001)
    }

    func testForwardLossIsAttributedToTheOutboundDirection() {
        let snap = snapshot(framesSent: 8, framesReceived: 50, retransmissions: 2)
        XCTAssertEqual(snap.df ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(snap.dr ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(snap.etx ?? 0, 1 / 0.8, accuracy: 0.001)
    }

    func testNoTrafficMeasuresNothingRatherThanClaimingPerfection() {
        let snap = snapshot()
        XCTAssertNil(snap.df)
        XCTAssertNil(snap.dr)
        XCTAssertNil(snap.etx)
    }

    /// One direction silent must not be reported as a zero — it is unknown,
    /// and the other direction stands in.
    func testASilentDirectionFallsBackRatherThanScoringZero() {
        let snap = snapshot(framesSent: 10, retransmissions: 0)
        XCTAssertEqual(snap.df ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertNil(snap.dr, "nothing was received, so nothing is known")
        XCTAssertEqual(snap.etx ?? 0, 1.0, accuracy: 0.0001)
    }

    func testETXIsClampedToTheSpecCeiling() {
        let snap = snapshot(framesSent: 1, framesReceived: 1,
                            retransmissions: 500, rejSent: 500)
        XCTAssertEqual(snap.etx ?? 0, 20.0, accuracy: 0.0001)
    }

    // MARK: - Session budget

    private func budget(
        elapsed: Double,
        cap: Double?,
        remaining: Int,
        rate: Double?
    ) -> SessionBudget {
        SessionBudget(
            startedAt: start,
            observedCapSeconds: cap,
            bytesRemaining: remaining,
            bytesPerSecond: rate,
            now: start.addingTimeInterval(elapsed))
    }

    /// W0ARP-10 caps at ~17½ min. Six minutes in at 25 B/s with 30 kB left,
    /// the honest answer is "most of this resumes next time", not an ETA
    /// the session will never reach.
    func testTransferThatCannotFitReportsWhatWillCarryOver() {
        let budget = budget(elapsed: 360, cap: 1_065, remaining: 30_000, rate: 25)

        XCTAssertEqual(budget.secondsToCap ?? 0, 705, accuracy: 0.5)
        XCTAssertEqual(budget.finishesThisSession, false,
                       "30 kB at 25 B/s needs 1200 s; only 705 s remain")
        XCTAssertEqual(budget.bytesBeforeCap ?? 0, 17_625, "705 s × 25 B/s")
        XCTAssertEqual(budget.bytesCarriedToNextSession, 30_000 - 17_625)
    }

    /// The boundary: exactly enough time is still enough.
    func testTransferThatExactlyFitsIsNotReportedAsOverrunning() {
        // 705 s remain; 705 s × 25 B/s = 17,625 bytes.
        let budget = budget(elapsed: 360, cap: 1_065, remaining: 17_625, rate: 25)
        XCTAssertEqual(budget.finishesThisSession, true)
        XCTAssertEqual(budget.bytesCarriedToNextSession, 0)
    }

    func testTransferThatFitsReportsNoCarryOver() {
        let budget = budget(elapsed: 60, cap: 1_065, remaining: 5_000, rate: 25)
        XCTAssertEqual(budget.finishesThisSession, true)
        XCTAssertEqual(budget.bytesCarriedToNextSession, 0)
    }

    /// A gateway with no cap history must not have one invented for it.
    func testNoObservedCapMakesNoProjection() {
        let budget = budget(elapsed: 300, cap: nil, remaining: 20_000, rate: 25)
        XCTAssertFalse(budget.hasCap)
        XCTAssertNil(budget.secondsToCap)
        XCTAssertNil(budget.bytesBeforeCap)
        XCTAssertNil(budget.finishesThisSession)
        XCTAssertEqual(budget.bytesCarriedToNextSession, 0)
    }

    /// A very short previous session means the link failed, not that a
    /// timer fired — that is not evidence of a cap.
    func testAShortPreviousSessionIsNotTreatedAsACap() {
        let budget = budget(elapsed: 30, cap: 45, remaining: 20_000, rate: 25)
        XCTAssertFalse(budget.hasCap)
        XCTAssertNil(budget.secondsToCap)
    }

    func testPastTheCapClampsToZeroRatherThanGoingNegative() {
        let budget = budget(elapsed: 1_200, cap: 1_065, remaining: 5_000, rate: 25)
        XCTAssertEqual(budget.secondsToCap ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(budget.bytesBeforeCap ?? -1, 0)
        XCTAssertEqual(budget.bytesCarriedToNextSession, 5_000,
                       "everything left now resumes next session")
    }

    func testUnknownRateMakesNoProjection() {
        let budget = budget(elapsed: 60, cap: 1_065, remaining: 20_000, rate: nil)
        XCTAssertNil(budget.bytesBeforeCap)
        XCTAssertNil(budget.finishesThisSession)
    }

    func testNothingLeftToTransferAlwaysFits() {
        let budget = budget(elapsed: 1_000, cap: 1_065, remaining: 0, rate: 25)
        XCTAssertEqual(budget.finishesThisSession, true)
        XCTAssertEqual(budget.bytesCarriedToNextSession, 0)
    }

    func testElapsedIsZeroBeforeASessionStarts() {
        let budget = SessionBudget(
            startedAt: nil, observedCapSeconds: 1_065,
            bytesRemaining: 0, bytesPerSecond: nil, now: start)
        XCTAssertEqual(budget.elapsed, 0)
    }
}
