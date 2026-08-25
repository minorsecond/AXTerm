//
//  AX25ConnectRTTKarnTests.swift
//  AXTermTests
//
//  Karn's algorithm on the connect handshake.
//
//  Field capture 2026-08-25, connecting to W0ARP-10 on a busy channel: the UA
//  arrived on the 5th SABM, after 4+8+16+30s of backoff. The RTT sample was
//  taken against the *first* SABM, so the whole backoff ladder was charged to
//  the path:
//
//      [──] [RTT] Update | peer=W0ARP-10 rto=30000.0ms rttvar=30560.3ms srtt=61120.5ms
//
//  The link's real round trip was 1.8s. Every T3 poll afterwards waited the
//  clamped 30s maximum on a healthy link. The I-frame path already discarded
//  ambiguous samples via `rttSendTime(ackedBy:)`; the connect path did not.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25ConnectRTTKarnTests: XCTestCase {

    private let peer = AX25Address(call: "W0ARP", ssid: 10)

    private func makeManager() -> (AX25SessionManager, AX25VirtualClock) {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        return (manager, clock)
    }

    // MARK: - The unambiguous case still samples

    func testFirstSABMAnsweredByUAProducesAnRTTSample() {
        let (manager, clock) = makeManager()
        _ = manager.connect(to: peer)
        let session = try! XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), channel: 0))

        clock.currentTime += 1.8
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)

        XCTAssertEqual(session.state, .connected)
        // A UA that answers the only SABM in flight is unambiguous, so the
        // measurement is real and must be kept.
        let srtt = try! XCTUnwrap(session.timers.srtt)
        XCTAssertEqual(srtt, 1.8, accuracy: 0.01)
    }

    // MARK: - The ambiguous case must not

    func testUAAfterRetransmittedSABMProducesNoRTTSample() {
        let (manager, clock) = makeManager()
        _ = manager.connect(to: peer)
        let session = try! XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), channel: 0))

        clock.currentTime += 4.0
        _ = manager.handleT1Timeout(session: session)   // SABM #2
        clock.currentTime += 8.0
        _ = manager.handleT1Timeout(session: session)   // SABM #3
        clock.currentTime += 16.0
        _ = manager.handleT1Timeout(session: session)   // SABM #4

        clock.currentTime += 1.8
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)

        XCTAssertEqual(session.state, .connected)
        // 29.8s elapsed since the first SABM, but the UA cannot be attributed
        // to any particular one. No sample beats a fabricated one.
        XCTAssertNil(session.timers.srtt,
                     "A UA answering a retransmitted SABM must yield no RTT sample")
    }

    func testRetransmittedConnectDoesNotInflateRTO() {
        let (manager, clock) = makeManager()
        _ = manager.connect(to: peer)
        let session = try! XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), channel: 0))
        let rtoBeforeAnyTimeout = session.timers.rto

        clock.currentTime += 4.0
        _ = manager.handleT1Timeout(session: session)
        clock.currentTime += 8.0
        _ = manager.handleT1Timeout(session: session)
        clock.currentTime += 60.0
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)

        // Backoff legitimately raised the RTO while retrying; what must not
        // happen is the 72s elapsed becoming a measurement that pins the RTO
        // at its ceiling for the rest of the session.
        XCTAssertLessThan(session.timers.rto, 30.0,
                          "A 72s ambiguous elapsed time must not drive the RTO to its clamp")
        XCTAssertGreaterThanOrEqual(session.timers.rto, rtoBeforeAnyTimeout)
    }

    // MARK: - The flag must not leak between sessions

    func testReconnectingClearsTheRetransmitFlag() {
        let (manager, clock) = makeManager()
        _ = manager.connect(to: peer)
        let first = try! XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), channel: 0))

        clock.currentTime += 4.0
        _ = manager.handleT1Timeout(session: first)
        XCTAssertTrue(first.sabmRetransmitted)

        clock.currentTime += 1.0
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        manager.forceDisconnect(session: first)

        // A fresh connect is a fresh measurement opportunity. If the flag
        // survived, this peer could never produce an RTT sample again.
        clock.currentTime += 1.0
        _ = manager.connect(to: peer)
        let second = try! XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), channel: 0))
        XCTAssertFalse(second.sabmRetransmitted)

        clock.currentTime += 2.0
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        XCTAssertNotNil(second.timers.srtt,
                        "A clean reconnect must be able to measure the path again")
    }

    // MARK: - A T1 expiry on an established link is not a connect retransmit

    func testT1TimeoutWhileConnectedDoesNotSetTheConnectFlag() {
        let (manager, clock) = makeManager()
        _ = manager.connect(to: peer)
        let session = try! XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), channel: 0))
        clock.currentTime += 1.5
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        XCTAssertEqual(session.state, .connected)

        _ = manager.sendData(Data([0x41]), to: peer, path: DigiPath(), channel: 0)
        clock.currentTime += 5.0
        _ = manager.handleT1Timeout(session: session)

        // The flag describes the connect handshake only. An I-frame retransmit
        // has its own Karn bookkeeping and must not be conflated with it.
        XCTAssertFalse(session.sabmRetransmitted,
                       "A T1 expiry in the connected state is an I-frame retransmit, not a SABM one")
    }
}
