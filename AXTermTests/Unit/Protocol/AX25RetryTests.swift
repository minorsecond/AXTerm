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
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
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
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        let destination = AX25Address(call: "N0HI", ssid: 7)
        let path = DigiPath.from(["W0ARP-7"])
        
        let session = connectSession(manager: manager, destination: destination, path: path)
        
        // Peer sends RNR (Receive Not Ready)
        _ = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 0, isPoll: false)
        let actions = session.stateMachine.handle(event: .receivedRNR(nr: 0))
        
        // Although this doesn't block sendData() at the manager level immediately (as it just queues),
        // we check if T1 stops to prevent retransmissions while peer is busy
        
        XCTAssertTrue(actions.contains(.stopT1), "RNR should stop T1 timer to prevent polling busy peer too aggressively")
        
        // NOTE: A more complete test would verify that the manager actually pauses sending queued frames.
        // For now, verified T1 behavior is most critical for "flakiness".
    }

    // Test that correct frames are retransmitted on REJ
    func testREJRetransmissions() {
        let manager = AX25SessionManager()
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
}

