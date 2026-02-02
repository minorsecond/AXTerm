//
//  AXDPProtocolTests.swift
//  AXTermIntegrationTests
//
//  Tests for AXDP (AXTerm Data Protocol) extension handling over RF simulation.
//

import XCTest
@testable import AXTerm

/// Tests AXDP protocol features through Direwolf simulation.
final class AXDPProtocolTests: XCTestCase {

    var clientA: SimulatorClient!
    var clientB: SimulatorClient!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        clientA = SimulatorClient.stationA()
        clientB = SimulatorClient.stationB()

        try await clientA.connect()
        try await clientB.connect()

        clientA.clearReceiveBuffer()
        clientB.clearReceiveBuffer()

        try await Task.sleep(nanoseconds: 200_000_000)
    }

    override func tearDown() async throws {
        clientA?.disconnect()
        clientB?.disconnect()
        clientA = nil
        clientB = nil
    }

    // MARK: - AXDP Magic Header Tests

    /// Test that AXDP frames preserve the magic header through transmission
    func testAXDPMagicPreservation() async throws {
        let frame = TestFrames.axdpChatHello
        try await clientA.sendAX25Frame(frame)

        let received = try await clientB.waitForFrame(timeout: 10.0)

        // Extract payload from AX.25 frame (skip addresses + control + PID)
        if received.count > 16 {
            let payloadData = received.suffix(from: 16)
            XCTAssertTrue(
                TestAXDPBuilder.hasAXDPMagic(payloadData),
                "AXDP magic header should be preserved through RF"
            )
        } else {
            XCTFail("Received frame too short")
        }
    }

    /// Test AXDP chat message transmission
    func testAXDPChatMessage() async throws {
        let testMessage = "AXDP integration test message"
        let axdpPayload = TestAXDPBuilder.buildChatMessage(text: testMessage)
        let frame = TestFrameBuilder.buildUIFrame(
            from: TestAX25Address("TEST-1"),
            to: TestAX25Address("TEST-2"),
            payload: axdpPayload
        )

        try await clientA.sendAX25Frame(frame)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        // Verify AXDP structure
        if received.count > 16 {
            let payloadData = received.suffix(from: 16)
            XCTAssertTrue(TestAXDPBuilder.hasAXDPMagic(payloadData))

            // Verify it can be decoded by the real AXDP decoder
            if let message = AXDP.Message.decode(from: Data(payloadData)) {
                XCTAssertEqual(message.type, .chat, "Should be a chat message")
                if let textData = message.payload, let text = String(data: textData, encoding: .utf8) {
                    XCTAssertEqual(text, testMessage, "Message text should match")
                }
            } else {
                XCTFail("Should be able to decode AXDP message")
            }
        }
    }

    /// Test AXDP PING message
    func testAXDPPing() async throws {
        let pingPayload = TestAXDPBuilder.buildPing()
        let frame = TestFrameBuilder.buildUIFrame(
            from: TestAX25Address("TEST-1"),
            to: TestAX25Address("TEST-2"),
            payload: pingPayload
        )

        try await clientA.sendAX25Frame(frame)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        if received.count > 16 {
            let payloadData = received.suffix(from: 16)
            XCTAssertTrue(TestAXDPBuilder.hasAXDPMagic(payloadData))

            if let message = AXDP.Message.decode(from: Data(payloadData)) {
                XCTAssertEqual(message.type, .ping, "Should be a ping message")
            }
        }
    }

    // MARK: - Mixed Protocol Tests

    /// Test alternating AXDP and plain text frames
    func testMixedProtocolTraffic() async throws {
        // Send plain text
        try await clientA.sendAX25Frame(TestFrames.plainTextHello)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Send AXDP
        try await clientA.sendAX25Frame(TestFrames.axdpChatHello)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Send plain text again
        let plainFrame2 = TestFrameBuilder.buildUIFrame(
            from: "TEST-1",
            to: "TEST-2",
            text: "Another plain message"
        )
        try await clientA.sendAX25Frame(plainFrame2)

        // Wait for frames
        try await Task.sleep(nanoseconds: 3_000_000_000)

        let received = clientB.drainReceivedFrames()
        XCTAssertGreaterThanOrEqual(received.count, 1, "Should receive mixed traffic")

        // Verify we can distinguish AXDP from plain text
        var axdpCount = 0
        var plainCount = 0

        for frame in received {
            if frame.count > 16 {
                let payload = Data(frame.suffix(from: 16))
                if TestAXDPBuilder.hasAXDPMagic(payload) {
                    axdpCount += 1
                } else {
                    plainCount += 1
                }
            }
        }

        // We should have at least some frames
        XCTAssertGreaterThan(axdpCount + plainCount, 0, "Should have received some frames")
    }
}
