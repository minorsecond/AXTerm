//
//  DelayedAckTests.swift
//  AXTermTests
//
//  T2 delayed cumulative acknowledgment (AX.25 §6.7.1.2 "response delay
//  timer"). Before this, every in-sequence I-frame produced an immediate RR:
//  a gateway running K=4 got four of our key-ups per burst where the
//  protocol needs exactly one, each costing ~0.5 s of channel time at
//  1200 baud — and on simplex our RR could collide with the gateway's next
//  I-frame, converting our own acknowledgment into inbound loss and a full
//  go-back-N resend.
//
//  The rules under test:
//  - An in-sequence I-frame with P=0 arms (or re-arms) T2 instead of acking.
//  - A P=1 frame is answered immediately with F=1 — that ack is cumulative,
//    so the whole burst is acknowledged by the one response.
//  - T2 expiry acks once, and only if an ack is still owed.
//  - Anything that already carries N(R) — an outgoing I-frame, a REJ —
//    satisfies the debt and disarms T2.
//

import XCTest
@testable import AXTerm

final class DelayedAckTests: XCTestCase {

    private func connected(config: AX25SessionConfig = AX25SessionConfig()) -> AX25StateMachine {
        var sm = AX25StateMachine(config: config)
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
        return sm
    }

    private func rrActions(_ actions: [AX25SessionAction]) -> [(nr: Int, pf: Bool)] {
        actions.compactMap {
            if case .sendRR(let nr, let pf, _) = $0 { return (nr, pf) }
            return nil
        }
    }

    private func iFrame(_ ns: Int, pf: Bool = false) -> AX25SessionEvent {
        .receivedIFrame(ns: ns, nr: 0, pf: pf, payload: Data("f\(ns)".utf8))
    }

    // MARK: - The burst case

    /// The download pattern: the gateway sends its whole window with P=1 on
    /// the final frame. One RR — the F=1 response — must acknowledge all of
    /// it; the P=0 frames must produce no RR at all.
    func testBurstWithFinalPollProducesExactlyOneAck() {
        var sm = connected()
        var allActions = [AX25SessionAction]()
        for ns in 0..<3 {
            let actions = sm.handle(event: iFrame(ns))
            XCTAssertTrue(rrActions(actions).isEmpty,
                          "P=0 frame \(ns) must not be acked immediately")
            XCTAssertTrue(actions.contains(.startT2),
                          "an unacked delivery arms the response timer")
            allActions.append(contentsOf: actions)
        }
        let final = sm.handle(event: iFrame(3, pf: true))
        let rrs = rrActions(final)
        XCTAssertEqual(rrs.count, 1)
        XCTAssertEqual(rrs.first?.nr, 4, "cumulative: one RR covers the whole burst")
        XCTAssertEqual(rrs.first?.pf, true, "the poll demands F=1")
        XCTAssertTrue(final.contains(.stopT2), "the debt is paid; disarm T2")
    }

    /// A peer that never polls still gets its ack when T2 expires — once.
    func testQuietBurstAcksOnceWhenT2Fires() {
        var sm = connected()
        for ns in 0..<3 {
            XCTAssertTrue(rrActions(sm.handle(event: iFrame(ns))).isEmpty)
        }
        let onExpiry = sm.handle(event: .t2Timeout)
        let rrs = rrActions(onExpiry)
        XCTAssertEqual(rrs.count, 1)
        XCTAssertEqual(rrs.first?.nr, 3)
        XCTAssertEqual(rrs.first?.pf, false)

        XCTAssertTrue(rrActions(sm.handle(event: .t2Timeout)).isEmpty,
                      "a stale T2 with nothing owed must stay silent")
    }

    func testT2WithNothingPendingSendsNothing() {
        var sm = connected()
        XCTAssertTrue(sm.handle(event: .t2Timeout).isEmpty)
    }

    // MARK: - Frames that already carry the ack

    /// REJ carries N(R): detecting a gap acknowledges everything before it,
    /// so the ack debt is settled and T2 must not fire a redundant RR.
    func testREJSettlesTheAckDebt() {
        var sm = connected()
        _ = sm.handle(event: iFrame(0))          // pending ack, T2 armed
        let gap = sm.handle(event: iFrame(2))    // 1 missing → REJ
        XCTAssertTrue(gap.contains(where: {
            if case .sendREJ = $0 { return true }
            return false
        }))
        XCTAssertTrue(gap.contains(.stopT2), "REJ carries N(R) — the debt is paid")
        XCTAssertTrue(rrActions(sm.handle(event: .t2Timeout)).isEmpty)
    }

    /// Filling the gap delivers the run; with P=0 that delivery re-arms T2
    /// rather than acking immediately.
    func testGapFillReturnsToDelayedAcking() {
        var sm = connected()
        _ = sm.handle(event: iFrame(0))
        _ = sm.handle(event: iFrame(2))          // REJ, debt settled
        let fill = sm.handle(event: iFrame(1))   // delivers 1 and 2
        XCTAssertEqual(sm.sequenceState.vr, 3)
        XCTAssertTrue(rrActions(fill).isEmpty, "recovered run is still a P=0 delivery")
        XCTAssertTrue(fill.contains(.startT2))
        XCTAssertEqual(rrActions(sm.handle(event: .t2Timeout)).first?.nr, 3)
    }

    // MARK: - Duplicates

    /// The lost-RR pattern: the peer re-sends an already-received burst.
    /// Re-acks are just as cumulative — silence until the poll, then one
    /// F=1 response.
    func testDuplicateBurstIsReackedOnce() {
        var sm = connected()
        for ns in 0..<3 { _ = sm.handle(event: iFrame(ns)) }
        _ = sm.handle(event: .t2Timeout)         // acked at V(R)=3

        var dupActions = [AX25SessionAction]()
        dupActions.append(contentsOf: sm.handle(event: iFrame(0)))
        dupActions.append(contentsOf: sm.handle(event: iFrame(1)))
        XCTAssertTrue(rrActions(dupActions).isEmpty,
                      "duplicates re-arm T2; they must not each get an RR")
        let poll = sm.handle(event: iFrame(2, pf: true))
        let rrs = rrActions(poll)
        XCTAssertEqual(rrs.count, 1)
        XCTAssertEqual(rrs.first?.pf, true)
        XCTAssertEqual(rrs.first?.nr, 3)
    }

    // MARK: - Unchanged behaviors

    /// An RR command with P=1 (a keepalive poll) is still answered
    /// immediately — that path was never delayed and must not be.
    func testPollIsStillAnsweredImmediately() {
        var sm = connected()
        let actions = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: true))
        XCTAssertEqual(rrActions(actions).count, 1)
        XCTAssertEqual(rrActions(actions).first?.pf, true)
    }

    /// T2 in a dead session is inert.
    func testT2InDisconnectedStateIsIgnored() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        XCTAssertTrue(sm.handle(event: .t2Timeout).isEmpty)
    }

    /// The manager piggybacks N(R) on every I-frame it builds; the state
    /// machine exposes the settle hook it calls when that happens.
    func testOutgoingIFrameSettlesTheDebtViaTheHook() {
        var sm = connected()
        _ = sm.handle(event: iFrame(0))
        XCTAssertTrue(sm.ackPending)
        sm.noteAckTransmitted()
        XCTAssertFalse(sm.ackPending)
        XCTAssertTrue(rrActions(sm.handle(event: .t2Timeout)).isEmpty)
    }
}
