//
//  OnAirAfterPeerHeardTests.swift
//  AXTermTests
//
//  Hearing the peer proves only that our frames handed to the radio before
//  it began transmitting have gone. Frames handed while it was on the air
//  waited for the channel and go out after it. Smoke run 2026-10-03-1, test
//  13.3, issue 103: A (705) handed four 256-byte frames to the modem while
//  the phone's four RRs were arriving; each RR heard pulled the estimate
//  back to "now", T1 expired during A's own 7.5 s burst, and A resent
//  frames that were still going out.
//

import XCTest
@testable import AXTerm

@MainActor
final class OnAirAfterPeerHeardTests: XCTestCase {

    private let local = AX25Address(call: "LOCAL", ssid: 1)
    private let peer = AX25Address(call: "PEER", ssid: 2)
    private let keyUp = 0.8
    /// A 256-byte I-frame on the air: info plus address, control, PID, FCS.
    private let fullFrame = 274
    private func airtime(_ bytes: Int) -> Double { Double(bytes) * 8 / 1200 }

    private func connectedSession() throws -> AX25Session {
        let manager = AX25SessionManager(localCallsign: local, clock: RecordingTimerScheduler())
        manager.keyUpSeconds = { [keyUp] _ in (keyUp, keyUp) }
        _ = manager.connect(to: peer, path: DigiPath())
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath()))
        XCTAssertEqual(session.state, .connected)
        return session
    }

    func testFramesHandedOverWhileThePeerTransmittedStillHaveTheirAirtimeAhead() throws {
        let session = try connectedSession()
        // The peer's RRs arrive between our hand-offs, as at 12:28:52.
        session.noteHandedToRadio(bytes: fullFrame, at: 100.00)
        session.capOnAir(at: 100.06)
        session.noteHandedToRadio(bytes: fullFrame, at: 100.10)
        session.capOnAir(at: 100.16)
        session.noteHandedToRadio(bytes: fullFrame, at: 100.24)
        session.capOnAir(at: 100.31)
        session.noteHandedToRadio(bytes: fullFrame, at: 100.34)

        // All four go out after the last RR: a key-up, then four frames.
        XCTAssertEqual(session.onAirUntil, 100.31 + keyUp + 4 * airtime(fullFrame), accuracy: 0.001)
    }

    func testAFrameHandedOverWellBeforeThePeerSpokeHasGone() throws {
        let session = try connectedSession()
        session.noteHandedToRadio(bytes: 30, at: 100.0)
        session.capOnAir(at: 105.0)
        XCTAssertLessThanOrEqual(session.onAirUntil, 105.0,
                                 "the peer answering is proof our earlier frame went out")
    }

    /// The RRs at 12:28:52 acknowledged I1 to I4, which had gone; I5 to I0,
    /// handed over meanwhile, had not. An acknowledged frame has certainly
    /// left, however recently it was handed over.
    func testAnAcknowledgedFrameHasGoneHoweverRecentlyItWasHandedOver() throws {
        let session = try connectedSession()
        XCTAssertEqual(session.va, 0)
        for ns in 0..<4 { session.noteHandedToRadio(bytes: fullFrame, at: 100.0, ns: ns) }
        session.capOnAir(at: 100.1, acknowledgedUpTo: 2)
        XCTAssertEqual(session.onAirUntil, 100.1 + keyUp + 2 * airtime(fullFrame), accuracy: 0.001,
                       "N(R) 2 proves frames 0 and 1 sent; 2 and 3 still wait for the channel")
        session.capOnAir(at: 100.2, acknowledgedUpTo: 4)
        XCTAssertEqual(session.onAirUntil, 100.2, accuracy: 0.001)
    }

    func testHearingThePeerStillPullsAnOverlongEstimateBack() throws {
        let session = try connectedSession()
        // An estimate made at 1200 bit/s runs ahead on a faster link; the
        // peer answering long after the hand-off brings it back.
        for _ in 0..<7 { session.noteHandedToRadio(bytes: fullFrame, at: 100.0) }
        XCTAssertGreaterThan(session.onAirUntil, 112)
        session.capOnAir(at: 104.0)
        XCTAssertEqual(session.onAirUntil, 104.0, accuracy: 0.001)
    }
}
