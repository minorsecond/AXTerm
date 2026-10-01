//
//  AX25PropertyFindingsTests.swift
//  AXTermTests
//
//  Fixed-input tests for what the seeded property tests found. Each one
//  names the property and seed that first showed it. Defects that were
//  fixed are plain tests; behavior that departs from AX.25 2.2 but was
//  left alone as a design choice is recorded with XCTExpectFailure, so the
//  day it changes the test says so.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25PropertyFindingsTests: XCTestCase {

    private let local = AX25Address(call: "LOCAL", ssid: 1)
    private let peer = AX25Address(call: "PEER", ssid: 2)

    private func makeManager(maxRetries: Int = 2) -> (AX25SessionManager, AX25VirtualClock) {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = AX25SessionConfig(maxRetries: maxRetries, rtoMin: 1, rtoMax: 4, initialRto: 1)
        return (manager, clock)
    }

    private func connected(_ manager: AX25SessionManager) throws -> AX25Session {
        _ = manager.connect(to: peer)
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer))
        XCTAssertEqual(session.state, .connected)
        return session
    }

    private func isDMFinal(_ frame: OutboundFrame?) -> Bool {
        frame?.displayInfo == "DM" && ((frame?.controlByte ?? 0) & 0x10) != 0
    }

    // MARK: - Fixed: DM(F=1) to a poll on a link that is not up
    //
    // S1.hostile seed 0xA530300FFEB8C6B2 (I P=1 while disconnecting) and
    // S2.faithfulPeer seed 0xE38B709A44E6F9BE (I P=1 after our N2 failure).
    // §6.3.5: "Any TNC receiving a command frame other than a SABM(E) or UI
    // frame with the P bit set to '1' responds with a DM frame with the F
    // bit set to '1'." SDL C4.3 says the same while awaiting release.

    func testIFramePollWhileDisconnectingDrawsDM() throws {
        let (manager, _) = makeManager()
        let session = try connected(manager)
        _ = manager.disconnect(session: session)
        XCTAssertEqual(session.state, .disconnecting)

        let reply = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                                ns: 0, nr: 0, pf: true, payload: Data("x".utf8))
        XCTAssertTrue(isDMFinal(reply), "got \(String(describing: reply?.displayInfo))")
    }

    func testIFramePollOnAnEndedSessionDrawsDM() throws {
        let (manager, _) = makeManager()
        let session = try connected(manager)
        _ = manager.handleInboundDISC(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .disconnected)

        let reply = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                                ns: 0, nr: 0, pf: true, payload: Data("x".utf8))
        XCTAssertTrue(isDMFinal(reply))
        XCTAssertNil(manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                                 ns: 1, nr: 0, pf: false, payload: Data("y".utf8)),
                     "a P=0 frame is ignored, never answered with DM")
    }

    func testPollsAfterLinkFailureDrawDM() throws {
        let (manager, clock) = makeManager(maxRetries: 1)
        let session = try connected(manager)
        _ = manager.sendData(Data("hello".utf8), to: peer)
        clock.advance(by: 60)
        XCTAssertEqual(session.state, .error, "precondition: N2 exhausted")

        let iReply = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                                 ns: 0, nr: 0, pf: true, payload: Data("x".utf8))
        XCTAssertTrue(isDMFinal(iReply))
        let rrReply = manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                    nr: 0, pf: true, isCommand: true)
        XCTAssertTrue(isDMFinal(rrReply.first))
        XCTAssertTrue(manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                    nr: 0, pf: true, isCommand: false).isEmpty,
                      "an F=1 response is not a poll")
        XCTAssertEqual(session.state, .error, "answering does not revive the link")
    }
}
