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

    // MARK: - Fixed: a lap-old retransmission is not buffered as new data
    //
    // S2.faithfulPeer seed 0xA4E687328B834A8A (peer K=7): peer frames 4, 5
    // and 6 were delivered a second time after frame 11. A peer may keep up
    // to 7 frames outstanding (§6.4.1, k up to 7 in modulo 8), and the
    // receive span is 4. When our ack of a full window is lost, the peer
    // resends frames we already delivered, and their N(S) sits 1 to 3 ahead
    // of V(R), where an out-of-sequence frame is buffered. The buffered
    // copy was then delivered as the next lap's frame, and the real one
    // dropped as a duplicate.

    func testRetransmissionOfADeliveredWindowIsNotDeliveredAgain() throws {
        let (manager, _) = makeManager()
        var delivered: [String] = []
        manager.onDataReceived = { _, data in delivered.append(String(decoding: data, as: UTF8.self)) }
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)

        func send(_ ns: Int, _ text: String, pf: Bool = false) {
            _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                            ns: ns, nr: 0, pf: pf, payload: Data(text.utf8))
        }
        // A full K=7 window, all received. Our RR answering the poll is lost.
        for ns in 0..<7 { send(ns, "f\(ns)", pf: ns == 6) }
        XCTAssertEqual(delivered, (0..<7).map { "f\($0)" })

        // The peer's T1 runs out and it resends the window from frame 0.
        for ns in 0..<7 { send(ns, "f\(ns)", pf: ns == 0) }
        XCTAssertEqual(delivered.count, 7, "a retransmission was delivered: \(delivered)")

        // It hears our ack at last and carries on with frames 7 and 8.
        send(7, "f7")
        send(0, "f8")
        XCTAssertEqual(delivered, (0...8).map { "f\($0)" })
    }

    /// A genuine new frame that repeats the old bytes is held back, not
    /// lost: it is sent again after the REJ and delivered then.
    func testNewFrameRepeatingOldBytesIsDeliveredOnItsResend() throws {
        let (manager, _) = makeManager()
        var delivered: [String] = []
        manager.onDataReceived = { _, data in delivered.append(String(decoding: data, as: UTF8.self)) }
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        func send(_ ns: Int, _ text: String) -> OutboundFrame? {
            manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                        ns: ns, nr: 0, pf: false, payload: Data(text.utf8))
        }
        for ns in 0..<7 { _ = send(ns, "line\r") }
        _ = send(7, "x")
        // Frame 8 (N(S)=0) is lost; frame 9 (N(S)=1) repeats the bytes of
        // frame 1, so it is not buffered. A REJ asks for frame 8.
        let reply = send(1, "line\r")
        XCTAssertEqual(reply?.displayInfo, "REJ(0)")
        XCTAssertEqual(delivered.count, 8)
        // Go-back-N: frames 8 and 9 again.
        _ = send(0, "line\r")
        _ = send(1, "line\r")
        XCTAssertEqual(delivered.count, 10)
    }

    // MARK: - Fixed: a new link starts its N2 ladder at zero
    //
    // S1.hostile seed 0x036E22AFF228470A: retryCount 9 with N2=8 on a
    // connected link. A DISC sent while connecting retried until N2 and
    // gave up (disconnected, retryCount N2+1); the session had never been
    // connected, so a peer SABM reused it, and the link came up already
    // past N2. Its first T1 expiry failed it.

    func testLinkOpenedAfterAnExhaustedTeardownGetsItsFullN2() throws {
        let (manager, clock) = makeManager(maxRetries: 3)
        _ = manager.connect(to: peer)
        let session = try XCTUnwrap(manager.existingSession(for: peer))
        _ = manager.disconnect(session: session)
        XCTAssertEqual(session.state, .disconnecting)
        clock.advance(by: 120)
        XCTAssertEqual(session.state, .disconnected, "precondition: the DISC ran out its retries")

        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let reopened = try XCTUnwrap(manager.existingSession(for: peer))
        XCTAssertEqual(reopened.state, .connected)
        XCTAssertEqual(reopened.stateMachine.retryCount, 0)

        _ = manager.sendData(Data("hello".utf8), to: peer)
        _ = manager.handleT1Timeout(session: reopened)
        XCTAssertEqual(reopened.state, .connected, "one T1 expiry must not fail a fresh link with N2=3")
    }
}
