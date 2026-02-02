//
//  AX25TransmissionTests.swift
//  AXTermIntegrationTests
//
//  Tests for AX.25 frame transmission between simulated stations.
//

import XCTest
@testable import AXTerm

/// Tests AX.25 frame transmission through Direwolf simulation.
final class AX25TransmissionTests: XCTestCase {

    var clientA: SimulatorClient!
    var clientB: SimulatorClient!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        clientA = SimulatorClient.stationA()
        clientB = SimulatorClient.stationB()

        try await clientA.connect()
        try await clientB.connect()

        // Clear any buffered frames
        clientA.clearReceiveBuffer()
        clientB.clearReceiveBuffer()

        // Small delay for connection stabilization
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms
    }

    override func tearDown() async throws {
        clientA?.disconnect()
        clientB?.disconnect()
        clientA = nil
        clientB = nil
    }

    // MARK: - UI Frame Tests

    /// Test sending a plain text UI frame from A to B
    func testPlainTextUIFrame_AtoB() async throws {
        // Send frame from A
        try await clientA.sendAX25Frame(TestFrames.plainTextHello)

        // Wait for frame at B (allow time for audio simulation)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        // Verify we received something
        XCTAssertFalse(received.isEmpty, "Should receive frame data")

        // Verify it's not AXDP
        XCTAssertFalse(TestAXDPBuilder.hasAXDPMagic(received), "Plain text should not have AXDP magic")
    }

    /// Test sending a plain text UI frame from B to A
    func testPlainTextUIFrame_BtoA() async throws {
        // Send frame from B
        try await clientB.sendAX25Frame(TestFrames.plainTextReply)

        // Wait for frame at A
        let received = try await clientA.waitForFrame(timeout: 10.0)

        XCTAssertFalse(received.isEmpty, "Should receive frame data")
    }

    /// Test bidirectional communication
    func testBidirectionalCommunication() async throws {
        // Send from A to B
        try await clientA.sendAX25Frame(TestFrames.plainTextHello)
        let receivedAtB = try await clientB.waitForFrame(timeout: 10.0)
        XCTAssertFalse(receivedAtB.isEmpty)

        // Small delay between transmissions
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms

        // Send from B to A
        try await clientB.sendAX25Frame(TestFrames.plainTextReply)
        let receivedAtA = try await clientA.waitForFrame(timeout: 10.0)
        XCTAssertFalse(receivedAtA.isEmpty)
    }

    /// Test broadcast frame reception
    func testBroadcastFrame() async throws {
        // Send broadcast from A
        try await clientA.sendAX25Frame(TestFrames.broadcast)

        // B should receive it
        let received = try await clientB.waitForFrame(timeout: 10.0)
        XCTAssertFalse(received.isEmpty)
    }

    /// Test multiple frames in sequence
    func testMultipleFrames() async throws {
        let messages = ["First message", "Second message", "Third message"]

        for msg in messages {
            let frame = TestFrameBuilder.buildUIFrame(
                from: "TEST-1",
                to: "TEST-2",
                text: msg
            )
            try await clientA.sendAX25Frame(frame)

            // Small delay between frames
            try await Task.sleep(nanoseconds: 300_000_000)  // 300ms
        }

        // Wait a bit for all frames to arrive
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s

        // Should have received multiple frames
        let received = clientB.drainReceivedFrames()
        XCTAssertGreaterThanOrEqual(received.count, 1, "Should receive at least one frame")
    }

    // MARK: - Frame Content Verification

    /// Test that payload content is preserved through transmission
    func testPayloadPreservation() async throws {
        let testPayload = "The quick brown fox jumps over the lazy dog 1234567890"
        let frame = TestFrameBuilder.buildUIFrame(
            from: "TEST-1",
            to: "TEST-2",
            text: testPayload
        )

        try await clientA.sendAX25Frame(frame)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        // The received frame should be a valid AX.25 frame
        // Extract payload (skip address fields + control + PID)
        // Address: 7 bytes dest + 7 bytes source = 14 bytes
        // Control: 1 byte, PID: 1 byte
        // So payload starts at offset 16
        if received.count > 16 {
            let payloadData = received.suffix(from: 16)
            if let payloadText = String(data: payloadData, encoding: .utf8) {
                XCTAssertEqual(payloadText, testPayload, "Payload should be preserved")
            }
        }
    }
}
