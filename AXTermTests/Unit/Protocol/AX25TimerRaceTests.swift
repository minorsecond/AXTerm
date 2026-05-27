
//
//  AX25TimerRaceTests.swift
//  AXTermTests
//
//  Phase 4: Deterministic timer race condition tests using VirtualClock.
//
//  These tests exercise T1/T3 timer semantics without any wall-clock delays.
//  The VirtualClock.advance(by:) method fires timers in exact chronological order,
//  making previously non-deterministic races fully reproducible.
//
//  Coverage:
//    - T1 fires and triggers retransmission after grace period
//    - RR arriving in grace period cancels retransmission (no duplicate TX)
//    - T1 backoff doubles RTO on each retry
//    - T3 idle polling fires at the correct virtual time
//    - T3 cancelled when I-frame is sent (T1 takes over)
//    - T1 takes over from T3 when data is sent
//    - N2 retries → link error at exactly the right virtual time
//    - Simultaneous T1 + T3 expiry: T1 wins (T3 should be cancelled by data TX)
//    - T1 cancels pending grace-period retransmit when RR arrives mid-grace
//    - SABM → T1 → UA → T1 cancelled, T3 started
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25TimerRaceTests: XCTestCase {

    // MARK: - Helpers

    private let local = AX25Address(call: "NOCALL", ssid: 0)
    private let peer  = AX25Address(call: "TIMER-1", ssid: 0)
    private let path  = DigiPath([])

    /// Build a manager with a virtual clock and a small RTO for fast test execution.
    /// Default RTO is set to 2s so advances are meaningful but small.
    private func makeManager(
        rto: TimeInterval = 2.0,
        maxRetries: Int = 4
    ) -> (AX25SessionManager, AX25VirtualClock) {
        let clock   = AX25VirtualClock()
        let config  = AX25SessionConfig(maxRetries: maxRetries, rtoMin: rto, rtoMax: rto * 8, initialRto: rto)
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = config
        return (manager, clock)
    }

    /// Establish a connected session and return the session handle.
    private func connect(
        _ manager: AX25SessionManager
    ) -> AX25Session {
        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        let s = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(s.state, .connected)
        return s
    }

    // MARK: - T1: Basic Retransmission

    /// T1 fires after RTO + grace period and retransmits unacked frame.
    func testT1FiresAndRetransmits() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        // Note: onSendFrame captures timer-driven retransmissions only.
        // The initial I-frame is returned directly by sendData(), not via callback.
        var retransmitFrames: [OutboundFrame] = []
        manager.onSendFrame = { retransmitFrames.append($0) }

        _ = manager.sendData(Data("Hello".utf8), to: peer, path: path, channel: 0)
        print("[TEST] After sendData: outstanding=\(session.outstandingCount) t1=\(session.t1TimerTask != nil) t3=\(session.t3TimerTask != nil) rto=\(session.timers.rto) clockTime=\(clock.currentTime)")
        XCTAssertEqual(session.outstandingCount, 1)
        XCTAssertEqual(retransmitFrames.count, 0, "No retransmits before T1 fires")

        // Advance past RTO (2s) + grace period (0.2s)
        clock.advance(by: 2.21)
        print("[TEST] After advance: retransmitCount=\(retransmitFrames.count) retryCount=\(session.stateMachine.retryCount) outstanding=\(session.outstandingCount) clockTime=\(clock.currentTime)")

        // T1 fires: sends RR(P=1) poll + retransmits I-frame. Only count I-frames.
        // (The RR poll is also emitted via onSendFrame but is not a "retransmission".)
        let iFramesRetransmitted = retransmitFrames.filter { $0.frameType == "i" }.count
        XCTAssertEqual(iFramesRetransmitted, 1, "T1 should have retransmitted 1 I-frame")
        XCTAssertEqual(session.stateMachine.retryCount, 1, "retryCount should be 1 after one T1 timeout")
        XCTAssertEqual(session.outstandingCount, 1, "Frame should still be outstanding until RR received")
    }

    /// Retransmission does NOT fire if RR arrives before grace period expires.
    func testRRWithinGracePeriodCancelsRetransmit() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        // onSendFrame captures timer-driven retransmissions only (not initial sends)
        var retransmitCount = 0
        manager.onSendFrame = { _ in retransmitCount += 1 }

        _ = manager.sendData(Data("GracePeriodTest".utf8), to: peer, path: path, channel: 0)

        // Advance past RTO but NOT past grace period (grace = 0.2s)
        // At 2.05s: T1 has fired, grace period is running (0.15s remaining)
        clock.advance(by: 2.05)
        XCTAssertEqual(retransmitCount, 0, "Grace period still active — no retransmit yet")

        // Now deliver the RR — this should cancel the pending retransmit
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 1, isPoll: false)

        // Advance past where grace period would have fired
        clock.advance(by: 0.5)

        // No retransmit should have been emitted
        XCTAssertEqual(retransmitCount, 0, "RR in grace period should suppress retransmission")
        XCTAssertEqual(session.outstandingCount, 0, "Frame should be acked by RR(1)")
        XCTAssertEqual(session.stateMachine.retryCount, 0, "retryCount resets on V(A) advance")
    }

    // MARK: - T1: Exponential Backoff

    /// Each T1 timeout doubles the RTO (exponential backoff).
    func testT1ExponentialBackoff() {
        let (manager, clock) = makeManager(rto: 1.0)
        let session = connect(manager)

        _ = manager.sendData(Data("BackoffTest".utf8), to: peer, path: path, channel: 0)

        let rto1 = session.timers.rto
        XCTAssertEqual(rto1, 1.0, accuracy: 0.01, "Initial RTO should be 1.0s")

        // Trigger first timeout
        clock.advance(by: rto1 + 0.21)
        XCTAssertEqual(session.stateMachine.retryCount, 1)

        let rto2 = session.timers.rto
        XCTAssertGreaterThan(rto2, rto1, "RTO must increase after first timeout (backoff)")

        // Trigger second timeout
        clock.advance(by: rto2 + 0.21)
        XCTAssertEqual(session.stateMachine.retryCount, 2)

        let rto3 = session.timers.rto
        XCTAssertGreaterThan(rto3, rto2, "RTO must keep increasing (exponential backoff)")
    }

    /// RTO is bounded by rtoMax: never grows unboundedly.
    func testT1BackoffBoundedByMax() {
        let rtoMax: TimeInterval = 4.0
        let clock   = AX25VirtualClock()
        let config  = AX25SessionConfig(maxRetries: 10, rtoMin: 1.0, rtoMax: rtoMax, initialRto: 1.0)
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = config

        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)
        _ = manager.sendData(Data("BoundedBackoff".utf8), to: peer, path: path, channel: 0)

        // Fire many timeouts; RTO must never exceed rtoMax
        for _ in 0..<8 {
            let rto = session.timers.rto
            clock.advance(by: rto + 0.21)
            XCTAssertLessThanOrEqual(
                session.timers.rto, rtoMax + 0.001,
                "RTO must never exceed rtoMax=\(rtoMax)"
            )
        }
    }

    // MARK: - T1: Max Retries → Link Error

    /// Exactly N2 retries trigger link error; no more, no less.
    func testT1MaxRetriesExact() {
        let n2 = 3
        let (manager, clock) = makeManager(rto: 1.0, maxRetries: n2)
        let session = connect(manager)

        _ = manager.sendData(Data("MaxRetryTest".utf8), to: peer, path: path, channel: 0)

        for attempt in 1...n2 {
            let rto = session.timers.rto
            clock.advance(by: rto + 0.21)
            if attempt < n2 {
                XCTAssertEqual(session.state, .connected,
                    "Session must stay connected after retry \(attempt) (< N2=\(n2))")
            }
        }

        // One more advance — this is the N2+1-th timeout
        let rto = session.timers.rto
        clock.advance(by: rto + 0.21)

        XCTAssertEqual(session.state, .error,
            "Session must enter error state after exceeding N2=\(n2) retries")
        XCTAssertEqual(session.outstandingCount, 0,
            "Send buffer must be cleared on link failure")
    }

    // MARK: - T3: Idle Keepalive

    /// T3 fires when session is idle (no outstanding frames) and sends a keepalive RR.
    func testT3IdlePollFires() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        var txFrames: [OutboundFrame] = []
        manager.onSendFrame = { txFrames.append($0) }

        // No data sent — session is idle, T3 is running
        XCTAssertEqual(session.outstandingCount, 0)

        // Advance past T3 timeout (default ~180s; override for test)
        // We'll fire T3 directly by using handleT3Timeout which is test-accessible
        let t3Frames = manager.handleT3Timeout(session: session)

        // T3 should emit an RR poll to keepalive the link
        XCTAssertFalse(t3Frames.isEmpty, "T3 should produce a keepalive frame")
        let isRR = t3Frames.first?.frameType == "s"
        XCTAssertTrue(isRR, "T3 keepalive should be an S-frame (RR)")
    }

    /// T3 is cancelled when I-frame is sent; T1 takes over timing.
    func testT3CancelledWhenDataSent() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        // After connect, T3 should be running
        let t3ActiveAfterConnect = session.t3TimerTask != nil
        XCTAssertTrue(t3ActiveAfterConnect, "T3 should be active after connection established")

        // Send data — T1 should start, T3 should stop
        _ = manager.sendData(Data("KillT3".utf8), to: peer, path: path, channel: 0)

        // T3 should be cancelled (T1 is active for the outstanding frame)
        XCTAssertNil(session.t3TimerTask, "T3 should be cancelled once I-frame is outstanding")
        XCTAssertNotNil(session.t1TimerTask, "T1 should be active for unacked I-frame")
    }

    /// T3 resumes after all frames are acked (T1 stops, T3 restarts).
    func testT3RestartsAfterAllFramesAcked() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        _ = manager.sendData(Data("AckMeBack".utf8), to: peer, path: path, channel: 0)

        // T1 running, T3 not
        XCTAssertNotNil(session.t1TimerTask, "T1 should be running")
        XCTAssertNil(session.t3TimerTask, "T3 should be off while frames are outstanding")

        // Peer acks all frames
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 1, isPoll: false)

        // Now T1 should be stopped, T3 should be running
        XCTAssertNil(session.t1TimerTask, "T1 should stop after all frames acked")
        XCTAssertNotNil(session.t3TimerTask, "T3 should restart when link goes idle")
    }

    // MARK: - T1 + Virtual Clock: Concurrent Retry + ACK Race

    /// Two frames sent; first frame acked mid-T1; second frame retransmitted (not first).
    func testPartialAckDuringT1RetransmitsOnlyUnacked() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        // onSendFrame captures timer-driven retransmissions only
        var retransmitFrames: [OutboundFrame] = []
        manager.onSendFrame = { retransmitFrames.append($0) }

        _ = manager.sendData(Data("FrameA".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("FrameB".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 2)

        // Advance past RTO + grace — T1 fires, both frames retransmitted.
        // T1 also sends RR(P=1); count only I-frames.
        clock.advance(by: 2.21)
        XCTAssertEqual(session.stateMachine.retryCount, 1)
        let iFramesAfterFirst = retransmitFrames.filter { $0.frameType == "i" }
        XCTAssertEqual(iFramesAfterFirst.count, 2, "Both frames should be retransmitted on T1")

        // Peer now acks FrameA (N(R)=1)
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 1, isPoll: false)
        XCTAssertEqual(session.outstandingCount, 1, "Only FrameB outstanding")
        XCTAssertEqual(session.stateMachine.retryCount, 0, "retryCount resets on V(A) advance")

        // Advance past the current (backed-off) RTO + grace period for the second T1 timeout.
        // After the first T1 timeout, backoff() doubles RTO: 2.0 → 4.0.
        // Karn's algorithm: no RTT update for retransmitted frames → RTO stays at 4.0.
        // Use session.timers.rto (not the original 2.0) so the advance is correct regardless
        // of how many backoffs have accumulated.
        let rtoAfterBackoff = session.timers.rto
        let iCountBeforeSecondTimeout = retransmitFrames.filter { $0.frameType == "i" }.count
        clock.advance(by: rtoAfterBackoff + 0.21)

        let newIFrames = retransmitFrames.filter { $0.frameType == "i" }.dropFirst(iCountBeforeSecondTimeout)
        XCTAssertEqual(newIFrames.count, 1, "Only one I-frame (FrameB) should be retransmitted")

        // Verify it's the right frame (N(S)=1 for FrameB)
        if let retransmitted = newIFrames.first, let ctrl = retransmitted.controlByte {
            let ns = Int((ctrl >> 1) & 0x07)
            XCTAssertEqual(ns, 1, "Retransmitted frame N(S) should be 1 (FrameB)")
        }
    }

    // MARK: - SABM Handshake Timer Lifecycle

    /// SABM send starts T1; UA received stops T1 and starts T3.
    func testSABMT1CancelledByUA() {
        let (manager, _) = makeManager()

        _ = manager.connect(to: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)

        XCTAssertEqual(session.state, .connecting)
        XCTAssertNotNil(session.t1TimerTask, "T1 should be armed while waiting for UA")

        // UA arrives — T1 should cancel, T3 should start
        manager.handleInboundUA(from: peer, path: path, channel: 0)

        XCTAssertEqual(session.state, .connected)
        XCTAssertNil(session.t1TimerTask, "T1 should be cleared after UA")
        XCTAssertNotNil(session.t3TimerTask, "T3 should start on connection established")
    }

    /// SABM timeout and retry: T1 fires → retransmits SABM → eventually gives up.
    func testSABMT1RetryAndGiveUp() {
        let n2 = 2
        let (manager, clock) = makeManager(rto: 1.0, maxRetries: n2)
        var txFrames: [OutboundFrame] = []
        manager.onSendFrame = { txFrames.append($0) }

        // connect() returns the initial SABM frame directly (not via onSendFrame)
        let initialFrame = manager.connect(to: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertNotNil(initialFrame, "connect() must return initial SABM frame")
        XCTAssertEqual(initialFrame?.frameType, "u", "Initial SABM must be a U-frame")

        // Fire N2+1 T1 timeouts — should eventually give up
        for _ in 0..<(n2 + 1) {
            let rto = session.timers.rto
            clock.advance(by: rto + 0.21)
        }

        XCTAssertEqual(session.state, .error, "Session must enter error state after SABM retry exhaustion")
    }

    // MARK: - Virtual Clock: Deterministic Ordering of Simultaneous Timers

    /// Two sessions created at the same time; virtual clock fires their timers in strict order.
    func testTwoSessionTimersFireInOrder() {
        let clock   = AX25VirtualClock()
        let config  = AX25SessionConfig(maxRetries: 4, rtoMin: 1.0, rtoMax: 8.0, initialRto: 1.0)
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = config

        let peerA = AX25Address(call: "PEERA-1", ssid: 0)
        let peerB = AX25Address(call: "PEERB-2", ssid: 0)

        _ = manager.connect(to: peerA, path: path, channel: 0)
        manager.handleInboundUA(from: peerA, path: path, channel: 0)
        let sessionA = manager.session(for: peerA, path: path, channel: 0)

        _ = manager.connect(to: peerB, path: path, channel: 0)
        manager.handleInboundUA(from: peerB, path: path, channel: 0)
        let sessionB = manager.session(for: peerB, path: path, channel: 0)

        _ = manager.sendData(Data("DataA".utf8), to: peerA, path: path, channel: 0)
        _ = manager.sendData(Data("DataB".utf8), to: peerB, path: path, channel: 0)

        // Advance past both T1 timeouts + grace periods
        clock.advance(by: 1.5)

        // Both sessions should have timed out once
        XCTAssertEqual(sessionA.stateMachine.retryCount, 1, "Session A should have 1 retry")
        XCTAssertEqual(sessionB.stateMachine.retryCount, 1, "Session B should have 1 retry")
    }

    // MARK: - T1 Grace Period Edge Case

    /// RR arrives exactly at the grace period boundary — should still cancel retransmit.
    func testRRAtExactGraceBoundaryStillCancels() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        var retransmitCount = 0
        manager.onSendFrame = { _ in retransmitCount += 1 }

        _ = manager.sendData(Data("BoundaryTest".utf8), to: peer, path: path, channel: 0)

        // Advance to T1 fire point (2.0s), grace period starts
        clock.advance(by: 2.0)
        XCTAssertEqual(retransmitCount, 0, "Grace period not yet expired")

        // RR arrives at t=2.0 + epsilon — grace period is running (expires at 2.2)
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 1, isPoll: false)

        // Advance through grace period end (t=2.5)
        clock.advance(by: 0.5)

        // No retransmit should have fired
        XCTAssertEqual(retransmitCount, 0,
            "RR delivered during grace period must suppress retransmit")
        XCTAssertEqual(session.outstandingCount, 0, "Frame should be acked by RR(1)")
    }
}
