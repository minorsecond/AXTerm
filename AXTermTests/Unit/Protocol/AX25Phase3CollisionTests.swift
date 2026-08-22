//
//  AX25Phase3CollisionTests.swift
//  AXTermTests
//
//  Phase 3 — Adversarial Collisions & Recovery
//
//  Deterministic torture tests for:
//    - REJ storms (amplification, duplicate suppression, delayed/stale REJ)
//    - Duplicate SABM handling (while connected, during reconnect, collision)
//    - DISC collisions (simultaneous DISC, DISC during retransmit, ghost timer cleanup)
//    - Partial-window recovery (partial ACK, retransmit subset correctness)
//    - Stale/invalid frame rejection (invalid N(R) in REJ)
//
//  All timer-sensitive tests use AX25VirtualClock for determinism.
//  All tests assert internal invariants via checkInvariants().
//
//  Bugs identified and regression-tested here:
//    Bug A: REJ retransmission amplification — N REJs produce N retransmits
//    Bug B: DISC received while connected does not stop T1 timer (ghost timer)
//    Bug C: DISC collision — handleInboundDISC only searches .connected sessions,
//            misses .disconnecting for the simultaneous-DISC (§6.4.2) case
//    Bug D: Stale REJ corrupts send buffer — acknowledgeUpTo(from:to:) not guarded
//            by isValidNR, wraps modulo loop and deletes all buffered frames

import XCTest
@testable import AXTerm

@MainActor
final class AX25Phase3CollisionTests: XCTestCase {

    // MARK: - Shared Fixtures

    private let local = AX25Address(call: "NOCALL", ssid: 0)
    private let peer  = AX25Address(call: "COLLIDE", ssid: 1)
    private let path  = DigiPath([])

    private func makeManager(
        windowSize: Int = 4,
        rto: TimeInterval = 2.0,
        maxRetries: Int = 4
    ) -> (AX25SessionManager, AX25VirtualClock) {
        let clock  = AX25VirtualClock()
        let config = AX25SessionConfig(
            windowSize: windowSize,
            maxRetries: maxRetries,
            rtoMin: rto,
            rtoMax: rto * 8,
            initialRto: rto
        )
        let mgr = AX25SessionManager(localCallsign: local, clock: clock)
        mgr.defaultConfig = config
        return (mgr, clock)
    }

    private func connect(_ manager: AX25SessionManager) -> AX25Session {
        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        let s = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(s.state, .connected, "Pre-condition: session must be connected")
        return s
    }

    // MARK: ──────────────────────────────────────────────────────────────
    // MARK: REJ Storm Tests
    // MARK: ──────────────────────────────────────────────────────────────

    /// Bug A: A flood of identical REJ(N(R)) frames must NOT amplify retransmissions.
    ///
    /// Protocol semantics: one REJ triggers one retransmit cycle; T1 governs
    /// all subsequent retransmits. 100 duplicate REJs for the same N(R) with no
    /// ack progress must produce exactly 1 retransmission, not 100.
    ///
    /// Invariant violated before fix:
    ///   retransmitCount must equal 1 after REJ storm with no ack progress
    func testREJStorm_NoRetransmissionAmplification() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        _ = manager.sendData(Data("StormTarget".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)
        XCTAssertEqual(session.va, 0)
        XCTAssertEqual(session.vs, 1)

        // Count I-frame retransmissions returned by handleInboundREJ
        var iFramesRetransmitted = 0
        for _ in 0..<100 {
            let frames = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
            iFramesRetransmitted += frames.filter { $0.frameType == "i" }.count
        }

        // Exactly 1 retransmit: the first REJ triggers it; all subsequent are rate-limited
        XCTAssertEqual(iFramesRetransmitted, 1,
            "REJ storm (100× same N(R)) must produce exactly 1 retransmission — " +
            "not 100 (retransmission amplification)")

        // Session must survive intact
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.outstandingCount, 1, "Frame must still be outstanding (not acked)")
    }

    /// Duplicate REJ with the same N(R) while T1 is already running must not
    /// produce additional retransmits. T1 owns the retransmit cycle after the first REJ.
    func testREJDuplicate_T1RunningPreventsAdditionalRetransmit() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        _ = manager.sendData(Data("FrameA".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("FrameB".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 2)

        // First REJ: retransmit both frames (correct behavior)
        let first = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
        let firstICount = first.filter { $0.frameType == "i" }.count
        XCTAssertEqual(firstICount, 2, "First REJ must retransmit both outstanding frames")

        // Duplicate REJ before T1 fires: must NOT retransmit again
        let second = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
        let secondICount = second.filter { $0.frameType == "i" }.count
        XCTAssertEqual(secondICount, 0,
            "Duplicate REJ(same N(R)) while T1 running must not retransmit")

        let third = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
        XCTAssertEqual(third.filter { $0.frameType == "i" }.count, 0,
            "Third duplicate REJ must also be suppressed")

        // T1 fires: retransmits via timer (separate from REJ suppression)
        var timerRetransmits: [OutboundFrame] = []
        manager.onSendFrame = { timerRetransmits.append($0) }
        clock.advance(by: 2.21)

        let timerI = timerRetransmits.filter { $0.frameType == "i" }.count
        XCTAssertEqual(timerI, 2, "T1 must still retransmit both frames after REJ suppression")

        XCTAssertEqual(session.outstandingCount, 2)
    }

    /// REJ after partial ACK progress: only the unacked portion should be retransmitted.
    func testREJAfterPartialACK_RetransmitsOnlyUnacked() {
        let (manager, _) = makeManager(windowSize: 4)
        let session = connect(manager)

        // Send 4 frames: ns=0,1,2,3
        for i in 0..<4 {
            _ = manager.sendData(Data("F\(i)".utf8), to: peer, path: path, channel: 0)
        }
        XCTAssertEqual(session.outstandingCount, 4)

        // Peer acks 0 and 1 (RR(2))
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 2, isPoll: false)
        XCTAssertEqual(session.va, 2)
        XCTAssertEqual(session.outstandingCount, 2)

        // REJ(2): peer wants retransmit starting from ns=2
        let rejFrames = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 2)
        let retransmittedNS = rejFrames.filter { $0.frameType == "i" }.compactMap { f -> Int? in
            guard let ctrl = f.controlByte else { return nil }
            return Int((ctrl >> 1) & 0x07)
        }.sorted()

        // Must retransmit exactly ns=2 and ns=3, NOT ns=0 or ns=1
        XCTAssertEqual(retransmittedNS, [2, 3],
            "REJ(2) after RR(2) must retransmit only frames 2 and 3")

        // Frames 0 and 1 must not be in retransmit set
        XCTAssertFalse(retransmittedNS.contains(0), "Frame 0 already acked — must not retransmit")
        XCTAssertFalse(retransmittedNS.contains(1), "Frame 1 already acked — must not retransmit")
    }

    /// REJ that advances V(A) (new acks) must trigger retransmit even if T1 is running.
    /// This is correct: REJ(3) after RR(2) means peer acked one more frame and wants
    /// a retransmit from 3 — different from a pure duplicate REJ.
    func testREJWithACKProgress_AlwaysRetransmits() {
        let (manager, _) = makeManager(windowSize: 4)
        let session = connect(manager)

        for i in 0..<4 {
            _ = manager.sendData(Data("X\(i)".utf8), to: peer, path: path, channel: 0)
        }

        // First REJ(0): retransmit all
        let first = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
        XCTAssertEqual(first.filter { $0.frameType == "i" }.count, 4)

        // REJ(2): NEW ack progress (va advances to 2), retransmit from 2
        let second = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 2)
        XCTAssertEqual(session.va, 2)
        let retransmittedNS2 = second.filter { $0.frameType == "i" }.compactMap { f -> Int? in
            guard let ctrl = f.controlByte else { return nil }
            return Int((ctrl >> 1) & 0x07)
        }.sorted()
        XCTAssertEqual(retransmittedNS2, [2, 3],
            "REJ with ack progress must retransmit from new V(A)")
    }

    /// Bug D: REJ with N(R) < V(A) is stale and MUST be fully ignored.
    ///
    /// Before fix: acknowledgeUpTo(from: va, to: stale_nr) wraps modulo loop,
    /// deletes all frames from sendBuffer, then checkInvariants() fires an
    /// assertion crash (sendBuffer.count != outstandingCount).
    ///
    /// After fix: isValidNR check guards acknowledgeUpTo; stale REJ is discarded.
    func testStaleREJ_DoesNotCorruptSendBuffer() {
        let (manager, _) = makeManager(windowSize: 4)
        let session = connect(manager)

        // Send 3 frames: ns=0,1,2
        _ = manager.sendData(Data("F0".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("F1".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("F2".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 3)

        // Ack all: va=3, vs=3, outstanding=0
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 3, isPoll: false)
        XCTAssertEqual(session.va, 3)
        XCTAssertEqual(session.outstandingCount, 0)

        // Send a new frame: ns=3, va=3, vs=4, outstanding=1
        _ = manager.sendData(Data("F3".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)
        XCTAssertNotNil(session.sendBuffer[3], "Frame ns=3 must be in sendBuffer")

        // REJ(1): stale — nr=1 < va=3
        // This MUST be ignored entirely; it must not corrupt sendBuffer
        _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 1)

        XCTAssertEqual(session.outstandingCount, 1,
            "Stale REJ(1) must not delete frame ns=3 from sendBuffer (Bug D)")
        XCTAssertNotNil(session.sendBuffer[3],
            "Frame ns=3 must survive stale REJ — send buffer corruption prevents retransmit")
        XCTAssertEqual(session.va, 3, "V(A) must not regress on stale REJ")
    }

    /// Stale REJ with N(R) == V(A) (already acked) must also be a no-op.
    func testREJForAlreadyAckedFrame_IsNoOp() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        _ = manager.sendData(Data("Single".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)

        // Ack the frame
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 1, isPoll: false)
        XCTAssertEqual(session.outstandingCount, 0)

        // REJ(0): asking to retransmit a frame we no longer have (already acked)
        let frames = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
        XCTAssertEqual(frames.filter { $0.frameType == "i" }.count, 0,
            "REJ for already-acked frame must produce no retransmits")
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertEqual(session.state, .connected)
    }

    // MARK: ──────────────────────────────────────────────────────────────
    // MARK: DISC Collision Tests
    // MARK: ──────────────────────────────────────────────────────────────

    /// Bug B: Receiving DISC while connected must cancel T1.
    ///
    /// Before fix: (.connected, .receivedDISC) state machine returned
    /// [.sendUA, .stopT3, .notifyDisconnected] without .stopT1, leaving the
    /// T1 timer alive as a ghost that fires into a disconnected session.
    ///
    /// After fix: .stopT1 is included, ensuring full timer cleanup on DISC.
    func testDISC_CancelsTi1Timer() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        // Send a frame so T1 is running
        _ = manager.sendData(Data("Pending".utf8), to: peer, path: path, channel: 0)
        XCTAssertNotNil(session.t1TimerTask, "Pre-condition: T1 must be running")
        XCTAssertEqual(session.outstandingCount, 1)

        // Peer sends DISC while we have outstanding frames
        _ = manager.handleInboundDISC(from: peer, path: path, channel: 0)

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertNil(session.t1TimerTask,
            "T1 must be cancelled after DISC received (Bug B — ghost timer)")
        XCTAssertNil(session.t1PendingRetransmitTask,
            "T1 grace-period task must also be cancelled on DISC")
        XCTAssertNil(session.t3TimerTask,
            "T3 must also be stopped on DISC")

        // Advance well past where T1 would have fired — must produce no retransmissions
        var ghostFrames: [OutboundFrame] = []
        manager.onSendFrame = { ghostFrames.append($0) }
        clock.advance(by: 10.0)

        XCTAssertEqual(ghostFrames.filter { $0.frameType == "i" }.count, 0,
            "Ghost T1 must not fire retransmissions after DISC")
    }

    /// Send buffer must be cleared when DISC arrives mid-transfer.
    func testDISC_ClearsSendBufferAndTimers() {
        let (manager, _) = makeManager(windowSize: 4)
        let session = connect(manager)

        // Fill window
        for i in 0..<4 {
            _ = manager.sendData(Data("Frame\(i)".utf8), to: peer, path: path, channel: 0)
        }
        XCTAssertEqual(session.outstandingCount, 4)
        XCTAssertNotNil(session.t1TimerTask)

        _ = manager.handleInboundDISC(from: peer, path: path, channel: 0)

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(session.outstandingCount, 0,
            "Send buffer must be cleared on DISC")
        XCTAssertNil(session.t1TimerTask, "T1 must stop on DISC (Bug B)")
        XCTAssertNil(session.t3TimerTask, "T3 must stop on DISC")
    }

    /// Bug C: Simultaneous DISC collision (AX.25 §6.4.2).
    ///
    /// When we send DISC (state = .disconnecting) and peer also sends DISC,
    /// we must respond with UA (not DM) and transition to .disconnected.
    ///
    /// Before fix: handleInboundDISC used findConnectedSession which only
    /// searches .connected sessions — .disconnecting sessions were missed and the
    /// DISC fell into the no-session path. The fix ensures .disconnecting sessions
    /// are found and the collision is completed with a proper state transition.
    func testSimultaneousDISC_Collision_RespondWithDM() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        // We initiate disconnect: state = .disconnecting
        _ = manager.disconnect(session: session)
        XCTAssertEqual(session.state, .disconnecting,
            "Pre-condition: we must be in disconnecting state")

        // Peer also sends DISC (collision)
        let response = manager.handleInboundDISC(from: peer, path: path, channel: 0)

        // SDL C4.3: DISC in awaiting release is answered with DM; §6.3.4 confirms
        // the peer accepts UA or DM in reply to its DISC. (The Bug C guarantee that
        // the .disconnecting session is FOUND and answered still holds — the answer
        // is simply the SDL's DM rather than UA.)
        XCTAssertNotNil(response, "DISC collision must produce a response frame")
        XCTAssertEqual(response?.displayInfo, "DM",
            "SDL C4.3: DISC collision is answered with DM (§6.3.4 permits either)")

        // Both sides disconnect cleanly
        XCTAssertEqual(session.state, .disconnected,
            "Session must reach .disconnected after DISC collision")

        // T1 must be stopped (not running into limbo)
        XCTAssertNil(session.t1TimerTask, "T1 must stop after DISC collision")
    }

    /// DISC arriving in .disconnecting state cleans up all timers.
    func testDISC_DuringDisconnecting_CleansTimers() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        // Send data then disconnect (T1 running, then DISC starts T1 again for DISC retry)
        _ = manager.sendData(Data("Data".utf8), to: peer, path: path, channel: 0)
        _ = manager.disconnect(session: session)
        XCTAssertEqual(session.state, .disconnecting)

        // Peer sends DISC back
        _ = manager.handleInboundDISC(from: peer, path: path, channel: 0)
        XCTAssertEqual(session.state, .disconnected)

        // No activity after disconnect
        var orphanFrames: [OutboundFrame] = []
        manager.onSendFrame = { orphanFrames.append($0) }
        clock.advance(by: 20.0)

        XCTAssertTrue(orphanFrames.isEmpty, "No frames must be emitted after both sides disconnected")
    }

    /// Receiving DISC with no matching session produces DM (not a crash).
    func testDISC_NoSession_ReturnsDM() {
        let (manager, _) = makeManager()
        let unknownPeer = AX25Address(call: "GHOST-9", ssid: 0)

        let response = manager.handleInboundDISC(from: unknownPeer, path: path, channel: 0)

        XCTAssertNotNil(response, "DISC with no session must return DM")
        XCTAssertEqual(response?.displayInfo, "DM",
            "DISC with no session must return DM")
    }

    /// DISC while outstanding frames exist clears the retransmit queue cleanly.
    func testDISC_WithOutstandingFrames_CompleteCleanTeardown() {
        let (manager, clock) = makeManager(windowSize: 4, rto: 2.0)
        let session = connect(manager)

        // Send full window worth of frames
        for i in 0..<4 {
            _ = manager.sendData(Data("Chunk\(i)".utf8), to: peer, path: path, channel: 0)
        }
        XCTAssertEqual(session.outstandingCount, 4)
        XCTAssertNotNil(session.t1TimerTask)

        // DISC arrives mid-transfer
        _ = manager.handleInboundDISC(from: peer, path: path, channel: 0)

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(session.outstandingCount, 0,
            "All outstanding frames must be cleared on DISC")
        XCTAssertNil(session.t1TimerTask)
        XCTAssertNil(session.t3TimerTask)

        // No more frames after teardown
        var postDisc: [OutboundFrame] = []
        manager.onSendFrame = { postDisc.append($0) }
        clock.advance(by: 30.0)
        XCTAssertTrue(postDisc.isEmpty)
    }

    // MARK: ──────────────────────────────────────────────────────────────
    // MARK: Duplicate SABM Tests
    // MARK: ──────────────────────────────────────────────────────────────

    /// Duplicate SABM received while connected must reset the session (§4.3.3.1).
    /// V(S), V(R), V(A) all return to 0; send buffer flushed; T1 cancelled; T3 running.
    func testDuplicateSABM_WhileConnected_ResetsSession() {
        let (manager, _) = makeManager(windowSize: 4)
        let session = connect(manager)

        // Build up state: send 2 frames, advance vs
        _ = manager.sendData(Data("Before".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("SABM".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.vs, 2)
        XCTAssertEqual(session.outstandingCount, 2)

        // Peer re-sends SABM (link reset)
        let ua = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)

        // Must respond with UA to acknowledge the re-connection
        XCTAssertNotNil(ua)
        XCTAssertEqual(ua?.displayInfo, "UA")
        XCTAssertEqual(ua?.frameType, "u")

        // Session state fully reset
        XCTAssertEqual(session.state, .connected, "Session must stay connected after SABM reset")
        XCTAssertEqual(session.vs, 0, "V(S) must reset to 0 after SABM")
        XCTAssertEqual(session.vr, 0, "V(R) must reset to 0 after SABM")
        XCTAssertEqual(session.va, 0, "V(A) must reset to 0 after SABM")
        XCTAssertEqual(session.outstandingCount, 0, "Send buffer must be flushed on SABM reset")
        XCTAssertNil(session.t1TimerTask, "T1 must stop after SABM reset")
        XCTAssertNotNil(session.t3TimerTask, "T3 must be running after SABM reset")
    }

    /// SABM collision: we send SABM (connecting) and receive SABM simultaneously.
    /// Per §6.3.3 we must respond with UA and transition to connected.
    func testSABM_OutboundCollision_TransitionsToConnected() {
        let (manager, _) = makeManager()

        _ = manager.connect(to: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(session.state, .connecting,
            "Pre-condition: we must be in connecting state")

        // Peer sends SABM back (collision)
        let ua = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)

        XCTAssertEqual(session.state, .connected,
            "SABM collision must transition to connected")
        XCTAssertNotNil(ua, "SABM collision must generate UA response")
        XCTAssertEqual(ua?.displayInfo, "UA")
        XCTAssertNil(session.t1TimerTask, "T1 must stop after SABM collision resolved")
        XCTAssertNotNil(session.t3TimerTask, "T3 must start after SABM collision resolved")
    }

    /// No duplicate sessions from multiple SABM receptions.
    func testDuplicateSABM_NoSessionLeak() {
        let (manager, _) = makeManager()
        let countBefore = manager.sessions.count

        // Receive 5 SABMs from the same peer
        for _ in 0..<5 {
            _ = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)
        }

        XCTAssertEqual(manager.sessions.count, countBefore + 1,
            "5 SABMs from same peer must create exactly 1 session (no leaks)")
    }

    /// SABM while in .disconnecting state should be handled gracefully.
    /// Per spec: remote may not know we're disconnecting; accept the re-connect.
    func testSABM_WhileDisconnecting_Accepted() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        // We initiate disconnect
        _ = manager.disconnect(session: session)
        XCTAssertEqual(session.state, .disconnecting)

        // Peer sends SABM (they don't know we're disconnecting, or it crossed in transit)
        // The state machine doesn't handle (.disconnecting, .receivedSABM) explicitly
        // so it falls through to the catch-all. Verify no crash and clean state.
        let response = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)

        // Don't crash; session should be in a consistent state
        XCTAssertTrue(
            session.state == .disconnecting ||
            session.state == .disconnected ||
            session.state == .connected,
            "SABM while disconnecting must leave session in a consistent state, got \(session.state)"
        )
        _ = response // Ignore response frame (behavior is implementation-defined for this edge)
    }

    // MARK: ──────────────────────────────────────────────────────────────
    // MARK: Partial Window Recovery Tests
    // MARK: ──────────────────────────────────────────────────────────────

    /// Partial ACK advances V(A) correctly; remaining window is still tracked.
    func testPartialWindowACK_CorrectBufferState() {
        let (manager, _) = makeManager(windowSize: 4)
        let session = connect(manager)

        // Send 4 frames
        for i in 0..<4 {
            _ = manager.sendData(Data("Chunk\(i)".utf8), to: peer, path: path, channel: 0)
        }
        XCTAssertEqual(session.outstandingCount, 4)

        // Ack first two (V(A) = 2)
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 2, isPoll: false)
        XCTAssertEqual(session.va, 2)
        XCTAssertEqual(session.outstandingCount, 2)
        XCTAssertNil(session.sendBuffer[0], "Acked frame ns=0 must be removed")
        XCTAssertNil(session.sendBuffer[1], "Acked frame ns=1 must be removed")
        XCTAssertNotNil(session.sendBuffer[2], "Outstanding frame ns=2 must remain")
        XCTAssertNotNil(session.sendBuffer[3], "Outstanding frame ns=3 must remain")

        // Ack remaining
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 4, isPoll: false)
        XCTAssertEqual(session.va, 4)
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertNil(session.t1TimerTask, "T1 must stop when window empties")
        XCTAssertNotNil(session.t3TimerTask, "T3 must start when window empties")
    }

    /// After REJ(nr) retransmit, delayed ACK must cleanly advance V(A).
    func testDelayedACK_AfterRetransmit_CleansUpCorrectly() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        _ = manager.sendData(Data("Msg0".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("Msg1".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 2)

        // REJ(0): peer missed frame 0
        let rejFrames = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
        XCTAssertEqual(rejFrames.filter { $0.frameType == "i" }.count, 2,
            "REJ(0) must retransmit both outstanding frames")

        // Delayed ACK arrives after retransmit
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 2, isPoll: false)
        XCTAssertEqual(session.va, 2)
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertNil(session.t1TimerTask, "T1 stops when all acked")

        // Virtual clock: no more retransmits after ACK
        var lateFrames: [OutboundFrame] = []
        manager.onSendFrame = { lateFrames.append($0) }
        clock.advance(by: 10.0)
        XCTAssertEqual(lateFrames.filter { $0.frameType == "i" }.count, 0,
            "No retransmits after full ACK")
    }

    /// Retransmit queue stability: multiple T1 timeouts must not accumulate duplicate frames.
    func testT1_RetransmitQueueStability_NoDuplicates() {
        let (manager, clock) = makeManager(windowSize: 2, rto: 1.0, maxRetries: 4)
        let session = connect(manager)

        _ = manager.sendData(Data("Stable".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)

        var allRetransmits: [OutboundFrame] = []
        manager.onSendFrame = { allRetransmits.append($0) }

        // Fire T1 three times (each causes 1 retransmit)
        for attempt in 1...3 {
            let rto = session.timers.rto
            clock.advance(by: rto + 0.21)
            let iCount = allRetransmits.filter { $0.frameType == "i" }.count
            XCTAssertEqual(iCount, attempt,
                "After \(attempt) T1 timeouts, exactly \(attempt) I-frame retransmit(s) — no accumulation")
        }

        // Session still has exactly 1 outstanding frame (not duplicated)
        XCTAssertEqual(session.outstandingCount, 1)
    }

    // MARK: ──────────────────────────────────────────────────────────────
    // MARK: Duplicate Frame Suppression Tests
    // MARK: ──────────────────────────────────────────────────────────────

    /// Receiving the same I-frame repeatedly must deliver it exactly once.
    func testDuplicateIFrame_DeliveredExactlyOnce() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        var deliveredCount = 0
        manager.onDataReceived = { _, _ in deliveredCount += 1 }

        // Same frame 10 times
        for _ in 0..<10 {
            _ = manager.handleInboundIFrame(
                from: peer, path: path, channel: 0,
                ns: 0, nr: 0, pf: false,
                payload: Data("Repeat".utf8)
            )
        }

        XCTAssertEqual(deliveredCount, 1, "Duplicate I-frames must be delivered exactly once")
        XCTAssertEqual(session.vr, 1, "V(R) must advance exactly once for the sequence")
    }

    /// Receiving duplicate RR frames must not corrupt the ACK state.
    func testDuplicateRR_NoWindowCorruption() {
        let (manager, _) = makeManager(windowSize: 4)
        let session = connect(manager)

        for i in 0..<4 {
            _ = manager.sendData(Data("D\(i)".utf8), to: peer, path: path, channel: 0)
        }
        XCTAssertEqual(session.outstandingCount, 4)

        // Same RR(2) received 10 times
        for _ in 0..<10 {
            _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 2, isPoll: false)
        }

        // V(A) must be exactly 2 (not over-advanced)
        XCTAssertEqual(session.va, 2)
        XCTAssertEqual(session.outstandingCount, 2,
            "Duplicate RR(2) must not over-ack; frames 2 and 3 must remain outstanding")
        XCTAssertNil(session.sendBuffer[0], "ns=0 must be acked")
        XCTAssertNil(session.sendBuffer[1], "ns=1 must be acked")
        XCTAssertNotNil(session.sendBuffer[2], "ns=2 must still be outstanding")
        XCTAssertNotNil(session.sendBuffer[3], "ns=3 must still be outstanding")
    }

    /// Receiving a duplicate I-frame that was already delivered must send RR
    /// to help the peer recover (peer may not have seen our previous RR).
    func testDuplicateIFrame_StillRespondsWithRR() {
        let (manager, _) = makeManager()
        _ = connect(manager)

        // First delivery — V(R) advances to 1
        let first = manager.handleInboundIFrame(
            from: peer, path: path, channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data("Hello".utf8)
        )
        XCTAssertNotNil(first, "First I-frame must trigger RR response")
        XCTAssertEqual(first?.frameType, "s", "Response must be an S-frame (RR)")

        // Duplicate delivery — V(R) must NOT advance again; must still RR
        let dup = manager.handleInboundIFrame(
            from: peer, path: path, channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data("Hello".utf8)
        )
        XCTAssertNotNil(dup, "Duplicate I-frame must still produce an RR (peer recovery)")
    }

    // MARK: ──────────────────────────────────────────────────────────────
    // MARK: Timer Race Tests (Virtual Clock)
    // MARK: ──────────────────────────────────────────────────────────────

    /// RR arriving exactly as T1 fires (grace period overlap) must cancel retransmit.
    func testRR_ArrivingDuringT1GracePeriod_CancelsRetransmit() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        var retransmits: [OutboundFrame] = []
        manager.onSendFrame = { retransmits.append($0) }

        _ = manager.sendData(Data("RaceTest".utf8), to: peer, path: path, channel: 0)

        // Advance to T1 fire point (grace period starts)
        clock.advance(by: 2.0)
        XCTAssertEqual(retransmits.filter { $0.frameType == "i" }.count, 0,
            "Grace period active — no retransmit yet")

        // RR arrives during grace period (t=2.0 + 0.1s, before grace expires at t=2.2s)
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 1, isPoll: false)
        XCTAssertEqual(session.outstandingCount, 0, "RR must ack the frame")

        // Advance through rest of grace period and beyond
        clock.advance(by: 1.0)

        XCTAssertEqual(retransmits.filter { $0.frameType == "i" }.count, 0,
            "RR during grace period must suppress retransmit")
        XCTAssertEqual(session.stateMachine.retryCount, 0,
            "retryCount must be 0 (RR acked before retransmit fired)")
    }

    /// T3 must not fire while T1 is active (outstanding frames).
    /// If both expire simultaneously, T1 governs and T3 is irrelevant.
    func testT3_DoesNotFireWhileT1Active() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        // T3 is running after connect
        XCTAssertNotNil(session.t3TimerTask)

        // Sending data stops T3 and starts T1
        _ = manager.sendData(Data("KillT3".utf8), to: peer, path: path, channel: 0)
        XCTAssertNil(session.t3TimerTask, "T3 must stop when data is sent")
        XCTAssertNotNil(session.t1TimerTask, "T1 must be running")

        // Advance just past the T3 default fire time (30s) but before T1 exhausts
        // retries (rto=2, maxRetries=4, backoff: ~63s total until error).
        // If T3 incorrectly rescheduled itself, t3TimerTask would be non-nil here.
        clock.advance(by: 31.0)

        // T3 must remain nil: it was cancelled when data was sent and must NOT
        // reschedule while T1 has outstanding frames.
        XCTAssertNil(session.t3TimerTask,
            "T3 must not reschedule while T1 has outstanding frames")
        // Sanity: T1 must still be running (not yet exhausted at 31s with rto=2)
        XCTAssertNotNil(session.t1TimerTask,
            "T1 must still be running at 31s (exhausts ~63s with rto=2, maxRetries=4)")
        XCTAssertEqual(session.state, .connected,
            "Session must still be connected (T1 exhausts at ~63s)")
    }

    /// Reconnect after N2 timeout: new session must start with clean slate.
    func testReconnect_AfterN2Timeout_FreshSlate() {
        let (manager, clock) = makeManager(rto: 1.0, maxRetries: 2)
        let session = connect(manager)

        _ = manager.sendData(Data("Stale".utf8), to: peer, path: path, channel: 0)

        // Exhaust N2 retries → session enters .error
        for _ in 0..<(2 + 1) {
            let rto = session.timers.rto
            clock.advance(by: rto + 0.21)
        }
        XCTAssertEqual(session.state, .error,
            "Session must enter .error after N2 retries exhausted")
        XCTAssertEqual(session.outstandingCount, 0,
            "Send buffer must be cleared on link failure")

        // Reconnect: must start fresh
        _ = manager.connect(to: peer, path: path, channel: 0)
        let reconnected = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(reconnected.state, .connecting)

        // Accept the reconnect
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        XCTAssertEqual(reconnected.state, .connected)
        XCTAssertEqual(reconnected.vs, 0, "V(S) must be reset after reconnect")
        XCTAssertEqual(reconnected.vr, 0, "V(R) must be reset after reconnect")
        XCTAssertEqual(reconnected.va, 0, "V(A) must be reset after reconnect")
        XCTAssertEqual(reconnected.outstandingCount, 0,
            "Send buffer must be empty after reconnect (stale frames must not linger)")
    }

    // MARK: ──────────────────────────────────────────────────────────────
    // MARK: Multi-Scenario Integration: Partial ACK → REJ → Retransmit → ACK
    // MARK: ──────────────────────────────────────────────────────────────

    /// Full recovery scenario: partial window → REJ → retransmit → final ACK.
    /// Tests the complete path including invariant integrity at each step.
    func testFullRecovery_PartialACK_REJ_Retransmit_FinalACK() {
        let (manager, clock) = makeManager(windowSize: 4, rto: 2.0)
        let session = connect(manager)

        // Phase 1: Send full window
        for i in 0..<4 {
            _ = manager.sendData(Data("Block\(i)".utf8), to: peer, path: path, channel: 0)
        }
        XCTAssertEqual(session.outstandingCount, 4)

        // Phase 2: Partial ACK — only frames 0,1 received by peer
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 2, isPoll: false)
        XCTAssertEqual(session.va, 2, "Partial ACK: V(A)=2")
        XCTAssertEqual(session.outstandingCount, 2)

        // Phase 3: REJ from peer — frame 2 was lost, restart from 2
        let rejFrames = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 2)
        let retransmittedNS = rejFrames.filter { $0.frameType == "i" }.compactMap { f -> Int? in
            guard let ctrl = f.controlByte else { return nil }
            return Int((ctrl >> 1) & 0x07)
        }.sorted()
        XCTAssertEqual(retransmittedNS, [2, 3], "REJ(2) must retransmit exactly frames 2,3")

        // Phase 4: Duplicate REJ during retransmit cycle — must not amplify
        let dupRej = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 2)
        XCTAssertEqual(dupRej.filter { $0.frameType == "i" }.count, 0,
            "Duplicate REJ during active retransmit must be suppressed")

        // Phase 5: Final ACK from peer
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 4, isPoll: false)
        XCTAssertEqual(session.va, 4)
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertNil(session.t1TimerTask, "T1 must stop when window clears")
        XCTAssertNotNil(session.t3TimerTask, "T3 must resume when idle")

        // Phase 6: Virtual clock — no phantom retransmits
        var phantom: [OutboundFrame] = []
        manager.onSendFrame = { phantom.append($0) }
        clock.advance(by: 10.0)
        XCTAssertEqual(phantom.filter { $0.frameType == "i" }.count, 0,
            "No phantom I-frame retransmits after complete ACK")
    }
}
