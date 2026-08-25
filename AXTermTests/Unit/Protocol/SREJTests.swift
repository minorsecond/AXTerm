//
//  SREJTests.swift
//  AXTermTests
//
//  Selective reject (AX.25 2.2 §6.4.4.2), enabled only when XID
//  negotiation agreed on it. Go-back-N (REJ) resends every outstanding
//  frame past the gap — on the observed 23%-retx link to W0ARP-10 that
//  multiplies one loss into a whole window of duplicate airtime. SREJ
//  asks for exactly the missing frame.
//
//  The F-bit asymmetry matters and is easy to get wrong (§4.3.2.4):
//  SREJ with F=1 acknowledges everything below N(R); SREJ with F=0
//  acknowledges NOTHING — so sending one must not settle the T2 ack debt,
//  and receiving one must not clear the send buffer.
//

import XCTest
@testable import AXTerm

final class SREJStateMachineTests: XCTestCase {

    private func connected(srej: Bool = true) -> AX25StateMachine {
        var sm = AX25StateMachine(config: AX25SessionConfig(srejEnabled: srej))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
        return sm
    }

    private func iFrame(_ ns: Int, pf: Bool = false) -> AX25SessionEvent {
        .receivedIFrame(ns: ns, nr: 0, pf: pf, payload: Data("f\(ns)".utf8))
    }

    private func srejs(_ actions: [AX25SessionAction]) -> [(nr: Int, pf: Bool)] {
        actions.compactMap {
            if case .sendSREJ(let nr, let pf, _) = $0 { return (nr, pf) }
            return nil
        }
    }

    func testGapSendsSREJForExactlyTheMissingFrame() {
        var sm = connected()
        _ = sm.handle(event: iFrame(0))
        let actions = sm.handle(event: iFrame(2))   // 1 is missing

        XCTAssertEqual(srejs(actions).map(\.nr), [1], "ask for frame 1 and nothing else")
        XCTAssertFalse(actions.contains { if case .sendREJ = $0 { return true }; return false },
                       "never go-back-N when selective reject was negotiated")
        XCTAssertTrue(actions.contains(.startT1), "T1 times the retransmission we asked for")
    }

    func testWithoutNegotiationTheGapStillDrawsREJ() {
        var sm = connected(srej: false)
        _ = sm.handle(event: iFrame(0))
        let actions = sm.handle(event: iFrame(2))
        XCTAssertTrue(actions.contains { if case .sendREJ = $0 { return true }; return false })
        XCTAssertTrue(srejs(actions).isEmpty)
    }

    func testOnlyOneSREJOutstandingPerGap() {
        var sm = connected()
        _ = sm.handle(event: iFrame(0))
        _ = sm.handle(event: iFrame(2))
        let more = sm.handle(event: iFrame(3))      // still the same gap at 1
        XCTAssertTrue(srejs(more).isEmpty, "one SREJ per gap; T1 backs it up")
    }

    /// F=0 SREJ acknowledges nothing, so the T2 ack debt must survive it —
    /// the peer only learns our V(R) from the eventual RR.
    func testSREJWithFZeroLeavesTheAckDebtPending() {
        var sm = connected()
        _ = sm.handle(event: iFrame(0))             // ack debt armed
        let gap = sm.handle(event: iFrame(2))
        XCTAssertEqual(srejs(gap).first?.pf, false)
        XCTAssertFalse(gap.contains(.stopT2), "F=0 SREJ acks nothing — the debt stands")

        let onExpiry = sm.handle(event: .t2Timeout)
        XCTAssertTrue(onExpiry.contains { if case .sendRR(1, false, _) = $0 { return true }; return false },
                      "T2 still owes the peer RR(1)")
    }

    /// A gap frame carrying P=1 demands a Final. SREJ(F=1) both answers
    /// the poll and acknowledges below N(R) — that one settles the debt.
    func testGapWithPollDrawsSREJFinal() {
        var sm = connected()
        _ = sm.handle(event: iFrame(0))
        let gap = sm.handle(event: iFrame(2, pf: true))
        XCTAssertEqual(srejs(gap).first?.pf, true)
        XCTAssertTrue(gap.contains(.stopT2), "F=1 SREJ acks below N(R) — debt settled")
        XCTAssertTrue(sm.handle(event: .t2Timeout).isEmpty)
    }

    /// Two separate gaps: filling the first must immediately SREJ the
    /// second, or the tail sits in the buffer until T1 rescues it.
    func testFillingTheFirstGapAsksForTheSecond() {
        var sm = connected()
        _ = sm.handle(event: iFrame(0))             // vr=1
        _ = sm.handle(event: iFrame(2))             // gap at 1 → SREJ(1)
        _ = sm.handle(event: iFrame(4))             // second gap at 3, SREJ already out
        let fill = sm.handle(event: iFrame(1))      // delivers 1,2 → vr=3; 4 still buffered

        XCTAssertEqual(sm.sequenceState.vr, 3)
        XCTAssertEqual(srejs(fill).map(\.nr), [3], "the second gap is asked for at once")
        XCTAssertTrue(fill.contains(.startT1))
    }
}

@MainActor
final class SREJManagerTests: XCTestCase {

    private var manager: AX25SessionManager!
    private let peer = AX25Address(call: "W0ARP", ssid: 10)

    override func setUp() {
        super.setUp()
        manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        manager.getConfigForDestination = { _, _ in
            AX25SessionConfig(windowSize: 4, srejEnabled: true)
        }
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    private func connectAndSendThree() -> AX25Session {
        _ = manager.handleInboundSABM(
            from: peer, to: manager.localCallsign, path: DigiPath(), channel: 0)
        let session = manager.existingSession(for: peer)!
        for byte in ["A", "B", "C"] {
            _ = manager.sendData(Data(byte.utf8), to: peer, path: DigiPath(), channel: 0)
        }
        XCTAssertEqual(session.outstandingCount, 3)
        return session
    }

    func testInboundSREJRetransmitsExactlyTheRequestedFrame() {
        let session = connectAndSendThree()
        let frames = manager.handleInboundSREJ(
            from: peer, path: DigiPath(), channel: 0, nr: 1, pf: false)

        XCTAssertEqual(frames.count, 1, "SREJ(1) asks for one frame, not go-back-N")
        XCTAssertEqual(frames.first?.ns, 1)
        XCTAssertEqual(session.va, 0, "F=0: nothing acknowledged")
        XCTAssertEqual(session.outstandingCount, 3, "send buffer untouched")
    }

    func testInboundSREJWithFinalAcksBelowIt() {
        let session = connectAndSendThree()
        let frames = manager.handleInboundSREJ(
            from: peer, path: DigiPath(), channel: 0, nr: 2, pf: true)

        XCTAssertEqual(session.va, 2, "F=1: frames 0 and 1 are acknowledged")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.ns, 2)
    }

    func testDuplicateSREJDoesNotAmplifyRetransmissions() {
        _ = connectAndSendThree()
        let first = manager.handleInboundSREJ(
            from: peer, path: DigiPath(), channel: 0, nr: 1, pf: false)
        XCTAssertEqual(first.count, 1)
        let second = manager.handleInboundSREJ(
            from: peer, path: DigiPath(), channel: 0, nr: 1, pf: false)
        XCTAssertTrue(second.isEmpty, "a duplicate SREJ storm must not multiply airtime — T1 owns the retry")
    }

    func testSREJForUnknownSessionIsIgnored() {
        let frames = manager.handleInboundSREJ(
            from: AX25Address(call: "N0BODY", ssid: 1), path: DigiPath(), channel: 0, nr: 0, pf: false)
        XCTAssertTrue(frames.isEmpty)
    }
}
