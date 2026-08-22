//
//  AX25RetryTests.swift
//  AXTermTests
//
//  Regression tests for AX.25 retry logic and connection stability.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25RetryTests: XCTestCase {

    // Helper to establish a connected session
    private func connectSession(
        manager: AX25SessionManager,
        destination: AX25Address,
        path: DigiPath
    ) -> AX25Session {
        _ = manager.connect(to: destination, path: path, channel: 0)
        let session = manager.session(for: destination, path: path, channel: 0)
        manager.handleInboundUA(from: destination, path: path, channel: 0)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    // Test that retryCount only resets when V(A) advances (progress made)
    func testRetryCountResetsOnlyOnProgress() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])
        
        // 1. Establish connection
        let session = connectSession(manager: manager, destination: destination, path: path)
        
        // 2. Send 2 frames (vs=0, vs=1)
        _ = manager.sendData(Data("FRAME1".utf8), to: destination, path: path, channel: 0) // vs becomes 1
        _ = manager.sendData(Data("FRAME2".utf8), to: destination, path: path, channel: 0) // vs becomes 2
        XCTAssertEqual(session.outstandingCount, 2)
        
        // 3. Trigger T1 timeout to increment retryCount
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.stateMachine.retryCount, 1, "retryCount should be 1 after timeout")
        
        // 4. Receive RR(nr=1) - Acks FRAME1 (progress made!)
        _ = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 1, isPoll: false)
        XCTAssertEqual(session.stateMachine.retryCount, 0, "retryCount should reset because V(A) advanced")
        XCTAssertEqual(session.outstandingCount, 1)
        
        // 5. Trigger T1 timeout again (on FRAME2)
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.stateMachine.retryCount, 1, "retryCount should increment again")
        
        // 6. Receive RR(nr=1) AGAIN (No progress, duplicate ack)
        // Peer might resend RR(1) if it hasn't received FRAME2 yet
        _ = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 1, isPoll: false)
        XCTAssertEqual(session.stateMachine.retryCount, 1, "retryCount must NOT reset on duplicate RR (no progress)")
        
        // 7. Receive RR(nr=2) - Acks FRAME2 (progress made!)
        _ = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 2, isPoll: false)
        XCTAssertEqual(session.stateMachine.retryCount, 0, "retryCount should reset when V(A) advances")
    }

    // Test that retryCount increments on each T1 timeout
    func testRetryCountIncrementsOnTimeout() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])
        
        let session = connectSession(manager: manager, destination: destination, path: path)
        _ = manager.sendData(Data("FRAME1".utf8), to: destination, path: path, channel: 0)
        
        XCTAssertEqual(session.stateMachine.retryCount, 0)
        
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.stateMachine.retryCount, 1)
        
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.stateMachine.retryCount, 2)
        
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.stateMachine.retryCount, 3)
    }

    // Test that exceeding N2 triggers link failure
    func testMaxRetriesTriggersError() {
        // Configure small N2 for testing
        let config = AX25SessionConfig(maxRetries: 3)
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.defaultConfig = config
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])
        
        let session = connectSession(manager: manager, destination: destination, path: path)
        _ = manager.sendData(Data("FRAME1".utf8), to: destination, path: path, channel: 0)
        
        // Retry 1
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.state, .connected)
        
        // Retry 2
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.state, .connected)
        
        // Retry 3
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.state, .connected)
        
        // Retry 4 (Exceeds maxRetries=3)
        _ = manager.handleT1Timeout(session: session)
        
        XCTAssertEqual(session.state, .error)
        
        // Verify state machine statistics to confirm error
        // (Internal actions are consumed by manager, but state change is key)
    }

    // Test that receiving a duplicate ACK (same NR) does not reset retry count
    // This is crucial for handling "stuck" peers that keep acking the same old frame
    func testDuplicateAckDoesNotResetRetry() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])
        
        let session = connectSession(manager: manager, destination: destination, path: path)
        
        // Send frame vs=0
        _ = manager.sendData(Data("FRAME1".utf8), to: destination, path: path, channel: 0)
        
        // Peer acks it (nr=1)
        _ = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 1, isPoll: false)
        // retryCount is 0, session idle
        
        // Send next frame vs=1
        _ = manager.sendData(Data("FRAME2".utf8), to: destination, path: path, channel: 0)
        
        // Timeout occurs (peer didn't ack FRAME2)
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.stateMachine.retryCount, 1)
        
        // Receive RR(nr=1) - Peer still asking for 1 (maybe didn't hear FRAME2)
        // This is a duplicate ACK for the previous state. Progress NOT made.
        _ = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 1, isPoll: false)
        
        XCTAssertEqual(session.stateMachine.retryCount, 1, "Duplicate RR(nr=1) should NOT reset retry count")
    }

    // Test that receiving RNR stops sending
    func testRNRStopSending() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])
        
        let session = connectSession(manager: manager, destination: destination, path: path)
        
        // Peer sends RNR (Receive Not Ready)
        _ = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 0, isPoll: false)
        let actions = session.stateMachine.handle(event: .receivedRNR(nr: 0))
        
        // Sending is gated by the peer-busy condition, not by stopping T1. T1 must keep
        // running so the busy peer is polled until it clears the condition — stopping it
        // left the link with no timer at all and stalled the session.

        XCTAssertTrue(sm_peerBusy(session), "RNR must set the peer receiver-busy condition")
        XCTAssertTrue(actions.contains(.startT1), "RNR must keep T1 running to poll the busy peer")
        XCTAssertFalse(actions.contains(.stopT1), "Stopping T1 on RNR strands the link")
    }

    /// Regression: an inbound RNR must retire the frames its N(R) acknowledges.
    ///
    /// Both S-frame dispatch sites used to `break` on RNR, so the acknowledgement it
    /// carries was thrown away. V(A) stayed put, the send buffer kept frames the peer
    /// had already taken, and T1 retransmitted them until the retry counter tripped
    /// "Link failure (retries exceeded)" against a peer that was merely busy.
    func testInboundRNRAcknowledgesFrames() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)

        _ = manager.sendData(Data("FRAME1".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("FRAME2".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 2)

        // Peer acknowledges the first frame while reporting a full receive buffer.
        _ = manager.handleInboundRNR(from: destination, path: path, channel: 0, nr: 1)

        XCTAssertEqual(session.va, 1, "RNR(N(R)=1) must advance V(A) to 1")
        XCTAssertEqual(session.outstandingCount, 1, "the acknowledged frame must leave the send buffer")
        XCTAssertFalse(session.sendBuffer.keys.contains(0), "N(S)=0 was acked and must be retired")
        XCTAssertTrue(session.stateMachine.peerBusy, "RNR must set the peer receiver-busy condition")
    }

    /// While the peer is busy, queued data must stay queued rather than being pushed
    /// into a receive buffer the peer has explicitly told us is full.
    func testPeerBusySuppressesQueuedSends() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)

        // Fill the window so further sends have to queue.
        let windowSize = session.stateMachine.config.windowSize
        for i in 0..<(windowSize + 2) {
            _ = manager.sendData(Data("F\(i)".utf8), to: destination, path: path, channel: 0)
        }
        XCTAssertGreaterThan(session.pendingDataQueue.count, 0, "precondition: data is queued")
        let queuedBefore = session.pendingDataQueue.count

        // Peer acks one frame but reports busy — the freed slot must NOT be used.
        _ = manager.handleInboundRNR(from: destination, path: path, channel: 0, nr: 1)

        XCTAssertTrue(session.stateMachine.peerBusy)
        XCTAssertEqual(session.pendingDataQueue.count, queuedBefore,
                       "no queued data may be sent while the peer is busy")

        // Once the peer clears the condition with RR, the queue drains again.
        _ = manager.handleInboundRRFrames(from: destination, path: path, channel: 0, nr: 2)
        XCTAssertFalse(session.stateMachine.peerBusy, "RR clears the busy condition")
        XCTAssertLessThan(session.pendingDataQueue.count, queuedBefore,
                          "queued data must resume draining after RR")
    }

    /// Regression (field capture, KB5YZB-7): an RR poll that drains queued data must not
    /// also "retransmit" what the drain just sent.
    ///
    /// The no-ACK-progress retransmit read `outstandingCount` *after* draining, so a frame
    /// created microseconds earlier by the drain counted as an unacknowledged frame the peer
    /// had failed to ack — and every freshly drained I-frame went on the air twice.
    func testRRPollDoesNotDuplicateFreshlyDrainedFrames() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath()

        let session = connectSession(manager: manager, destination: destination, path: path)

        // Peer opens with the wrong N(S) (it sends 1 while we expect 0), creating a receive
        // gap. Outbound data is held while that gap is unresolved.
        _ = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 1, nr: 0, pf: true, payload: Data("HELLO".utf8)
        )
        XCTAssertTrue(session.hasReceiveSequenceGap, "precondition: a receive gap exists")

        _ = manager.sendData(Data("bbs\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.pendingDataQueue.count, 1, "precondition: data is queued behind the gap")

        // Frames reach the air by two routes: the drain emits through onSendFrame, while the
        // caller transmits whatever handleInboundRRFrames returns. Count both.
        var emitted: [OutboundFrame] = []
        manager.onSendFrame = { emitted.append($0) }

        // Peer polls. This drains the queued frame — and must put it on the air exactly once.
        let returned = manager.handleInboundRRFrames(
            from: destination, path: path, channel: 0,
            nr: 0, pf: true, isCommand: true
        )

        let iFrames = (emitted + returned).filter { $0.frameType == "i" }
        XCTAssertEqual(iFrames.count, 1,
                       "a freshly drained I-frame must go on the air once, not twice")
        XCTAssertEqual(iFrames.first?.payload, Data("bbs\r".utf8))
    }

    /// Regression (field capture 2026-08-22, direct KB5YZB-7 session): a peer
    /// that cannot hear us but keeps command-polling must not be able to poll
    /// us into an infinite retransmission loop.
    ///
    /// The peer's RR(P=1) polls arrived every ~10 s — always inside our RTO —
    /// and each poll-driven retransmit restarted T1, so T1 never expired,
    /// retryCount froze at 0, and N2 link failure could never trigger. The
    /// same I-frame was retransmitted forever. Poll-driven retransmissions now
    /// climb the same N2 ladder as T1 expiries.
    func testPeerPollingWithoutAckExhaustsN2InsteadOfLivelocking() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: destination, path: path)
        let maxRetries = session.stateMachine.config.maxRetries

        _ = manager.sendData(Data("b\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)

        // The peer keeps polling with nr that acks nothing.
        var sawLinkFailure = false
        for poll in 1...(maxRetries + 2) {
            let frames = manager.handleInboundRRFrames(
                from: destination, path: path, channel: 0,
                nr: 0, pf: true, isCommand: true
            )
            if session.state == .error {
                sawLinkFailure = true
                XCTAssertTrue(frames.filter { $0.frameType == "i" }.isEmpty,
                              "no retransmit may accompany the link-failure declaration")
                XCTAssertLessThanOrEqual(poll, maxRetries + 1,
                                         "N2 must trip after maxRetries no-progress cycles")
                break
            }
            XCTAssertEqual(frames.filter { $0.frameType == "i" }.count, 1,
                           "poll \(poll): each no-progress poll retransmits the outstanding frame")
        }
        XCTAssertTrue(sawLinkFailure,
                      "the retry ladder must reach link failure — the old code looped forever")
        XCTAssertNil(session.t1TimerTask, "timers must be stopped on link failure")
    }

    /// Regression (field capture 2026-08-22): RR polls from a peer's stale
    /// session, arriving while we were still CONNECTING with four unanswered
    /// SABMs on the air, produced vacuous loss=0 samples — adaptive announced
    /// "Good link quality" for a station we could not reach at all. Samples
    /// require a connected session with at least one I-frame of real evidence.
    func testLinkQualitySamplesRequireConnectedSessionWithIFrameEvidence() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath()
        var samples = 0
        manager.onLinkQualitySample = { _, _ in samples += 1 }

        // Still connecting (SABM unanswered) — the peer's zombie session polls us.
        _ = manager.connect(to: destination, path: path, channel: 0)
        _ = manager.handleInboundRRFrames(from: destination, path: path, channel: 0,
                                          nr: 0, pf: true, isCommand: true)
        XCTAssertEqual(samples, 0, "no link-quality sample while connecting")

        // Connected but no I-frame ever sent: still no evidence to learn from.
        manager.handleInboundUA(from: destination, path: path, channel: 0)
        _ = manager.handleInboundRRFrames(from: destination, path: path, channel: 0,
                                          nr: 0, pf: true, isCommand: true)
        XCTAssertEqual(samples, 0, "SABMs and polls alone are not loss evidence")

        // Real I-frame traffic: now samples flow.
        _ = manager.sendData(Data("info\r".utf8), to: destination, path: path, channel: 0)
        _ = manager.handleInboundRRFrames(from: destination, path: path, channel: 0,
                                          nr: 1, pf: false, isCommand: false)
        XCTAssertEqual(samples, 1, "an acked I-frame is genuine link-quality evidence")
    }

    /// Ack progress must reset the poll-retransmission ladder: a slow peer that
    /// DOES make progress, however marginal, is never declared failed.
    func testPollLadderResetsOnAckProgress() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: destination, path: path)

        _ = manager.sendData(Data("A".utf8), to: destination, path: path, channel: 0)
        for _ in 1...3 {
            _ = manager.handleInboundRRFrames(from: destination, path: path, channel: 0,
                                              nr: 0, pf: true, isCommand: true)
        }
        XCTAssertEqual(session.stateMachine.retryCount, 3)

        // The frame finally lands: ack advances V(A) and resets the ladder.
        _ = manager.handleInboundRRFrames(from: destination, path: path, channel: 0,
                                          nr: 1, pf: false, isCommand: false)
        XCTAssertEqual(session.stateMachine.retryCount, 0,
                       "genuine ack progress must clear the no-progress ladder")
        XCTAssertEqual(session.state, .connected)
    }

    /// Regression (field capture, KB5YZB-7): a receive gap must be able to heal on its own.
    ///
    /// After UA, T1 is stopped. If the peer then sends a wrong N(S), the receive buffer holds
    /// a gap that gates outbound data — but with T1 stopped, the T1-timeout flush that exists
    /// to skip past an unrecoverable gap could never run, so the session stalled until the
    /// peer happened to speak. Sending REJ must therefore start T1.
    ///
    /// Second field capture (2026-08-22, KB5YZB-7 via DRLNOD): the flush itself must be a
    /// last resort. The old retryCount>=2 threshold skipped V(R) past frames the peer was
    /// still actively retransmitting (~8 s into REJ recovery on a 4–8 s RTT path), silently
    /// losing their data. §6.4.4.1 forbids delivering across a gap, so the flush may only
    /// fire on the retry just before N2 would tear the link down.
    func testREJStartsT1SoReceiveGapCanHealOnlyAsLastResort() {
        let config = AX25SessionConfig(windowSize: 4)
        var sm = AX25StateMachine(config: config)
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)

        // Peer sends N(S)=1 while V(R)=0 — out of sequence, buffered, REJ sent.
        let actions = sm.handle(
            event: .receivedIFrame(ns: 1, nr: 0, pf: true, payload: Data("HELLO".utf8))
        )
        XCTAssertTrue(actions.contains(.sendREJ(nr: 0, pf: true)), "precondition: REJ is sent")
        XCTAssertTrue(actions.contains(.startT1),
                      "REJ must start T1 — it is what drives the gap-flush recovery")
        XCTAssertFalse(sm.receiveBuffer.isEmpty, "precondition: the frame is buffered")

        // While retries remain, the gap must NOT be skipped: the peer may still be
        // retransmitting the missing frame (REJ recovery in progress).
        let flushThreshold = config.maxRetries - 1
        for retry in 1..<flushThreshold {
            let early = sm.handle(event: .t1Timeout)
            XCTAssertFalse(early.contains(.deliverData(Data("HELLO".utf8))),
                           "retry \(retry): buffered data must not be delivered across the gap")
            XCTAssertFalse(sm.receiveBuffer.isEmpty,
                           "retry \(retry): the gap must be held while REJ recovery can still succeed")
            XCTAssertEqual(sm.sequenceState.vr, 0,
                           "retry \(retry): V(R) must not advance past the missing frame")
        }

        // The peer never retransmits N(S)=0. On the retry before N2 link failure,
        // flushing past the gap beats tearing the whole link down.
        let flushed = sm.handle(event: .t1Timeout)

        XCTAssertTrue(sm.receiveBuffer.isEmpty,
                      "the receive buffer must flush so outbound data stops being gated")
        XCTAssertTrue(flushed.contains(.deliverData(Data("HELLO".utf8))),
                      "the buffered frame must be delivered rather than discarded")
        XCTAssertEqual(sm.sequenceState.vr, 2, "V(R) must advance past the lost frame")
    }

    /// Regression (field capture 2026-08-22, KB5YZB-7): an RR that acknowledges
    /// everything outstanding must not strip T1 from the I-frame the same call just
    /// drained onto the air.
    ///
    /// The state machine's [stopT1, startT3] is computed while nothing is
    /// outstanding, but the handler drained the queue (transmitting "bbs" and
    /// starting T1) BEFORE executing those actions — so the stale stopT1 cancelled
    /// the fresh frame's timer. Had the peer's ack been lost, the frame would have
    /// hung unprotected until the 30 s T3 enquiry.
    func testRRDrainedFrameKeepsItsT1Timer() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath()

        let session = connectSession(manager: manager, destination: destination, path: path)

        // Fill the window so one chunk queues behind it.
        let windowSize = session.stateMachine.config.windowSize
        for i in 0...windowSize {
            _ = manager.sendData(Data("F\(i)".utf8), to: destination, path: path, channel: 0)
        }
        XCTAssertEqual(session.pendingDataQueue.count, 1, "precondition: one chunk queued")

        // Peer acks the whole window. The state machine sees outstanding == 0 and
        // emits stopT1/startT3 — but the drain then transmits the queued chunk.
        _ = manager.handleInboundRRFrames(
            from: destination, path: path, channel: 0,
            nr: windowSize, pf: true, isCommand: false
        )

        XCTAssertEqual(session.outstandingCount, 1, "the drained chunk is now outstanding")
        XCTAssertNotNil(session.t1TimerTask,
            "T1 must be running for the freshly drained frame — the pre-drain stopT1 is stale")
    }

    /// Same hazard on the UA path: data queued while connecting is drained on UA,
    /// and the UA's stopT1 (aimed at the SABM timer) must not cancel the T1 that
    /// the drain starts for the transmitted data.
    func testUADrainedFrameKeepsItsT1Timer() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath()

        _ = manager.connect(to: destination, path: path, channel: 0)
        let session = manager.session(for: destination, path: path, channel: 0)
        _ = manager.sendData(Data("EARLY".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.pendingDataQueue.count, 1, "precondition: data queued while connecting")

        manager.handleInboundUA(from: destination, path: path, channel: 0)

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.outstandingCount, 1, "queued data must be transmitted on connect")
        XCTAssertNotNil(session.t1TimerTask,
            "T1 must survive the UA's stale stopT1 — it now protects the drained frame")
    }

    // Test that correct frames are retransmitted on REJ
    func testREJRetransmissions() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])
        
        let session = connectSession(manager: manager, destination: destination, path: path)
        
        // Send 3 frames
        _ = manager.sendData(Data("FRAME1".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("FRAME2".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("FRAME3".utf8), to: destination, path: path, channel: 0)
        
        // Receive REJ(nr=1) - Peer acked FRAME1 but missed FRAME2 (and FRAME3 sent out of order)
        // Peer is asking for retransmission starting from FRAME2 (nr=1)
        // Note: handleInboundREJ returns the retransmitted frames directly
        let retransmitFrames = manager.handleInboundREJ(from: destination, path: path, channel: 0, nr: 1)

        // Should retransmit FRAME2 and FRAME3
        XCTAssertEqual(retransmitFrames.count, 2)
        XCTAssertEqual(String(data: retransmitFrames[0].payload, encoding: .utf8), "FRAME2")
        // Note: REJ retransmits everything from nr upwards
        XCTAssertEqual(String(data: retransmitFrames[1].payload, encoding: .utf8), "FRAME3")
        
        // Also verify updated N(R) in retransmitted frames
        // If we had received I-frames in the meantime, the retransmitted frames should carry fresh N(R)
    }

    /// Reads the peer receiver-busy condition off a session's state machine.
    private func sm_peerBusy(_ session: AX25Session) -> Bool {
        session.stateMachine.peerBusy
    }

}

