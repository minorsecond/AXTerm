//
//  T1PeerAckDelayTests.swift
//  AXTermTests
//
//  T1 against a peer that holds its acknowledgment.
//
//  An I-frame sent without P=1 is acknowledged when the peer's T2 runs out,
//  not at once. On 2026-10-01 station B sent one chat line (P=0) to a peer
//  whose T2 is 2 s, through an IC-705 whose key-up path adds about 1.6 s.
//  B's T1 fired after 4.3 s, while the RR needed about 5.3 s to arrive, so
//  B's retransmission keyed over the RR and neither was heard. The RTO is
//  learned from exchanges the peer answers at once, so it cannot cover the
//  peer's T2 by itself. These pin that the first wait for unpolled frames
//  does, and that a poll (which is answered at once) still waits only the
//  RTO.
//

import XCTest
@testable import AXTerm

@MainActor
final class T1PeerAckDelayTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 2)
    private let local = AX25Address(call: "K0EPI", ssid: 3)

    /// Frames go out two ways: `sendData` returns the first transmission,
    /// and timers hand theirs to `onSendFrame`. The log holds both.
    private final class SentLog { var frames: [OutboundFrame] = [] }

    private func connected() throws -> (AX25SessionManager, AX25VirtualClock, AX25Session, SentLog) {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        manager.localCallsign = local
        let log = SentLog()
        manager.onSendFrame = { log.frames.append($0) }
        // B answered A's call, as in the field; the station that placed a
        // call polls its first I-frame anyway (shouldPollFirstOutboundIFrame).
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        clock.advance(by: 1)
        XCTAssertEqual(session.state, .connected)
        log.frames.removeAll()
        return (manager, clock, session, log)
    }

    private func isIFrame(_ frame: OutboundFrame) -> Bool {
        guard let control = frame.controlByte else { return false }
        return control & 0x01 == 0
    }

    private func polls(_ frame: OutboundFrame) -> Bool {
        (frame.controlByte ?? 0) & 0x10 != 0
    }

    // MARK: - The delay itself

    func testUnpolledFramesWaitForThePeersAckDelay() {
        let delay = AX25SessionManager.t1Delay(rto: 4.0, srtt: 2.5, bytesInFlight: 83,
                                               awaitingDelayedAck: true)
        // 2.5 s round trip + 83 bytes of our own airtime at 1200 bps + 3 s.
        XCTAssertEqual(delay, 2.5 + 83.0 * 8 / 1200 + 3.0, accuracy: 0.001)
        XCTAssertGreaterThan(delay, 4.0)
    }

    func testAPollWaitsOnlyTheRTO() {
        XCTAssertEqual(AX25SessionManager.t1Delay(rto: 4.0, srtt: 2.5, bytesInFlight: 83,
                                                  awaitingDelayedAck: false), 4.0)
    }

    func testTheRTOWinsWhenItIsAlreadyLonger() {
        XCTAssertEqual(AX25SessionManager.t1Delay(rto: 12.0, srtt: 2.5, bytesInFlight: 83,
                                                  awaitingDelayedAck: true), 12.0)
    }

    func testWithNoRoundTripYetTheRTOStandsInForIt() {
        XCTAssertEqual(AX25SessionManager.t1Delay(rto: 4.0, srtt: nil, bytesInFlight: 0,
                                                  awaitingDelayedAck: true), 7.0, accuracy: 0.001)
    }

    // MARK: - On the link

    /// The field case: one unpolled chat line. Nothing is resent while the
    /// peer's delayed ack could still be on its way.
    func testALoneUnpolledFrameIsNotResentBeforeThePeersAckCanArrive() throws {
        let (manager, clock, session, log) = try connected()
        log.frames += manager.sendData(Data("B to A test 1: reply without the sidebar".utf8), to: peer)
        let first = try XCTUnwrap(log.frames.first(where: isIFrame))
        XCTAssertFalse(polls(first), "precondition: a lone frame does not fill the window, so P=0")

        clock.advance(by: session.timers.rto + 0.5)

        XCTAssertEqual(log.frames.filter(isIFrame).count, 1,
                       "T1 resent the frame before the peer's delayed RR could arrive")
        XCTAssertEqual(session.stateMachine.retryCount, 0)
    }

    /// The delayed ack arriving inside the longer wait settles it with no
    /// retransmission at all.
    func testTheDelayedAckArrivingLateStillSettlesItWithoutARetry() throws {
        let (manager, clock, session, log) = try connected()
        log.frames += manager.sendData(Data("hello".utf8), to: peer)
        clock.advance(by: session.timers.rto + 1.0)
        _ = manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                          nr: session.vs, pf: false, isCommand: false)
        clock.advance(by: 20)

        XCTAssertEqual(log.frames.filter(isIFrame).count, 1)
        XCTAssertEqual(session.outstandingCount, 0)
    }

    /// A frame really lost is still recovered, a few seconds later than the
    /// bare RTO, and the recovery after that waits only the RTO.
    func testALostUnpolledFrameIsStillRecovered() throws {
        let (manager, clock, session, log) = try connected()
        log.frames += manager.sendData(Data("hello".utf8), to: peer)
        let wait = AX25SessionManager.t1Delay(rto: session.timers.rto, srtt: session.timers.srtt,
                                              bytesInFlight: 5 + 18, awaitingDelayedAck: true)
        clock.advance(by: wait + 0.5)

        XCTAssertGreaterThanOrEqual(session.stateMachine.retryCount, 1, "a lost frame must still time out")
        XCTAssertGreaterThan(log.frames.count, 1, "the timeout polls or resends")
    }

    /// A window-filling burst ends with P=1, which the peer answers at once,
    /// so its T1 is the plain RTO.
    func testAWindowFillingBurstKeepsThePlainRTO() throws {
        let (manager, clock, session, log) = try connected()
        let window = session.liveWindowSize
        for i in 0..<window {
            log.frames += manager.sendData(Data("frame \(i)".utf8), to: peer)
        }
        XCTAssertTrue(log.frames.filter(isIFrame).contains(where: polls), "precondition: the window-full checkpoint polls")

        clock.advance(by: session.timers.rto + 0.5)

        XCTAssertGreaterThanOrEqual(session.stateMachine.retryCount, 1,
                                    "a polled burst waits only the RTO")
    }
}
