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

    // S2.faithfulPeer seed 0x404236750E5215E5 (peer K=6, N2=2): frames 1
    // and 2 were lost, the T1 gap flush skipped them, and the peer, which
    // had not yet heard the ack that skip sent, resent them. By then V(R)
    // had moved on so that their N(S) sat just ahead of it; they were
    // buffered and delivered after frame 6.

    func testCopiesOfFramesSkippedByTheGapFlushAreNotDeliveredLater() throws {
        let (manager, _) = makeManager(maxRetries: 2)
        var delivered: [String] = []
        manager.onDataReceived = { _, data in delivered.append(String(decoding: data, as: UTF8.self)) }
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer))
        func send(_ ns: Int, _ text: String) {
            _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                            ns: ns, nr: 0, pf: false, payload: Data(text.utf8))
        }
        // A K=6 window; frames 0 and 1 are lost, 2 and 3 are buffered.
        send(2, "f2"); send(3, "f3")
        // Two T1 expiries reach the flush threshold: 0 and 1 are skipped.
        _ = manager.handleT1Timeout(session: session)
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(delivered, ["f2", "f3"], "precondition: the flush skipped frames 0 and 1")
        send(4, "f4"); send(5, "f5")

        // The peer resends frame 0; its N(S) is now 2 ahead of V(R)=6.
        send(0, "f0")
        send(6, "f6"); send(7, "f7"); send(0, "f8")
        XCTAssertEqual(delivered, ["f2", "f3", "f4", "f5", "f6", "f7", "f8"])
    }

    // MARK: - Fixed: a poll that fills one SREJ gap and exposes another
    //
    // S1.hostile seed 0xD01EA0FF5018BFC4: with SREJ negotiated, V(R)=0 and
    // frames 1 and 3 buffered, I(0) with P=1 delivered 0 and 1 and exposed
    // the gap at 2. The state machine asked for SREJ(2) F=0 and RR F=1,
    // but the manager returns one response per I-frame, so only the SREJ
    // went out and the poll was never answered (§6.2).

    func testPollThatExposesASecondSREJGapIsAnswered() throws {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = AX25SessionConfig(srejEnabled: true)
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        func send(_ ns: Int, pf: Bool) -> OutboundFrame? {
            manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                        ns: ns, nr: 0, pf: pf, payload: Data("f\(ns)".utf8))
        }
        _ = send(1, pf: false)  // gap at 0: SREJ(0)
        _ = send(3, pf: false)  // buffered behind it
        let reply = try XCTUnwrap(send(0, pf: true))

        XCTAssertEqual(manager.existingSession(for: peer)?.vr, 2)
        XCTAssertEqual(reply.frameType, "s")
        XCTAssertEqual(reply.isCommand, false)
        XCTAssertNotEqual((reply.controlByte ?? 0) & 0x10, 0, "the poll needs F=1: got \(reply.displayInfo ?? "?")")
        XCTAssertEqual(reply.displayInfo, "SREJ(2)", "the new gap is still asked for")
    }

    // MARK: - Fixed: RTT samples only from frames newly acknowledged
    //
    // T5.rttSampleSource seed 0xFDC063FFDAB7FDA1: RR(2) with V(A)=7 and
    // V(S)=0 acknowledged nothing new, yet took a 34.6 s RTT sample from a
    // frame acknowledged a lap earlier by a piggybacked N(R), whose send
    // time was never cleared. Spec 7.3 updates the estimator "on each acked
    // frame"; Karn's rule likewise times only an unambiguous new ack.

    func testRepeatedAckAfterAPiggybackedAckTakesNoRTTSample() throws {
        let (manager, clock) = makeManager()
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer))

        _ = manager.sendData(Data("hello".utf8), to: peer)
        clock.advance(by: 0.5)
        // The peer's reply acknowledges our frame by piggybacking N(R)=1.
        _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                        ns: 0, nr: 1, pf: false, payload: Data("hi".utf8))
        XCTAssertEqual(session.va, 1)
        let srtt = session.timers.srtt

        // A poll 25 s later (inside T3, so no timer of ours runs) repeats
        // N(R)=1.
        clock.advance(by: 25)
        _ = manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                          nr: 1, pf: true, isCommand: true)
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.timers.srtt, srtt, "a repeated N(R) was timed against a frame acked long ago")
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
