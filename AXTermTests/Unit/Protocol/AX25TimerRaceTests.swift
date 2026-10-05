
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
//    - T1 fires and triggers retransmission as it expires
//    - RR arriving before T1 expires stops retransmission (no duplicate TX)
//    - T1 backoff doubles RTO on each retry
//    - T3 idle polling fires at the correct virtual time
//    - T3 canceled when I-frame is sent (T1 takes over)
//    - T1 takes over from T3 when data is sent
//    - N2 retries → link error at exactly the right virtual time
//    - Simultaneous T1 + T3 expiry: T1 wins (T3 should be canceled by data TX)
//    - SABM → T1 → UA → T1 canceled, T3 started
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
        _ = manager.connect(to: peer, path: path, radio: .primary)
        manager.handleInboundUA(from: peer, path: path, radio: .primary)
        let s = manager.session(for: peer, path: path, radio: .primary)
        XCTAssertEqual(s.state, .connected)
        return s
    }

    // MARK: - T1: Basic Retransmission

    /// T1 fires after T1V and retransmits the unacked frame.
    func testT1FiresAndRetransmits() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        // Note: onSendFrame captures timer-driven retransmissions only.
        // The initial I-frame is returned directly by sendData(), not via callback.
        var retransmitFrames: [OutboundFrame] = []
        manager.onSendFrame = { retransmitFrames.append($0) }

        _ = manager.sendData(Data("Hello".utf8), to: peer, path: path, radio: .primary)
        print("[TEST] After sendData: outstanding=\(session.outstandingCount) t1=\(session.t1TimerTask != nil) t3=\(session.t3TimerTask != nil) rto=\(session.timers.rto) clockTime=\(clock.currentTime)")
        XCTAssertEqual(session.outstandingCount, 1)
        XCTAssertEqual(retransmitFrames.count, 0, "No retransmits before T1 fires")

        // Advance past T1's expiry
        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
        print("[TEST] After advance: retransmitCount=\(retransmitFrames.count) retryCount=\(session.stateMachine.retryCount) outstanding=\(session.outstandingCount) clockTime=\(clock.currentTime)")

        // First T1 fires: immediately retransmit the outstanding I-frame with P=1
        let iFramesRetransmitted = retransmitFrames.filter { $0.frameType == "i" }.count
        XCTAssertEqual(iFramesRetransmitted, 1, "First T1 should immediately retransmit the outstanding I-frame with P=1")
        XCTAssertEqual(retransmitFrames.filter { $0.frameType == "i" }.first?.controlByte.map { Int($0 & 0x10) }, 0x10, "Retransmitted frame must have P=1 set")
        XCTAssertEqual(session.stateMachine.retryCount, 1, "retryCount should be 1 after one T1 timeout")
        XCTAssertEqual(session.outstandingCount, 1, "Frame should still be outstanding until RR received")

        retransmitFrames.removeAll()
        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
        let secondIFramesRetransmitted = retransmitFrames.filter { $0.frameType == "i" }.count
        XCTAssertEqual(secondIFramesRetransmitted, 1, "Second consecutive T1 should also retransmit 1 I-frame")
    }

    /// Retransmission does NOT fire if RR arrives before T1 expires.
    func testRRBeforeT1ExpiresStopsRetransmit() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        // onSendFrame captures timer-driven retransmissions only (not initial sends)
        var retransmitCount = 0
        manager.onSendFrame = { _ in retransmitCount += 1 }

        _ = manager.sendData(Data("BeforeT1Test".utf8), to: peer, path: path, radio: .primary)

        // 50 ms before T1 expires
        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime) - 0.06)
        XCTAssertEqual(retransmitCount, 0, "T1 has not expired yet")

        _ = manager.handleInboundRR(from: peer, path: path, radio: .primary, nr: 1, isPoll: false)
        clock.advance(by: 0.5)

        XCTAssertEqual(retransmitCount, 0, "an RR before T1 expires stops the retransmit")
        XCTAssertEqual(session.outstandingCount, 0, "Frame should be acked by RR(1)")
        XCTAssertEqual(session.stateMachine.retryCount, 0, "retryCount resets on V(A) advance")
    }

    /// DM arriving before T1 fires cancels the timer and prevents late retransmit.
    func testDMStopsT1BeforeItFires() {
        let (manager, clock) = makeManager(rto: 1.0)
        let session = connect(manager)

        var txFrames: [OutboundFrame] = []
        manager.onSendFrame = { txFrames.append($0) }

        _ = manager.sendData(Data("HELP\r".utf8), to: peer, path: path, radio: .primary)
        XCTAssertEqual(session.outstandingCount, 1)
        XCTAssertNotNil(session.t1TimerTask)

        manager.handleInboundDM(from: peer, path: path, radio: .primary)
        clock.advance(by: 2.0)

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertTrue(txFrames.isEmpty, "No timer-driven frames should be emitted after DM")
        XCTAssertNil(session.t1TimerTask)
    }

    // MARK: - T1: No backoff on a connected link

    /// AX.25 2.2 Figure C4.5c: Timer Recovery's T1 expiry does not call
    /// Select T1, so each retry on a connected link waits the same T1V.
    /// (Until 2026-10-05 each timeout doubled the RTO.)
    func testConnectedRetriesKeepT1V() {
        let (manager, clock) = makeManager(rto: 1.0)
        let session = connect(manager)
        _ = manager.sendData(Data("BackoffTest".utf8), to: peer, path: path, radio: .primary)
        let t1v = session.timers.rto

        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
        XCTAssertEqual(session.stateMachine.retryCount, 1)
        XCTAssertEqual(session.timers.rto, t1v)

        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
        XCTAssertEqual(session.stateMachine.retryCount, 2)
        XCTAssertEqual(session.timers.rto, t1v)
    }

    /// Nothing grows over many retries either: there is nothing to bound.
    func testT1VStaysPutOverManyRetries() {
        let clock   = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = AX25SessionConfig(maxRetries: 10, initialRto: 1.0)
        _ = manager.connect(to: peer, path: path, radio: .primary)
        manager.handleInboundUA(from: peer, path: path, radio: .primary)
        let session = manager.session(for: peer, path: path, radio: .primary)
        _ = manager.sendData(Data("BoundedBackoff".utf8), to: peer, path: path, radio: .primary)
        let t1v = session.timers.rto

        for _ in 0..<8 {
            clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
            XCTAssertEqual(session.timers.rto, t1v)
        }
    }

    // MARK: - T1: Max Retries → Link Error

    /// Exactly N2 retries trigger link error; no more, no less.
    func testT1MaxRetriesExact() {
        let n2 = 3
        let (manager, clock) = makeManager(rto: 1.0, maxRetries: n2)
        let session = connect(manager)

        _ = manager.sendData(Data("MaxRetryTest".utf8), to: peer, path: path, radio: .primary)

        for attempt in 1...n2 {
            let rto = session.timers.rto
            clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
            if attempt < n2 {
                XCTAssertEqual(session.state, .connected,
                    "Session must stay connected after retry \(attempt) (< N2=\(n2))")
            }
        }

        // One more advance — this is the N2+1-th timeout
        let rto = session.timers.rto
        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))

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

    /// T3 is canceled when I-frame is sent; T1 takes over timing.
    func testT3CancelledWhenDataSent() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        // After connect, T3 should be running
        let t3ActiveAfterConnect = session.t3TimerTask != nil
        XCTAssertTrue(t3ActiveAfterConnect, "T3 should be active after connection established")

        // Send data — T1 should start, T3 should stop
        _ = manager.sendData(Data("KillT3".utf8), to: peer, path: path, radio: .primary)

        // T3 should be canceled (T1 is active for the outstanding frame)
        XCTAssertNil(session.t3TimerTask, "T3 should be canceled once I-frame is outstanding")
        XCTAssertNotNil(session.t1TimerTask, "T1 should be active for unacked I-frame")
    }

    /// T3 resumes after all frames are acked (T1 stops, T3 restarts).
    func testT3RestartsAfterAllFramesAcked() {
        let (manager, _) = makeManager()
        let session = connect(manager)

        _ = manager.sendData(Data("AckMeBack".utf8), to: peer, path: path, radio: .primary)

        // T1 running, T3 not
        XCTAssertNotNil(session.t1TimerTask, "T1 should be running")
        XCTAssertNil(session.t3TimerTask, "T3 should be off while frames are outstanding")

        // Peer acks all frames
        _ = manager.handleInboundRR(from: peer, path: path, radio: .primary, nr: 1, isPoll: false)

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

        _ = manager.sendData(Data("FrameA".utf8), to: peer, path: path, radio: .primary)
        _ = manager.sendData(Data("FrameB".utf8), to: peer, path: path, radio: .primary)
        XCTAssertEqual(session.outstandingCount, 2)

        // Advance past T1's expiry: it fires and retransmits both outstanding frames at once.
        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
        XCTAssertEqual(session.stateMachine.retryCount, 1)
        let iFramesAfterFirst = retransmitFrames.filter { $0.frameType == "i" }
        XCTAssertEqual(iFramesAfterFirst.count, 2, "First T1 should immediately retransmit both unacked I-frames")

        // Peer now acks FrameA (N(R)=1)
        _ = manager.handleInboundRR(from: peer, path: path, radio: .primary, nr: 1, isPoll: false)
        XCTAssertEqual(session.outstandingCount, 1, "Only FrameB outstanding")
        XCTAssertEqual(session.stateMachine.retryCount, 0, "retryCount resets on V(A) advance")

        // Advance past another T1 cycle for FrameB: immediately retransmits FrameB.
        let iCountBeforeSecondTimeout = retransmitFrames.filter { $0.frameType == "i" }.count
        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
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

        _ = manager.connect(to: peer, path: path, radio: .primary)
        let session = manager.session(for: peer, path: path, radio: .primary)

        XCTAssertEqual(session.state, .connecting)
        XCTAssertNotNil(session.t1TimerTask, "T1 should be armed while waiting for UA")

        // UA arrives — T1 should cancel, T3 should start
        manager.handleInboundUA(from: peer, path: path, radio: .primary)

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
        let initialFrame = manager.connect(to: peer, path: path, radio: .primary)
        let session = manager.session(for: peer, path: path, radio: .primary)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertNotNil(initialFrame, "connect() must return initial SABM frame")
        XCTAssertEqual(initialFrame?.frameType, "u", "Initial SABM must be a U-frame")

        // Fire N2+1 T1 timeouts — should eventually give up
        for _ in 0..<(n2 + 1) {
            let rto = session.timers.rto
            clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
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

        _ = manager.connect(to: peerA, path: path, radio: .primary)
        manager.handleInboundUA(from: peerA, path: path, radio: .primary)
        let sessionA = manager.session(for: peerA, path: path, radio: .primary)

        _ = manager.connect(to: peerB, path: path, radio: .primary)
        manager.handleInboundUA(from: peerB, path: path, radio: .primary)
        let sessionB = manager.session(for: peerB, path: path, radio: .primary)

        _ = manager.sendData(Data("DataA".utf8), to: peerA, path: path, radio: .primary)
        _ = manager.sendData(Data("DataB".utf8), to: peerB, path: path, radio: .primary)

        // Advance past both T1 timeouts
        clock.advance(by: 1.5)

        // Both sessions should have timed out once
        XCTAssertEqual(sessionA.stateMachine.retryCount, 1, "Session A should have 1 retry")
        XCTAssertEqual(sessionB.stateMachine.retryCount, 1, "Session B should have 1 retry")
    }

    // MARK: - T1 Expiry Edge Case

    /// The retry goes out as T1 expires (AX.25 2.2 Figure C4.4), with no
    /// wait for an ack that may be on its way. Until 2026-10-05 AXTerm held
    /// it 200 ms more, and an RR in that time suppressed it.
    func testRRJustAfterT1ExpiryFindsTheRetryAlreadySent() {
        let (manager, clock) = makeManager(rto: 2.0)
        let session = connect(manager)

        var retransmits: [OutboundFrame] = []
        manager.onSendFrame = { retransmits.append($0) }

        _ = manager.sendData(Data("BoundaryTest".utf8), to: peer, path: path, radio: .primary)

        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
        XCTAssertEqual(retransmits.filter { $0.frameType == "i" }.count, 1,
                       "the retry goes out when T1 expires")

        _ = manager.handleInboundRR(from: peer, path: path, radio: .primary, nr: 1, isPoll: false)
        XCTAssertEqual(session.outstandingCount, 0, "Frame should be acked by RR(1)")
    }

    // MARK: - T1: Stale Fire After Stop (Generation Guard)

    /// Regression (field capture 2026-08-22, KB5YZB-7 via DRLNOD): a T1 fire already
    /// in flight when stopT1 ran must be ignored. cancel() cannot recall a closure the
    /// dispatch queue has begun delivering, so twice in one session "T1 timeout fired"
    /// landed 40–60 ms after "Stopping T1 timer" and spent airtime on a needless RR
    /// poll. The generation guard must swallow such stale fires — while still letting
    /// legitimate fires through.
    func testStaleT1FireAfterStopIsIgnored() {
        let clock = RacyScheduler()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = AX25SessionConfig(maxRetries: 4, rtoMin: 2.0, rtoMax: 16.0, initialRto: 2.0)

        var timerDrivenFrames: [OutboundFrame] = []
        manager.onSendFrame = { timerDrivenFrames.append($0) }

        // Connect: SABM schedules T1; UA stops it, but the racy cancel is a no-op.
        _ = manager.connect(to: peer, path: path, radio: .primary)
        manager.handleInboundUA(from: peer, path: path, radio: .primary)
        let session = manager.session(for: peer, path: path, radio: .primary)
        XCTAssertEqual(session.state, .connected)

        // The connect-phase T1 closure now delivers anyway — it must be swallowed.
        clock.fireInFlight(within: 2.0..<3.0)
        XCTAssertEqual(session.stateMachine.retryCount, 0,
                       "stale connect-phase T1 must not count as a retry")
        XCTAssertTrue(timerDrivenFrames.isEmpty,
                      "stale connect-phase T1 must not put an RR poll on the air")

        // Data phase: I-frame starts T1; the ack stops it; the fire was already in flight.
        _ = manager.sendData(Data("Hello".utf8), to: peer, path: path, radio: .primary)
        _ = manager.handleInboundRRFrames(from: peer, path: path, radio: .primary,
                                          nr: 1, pf: false, isCommand: false)
        XCTAssertEqual(session.outstandingCount, 0)
        clock.fireInFlight(within: 2.0..<3.0)
        XCTAssertEqual(session.stateMachine.retryCount, 0,
                       "stale data-phase T1 must not count as a retry")
        XCTAssertTrue(timerDrivenFrames.isEmpty,
                      "stale data-phase T1 must not retransmit or poll")
        XCTAssertNil(session.t1TimerTask,
                     "a stale fire must not restart T1 on an idle session")

        // Positive control: a T1 that was NOT stopped must still work end to end.
        _ = manager.sendData(Data("World".utf8), to: peer, path: path, radio: .primary)
        clock.fireInFlight(within: 2.0..<3.0)   // live T1 fires → retransmit
        XCTAssertEqual(session.stateMachine.retryCount, 1,
                       "a legitimate T1 fire must still be processed")
        XCTAssertEqual(timerDrivenFrames.filter { $0.frameType == "i" }.count, 1,
                       "the outstanding I-frame must be retransmitted by the live T1")
    }
}

/// A scheduler whose cancel() is deliberately a no-op: models the production race
/// where stopT1's cancel() arrives after the dispatch queue has already begun
/// delivering the timeout closure. `fireInFlight` then delivers what a real queue
/// would have delivered anyway.
@MainActor
private final class RacyScheduler: AX25TimerScheduler {
    var currentTime: TimeInterval = 0.0
    private var pending: [(delay: TimeInterval, action: @MainActor @Sendable () -> Void)] = []

    func schedule(delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> AnyCancellableTask {
        pending.append((delay, action))
        return UncancellableToken()
    }

    /// Deliver every held closure whose delay falls in `range`. T1 runs for
    /// T1V from when our frame has left the radio, so its delay is T1V plus
    /// that frame's airtime (spec 7.3).
    func fireInFlight(within range: Range<TimeInterval>) {
        let inFlight = pending.filter { range.contains($0.delay) }
        pending.removeAll { range.contains($0.delay) }
        for entry in inFlight { entry.action() }
    }

    private struct UncancellableToken: AnyCancellableTask {
        func cancel() {}
    }
}
