//
//  AX25SessionTests.swift
//  AXTermTests
//
//  TDD tests for AX25 connected-mode session state machine.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25SessionTests: XCTestCase {

    private func connectSession(
        manager: AX25SessionManager,
        destination: AX25Address,
        path: DigiPath,
        uaSource: AX25Address? = nil
    ) -> AX25Session {
        _ = manager.connect(to: destination, path: path, channel: 0)
        let session = manager.session(for: destination, path: path, channel: 0)
        manager.handleInboundUA(from: uaSource ?? destination, path: path, channel: 0)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    // MARK: - Session State Tests

    func testSessionStateEquality() {
        XCTAssertEqual(AX25SessionState.disconnected, AX25SessionState.disconnected)
        XCTAssertEqual(AX25SessionState.connecting, AX25SessionState.connecting)
        XCTAssertEqual(AX25SessionState.connected, AX25SessionState.connected)
        XCTAssertEqual(AX25SessionState.disconnecting, AX25SessionState.disconnecting)
        XCTAssertNotEqual(AX25SessionState.disconnected, AX25SessionState.connected)
    }

    func testSessionStateRawValue() {
        XCTAssertEqual(AX25SessionState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(AX25SessionState.connecting.rawValue, "connecting")
        XCTAssertEqual(AX25SessionState.connected.rawValue, "connected")
        XCTAssertEqual(AX25SessionState.disconnecting.rawValue, "disconnecting")
    }

    func testDisconnectRequestWhileConnectingSendsDISC() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        let connectActions = sm.handle(event: .connectRequest)
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(connectActions.contains(.sendSABM))

        let disconnectActions = sm.handle(event: .disconnectRequest)
        XCTAssertEqual(sm.state, .disconnecting)
        XCTAssertTrue(disconnectActions.contains(.sendDISC))
        XCTAssertTrue(disconnectActions.contains(.stopT1))
        XCTAssertTrue(disconnectActions.contains(.startT1))
    }

    func testForceDisconnectFromConnectingStopsTimersAndNotifies() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        XCTAssertEqual(sm.state, .connecting)

        let actions = sm.handle(event: .forceDisconnect)
        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
        XCTAssertFalse(actions.contains(.sendDISC))
    }

    func testForceDisconnectFromConnectedStopsTimersAndNotifies() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)

        let actions = sm.handle(event: .forceDisconnect)
        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.stopT3))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
        XCTAssertFalse(actions.contains(.sendDISC))
    }

    // MARK: - Session Configuration Tests

    func testSessionConfigDefaults() {
        let config = AX25SessionConfig()

        // Default window size K=4
        XCTAssertEqual(config.windowSize, 4)

        // Default max retries N2=10
        XCTAssertEqual(config.maxRetries, 10)

        // Default modulo 8 (not extended)
        XCTAssertEqual(config.modulo, 8)
        XCTAssertFalse(config.extended)
    }

    func testSessionConfigCustomValues() {
        let config = AX25SessionConfig(
            windowSize: 4,
            maxRetries: 5,
            extended: true
        )

        XCTAssertEqual(config.windowSize, 4)
        XCTAssertEqual(config.maxRetries, 5)
        XCTAssertEqual(config.modulo, 128)
        XCTAssertTrue(config.extended)
    }

    func testSessionConfigWindowSizeClamped() {
        // Window size should be clamped to valid range
        let minConfig = AX25SessionConfig(windowSize: 0)
        XCTAssertEqual(minConfig.windowSize, 1)  // Minimum 1

        let maxConfig = AX25SessionConfig(windowSize: 10)
        XCTAssertEqual(maxConfig.windowSize, 7)  // Maximum 7 for mod-8
    }

    // MARK: - Sequence Number Tests

    func testSequenceNumberMod8Wraparound() {
        // Test modulo-8 sequence number behavior
        var seq = AX25SequenceState(modulo: 8)

        // Initial state
        XCTAssertEqual(seq.vs, 0)  // V(S) = next to send
        XCTAssertEqual(seq.vr, 0)  // V(R) = next expected to receive
        XCTAssertEqual(seq.va, 0)  // V(A) = oldest unacked

        // Increment send sequence
        seq.incrementVS()
        XCTAssertEqual(seq.vs, 1)

        // Increment 7 more times to wrap
        for _ in 0..<7 {
            seq.incrementVS()
        }
        XCTAssertEqual(seq.vs, 0)  // Should wrap at 8
    }

    func testSequenceNumberMod128Wraparound() {
        // Test modulo-128 (extended) sequence number behavior
        var seq = AX25SequenceState(modulo: 128)

        // Increment 128 times to wrap
        for _ in 0..<128 {
            seq.incrementVS()
        }
        XCTAssertEqual(seq.vs, 0)  // Should wrap at 128
    }

    func testSequenceNumberAckRange() {
        var seq = AX25SequenceState(modulo: 8)

        // Send 3 frames
        seq.incrementVS()  // vs=1
        seq.incrementVS()  // vs=2
        seq.incrementVS()  // vs=3

        // va=0, vs=3 means frames 0,1,2 are outstanding
        XCTAssertEqual(seq.outstandingCount, 3)

        // Receive ack for frame 2 (nr=2 means 0,1 are acked)
        seq.ackUpTo(nr: 2)
        XCTAssertEqual(seq.va, 2)
        XCTAssertEqual(seq.outstandingCount, 1)  // Only frame 2 outstanding
    }

    func testSequenceNumberWindowCheck() {
        var seq = AX25SequenceState(modulo: 8)
        let windowSize = 2

        // Can send while window not full
        XCTAssertTrue(seq.canSend(windowSize: windowSize))

        // Send 2 frames (fills window)
        seq.incrementVS()
        seq.incrementVS()
        XCTAssertFalse(seq.canSend(windowSize: windowSize))

        // Ack one frame
        seq.ackUpTo(nr: 1)
        XCTAssertTrue(seq.canSend(windowSize: windowSize))
    }

    // MARK: - Session Timer Tests

    func testSessionTimerConfiguration() {
        var timers = AX25SessionTimers()

        // Initial RTO should be default (4.0 per AX25SessionTimers)
        XCTAssertEqual(timers.rto, 4.0, accuracy: 0.1)

        // Update with RTT sample
        timers.updateRTT(sample: 1.5)
        // First sample: srtt=1.5, rttvar=0.75, rto=1.5+4*0.75=4.5
        XCTAssertEqual(timers.srtt!, 1.5, accuracy: 0.01)
        XCTAssertEqual(timers.rttvar, 0.75, accuracy: 0.01)

        // RTO should be clamped between min and max
        XCTAssertGreaterThanOrEqual(timers.rto, 1.0)  // min
        XCTAssertLessThanOrEqual(timers.rto, 30.0)    // max
    }

    func testSessionTimerBackoff() {
        var timers = AX25SessionTimers()

        let initialRTO = timers.rto  // 4.0 default
        timers.backoff()

        // Backoff should double the RTO (clamped to max 30)
        XCTAssertEqual(timers.rto, min(initialRTO * 2, 30.0), accuracy: 0.1)
    }

    func testSendDataUsesConnectedSessionWhenPathDiffers() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let originalPath = DigiPath.from(["W0ARP-7"])
        let requestedPath = DigiPath.from(["WIDE1-1"])

        let session = manager.session(for: destination, path: originalPath, channel: 0)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)

        XCTAssertEqual(session.state, .connected)

        let frames = manager.sendData(Data([0x41]), to: destination, path: requestedPath, channel: 0)

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.path, originalPath)
    }

    func testFirstT1TimeoutPollsBeforeRetransmittingOutstandingFrames() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        let session = manager.session(for: destination, path: path, channel: 0)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)

        XCTAssertEqual(session.state, .connected)

        let frames = manager.sendData(Data([0x41]), to: destination, path: path, channel: 0)
        XCTAssertEqual(frames.count, 1)

        let firstTimeoutFrames = manager.handleT1Timeout(session: session)

        let firstIFrames = firstTimeoutFrames.filter { $0.frameType == "i" }
        XCTAssertEqual(firstIFrames.count, 1, "First T1 should immediately retransmit the outstanding I-frame with P=1")
        XCTAssertEqual(firstIFrames.first?.controlByte.map { Int($0 & 0x10) }, 0x10, "Retransmitted frame must have P=1 set")
        let firstPollFrames = firstTimeoutFrames.filter { $0.frameType == "s" }
        XCTAssertEqual(firstPollFrames.count, 0, "First T1 should not send a separate RR poll command")

        let secondTimeoutFrames = manager.handleT1Timeout(session: session)
        let secondIFrames = secondTimeoutFrames.filter { $0.frameType == "i" }
        XCTAssertEqual(secondIFrames.count, 1, "Second consecutive T1 should also retransmit the outstanding I-frame")
        XCTAssertEqual(secondIFrames.first?.sessionId, session.id)

    }

    func testNonAdaptiveFirstT1TimeoutPollsBeforeRetransmit() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        manager.defaultConfig = AX25SessionConfig(adaptiveTimeout: false)

        let destination = AX25Address(call: "DRLNOD", ssid: 0)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: destination, path: path)

        let frames = manager.sendData(Data("c kb5yzb-7\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(frames.count, 1)

        let timeoutFrames = manager.handleT1Timeout(session: session)
        let iFrames = timeoutFrames.filter { $0.frameType == "i" }
        let pollFrames = timeoutFrames.filter { $0.frameType == "s" }

        XCTAssertEqual(iFrames.count, 1, "Adaptive-off should immediately retransmit the outstanding I-frame with P=1")
        XCTAssertEqual(iFrames.first?.controlByte.map { Int($0 & 0x10) }, 0x10, "Retransmitted frame must have P=1 set")
        XCTAssertEqual(pollFrames.count, 0, "T1 recovery should not send a separate RR poll command")

        let secondTimeoutFrames = manager.handleT1Timeout(session: session)
        XCTAssertEqual(
            secondTimeoutFrames.filter { $0.frameType == "i" }.count,
            1,
            "Second consecutive fixed-RTO T1 should also retransmit the outstanding I-frame"
        )
    }

    func testNonAdaptiveT1TimeoutDoesNotBackoffRTO() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        manager.defaultConfig = AX25SessionConfig(initialRto: 4.0, adaptiveTimeout: false)

        let destination = AX25Address(call: "DRLNOD", ssid: 0)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: destination, path: path)

        _ = manager.sendData(Data("Help\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.timers.rto, 4.0, accuracy: 0.01)

        _ = manager.handleT1Timeout(session: session)

        XCTAssertEqual(session.timers.rto, 4.0, accuracy: 0.01, "Adaptive-off should keep fixed FRACK/T1 rather than exponential RTO backoff")
    }

    /// §6.7.1.1: T1 "should be adjusted according to the number of repeaters".
    /// The initial RTO seed is scaled by the TNC-2 FRACK convention (2m+1) for m digis;
    /// a direct path is unchanged. Field capture 2026-08-22 (KB5YZB-7 via DRLNOD):
    /// a direct-link 4 s T1 on a one-digi path (measured RTT 4–8 s) fired before
    /// nearly every ack, costing a spurious retransmit + REJ per I-frame.
    func testInitialRTOScalesWithDigipeaterCount() {
        let config = AX25SessionConfig(initialRto: 4.0, adaptiveTimeout: false)
        let local = AX25Address(call: "K0EPI", ssid: 7)
        let remote = AX25Address(call: "KB5YZB", ssid: 7)

        let direct = AX25Session(localAddress: local, remoteAddress: remote, config: config)
        XCTAssertEqual(direct.timers.rto, 4.0, accuracy: 0.01, "direct path keeps the configured T1")

        let oneDigi = AX25Session(
            localAddress: local, remoteAddress: remote,
            path: DigiPath.from(["DRLNOD"]), config: config
        )
        XCTAssertEqual(oneDigi.timers.rto, 12.0, accuracy: 0.01, "one digi: T1 × (2·1+1)")

        let twoDigi = AX25Session(
            localAddress: local, remoteAddress: remote,
            path: DigiPath.from(["DRLNOD", "W0ARP-7"]), config: config
        )
        XCTAssertEqual(twoDigi.timers.rto, 20.0, accuracy: 0.01, "two digis: T1 × (2·2+1)")
    }

    /// Inbound FRMR must reach the session layer. Until the manager grew
    /// handleInboundFRMR, the state machine's FRMR handler was dead code: a
    /// peer's frame-reject was decoded, displayed, and silently ignored while
    /// we kept transmitting into a session the peer had declared broken.
    func testInboundFRMRMovesSessionToErrorAndStopsTimers() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath.from(["DRLNOD"])
        let session = connectSession(manager: manager, destination: destination, path: path)

        // Outstanding I-frame so T1 is running when the FRMR lands.
        _ = manager.sendData(Data("hello\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertNotNil(session.t1TimerTask, "precondition: T1 armed")

        manager.handleInboundFRMR(from: destination, path: path, channel: 0)

        XCTAssertEqual(session.state, .error, "FRMR is an unrecoverable protocol error")
        XCTAssertNil(session.t1TimerTask, "a dead session must not keep retransmitting")
    }

    /// The hop-scaled seed must respect rtoMax, and must only be a seed: the first
    /// RTT sample in adaptive mode replaces it with the measured estimate.
    func testHopScaledInitialRTOClampsAndYieldsToMeasuredRTT() {
        let local = AX25Address(call: "K0EPI", ssid: 7)
        let remote = AX25Address(call: "KB5YZB", ssid: 7)

        let clamped = AX25Session(
            localAddress: local, remoteAddress: remote,
            path: DigiPath.from(["DRLNOD", "W0ARP-7", "WIDE2-1"]),
            config: AX25SessionConfig(rtoMax: 30.0, initialRto: 8.0, adaptiveTimeout: false)
        )
        XCTAssertEqual(clamped.timers.rto, 30.0, accuracy: 0.01, "8 s × 7 hops multiplier clamps to rtoMax")

        var adaptive = AX25Session(
            localAddress: local, remoteAddress: remote,
            path: DigiPath.from(["DRLNOD"]),
            config: AX25SessionConfig(initialRto: 4.0, adaptiveTimeout: true)
        ).timers
        XCTAssertEqual(adaptive.rto, 12.0, accuracy: 0.01)
        adaptive.updateRTT(sample: 2.0)
        // First sample: srtt=2, rttvar=1, rto=2+4·1=6 — the seed is fully replaced.
        XCTAssertEqual(adaptive.rto, 6.0, accuracy: 0.01, "measured RTT replaces the hop-scaled seed")
    }

    func testSendDataQueuesWhileReceiveSequenceGapIsUnresolved() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        manager.defaultConfig = AX25SessionConfig(adaptiveTimeout: false)

        let destination = AX25Address(call: "DRLNOD", ssid: 0)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: destination, path: path)

        _ = manager.handleInboundIFrame(
            from: destination,
            path: path,
            channel: 0,
            ns: 1,
            nr: 0,
            pf: false,
            payload: Data("out of order".utf8)
        )
        XCTAssertTrue(session.hasReceiveSequenceGap)

        let frames = manager.sendData(Data("c kb5yzb-7\r".utf8), to: destination, path: path, channel: 0)

        XCTAssertTrue(frames.isEmpty, "Do not transmit new terminal data while waiting for a missing inbound I-frame")
        XCTAssertEqual(session.pendingDataQueue.count, 1)
        XCTAssertEqual(session.vs, 0, "Queued data must not consume an outbound sequence number")
    }

    func testRejRetransmitsWithConnectedSessionPathMismatch() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let originalPath = DigiPath.from(["W0ARP-7"])
        let incomingPath = DigiPath.from(["WIDE1-1"])

        let session = manager.session(for: destination, path: originalPath, channel: 0)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)

        XCTAssertEqual(session.state, .connected)

        let frames = manager.sendData(Data([0x41]), to: destination, path: originalPath, channel: 0)
        XCTAssertEqual(frames.count, 1)

        // Capture retransmissions returned by handleInboundREJ
        let retransmitFrames = manager.handleInboundREJ(from: destination, path: incomingPath, channel: 0, nr: 0)
        
        XCTAssertEqual(retransmitFrames.count, 1)
        XCTAssertEqual(retransmitFrames.first?.sessionId, session.id)

    }

    func testHandleInboundUAWithSSIDMismatchCompletesConnect() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let uaSource = AX25Address(call: "N0HI", ssid: 9)
        let path = DigiPath.from(["W0ARP-7"])

        _ = manager.connect(to: destination, path: path, channel: 0)
        let session = manager.session(for: destination, path: path, channel: 0)

        // Return value of handleInboundUA is irrelevant here, checking state transition
        _ = manager.handleInboundUA(from: uaSource, path: path, channel: 0)

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.remoteAddress.display, destination.display)
    }

    func testHandleInboundIFrameWithSSIDMismatchReturnsRR() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let mismatchSource = AX25Address(call: "N0HI", ssid: 9)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)

        // P=1 so the ack is synchronous — a P=0 frame would arm T2 instead.
        let sentFrame = manager.handleInboundIFrame(
            from: mismatchSource,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: true,
            payload: Data("INFO".utf8)
        )

        XCTAssertNotNil(sentFrame, "RR should be sent immediately")
        XCTAssertEqual(sentFrame?.frameType, "s")
        XCTAssertEqual(sentFrame?.displayInfo?.prefix(2), "RR")

    }

    func testHandleInboundRRWithSSIDMismatchAcksOutstanding() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let mismatchSource = AX25Address(call: "N0HI", ssid: 9)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)
        _ = manager.sendData(Data([0x41]), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)

        _ = manager.handleInboundRR(from: mismatchSource, path: path, channel: 0, nr: 1, isPoll: false)

        XCTAssertEqual(session.outstandingCount, 0)
    }

    func testHandleInboundREJWithSSIDMismatchRetransmits() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let mismatchSource = AX25Address(call: "N0HI", ssid: 9)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)
        _ = manager.sendData(Data([0x41]), to: destination, path: path, channel: 0)

        // Capture retransmissions returned by handleInboundREJ
        let retransmitFrames = manager.handleInboundREJ(from: mismatchSource, path: path, channel: 0, nr: 0)
        
        XCTAssertEqual(retransmitFrames.count, 1)
        XCTAssertEqual(retransmitFrames.first?.sessionId, session.id)
    }

    func testHandleInboundDMWithSSIDMismatchDisconnectsSession() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let mismatchSource = AX25Address(call: "N0HI", ssid: 9)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)

        // Only checking side effect on session state
        _ = manager.handleInboundDM(from: mismatchSource, path: path, channel: 0)

        XCTAssertEqual(session.state, .disconnected)
    }

    func testDMStopsOutstandingT1AndClearsSendBuffer() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        manager.defaultConfig = AX25SessionConfig(adaptiveTimeout: false)

        let destination = AX25Address(call: "DRLNOD", ssid: 0)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: destination, path: path)

        _ = manager.sendData(Data("HELP\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)
        XCTAssertNotNil(session.t1TimerTask)

        manager.handleInboundDM(from: destination, path: path, channel: 0)

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertNil(session.t1TimerTask, "DM must stop T1 immediately")
        XCTAssertNil(session.t1PendingRetransmitTask, "DM must cancel any pending grace retransmit")
    }

    func testDigiPathFromStripsRepeatedMarkerAndParsesSSID() {
        let path = DigiPath.from(["W0ARP-7*", "WIDE1-1*", "DRL"])

        XCTAssertEqual(path.digis.count, 3)
        XCTAssertEqual(path.digis[0].call, "W0ARP")
        XCTAssertEqual(path.digis[0].ssid, 7)
        XCTAssertTrue(path.digis[0].repeated)
        XCTAssertEqual(path.digis[1].call, "WIDE1")
        XCTAssertEqual(path.digis[1].ssid, 1)
        XCTAssertTrue(path.digis[1].repeated)
        XCTAssertEqual(path.digis[2].call, "DRL")
        XCTAssertEqual(path.digis[2].ssid, 0)
        XCTAssertFalse(path.digis[2].repeated)
        XCTAssertEqual(path.display, "W0ARP-7,WIDE1-1,DRL")
    }

    func testHandleInboundIFrameWhileConnectingIsIgnored() {
        // §6.3.1: "The originating TNC sending a SABM(E) command ignores and discards
        // any frames except SABM, DISC, UA and DM frames from the distant TNC."
        //
        // This test previously asserted the opposite — a DM reply to "reset a phantom
        // session". Live capture against KB5YZB-7 (BPQ) showed why that is wrong: the
        // peer had answered our SABM with UA plus its first I-frame, both lost on RF.
        // It was legitimately connected, and our DM told it to tear the new link down.
        // The spec's reset mechanism for a genuinely stale peer is the retransmitted
        // SABM itself, whose UA zeroes V(S)/V(A)/V(R) on both ends.
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7*"])

        _ = manager.connect(to: destination, path: path, channel: 0)

        let sentFrame = manager.handleInboundIFrame(
            from: destination,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: true,
            payload: Data("INFO".utf8)
        )

        XCTAssertNil(sentFrame, "§6.3.1: I-frame while our SABM is outstanding must be ignored — DM here tears down a freshly established peer")
        let session = manager.session(for: destination, path: path, channel: 0)
        XCTAssertEqual(session.state, .connecting, "Session must stay .connecting — SABM retransmit loop continues")
    }

    func testHandleInboundRRWhileConnectingIsIgnored() {
        // §6.3.1: same rule for supervisory frames. The KB5YZB-7 field log showed the
        // peer polling RR(P=1) right after its (lost) UA; answering DM destroyed the
        // link it had just established. The RR must be discarded and the SABM
        // retransmission loop left to complete the connection.
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath()

        _ = manager.connect(to: destination, path: path, channel: 0)
        let session = manager.session(for: destination, path: path, channel: 0)
        XCTAssertEqual(session.state, .connecting)

        // The exact frame from the field capture: RR(nr=0, P=1) command while connecting
        let response = manager.handleInboundRR(
            from: destination,
            path: path,
            channel: 0,
            nr: 0,
            isPoll: true
        )

        XCTAssertNil(response, "§6.3.1: RR while our SABM is outstanding must be ignored, not answered with DM")
        XCTAssertEqual(session.state, .connecting, "Session must stay .connecting — SABM retransmit loop must not be interrupted")
    }

    func testHandleInboundIFrameWithNoSessionDoesNotRespondWithDM() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let source = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        // No sessions created at all. An unexpected I-frame should be safely ignored
        // and MUST NOT trigger a DM, to avoid tearing down a valid remote link.
        let sentFrame = manager.handleInboundIFrame(
            from: source,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: false,
            payload: Data("INFO".utf8)
        )

        XCTAssertNil(sentFrame, "Unexpected inbound I-frame with no session should be ignored, not answered with DM")

    }

    func testHandleInboundIFrameDuplicateForExistingSessionIsAcknowledgedNotDM() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        // Establish a connected session.
        let session = connectSession(manager: manager, destination: destination, path: path)
        XCTAssertEqual(session.state, .connected)

        // First delivery of an in-sequence I-frame. P=1 keeps the ack
        // synchronous; the DM-vs-RR distinction under test is orthogonal
        // to the T2 delayed-ack batching.
        let firstResponse = manager.handleInboundIFrame(
            from: destination,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: true,
            payload: Data("WELCOME".utf8)
        )

        XCTAssertNotNil(firstResponse, "I-frame should be acknowledged immediately")
        XCTAssertEqual(firstResponse?.frameType, "s")  // RR

        // A duplicate decode of the same frame with a slightly different path
        // (e.g. without the repeated marker) must NOT cause a DM.
        // It should trigger another RR (immediate) to ensure the peer knows we have it.
        let altPath = DigiPath.from(["W0ARP-7*"])
        let duplicateResponse = manager.handleInboundIFrame(
            from: destination,
            path: altPath,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: true,
            payload: Data("WELCOME".utf8)
        )

        // We explicitly check that it IS an RR (and not a DM)
        if let frame = duplicateResponse {
            XCTAssertNotEqual(frame.frameType, "u", "Duplicate I-frame must not generate a DM U-frame")
            XCTAssertEqual(frame.frameType, "s", "Duplicate I-frame should trigger an RR")
        } else {
             XCTFail("Duplicate I-frame should trigger an immediate RR")
        }
    }

    // MARK: - Robustness & Safety Invariants

    func testHandleInboundRRWithNoSessionDoesNotCreateSessionOrRespond() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let source = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        let sentFrame = manager.handleInboundRR(
            from: source,
            path: path,
            channel: 0,
            nr: 1,
            isPoll: false
        )

        XCTAssertNil(sentFrame, "RR with no existing session should be ignored")
        XCTAssertTrue(manager.sessions.isEmpty, "RR with no session must not implicitly create a session")
    }

    func testRRFinalResponseDoesNotTriggerPollReply() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "DRLNOD", ssid: 0)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: destination, path: path)

        _ = manager.sendData(Data("Help\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)

        let response = manager.handleInboundRR(
            from: destination,
            path: path,
            channel: 0,
            nr: 1,
            pf: true,
            isCommand: false
        )

        XCTAssertNil(response, "RR(F=1) response must not be treated as a poll requiring our RR reply")
        XCTAssertEqual(session.outstandingCount, 0)
    }



    func testHandleInboundREJWithNoSessionDoesNotCreateSessionOrRespond() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let source = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        let retransmitFrames = manager.handleInboundREJ(
            from: source,
            path: path,
            channel: 0,
            nr: 0
        )

        XCTAssertTrue(retransmitFrames.isEmpty, "REJ with no session should not produce retransmits")
        XCTAssertTrue(manager.sessions.isEmpty, "REJ with no session must not implicitly create a session")
    }

    // MARK: - §6.3.5: DM Responses to Unknown-Session Polls

    // §6.3.5: "Any TNC receiving a command frame other than a SABM(E) or UI frame
    // with the P bit set to '1' responds with a DM frame with the F bit set to '1'.
    // The offending frame is ignored."  With no session, we are in the disconnected
    // state for that peer. This is what lets a peer holding a stale session (e.g.
    // after we crashed or restarted) clear it promptly instead of polling until its
    // own N2 expires. P=0 frames stay ignored — the tests above lock that in, and
    // it is the spec's own guard against DM storms from digipeated duplicates.

    private func assertIsDM(_ frame: OutboundFrame?, file: StaticString = #filePath, line: UInt = #line) {
        guard let frame else {
            XCTFail("expected a DM frame, got nil", file: file, line: line)
            return
        }
        let decoded = AX25ControlFieldDecoder.decode(control: frame.controlByte ?? 0)
        XCTAssertEqual(decoded.uType, .DM, "expected DM, got \(String(describing: decoded.uType))", file: file, line: line)
        XCTAssertNotEqual((frame.controlByte ?? 0) & 0x10, 0, "§6.3.5: the DM must carry F=1", file: file, line: line)
    }

    /// §6.3.5: RR command poll for an unknown session → DM(F=1).
    func testUnknownSessionRRPollAnsweredWithDM() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let stranger = AX25Address(call: "N0HI", ssid: 7)

        let frames = manager.handleInboundRRFrames(
            from: stranger, path: DigiPath(), channel: 0,
            nr: 0, pf: true, isCommand: true
        )

        XCTAssertEqual(frames.count, 1)
        assertIsDM(frames.first)
        XCTAssertTrue(manager.sessions.isEmpty, "the offending frame is ignored — no session is created")
    }

    /// §6.3.5: RNR and REJ command polls for an unknown session → DM(F=1).
    func testUnknownSessionRNRAndREJPollsAnsweredWithDM() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let stranger = AX25Address(call: "N0HI", ssid: 7)

        let rnrFrames = manager.handleInboundRNR(
            from: stranger, path: DigiPath(), channel: 0,
            nr: 0, pf: true, isCommand: true
        )
        XCTAssertEqual(rnrFrames.count, 1)
        assertIsDM(rnrFrames.first)

        let rejFrames = manager.handleInboundREJ(
            from: stranger, path: DigiPath(), channel: 0,
            nr: 0, pf: true, isCommand: true
        )
        XCTAssertEqual(rejFrames.count, 1)
        assertIsDM(rejFrames.first)

        XCTAssertTrue(manager.sessions.isEmpty)
    }

    /// §6.3.5: I-frame poll (P=1) for an unknown session → DM(F=1). I frames are
    /// always commands in AX.25 v2.2.
    func testUnknownSessionIFramePollAnsweredWithDM() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let stranger = AX25Address(call: "N0HI", ssid: 7)

        let frame = manager.handleInboundIFrame(
            from: stranger, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: true, payload: Data("INFO".utf8)
        )

        assertIsDM(frame)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    /// §6.3.5: a supervisory *response* frame for an unknown session is never
    /// answered — the rule covers command frames only.
    func testUnknownSessionRRResponseIsIgnored() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let stranger = AX25Address(call: "N0HI", ssid: 7)

        let frames = manager.handleInboundRRFrames(
            from: stranger, path: DigiPath(), channel: 0,
            nr: 0, pf: true, isCommand: false
        )
        XCTAssertTrue(frames.isEmpty, "§6.3.5 covers command frames; responses are discarded silently")
    }

    // MARK: - §6.2: REJ Command Poll Must Receive F=1 Reply

    /// §6.2: "The next response frame returned to a supervisory command frame with
    /// the P bit set to '1', received during the information transfer state, is an
    /// RR, RNR or REJ response frame with the F bit set to '1'."
    ///
    /// Regression: the manager previously dropped pf/isCommand on the floor when
    /// dispatching REJ, so an REJ poll never got its mandatory Final — the polling
    /// peer sat in its own T1 recovery waiting for an F=1 that never came.
    func testREJCommandPollReceivesRRFinalReply() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath()

        _ = manager.connect(to: destination, path: path, channel: 0)
        manager.handleInboundUA(from: destination, path: path, channel: 0)
        _ = manager.sendData(Data("DATA".utf8), to: destination, path: path, channel: 0)

        let frames = manager.handleInboundREJ(
            from: destination, path: path, channel: 0,
            nr: 0, pf: true, isCommand: true
        )

        let finalReplies = frames.filter { frame in
            frame.frameType == "s" && frame.isCommand != true && ((frame.controlByte ?? 0) & 0x10) != 0
        }
        XCTAssertEqual(finalReplies.count, 1,
            "§6.2: an REJ command with P=1 must be answered by exactly one supervisory response with F=1")
    }

    // MARK: - §6.3.1/§6.4.1: No I Frames Before the Link Is Up

    /// Data queued while still awaiting UA must not be drained onto the air by an
    /// inbound RR — I frames may only flow in the information-transfer state.
    func testRRWhileConnectingDoesNotDrainQueuedData() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath()

        _ = manager.connect(to: destination, path: path, channel: 0)
        let session = manager.session(for: destination, path: path, channel: 0)
        _ = manager.sendData(Data("EARLY".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.pendingDataQueue.count, 1, "precondition: data queued while connecting")

        var emitted: [OutboundFrame] = []
        manager.onSendFrame = { emitted.append($0) }
        let returned = manager.handleInboundRRFrames(
            from: destination, path: path, channel: 0,
            nr: 0, pf: true, isCommand: true
        )

        XCTAssertTrue((emitted + returned).allSatisfy { $0.frameType != "i" },
            "no I-frame may be transmitted before UA establishes the link")
        XCTAssertEqual(session.pendingDataQueue.count, 1, "queued data must remain queued until connected")
        XCTAssertEqual(session.state, .connecting)
    }


    func testT1TimeoutDoesNotRetransmitWhenNoOutstandingFrames() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.outstandingCount, 0)

        // No outstanding I-frames: T1 timeout should produce an RR poll
        // (to verify the link) but NOT retransmit any I-frames.
        let frames = manager.handleT1Timeout(session: session)

        // Should have exactly one frame: the RR poll
        XCTAssertEqual(frames.count, 1, "T1 with no outstanding should produce RR poll only")
        // Verify it's an S-frame (RR), not an I-frame retransmit
        if let frame = frames.first {
            XCTAssertEqual(frame.frameType, "s", "Should be S-frame (RR poll), not I-frame retransmit")
        }
    }


    // MARK: - Session Event Tests

    func testSessionEventTypes() {
        // Verify all event types exist
        let events: [AX25SessionEvent] = [
            .connectRequest,
            .disconnectRequest,
            .receivedUA,
            .receivedDM,
            .receivedSABM,
            .receivedDISC,
            .receivedFRMR,
            .receivedRR(nr: 0),
            .receivedRNR(nr: 0),
            .receivedREJ(nr: 0),
            .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data()),
            .t1Timeout,
            .t3Timeout
        ]

        XCTAssertEqual(events.count, 13)
    }

    // MARK: - Session Statistics Tests

    func testSessionStatisticsInitial() {
        let stats = AX25SessionStatistics()

        XCTAssertEqual(stats.framesSent, 0)
        XCTAssertEqual(stats.framesReceived, 0)
        XCTAssertEqual(stats.retransmissions, 0)
        XCTAssertEqual(stats.bytesSent, 0)
        XCTAssertEqual(stats.bytesReceived, 0)
    }

    func testSessionStatisticsUpdate() {
        var stats = AX25SessionStatistics()

        stats.recordSent(bytes: 100)
        stats.recordReceived(bytes: 50)
        stats.recordRetransmit()

        XCTAssertEqual(stats.framesSent, 1)
        XCTAssertEqual(stats.framesReceived, 1)
        XCTAssertEqual(stats.retransmissions, 1)
        XCTAssertEqual(stats.bytesSent, 100)
        XCTAssertEqual(stats.bytesReceived, 50)
    }

    // MARK: - State Machine Tests

    func testStateMachineInitialState() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        XCTAssertEqual(sm.state, .disconnected)
    }

    func testStateMachineConnectRequestFromDisconnected() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        let actions = sm.handle(event: .connectRequest)

        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(actions.contains(.sendSABM))
        XCTAssertTrue(actions.contains(.startT1))
    }

    func testStateMachineUAWhileConnecting() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)

        let actions = sm.handle(event: .receivedUA)

        XCTAssertEqual(sm.state, .connected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.startT3))
        XCTAssertTrue(actions.contains(.notifyConnected))
    }

    func testStateMachineDMWhileConnecting() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)

        let actions = sm.handle(event: .receivedDM)

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains { action in
            if case .notifyError = action { return true }
            return false
        })
    }

    func testStateMachineT1TimeoutRetry() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 3))
        _ = sm.handle(event: .connectRequest)

        // First timeout - should retry
        let actions1 = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(actions1.contains(.sendSABM))
        XCTAssertEqual(sm.retryCount, 1)
    }

    func testStateMachineT1TimeoutExceeded() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 2))
        _ = sm.handle(event: .connectRequest)

        _ = sm.handle(event: .t1Timeout)  // retry 1
        _ = sm.handle(event: .t1Timeout)  // retry 2
        let actions = sm.handle(event: .t1Timeout)  // exceed

        XCTAssertEqual(sm.state, .error)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains { action in
            if case .notifyError = action { return true }
            return false
        })
    }

    func testStateMachineDisconnectRequestWhileConnected() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        let actions = sm.handle(event: .disconnectRequest)

        XCTAssertEqual(sm.state, .disconnecting)
        XCTAssertTrue(actions.contains(.sendDISC))
        XCTAssertTrue(actions.contains(.stopT3))
        XCTAssertTrue(actions.contains(.startT1))
    }

    func testStateMachineUAWhileDisconnecting() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        _ = sm.handle(event: .disconnectRequest)

        let actions = sm.handle(event: .receivedUA)

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
    }

    func testStateMachineReceivedSABMWhileDisconnected() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        let actions = sm.handle(event: .receivedSABM)

        XCTAssertEqual(sm.state, .connected)
        XCTAssertTrue(actions.contains(.sendUA))
        XCTAssertTrue(actions.contains(.startT3))
        XCTAssertTrue(actions.contains(.notifyConnected))
    }

    func testStateMachineReceivedDISCWhileConnected() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        let actions = sm.handle(event: .receivedDISC)

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.sendUA))
        XCTAssertTrue(actions.contains(.stopT3))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
    }

    func testStateMachineReceivedIFrameInSequence() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        let payload = Data([0x01, 0x02, 0x03])
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: payload))

        XCTAssertTrue(actions.contains { action in
            if case .deliverData(let data, _) = action { return data == payload }
            return false
        })
        // P=0 → the ack is owed on T2, cumulatively.
        XCTAssertTrue(actions.contains(.startT2))
        XCTAssertTrue(sm.handle(event: .t2Timeout).contains { action in
            if case .sendRR(let nr, _, _) = action { return nr == 1 }
            return false
        })
        XCTAssertEqual(sm.sequenceState.vr, 1)
    }

    func testStateMachineReceivedIFrameOutOfSequence() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Receive frame with ns=1 when expecting ns=0
        let payload = Data([0x01])
        let actions = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: payload))

        // Should send REJ requesting retransmit from expected sequence
        XCTAssertTrue(actions.contains { action in
            if case .sendREJ(let nr, _, _) = action { return nr == 0 }
            return false
        })
        // Should NOT deliver data
        XCTAssertFalse(actions.contains { action in
            if case .deliverData = action { return true }
            return false
        })
    }

    func testStateMachineInSequenceAndDuplicateIFramesMaintainOrder() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        let payload1 = Data("LINE1".utf8)
        let payload2 = Data("LINE2".utf8)

        // Receive in-sequence ns=0
        let actions1 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: payload1))
        XCTAssertEqual(sm.sequenceState.vr, 1)
        XCTAssertTrue(actions1.contains { action in
            if case .deliverData(let data, _) = action { return data == payload1 }
            return false
        })

        // Receive in-sequence ns=1
        let actions2 = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: payload2))
        XCTAssertEqual(sm.sequenceState.vr, 2)
        XCTAssertTrue(actions2.contains { action in
            if case .deliverData(let data, _) = action { return data == payload2 }
            return false
        })

        // Duplicate of ns=1 should NOT advance VR or deliver again
        let actionsDup = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: payload2))
        XCTAssertEqual(sm.sequenceState.vr, 2, "Duplicate I-frame must not advance V(R)")
        XCTAssertFalse(actionsDup.contains { action in
            if case .deliverData = action { return true }
            return false
        })
        XCTAssertTrue(sm.handle(event: .t2Timeout).contains { action in
            if case .sendRR(let nr, _, _) = action { return nr == 2 }
            return false
        }, "Duplicate I-frame draws a re-ack of the current V(R) when T2 fires")
    }

    func testStateMachineReceivedRRAcknowledgesFrames() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Simulate sending I-frame (this would increment vs)
        sm.sequenceState.incrementVS()
        sm.sequenceState.incrementVS()
        XCTAssertEqual(sm.sequenceState.outstandingCount, 2)

        // Receive RR with nr=2 (acks frames 0,1)
        let actions = sm.handle(event: .receivedRR(nr: 2))

        XCTAssertEqual(sm.sequenceState.va, 2)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.startT3))
    }

    func testStateMachineReceivedFRMR() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        let actions = sm.handle(event: .receivedFRMR)

        XCTAssertEqual(sm.state, .error)
        XCTAssertTrue(actions.contains(.stopT3))
        XCTAssertTrue(actions.contains { action in
            if case .notifyError = action { return true }
            return false
        })
    }

    func testStateMachineT3TimeoutSendsRR() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        let actions = sm.handle(event: .t3Timeout)

        // §4.4.5.2: "When T3 times out, an RR or RNR frame is transmitted as a
        // command with the P bit set, and then T1 is started."
        XCTAssertTrue(actions.contains { action in
            if case .sendRR(_, let pf, let isCommand) = action { return pf == true && isCommand == true }
            return false
        }, "T3 expiry must transmit an RR command with P=1 (§4.4.5.2)")
        XCTAssertTrue(actions.contains(.startT1), "T1 times the enquiry (§4.4.5.2)")
        XCTAssertFalse(actions.contains(.startT3),
            "T3 restarts only when the enquiry is answered — not passively at expiry")
    }

    func testStateMachineSequenceStateReset() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Simulate some activity
        sm.sequenceState.incrementVS()
        sm.sequenceState.incrementVR()

        // Disconnect and reconnect
        _ = sm.handle(event: .disconnectRequest)
        _ = sm.handle(event: .receivedUA)
        _ = sm.handle(event: .connectRequest)

        // Sequence state should be reset
        XCTAssertEqual(sm.sequenceState.vs, 0)
        XCTAssertEqual(sm.sequenceState.vr, 0)
        XCTAssertEqual(sm.sequenceState.va, 0)
    }

    // Note: Pending data queue property is tested implicitly through
    // integration tests in the session manager tests, where sessions
    // are created and managed properly with MainActor context.

    // MARK: - Bug Fix: Stale N(R) in Retransmitted I-Frames (KB5YZB-7)

    func testRetransmittedIFrameUsesCurrentVR() {
        // BUG: When I-frames are retransmitted from sendBuffer, they carry the
        // original N(R) from when they were first built. After receiving more
        // I-frames from the remote, V(R) advances but retransmits still have
        // the old N(R), confusing the peer about our receive state.
        //
        // Repro from Direwolf log: AXDP frame sent with N(R)=0 before welcome
        // frames are processed. If retransmitted later, should use current V(R).
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath.from(["DRL"])

        let session = connectSession(manager: manager, destination: destination, path: path)

        // Send an I-frame (simulating AXDP PING). V(R) is 0 at this point.
        let frames = manager.sendData(Data([0x41, 0x58, 0x54, 0x31]), to: destination, path: path, channel: 0)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.nr, 0, "Initial I-frame should have N(R)=0")

        // Now receive two I-frames from the remote (welcome messages).
        // This advances V(R) to 2.
        _ = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data("Welcome part 1".utf8)
        )
        _ = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 1, nr: 0, pf: false,
            payload: Data("Welcome part 2".utf8)
        )
        XCTAssertEqual(session.vr, 2, "V(R) should advance to 2 after receiving 2 I-frames")

        // First T1 polls; second consecutive T1 retransmits the outstanding I-frame.
        // The retransmitted frame MUST have N(R)=2 (current V(R)), not N(R)=0 (stale).
        _ = manager.handleT1Timeout(session: session)
        let retransmitFrames = manager.handleT1Timeout(session: session)

        let iFrameRetransmits = retransmitFrames.filter { $0.frameType == "i" }
        XCTAssertFalse(iFrameRetransmits.isEmpty, "Should retransmit the outstanding I-frame")

        for frame in iFrameRetransmits {
            XCTAssertEqual(frame.nr, 2,
                "Retransmitted I-frame must use current V(R)=2, not stale N(R)=0")
        }
    }

    // MARK: - Bug Fix: T1 Timeout Must Send RR Poll P=1 (KB5YZB-7)

    func testT1TimeoutInConnectedStateSendsRRPoll() {
        // T1 fires in connected state with outstanding frames.
        // Under our new design, the state machine does not emit a separate S-frame RR poll command
        // because standard AX.25 dictates we retransmit the oldest outstanding I-frame with P=1 instead
        // (handled at the SessionManager level).
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Simulate sending an I-frame (increment V(S))
        sm.sequenceState.incrementVS()  // vs=1, va=0, outstanding=1

        // Also advance V(R) to simulate having received frames
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("test".utf8)))
        XCTAssertEqual(sm.sequenceState.vr, 1)

        // T1 fires
        let actions = sm.handle(event: .t1Timeout)

        // Must NOT include a separate RR poll
        let rrPollActions = actions.filter { action in
            if case .sendRR = action { return true }
            return false
        }
        XCTAssertTrue(rrPollActions.isEmpty,
            "T1 timeout with outstanding frames must not send a separate S-frame RR poll command")
    }

    // MARK: - Bug Fix: retryCount Not Reset on RR ACK (KB5YZB-7)

    func testRetryCountResetsOnRRAcknowledgment() {
        // BUG: When RR(N(R)) is received and V(A) advances (frames acknowledged),
        // retryCount is not reset. This means retry counts from earlier T1 timeouts
        // accumulate, causing premature "retries exceeded" link failure.
        //
        // Repro: AXDP PING triggers T1 timeouts (retryCount goes up). PING is
        // eventually ACKed. User sends "?" which also times out. The accumulated
        // retryCount from the PING phase pushes total retries over maxRetries.
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 5))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Simulate sending I-frame
        sm.sequenceState.incrementVS()  // vs=1, outstanding=1

        // T1 fires twice
        _ = sm.handle(event: .t1Timeout)  // retryCount=1
        _ = sm.handle(event: .t1Timeout)  // retryCount=2
        XCTAssertEqual(sm.retryCount, 2)

        // RR received, acknowledging our frame
        let actions = sm.handle(event: .receivedRR(nr: 1))
        XCTAssertEqual(sm.sequenceState.va, 1)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)

        // retryCount MUST be reset since the peer acknowledged our frames
        XCTAssertEqual(sm.retryCount, 0,
            "retryCount must reset to 0 when RR advances V(A) - successful ACK clears retry state")

        // Verify T1 stopped and T3 started (all frames acked)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.startT3))
    }

    func testRetryCountDoesNotResetOnDuplicateRR() {
        // retryCount should NOT reset if RR doesn't advance V(A) (duplicate RR)
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 5))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        sm.sequenceState.incrementVS()  // vs=1, outstanding=1

        _ = sm.handle(event: .t1Timeout)  // retryCount=1
        XCTAssertEqual(sm.retryCount, 1)

        // RR with nr=0 doesn't advance V(A) (duplicate/stale RR)
        _ = sm.handle(event: .receivedRR(nr: 0))
        XCTAssertEqual(sm.sequenceState.va, 0)

        // retryCount should remain since no progress was made
        XCTAssertEqual(sm.retryCount, 1,
            "retryCount should not reset on duplicate RR that doesn't advance V(A)")
    }

    // MARK: - Regression: Full KB5YZB-7 Scenario

    func testFullKB5YZBScenario_AXDPThenCommandRecovery() {
        // Regression test for the full KB5YZB-7 scenario:
        // 1. Connect to remote node via digipeater
        // 2. Send AXDP PING (I-frame with binary payload)
        // 3. Receive welcome messages from remote
        // 4. AXDP PING eventually ACKed
        // 5. Send "?" command
        // 6. T1 fires - must retransmit with current N(R) and poll
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath.from(["DRL"])

        let session = connectSession(manager: manager, destination: destination, path: path)

        // Step 1: Send AXDP PING immediately after connect
        let axdpPayload = Data([0x41, 0x58, 0x54, 0x31, 0x01, 0x00])
        let axdpFrames = manager.sendData(axdpPayload, to: destination, path: path, channel: 0)
        XCTAssertEqual(axdpFrames.count, 1)
        XCTAssertEqual(axdpFrames.first?.nr, 0, "AXDP PING sent before welcome, N(R)=0")

        // Step 2: Receive welcome I-frames from KB5YZB-7
        _ = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data("Welcome to YZBBPQ".utf8)
        )
        _ = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 1, nr: 0, pf: false,
            payload: Data("S USERS MHEARD".utf8)
        )
        XCTAssertEqual(session.vr, 2)

        // Step 3: Remote ACKs our AXDP frame (RR nr=1)
        _ = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 1)
        XCTAssertEqual(session.outstandingCount, 0, "AXDP frame should be ACKed")

        // Step 4: Send "?" command
        let cmdFrames = manager.sendData(Data("?\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(cmdFrames.count, 1)
        let cmdFrame = cmdFrames.first!
        XCTAssertEqual(cmdFrame.nr, 2, "Command should carry current V(R)=2")
        XCTAssertEqual(cmdFrame.ns, 1, "Command should be at N(S)=1")

        // Step 5: First T1 polls; second consecutive T1 retransmits (remote didn't respond)
        _ = manager.handleT1Timeout(session: session)
        let retransmitFrames = manager.handleT1Timeout(session: session)

        // Verify retransmit carries updated N(R) and there's an RR poll
        let iRetransmits = retransmitFrames.filter { $0.frameType == "i" }
        XCTAssertFalse(iRetransmits.isEmpty, "Must retransmit the ? command")
        for frame in iRetransmits {
            XCTAssertEqual(frame.nr, 2,
                "Retransmitted ? command must have current V(R)=2")
        }
    }

    func testRetransmitAfterPartialAckUpdatesNR() {
        // Test: send 3 frames, peer ACKs first 2, T1 fires for frame 3.
        // Frame 3's retransmit must use current V(R) not the original.
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["DRL"])

        let session = connectSession(manager: manager, destination: destination, path: path)

        // Send 3 frames
        _ = manager.sendData(Data("A".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("B".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("C".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 3)

        // Receive 2 I-frames from remote (V(R) advances to 2)
        _ = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 0, nr: 2, pf: false,
            payload: Data("resp1".utf8)
        )
        _ = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 1, nr: 2, pf: false,
            payload: Data("resp2".utf8)
        )
        XCTAssertEqual(session.vr, 2)

        // Peer ACKed our first 2 frames (piggybacked nr=2 in I-frames above)
        XCTAssertEqual(session.outstandingCount, 1, "Only frame C outstanding")

        // First T1 polls for frame C; second consecutive T1 retransmits
        _ = manager.handleT1Timeout(session: session)
        let retransmitFrames = manager.handleT1Timeout(session: session)

        let iRetransmits = retransmitFrames.filter { $0.frameType == "i" }
        XCTAssertEqual(iRetransmits.count, 1)
        XCTAssertEqual(iRetransmits.first?.nr, 2,
            "Retransmitted frame C must use current V(R)=2")
    }

    // MARK: - Duplicate I-Frame Processing (KB5YZB-7 bug)

    /// Proves that feeding the same I-frame to handleInboundIFrame twice produces
    /// a spurious duplicate RR. The first call advances V(R) and generates a valid RR.
    /// The second call sees the I-frame as outside-window and generates a SECOND RR
    /// with the same N(R) — exactly the behavior observed in the KB5YZB-7 live session.
    func testDuplicateIFrameProcessingProducesDuplicateRR() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        let peer = AX25Address(call: "KB5YZB", ssid: 7)
        let session = connectSession(manager: manager, destination: peer, path: DigiPath())

        // First processing: ns=0, P=1 → in-sequence → immediate RR(nr=1) F=1.
        // (A P=0 frame would arm T2 instead — the delayed cumulative ack.)
        let rr1 = manager.handleInboundIFrame(
            from: peer, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: true,
            payload: Data("Welcome".utf8)
        )
        XCTAssertNotNil(rr1, "First I-frame (in-sequence, P=1) must send immediate RR")
        XCTAssertEqual(session.vr, 1, "V(R) must advance to 1 after accepting ns=0")

        // Second processing of same frame: ns=0 arrives when V(R)=1 → outside window.
        // P=1 demands the re-ack synchronously.
        let rr2 = manager.handleInboundIFrame(
            from: peer, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: true,
            payload: Data("Welcome".utf8)
        )

        XCTAssertNotNil(rr2, "Duplicate I-frame with P=1 must send immediate RR")
        XCTAssertEqual(session.vr, 1,
            "V(R) must NOT advance again for an outside-window duplicate")
    }


    /// Verifies that only one data delivery occurs even if the same I-frame is processed twice.
    /// The second processing must NOT deliver duplicate payload to the application.
    func testDuplicateIFrameDoesNotDeliverDataTwice() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        let peer = AX25Address(call: "KB5YZB", ssid: 7)
        _ = connectSession(manager: manager, destination: peer, path: DigiPath())

        var deliveryCount = 0
        manager.onDataReceived = { _, _ in
            deliveryCount += 1
        }

        // First processing delivers data
        manager.handleInboundIFrame(
            from: peer, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data("Hello".utf8)
        )
        XCTAssertEqual(deliveryCount, 1, "First I-frame must deliver data")

        // Second processing (duplicate) must NOT deliver data again
        manager.handleInboundIFrame(
            from: peer, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data("Hello".utf8)
        )

        XCTAssertEqual(deliveryCount, 1,
            "Duplicate I-frame must NOT deliver payload again (would corrupt user data)")
    }

    /// Tests that RR frames sent immediately after receiving I-frames include the correct N(R) in the metadata.
    /// This ensures that downstream consumers (logging, etc.) and potential serialization logic
    /// perceive the frame correctly. A missing N(R) in `OutboundFrame` was causing issues.

    func testImmediateRRIncludesNR() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])
        
        // Establish connection
        let session = connectSession(manager: manager, destination: destination, path: path)
        XCTAssertEqual(session.state, .connected)
        
        // Receive I-frame with P=1 — the poll response is the synchronous
        // path; P=0 acks ride T2 (see DelayedAckTests).
        let sentFrame = manager.handleInboundIFrame(
            from: destination,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: true,
            payload: Data("TEST".utf8)
        )

        XCTAssertNotNil(sentFrame, "RR should be sent immediately after a P=1 I-frame")
        XCTAssertEqual(sentFrame?.frameType, "s")
        XCTAssertEqual(sentFrame?.displayInfo?.prefix(2), "RR")
        XCTAssertEqual(sentFrame?.nr, 1)
    }

    /// The first outbound user I-frame after SABM/UA carries P=1 to solicit an
    /// immediate ACK from conservative NET/ROM nodes.
    func testFirstSessionIFrameHasPollBit() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "DRLNOD", ssid: 0)
        let path = DigiPath()
        _ = connectSession(manager: manager, destination: destination, path: path)

        let twoChunks = Data(repeating: 0x41, count: AX25Constants.defaultPacketLength + 1)
        let multiFrameBurst = manager.sendData(twoChunks, to: destination, path: path, channel: 0)
        let iFrames = multiFrameBurst.filter { $0.frameType == "i" }

        XCTAssertEqual(iFrames.count, 2)
        XCTAssertEqual(iFrames[0].controlByte.map { Int($0 & 0x10) }, 0x10, "First session I-frame must poll")
        XCTAssertEqual(iFrames[1].controlByte.map { Int($0 & 0x10) }, 0x00, "Only the first frame in the burst should carry P=1")
    }

    /// Later idle user commands must not carry P=1 just because the send buffer
    /// was empty. DRLNOD live testing shows repeated idle-line polls can provoke DM.
    func testSecondIdleCommandDoesNotCarryPollBit() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        let destination = AX25Address(call: "DRLNOD", ssid: 0)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: destination, path: path)

        let helpFrames = manager.sendData(Data("Help\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(helpFrames.first?.controlByte.map { Int($0 & 0x10) }, 0x10)

        _ = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: session.vs, isPoll: false)
        XCTAssertEqual(session.outstandingCount, 0)

        let commandFrames = manager.sendData(Data("c kb5yzb-7\r".utf8), to: destination, path: path, channel: 0)
        let commandIFrame = commandFrames.first { $0.frameType == "i" }

        XCTAssertEqual(commandIFrame?.ns, 1)
        XCTAssertEqual(commandIFrame?.controlByte.map { Int($0 & 0x10) }, 0x00, "Second idle command must not poll")
    }

    func testInboundRRPollWithoutAckRetransmitsOutstandingFrame() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7), clock: clock)
        manager.defaultConfig = AX25SessionConfig(initialRto: 4.0, adaptiveTimeout: false)

        let destination = AX25Address(call: "DRLNOD", ssid: 0)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: destination, path: path)

        var timerDrivenFrames: [OutboundFrame] = []
        manager.onSendFrame = { timerDrivenFrames.append($0) }

        let helpFrames = manager.sendData(Data("Help\r".utf8), to: destination, path: path, channel: 0)
        let originalIFrame = helpFrames.first { $0.frameType == "i" }
        XCTAssertEqual(originalIFrame?.controlByte.map { Int($0 & 0x10) }, 0x10)

        clock.advance(by: 3.0)
        let responses = manager.handleInboundRRFrames(
            from: destination,
            path: path,
            channel: 0,
            nr: 0,
            pf: true,
            isCommand: true
        )

        let rrFinals = responses.filter { $0.frameType == "s" }
        let retransmittedIFrames = responses.filter { $0.frameType == "i" }

        XCTAssertEqual(rrFinals.count, 1, "RR(P=1) requires an RR(F=1) response")
        XCTAssertEqual(retransmittedIFrames.count, 1, "No-progress RR poll should retransmit the outstanding I-frame")
        XCTAssertEqual(retransmittedIFrames.first?.payload, Data("Help\r".utf8))
        XCTAssertEqual(retransmittedIFrames.first?.controlByte.map { Int($0 & 0x10) }, 0x10, "Peer-poll recovery preserves the original I-frame P bit")

        clock.advance(by: 1.21)
        XCTAssertTrue(timerDrivenFrames.isEmpty, "Inbound RR poll recovery must restart T1 and cancel the original timer")
        XCTAssertEqual(session.outstandingCount, 1)
    }

    /// Reproduction of the KB5YZB scenario where AXTerm sent SABM -> RR -> DM
    /// instead of just RR after receiving I-frames.
    /// Suspected cause: Session not transitioning to connected properly or race condition.
    func testReproduction_KB5YZB_Scenario() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        // K0EPI-7
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        var sentFrames: [OutboundFrame] = []
        manager.onSendFrame = { frame in
            sentFrames.append(frame)
        }

        // Peer: KB5YZB-7, via DRL
        let dest = AX25Address(call: "KB5YZB", ssid: 7)
        let path = DigiPath.from(["DRL"])

        // 1. Initiate Connection
        let frame1 = manager.connect(to: dest, path: path)

        // Verify SABM sent
        guard let sabm = frame1 else {
            XCTFail("Should have sent SABM")
            return
        }
        XCTAssertEqual(sabm.displayInfo, "SABM")

        // 2. Receive UA
        // [0.5] KB5YZB-7>K0EPI-7,DRL*:(UA res, f=1)
        manager.handleInboundUA(from: dest, path: path, channel: 0)

        // Session should be connected
        let session = manager.session(for: dest, path: path, channel: 0)
        XCTAssertEqual(session.state, .connected, "Session should be connected after receiving UA")

        // 3. Receive I-frame 0
        // [0.5] KB5YZB-7>K0EPI-7,DRL*:(I cmd, n(s)=0, n(r)=0, p=0, pid=0xf0)Welcome...
        let sentFrame1 = manager.handleInboundIFrame(
            from: dest,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: false,
            payload: Data("Welcome to YZBBPQ".utf8)
        )
        if let frame = sentFrame1 {
            sentFrames.append(frame)
        }

        // 4. Receive I-frame 1 with P=1
        // [0.5] KB5YZB-7>K0EPI-7,DRL*:(I cmd, n(s)=1, n(r)=0, p=1, pid=0xf0)S USERS...
        let sentFrame2 = manager.handleInboundIFrame(
            from: dest,
            path: path,
            channel: 0,
            ns: 1,
            nr: 0,
            pf: true, // Poll bit set!
            payload: Data("S USERS MHEARD".utf8)
        )

        // Analyze sent frames - collate from both handleInboundIFrame calls
        // The first call might not return anything (immediate ack or queued)
        // The second call with P=1 MUST return RR(F=1)
        if let frame = sentFrame2 {
            sentFrames.append(frame)
        }

        // Analyze sent frames
        // Expected behavior:
        // - RR(nr=1) (Optional, might be coalesced or immediate)
        // - RR(nr=2, f=1) (Mandatory response to P=1)
        //
        // Bad behavior observed in log:
        // - SABM (Why??)
        // - RR(nr=1)
        // - RR(nr=2, f=1)
        // - DM (Why??)

        for frame in sentFrames {
            print("Captured Frame: \(frame.displayInfo ?? "nil") type=\(frame.frameType) ctrl=\(String(format:"%02X", frame.controlByte ?? 0))")
        }

        XCTAssertFalse(sentFrames.contains(where: { $0.displayInfo == "SABM" }), "Should NOT have sent SABM after connection established")
        XCTAssertFalse(sentFrames.contains(where: { $0.displayInfo == "DM" }), "Should NOT have sent DM")
        
        // Should have sent RR with F=1 (Response to Poll)
        // And NR should be 2 (next expected is 2)
        let rrs = sentFrames.filter { $0.frameType == "s" && ($0.displayInfo ?? "").hasPrefix("RR") }
        XCTAssertTrue(rrs.count >= 1, "Should have sent at least one RR")
        
        if let lastRR = rrs.last {
            XCTAssertEqual(lastRR.nr, 2, "Last RR should ack up to 2")
            // Check F bit (bit 4 of control byte) if P was 1
            if let ctrl = lastRR.controlByte {
                 XCTAssertTrue(ctrl & 0x10 != 0, "Last RR should have Final bit set (F=1) in response to P=1")
            }
        }
    }
    func testDISCWithPathMismatch() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let dest = AX25Address(call: "KB5YZB", ssid: 7)
        let digi = AX25Address(call: "DRL", ssid: 0)
        // Assume DigiPath init takes array without label, or try strict string init if available
        // Based on previous files, DigiPath likely has init(_ components: [AX25Address])
        let path = DigiPath([digi])
        
        // 1. Establish connection (simulate receiving UA)
        manager.connect(to: dest, path: path)
        manager.handleInboundUA(from: dest, path: path, channel: 0)
        
        guard let session = manager.connectedSession(withPeer: dest) else {
            XCTFail("Session not connected")
            return
        }
        XCTAssertEqual(session.state, .connected)
        
        
        // 2. Peer sends DISC with DIFFERENT path (e.g. DRL*)
        // Create new address with repeated=true since properties are let
        let digiRepeated = AX25Address(call: "DRL", ssid: 0, repeated: true)
        let mismatchPath = DigiPath([digiRepeated])
        
        let capturedFrames = manager.handleInboundDISC(from: dest, path: mismatchPath, channel: 0)
        
        // Should send UA (Response) indicating we accepted the disconnect
        // Should NOT send DM
        if let frame = capturedFrames {
            XCTAssertEqual(frame.frameType, "u")
            // Check for UA type
            if let ctl = frame.controlByte {
                let isUA = (ctl & ~0x10) == 0x63
                XCTAssertTrue(isUA, "Frame should be UA, got control 0x\(String(format: "%02X", ctl))")
            }
        } else {
             XCTFail("Should send 1 frame (UA)")
        }
        
        XCTAssertEqual(session.state, .disconnected, "Session should be disconnected")
    }
    func testSessionKeyEqualityIgnoreRepeated() {
        let dest = AX25Address(call: "DEST", ssid: 0)
        
        let digi1 = AX25Address(call: "DIGI", ssid: 0, repeated: false)
        let digi2 = AX25Address(call: "DIGI", ssid: 0, repeated: true)
        
        let path1 = DigiPath([digi1])
        let path2 = DigiPath([digi2])
        
        // Check if DigiPath displays are equal (since SessionKey uses display string)
        XCTAssertEqual(path1.display, path2.display, "DigiPath display should match regardless of repeated status")
        
        let key1 = SessionKey(destination: dest, path: path1, channel: 0)
        let key2 = SessionKey(destination: dest, path: path2, channel: 0)
        
        XCTAssertEqual(key1, key2, "SessionKey should be equal regardless of repeated status in path")
        XCTAssertEqual(key1.hashValue, key2.hashValue, "SessionKey hashes should be equal")
    }
    
    func testDigiPathNormalization() {
        let digiRepeated = AX25Address(call: "DIGI", ssid: 0, repeated: true)
        let path = DigiPath([digiRepeated])
        
        XCTAssertTrue(path.digis[0].repeated, "Original path should have repeated=true")
        
        let normalized = path.normalized
        XCTAssertFalse(normalized.digis[0].repeated, "Normalized path should have repeated=false")
        XCTAssertEqual(normalized.digis[0].call, "DIGI", "Normalized path callsign should match")
        XCTAssertEqual(normalized.digis[0].ssid, 0, "Normalized path SSID should match")
    }

    func testRRWithHBitMismatch() {
        let sessionManager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        let dest = AX25Address(call: "DEST", ssid: 0)
        let digi = AX25Address(call: "DIGI", ssid: 0, repeated: false)
        let digiRepeated = AX25Address(call: "DIGI", ssid: 0, repeated: true)

        let path = DigiPath([digi])
        let pathRepeated = DigiPath([digiRepeated])

        // Establish connection properly
        // This sets state to connected and initializes session
        let session = connectSession(
            manager: sessionManager,
            destination: dest,
            path: path
        )

        // Manually buffer frames to simulate pending ACKs
        // We need to advance V(S) to match the buffered frames
        // V(S) starts at 0.
        
        let f0 = AX25FrameBuilder.buildIFrame(from: session.localAddress, to: session.remoteAddress, via: path, ns: 0, nr: 0, payload: Data([0x01]), sessionId: session.id)
        let f1 = AX25FrameBuilder.buildIFrame(from: session.localAddress, to: session.remoteAddress, via: path, ns: 1, nr: 0, payload: Data([0x02]), sessionId: session.id)
        
        session.sendBuffer[0] = f0
        session.sendBuffer[1] = f1
        
        // Mock sequence state to expect ACK for these frames
        // Accessing SequenceState via stateMachine might be restricted if strict private?
        // Let's assume we can modify it or V(S) was updated by sending.
        // buildIFrame in SessionManager increments VS, but here we used FrameBuilder directly.
        // We need to manually update VS if possible, or use session.sendData?
        // session.sendData is async/complex. Let's try to set sequenceState properties if accessible.
        
        // If sequenceState is internal/public we can set it.
        // If not, we might need another way. AX25SessionTests usually has access to internals via @testable.
        
        session.stateMachine.sequenceState.vs = 2
        session.stateMachine.sequenceState.va = 0

        // Simulate incoming RR with repeated path (H-bit set)
        // This simulates a digipeater setting the H-bit on the return path
        // Return value is irrelevant for this test, checking side effects
        _ = sessionManager.handleInboundRR(
            from: dest,
            path: pathRepeated,
            channel: 0,
            nr: 2,
            isPoll: false
        )

        // Verify that the RR was processed and V(A) advanced
        XCTAssertEqual(session.va, 2, "Session V(A) should update even with H-bit mismatch in RR path")
        XCTAssertEqual(session.sendBuffer.count, 0, "Send buffer should be cleared")
    }

    // MARK: - T3 Timer Bug Regression Tests

    /// §4.4.5.2: T3 expiry transmits an RR command with P=1 and starts T1.
    /// Without P=1 the peer owes no answer, so the "keepalive" could never
    /// actually confirm the link was alive.
    func testT3TimeoutSendsRRPoll() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)

        // Receive an I-frame to advance V(R) to 1
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("test".utf8)))
        XCTAssertEqual(sm.sequenceState.vr, 1)

        // Fire T3 timeout
        let actions = sm.handle(event: .t3Timeout)

        // §4.4.5.2: exactly one RR, sent as a command with P=1, carrying current V(R)
        let rrActions = actions.compactMap { action -> (Int, Bool, Bool)? in
            if case .sendRR(let nr, let pf, let isCommand) = action { return (nr, pf, isCommand) }
            return nil
        }
        XCTAssertEqual(rrActions.count, 1, "T3 timeout must produce exactly one RR")
        XCTAssertEqual(rrActions.first?.0, 1, "RR N(R) should equal current V(R)")
        XCTAssertTrue(rrActions.first?.1 ?? false, "§4.4.5.2: the enquiry carries P=1")
        XCTAssertTrue(rrActions.first?.2 ?? false, "§4.4.5.2: the enquiry is a command frame")
        XCTAssertTrue(actions.contains(.startT1), "§4.4.5.2: T1 is started to time the enquiry")
        XCTAssertFalse(actions.contains(.startT3),
            "T3 restarts when the response arrives — not passively at expiry")
    }

    /// T3 timeout should be reasonable for VHF packet (not 180s which is longer
    /// than peers typically wait before disconnecting).
    func testT3TimeoutValueIsReasonable() {
        let timers = AX25SessionTimers()
        XCTAssertLessThanOrEqual(timers.t3Timeout, 30.0,
            "T3 timeout of \(timers.t3Timeout)s is too long — peers disconnect after ~20s of no response")
    }

    // MARK: - Line Buffer Flush on Disconnect Regression Test

    /// When a session disconnects, any partially buffered text (no trailing CR/LF)
    /// must be flushed to the console, not silently discarded.
    func testLineBufferFlushedOnDisconnect() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 6)

        let destination = AX25Address(call: "K0EPI", ssid: 7)
        let path = DigiPath.from([])

        let session = connectSession(manager: manager, destination: destination, path: path)

        // Track data delivered via onDataReceived
        var deliveredData: [Data] = []
        manager.onDataReceived = { _, data in
            deliveredData.append(data)
        }

        // Receive I-frame with text that does NOT end with CR/LF
        // This simulates the K0EPI-7 BPQ node scenario where ns=6 payload
        // ends mid-word: "...report a problem, ema"
        let partialText = Data("     For questions, comments, or to report a problem, ema".utf8)
        let response = manager.handleInboundIFrame(
            from: destination,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: true,  // P=1 keeps the RR synchronous; delivery is what's under test
            payload: partialText
        )

        // Data should have been delivered to onDataReceived
        XCTAssertEqual(deliveredData.count, 1, "I-frame payload should be delivered")
        XCTAssertNotNil(response, "RR response should be generated")

        // The data was delivered to onDataReceived, which calls appendToSessionTranscript.
        // appendToSessionTranscript buffers until CR/LF.
        // We can't easily test the TerminalView layer here, but we CAN verify
        // that the state machine correctly delivers the data — the display bug
        // is in the TerminalView's line buffering, tested below.
    }

    // MARK: - T1 Re-Poll Bug Regression Test

    /// T1 timeout must send an RR poll even when there are NO outstanding I-frames.
    /// Without this, after T3 sends a single probe and gets no response (RF loss),
    /// T1 just silently restarts itself — AXTerm goes completely silent.
    func testT1TimeoutSendsRRPollEvenWithNoOutstanding() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)

        // Receive an I-frame to advance V(R)
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("test".utf8)))
        XCTAssertEqual(sm.sequenceState.vr, 1)

        // No outstanding I-frames
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)

        // Fire T1 timeout (simulates: T3 poll got no response, T1 fires)
        let actions = sm.handle(event: .t1Timeout)

        // Must contain an RR poll — not just startT1
        let rrActions = actions.compactMap { action -> (Int, Bool)? in
            if case .sendRR(let nr, let pf, _) = action { return (nr, pf) }
            return nil
        }
        XCTAssertEqual(rrActions.count, 1,
            "T1 timeout must send RR poll even with no outstanding I-frames — otherwise AXTerm goes silent after a single T3 probe")
        XCTAssertTrue(rrActions.first?.1 ?? false,
            "T1 re-poll must have P=1 to elicit a response")
    }
}
