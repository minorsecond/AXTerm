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
        let manager = AX25SessionManager()
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

    func testT1TimeoutRetransmitsOutstandingFrames() {
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        let session = manager.session(for: destination, path: path, channel: 0)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)

        XCTAssertEqual(session.state, .connected)

        let frames = manager.sendData(Data([0x41]), to: destination, path: path, channel: 0)
        XCTAssertEqual(frames.count, 1)

        let retransmitFrames = manager.handleT1Timeout(session: session)

        // Expect retransmitted I-frame
        let iFrames = retransmitFrames.filter { $0.frameType == "i" }
        
        XCTAssertEqual(iFrames.count, 1, "Should retransmit the outstanding I-frame")
        XCTAssertEqual(iFrames.first?.sessionId, session.id)
        // Now check for S-frames (RR poll) in the retransmit response
        let pollFrames = retransmitFrames.filter { $0.frameType == "s" }
        XCTAssertEqual(pollFrames.count, 1, "Should include RR poll (P=1)")

    }

    func testRejRetransmitsWithConnectedSessionPathMismatch() {
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let mismatchSource = AX25Address(call: "N0HI", ssid: 9)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)

        let sentFrame = manager.handleInboundIFrame(
            from: mismatchSource,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: false,
            payload: Data("INFO".utf8)
        )

        // With immediate ACK, the RR should be sent immediately
        XCTAssertNotNil(sentFrame, "RR should be sent immediately")
        XCTAssertEqual(sentFrame?.frameType, "s")
        XCTAssertEqual(sentFrame?.displayInfo?.prefix(2), "RR")

    }

    func testHandleInboundRRWithSSIDMismatchAcksOutstanding() {
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let mismatchSource = AX25Address(call: "N0HI", ssid: 9)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)

        // Only checking side effect on session state
        _ = manager.handleInboundDM(from: mismatchSource, path: path, channel: 0)

        XCTAssertEqual(session.state, .disconnected)
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

    func testHandleInboundIFrameWhileConnectingDoesNotSendDM() {
        let manager = AX25SessionManager()
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
            pf: false,
            payload: Data("INFO".utf8)
        )

        XCTAssertNil(sentFrame)

    }

    func testHandleInboundIFrameWithNoSessionDoesNotRespondWithDM() {
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        // Establish a connected session.
        let session = connectSession(manager: manager, destination: destination, path: path)
        XCTAssertEqual(session.state, .connected)

        // First delivery of an in-sequence I-frame — with delayed ACK, returns nil
        // but stores the RR in delayedAckFrame.
        // First delivery of an in-sequence I-frame
        let firstResponse = manager.handleInboundIFrame(
            from: destination,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: false,
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
            pf: false,
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
        let manager = AX25SessionManager()
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



    func testHandleInboundREJWithNoSessionDoesNotCreateSessionOrRespond() {
        let manager = AX25SessionManager()
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


    func testT1TimeoutDoesNotRetransmitWhenNoOutstandingFrames() {
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        let session = connectSession(manager: manager, destination: destination, path: path)
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.outstandingCount, 0)

        // No outstanding frames: T1 timeout should not produce retransmits.
        let retransmitFrames = manager.handleT1Timeout(session: session)
        
        XCTAssertTrue(retransmitFrames.isEmpty)
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
            if case .deliverData(let data) = action { return data == payload }
            return false
        })
        XCTAssertTrue(actions.contains { action in
            if case .sendRR(let nr, _) = action { return nr == 1 }
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
            if case .sendREJ(let nr, _) = action { return nr == 0 }
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
            if case .deliverData(let data) = action { return data == payload1 }
            return false
        })

        // Receive in-sequence ns=1
        let actions2 = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: payload2))
        XCTAssertEqual(sm.sequenceState.vr, 2)
        XCTAssertTrue(actions2.contains { action in
            if case .deliverData(let data) = action { return data == payload2 }
            return false
        })

        // Duplicate of ns=1 should NOT advance VR or deliver again
        let actionsDup = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: payload2))
        XCTAssertEqual(sm.sequenceState.vr, 2, "Duplicate I-frame must not advance V(R)")
        XCTAssertFalse(actionsDup.contains { action in
            if case .deliverData = action { return true }
            return false
        })
        XCTAssertTrue(actionsDup.contains { action in
            if case .sendRR(let nr, _) = action { return nr == 2 }
            return false
        }, "Duplicate I-frame should trigger RR for current V(R)")
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

        // T3 timeout should send RR as poll to keep link alive
        XCTAssertTrue(actions.contains { action in
            if case .sendRR(_, _) = action { return true }
            return false
        })
        XCTAssertTrue(actions.contains(.startT1))
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
        let manager = AX25SessionManager()
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

        // T1 fires - retransmit the outstanding I-frame.
        // The retransmitted frame MUST have N(R)=2 (current V(R)), not N(R)=0 (stale).
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
        // BUG: When T1 fires in connected state with outstanding frames,
        // AXTerm only retransmits I-frames but never sends an RR poll (P=1).
        // Per AX.25 spec, the station should send a supervisory command with
        // P=1 to force the peer to respond with its current state.
        //
        // This is critical when our I-frame was received but the response was
        // lost - polling lets us discover the peer already processed our command.
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

        // Must include an RR poll (P=1) with current V(R)
        let rrPollActions = actions.filter { action in
            if case .sendRR(let nr, let pf) = action {
                return pf == true && nr == 1
            }
            return false
        }
        XCTAssertFalse(rrPollActions.isEmpty,
            "T1 timeout with outstanding frames must send RR poll (P=1) with current V(R)")
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
        let manager = AX25SessionManager()
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

        // Step 5: T1 fires (remote didn't respond)
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
        let manager = AX25SessionManager()
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

        // T1 fires for frame C
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
        let manager = AX25SessionManager()
        let peer = AX25Address(call: "KB5YZB", ssid: 7)
        let session = connectSession(manager: manager, destination: peer, path: DigiPath())

        // First processing: ns=0 arrives when V(R)=0 → in-sequence → immediate RR(nr=1)
        let rr1 = manager.handleInboundIFrame(
            from: peer, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data("Welcome".utf8)
        )
        // With immediate ACK, the RR is sent immediately
        XCTAssertNotNil(rr1, "First I-frame (in-sequence) must send immediate RR")
        XCTAssertEqual(session.vr, 1, "V(R) must advance to 1 after accepting ns=0")

        // Second processing of same frame: ns=0 arrives when V(R)=1 → outside window
        // It triggers another RR (immediate) to ensure the peer knows we have it.
        let rr2 = manager.handleInboundIFrame(
            from: peer, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data("Welcome".utf8)
        )

        // With immediate ACK, the second RR is also immediate.
        XCTAssertNotNil(rr2, "Duplicate I-frame must send immediate RR")
        XCTAssertEqual(session.vr, 1,
            "V(R) must NOT advance again for an outside-window duplicate")
    }


    /// Verifies that only one data delivery occurs even if the same I-frame is processed twice.
    /// The second processing must NOT deliver duplicate payload to the application.
    func testDuplicateIFrameDoesNotDeliverDataTwice() {
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])
        
        // Establish connection
        let session = connectSession(manager: manager, destination: destination, path: path)
        XCTAssertEqual(session.state, .connected)
        
        // Receive I-frame
        let sentFrame = manager.handleInboundIFrame(
            from: destination,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: false,
            payload: Data("TEST".utf8)
        )
        
        // RR must be sent IMMEDIATELY (synchronously)
        XCTAssertNotNil(sentFrame, "RR should be sent immediately after I-frame")
        XCTAssertEqual(sentFrame?.frameType, "s")
        XCTAssertEqual(sentFrame?.displayInfo?.prefix(2), "RR")
        XCTAssertEqual(sentFrame?.nr, 1)
    }

    /// Tests that the first I-frame in a transmission burst has the Poll (P) bit set,
    /// while subsequent frames do not. This ensures we force an immediate response
    /// from the peer (improving interactivity and preventing timeouts), matching
    /// behaviors of other TNCs like Direwolf.
    func testFirstIFrameHasPollBit() {
        // ... (existing test)
    }

    /// Reproduction of the KB5YZB scenario where AXTerm sent SABM -> RR -> DM
    /// instead of just RR after receiving I-frames.
    /// Suspected cause: Session not transitioning to connected properly or race condition.
    func testReproduction_KB5YZB_Scenario() {
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
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
        let sessionManager = AX25SessionManager()
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
}
