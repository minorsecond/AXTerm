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
        XCTAssertEqual(retransmitFrames.count, 1)
        XCTAssertEqual(retransmitFrames.first?.sessionId, session.id)
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

        manager.handleInboundUA(from: uaSource, path: path, channel: 0)

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.remoteAddress.display, destination.display)
    }

    func testHandleInboundIFrameWithSSIDMismatchReturnsRR() {
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let mismatchSource = AX25Address(call: "N0HI", ssid: 9)
        let path = DigiPath.from(["W0ARP-7"])

        _ = connectSession(manager: manager, destination: destination, path: path)

        let rrFrame = manager.handleInboundIFrame(
            from: mismatchSource,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: false,
            payload: Data("INFO".utf8)
        )

        XCTAssertNotNil(rrFrame)
        XCTAssertEqual(rrFrame?.frameType, "s")
        XCTAssertEqual(rrFrame?.displayInfo?.prefix(2), "RR")
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

        manager.handleInboundDM(from: mismatchSource, path: path, channel: 0)

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

        let response = manager.handleInboundIFrame(
            from: destination,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: false,
            payload: Data("INFO".utf8)
        )

        XCTAssertNil(response)
    }

    func testHandleInboundIFrameWithNoSessionDoesNotRespondWithDM() {
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let source = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        // No sessions created at all. An unexpected I-frame should be safely ignored
        // and MUST NOT trigger a DM, to avoid tearing down a valid remote link.
        let response = manager.handleInboundIFrame(
            from: source,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: false,
            payload: Data("INFO".utf8)
        )

        XCTAssertNil(response, "Unexpected inbound I-frame with no session should be ignored, not answered with DM")
    }

    func testHandleInboundIFrameDuplicateForExistingSessionIsAcknowledgedNotDM() {
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        // Establish a connected session.
        let session = connectSession(manager: manager, destination: destination, path: path)
        XCTAssertEqual(session.state, .connected)

        // First delivery of an in-sequence I-frame should yield an RR.
        let firstResponse = manager.handleInboundIFrame(
            from: destination,
            path: path,
            channel: 0,
            ns: 0,
            nr: 0,
            pf: false,
            payload: Data("WELCOME".utf8)
        )
        XCTAssertNotNil(firstResponse)
        XCTAssertEqual(firstResponse?.frameType, "s")  // RR

        // A duplicate decode of the same frame with a slightly different path
        // (e.g. without the repeated marker) must NOT cause a DM; at worst it
        // is ignored or results in another RR.
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

        // We only care that we did not generate a DM here; in our current
        // implementation this will be nil (ignored) due to matching the
        // existing connected session earlier.
        if let frame = duplicateResponse {
            XCTAssertNotEqual(frame.frameType, "u", "Duplicate I-frame must not generate a DM U-frame")
        }
    }

    // MARK: - Robustness & Safety Invariants

    func testHandleInboundRRWithNoSessionDoesNotCreateSessionOrRespond() {
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)

        let source = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])

        let response = manager.handleInboundRR(
            from: source,
            path: path,
            channel: 0,
            nr: 1,
            isPoll: false
        )

        XCTAssertNil(response, "RR with no existing session should be ignored")
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
        let frames = manager.handleT1Timeout(session: session)
        XCTAssertTrue(frames.isEmpty)
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
}
