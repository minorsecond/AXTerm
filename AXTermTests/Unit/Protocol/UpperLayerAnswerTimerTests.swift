//
//  UpperLayerAnswerTimerTests.swift
//  AXTermTests
//
//  Frames the layer above sends while an inbound frame is being handled,
//  from a delivery or from an acknowledgment, are protected by T1 like any
//  other I-frame.
//
//  Found by the full-stack fuzz, 2026-10-02: YAPP's receiver sends AF the
//  moment EF is delivered, AXDP's receiver its completion ack the moment
//  the last chunk is, and a Winlink peer its next line the moment the last
//  one arrives. Those sends ran inside the inbound I-frame's action list,
//  before the stopT1 the state machine had computed while nothing was
//  outstanding, and that stopT1 then canceled the timer the answer had just
//  started. Lose the answer once and nothing resent it: the exchange sat
//  until the protocol above gave up (YAPP after its response timeout, AXDP
//  after its completion timeout), with the file already at the receiver.
//
//  The same happened to frames sent when an acknowledgment arrived: YAPP's
//  sender pumps its next blocks from the claim's ack handler, which ran
//  before the RR's own actions, so a burst sent on an RR that acked
//  everything lost its T1, and with it the poll on its last frame.
//
//  In the SDL a DL-DATA request from layer 3 is queued and handled after
//  the transition in progress, so the session now finishes a frame's
//  bookkeeping before it tells the layer above anything.
//

import XCTest
@testable import AXTerm

@MainActor
final class UpperLayerAnswerTimerTests: XCTestCase {

    private let local = AX25Address(call: "K0AAA", ssid: 1)
    private let peer = AX25Address(call: "K0BBB", ssid: 2)

    /// A connected session (the peer called us) whose delivered data is
    /// answered at once with `reply`, the way YAPP and AXDP answer.
    private func answeringSession(clock: AX25VirtualClock, reply: Data)
        -> (AX25SessionManager, AX25Session, () -> [OutboundFrame]) {
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        manager.onDataReceived = { [weak manager] _, _ in
            guard let manager else { return }
            let frames = manager.sendData(reply, to: self.peer, path: DigiPath(), radio: .primary)
            sent.append(contentsOf: frames)
        }
        return (manager, session, { sent })
    }

    private func iFrames(_ frames: [OutboundFrame]) -> [OutboundFrame] {
        frames.filter { $0.frameType == "i" }
    }

    func testAnAnswerSentFromADeliveryIsRetransmittedWhenItIsLost() {
        let clock = AX25VirtualClock()
        let reply = Data([0x06, 0x03])  // YAPP AF
        let (manager, session, sent) = answeringSession(clock: clock, reply: reply)

        _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                        ns: 0, nr: 0, pf: false, payload: Data([0x03, 0x01]))  // EF
        XCTAssertEqual(iFrames(sent()).count, 1, "the answer went out")
        XCTAssertEqual(session.outstandingCount, 1)

        // The answer is lost; the peer hears nothing and says nothing.
        clock.advance(by: 30)
        let resent = iFrames(sent()).dropFirst()
        XCTAssertFalse(resent.isEmpty, "T1 never fired for the answer, so nothing resent it")
        XCTAssertEqual(resent.first?.ns, 0)
        XCTAssertEqual(resent.first?.payload, reply)
    }

    /// The same with a poll on the delivered frame, which also answers with
    /// RR F=1 as the handler's response.
    func testAnAnswerToAPolledFrameIsRetransmittedWhenItIsLost() {
        let clock = AX25VirtualClock()
        let (manager, _, sent) = answeringSession(clock: clock, reply: Data("OK\r".utf8))

        let response = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                                   ns: 0, nr: 0, pf: true, payload: Data("HI\r".utf8))
        XCTAssertEqual(response?.nr, 1, "the poll is still answered")
        XCTAssertEqual(iFrames(sent()).count, 1)

        clock.advance(by: 30)
        XCTAssertGreaterThan(iFrames(sent()).count, 1, "the lost answer was never resent")
    }

    /// The answer carries N(R), so T2 has nothing left to send.
    func testTheAnswerSettlesTheDelayedAck() {
        let clock = AX25VirtualClock()
        let (manager, _, sent) = answeringSession(clock: clock, reply: Data([0x06, 0x03]))

        _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                        ns: 0, nr: 0, pf: false, payload: Data([0x03, 0x01]))
        // Before T1 (4 s by default) but after T2.
        clock.advance(by: 3)
        let rrs = sent().filter { $0.displayInfo?.hasPrefix("RR") == true }
        XCTAssertTrue(rrs.isEmpty, "the answer's N(R) already acknowledged the frame: \(rrs.compactMap(\.displayInfo))")
    }

    // MARK: Frames sent on an acknowledgment

    /// A session we opened, with one frame outstanding and a claim whose ack
    /// handler sends `next` once, the way YAPP pumps its next block.
    private func pumpingSession(clock: AX25VirtualClock, next: Data)
        -> (AX25SessionManager, AX25Session, () -> [OutboundFrame]) {
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        sent += manager.sendData(Data("first".utf8), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.outstandingCount, 1)
        var pumped = false
        _ = manager.claimDelivery(for: session.key, handler: { _, _ in }, ackHandler: { [weak manager] _, _ in
            guard let manager, !pumped else { return }
            pumped = true
            sent += manager.sendData(next, to: self.peer, path: DigiPath(), radio: .primary)
        })
        return (manager, session, { sent })
    }

    func testABlockSentWhenAnRRAcksEverythingIsRetransmittedWhenItIsLost() {
        let clock = AX25VirtualClock()
        let next = Data("second".utf8)
        let (manager, session, sent) = pumpingSession(clock: clock, next: next)

        _ = manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary, nr: 1)
        XCTAssertEqual(iFrames(sent()).count, 2, "the next block went out")
        XCTAssertEqual(session.outstandingCount, 1)

        clock.advance(by: 30)
        let resent = iFrames(sent()).dropFirst(2)
        XCTAssertFalse(resent.isEmpty, "the RR's stale stop of T1 left the new block unprotected")
        XCTAssertEqual(resent.first?.payload, next)
    }

    func testABlockSentWhenAPiggybackedAckArrivesIsRetransmittedWhenItIsLost() {
        let clock = AX25VirtualClock()
        let next = Data("second".utf8)
        let (manager, _, sent) = pumpingSession(clock: clock, next: next)

        _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                        ns: 0, nr: 1, pf: false, payload: Data("ok".utf8))
        XCTAssertEqual(iFrames(sent()).count, 2)

        clock.advance(by: 30)
        XCTAssertGreaterThan(iFrames(sent()).count, 2, "the new block was never resent")
    }

    /// A REJ that acks the first frame and asks for nothing else: a block
    /// pumped on its ack goes out once, not again as a "retransmission".
    func testABlockSentOnAREJsAckIsNotSentTwice() {
        let clock = AX25VirtualClock()
        let next = Data("second".utf8)
        let (manager, _, sent) = pumpingSession(clock: clock, next: next)

        let frames = manager.handleInboundREJ(from: peer, path: DigiPath(), radio: .primary, nr: 1)
        let all = iFrames(sent() + frames).filter { $0.payload == next }
        XCTAssertEqual(all.count, 1, "the pumped block was also sent as a REJ retransmission")
    }
}
