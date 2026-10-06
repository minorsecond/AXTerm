//
//  DisconnectOnQuitTests.swift
//  AXTermTests
//
//  Quitting sends DISC on every live link (DL-DISCONNECT from layer 3) and
//  waits for each to settle: the peer's UA or DM, or the DISC's first T1
//  running out. T1 starts when the frame has left the radio (spec 7.3), so
//  this waits out a slow key-up too.
//
//  Smoke run 2026-10-03-1, issue 85: A (705) quit twice with a link up to
//  B (ID-50) and no DISC reached the air. The quit closed the radios 0.4 s
//  after handing the DISC over, which suits a KISS TNC that holds the frame
//  but not AXTerm's own sound modem, where the frame was still queued and
//  keying the IC-705 through Warbler takes seconds. B polled the dead link
//  until the relaunched A answered DM.
//

import XCTest
@testable import AXTerm

@MainActor
final class DisconnectOnQuitTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)
    private let local = AX25Address(call: "K0EPI", ssid: 2)

    private func connected() throws -> (AX25SessionManager, AX25VirtualClock, AX25Session) {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        manager.localCallsign = local
        manager.defaultConfig = AX25SessionConfig(initialRto: 3.0)
        _ = try XCTUnwrap(manager.connect(to: peer))
        clock.advance(by: 1.0)
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        XCTAssertEqual(session.state, .connected)
        return (manager, clock, session)
    }

    func testTheUAToTheDISCSettlesIt() throws {
        let (manager, clock, session) = try connected()
        _ = try XCTUnwrap(manager.disconnect(session: session))
        XCTAssertFalse(manager.disconnectSettled(session.key))
        clock.advance(by: 1.5)
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertTrue(manager.disconnectSettled(session.key))
    }

    func testADMSettlesItToo() throws {
        let (manager, clock, session) = try connected()
        _ = try XCTUnwrap(manager.disconnect(session: session))
        clock.advance(by: 1.5)
        manager.handleInboundDM(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertTrue(manager.disconnectSettled(session.key))
    }

    /// No answer: settled once the DISC has had its T1, counted from when the
    /// radio said the frame went out.
    func testWithNoAnswerItSettlesAfterOneT1FromTheRealTransmission() throws {
        let (manager, clock, session) = try connected()
        _ = try XCTUnwrap(manager.disconnect(session: session))
        let t1 = session.timers.rto

        clock.advance(by: 2.5)                 // keying through Warbler
        manager.transmissionEnded(on: .primary)
        clock.advance(by: t1 - 0.1)
        XCTAssertFalse(manager.disconnectSettled(session.key),
                       "gave up before the DISC had a full T1 on the air")
        clock.advance(by: 0.2)
        XCTAssertTrue(manager.disconnectSettled(session.key))
    }

    func testALinkThatIsGoneIsSettled() throws {
        let (manager, _, session) = try connected()
        let key = session.key
        manager.forceDisconnect(session: session)
        XCTAssertTrue(manager.disconnectSettled(key))
    }
}
