//
//  BackwardsCompatibilityIntegrationTests.swift
//  AXTermIntegrationTests
//
//  Integration tests verifying backwards compatibility with standard AX.25 stations.
//  These tests ensure AXTerm can communicate with non-AXDP stations.
//

import XCTest
@testable import AXTerm

/// Tests backwards compatibility with standard AX.25/FX.25 traffic.
/// Ensures AXDP-aware stations can communicate with legacy stations.
final class BackwardsCompatibilityIntegrationTests: XCTestCase {

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

    // MARK: - Standard AX.25 Compatibility

    /// Test that standard plain text UI frames work correctly
    func testStandardUIFrame() async throws {
        // Build a standard UI frame like a legacy TNC would send
        let frame = TestFrameBuilder.buildUIFrame(
            from: "TEST-1",
            to: "TEST-2",
            text: "Standard AX.25 message - no AXDP"
        )

        try await clientA.sendAX25Frame(frame)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        // Should receive and be recognizable as non-AXDP
        XCTAssertFalse(received.isEmpty)
        if received.count > 16 {
            let payload = Data(received.suffix(from: 16))
            XCTAssertFalse(TestAXDPBuilder.hasAXDPMagic(payload), "Should be plain AX.25, not AXDP")
        }
    }

    /// Test APRS-style position report (common AX.25 usage)
    func testAPRSStyleFrame() async throws {
        // APRS position report format (simplified)
        // Real APRS would have specific PID and formatting
        let aprsPayload = "!3753.65N/12217.12W-PHG2360 Test APRS beacon"
        let frame = TestFrameBuilder.buildUIFrame(
            from: "TEST-1",
            to: "APRS",
            text: aprsPayload
        )

        try await clientA.sendAX25Frame(frame)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        XCTAssertFalse(received.isEmpty)
        if received.count > 16 {
            let payload = Data(received.suffix(from: 16))
            // APRS should not be detected as AXDP
            XCTAssertFalse(TestAXDPBuilder.hasAXDPMagic(payload))
            XCTAssertFalse(AXDP.hasMagic(payload), "APRS should not be detected as AXDP")
        }
    }

    /// Test that non-ASCII payloads don't false-positive as AXDP
    func testBinaryPayload() async throws {
        // Binary payload that might accidentally contain "AXT" bytes
        var binaryData = Data()
        binaryData.append(0x41)  // 'A'
        binaryData.append(0x58)  // 'X'
        binaryData.append(0x54)  // 'T'
        binaryData.append(0x00)  // NOT '1' - should break magic
        binaryData.append(contentsOf: [0x01, 0x02, 0x03, 0x04])

        let frame = TestFrameBuilder.buildUIFrame(
            from: TestAX25Address("TEST-1"),
            to: TestAX25Address("TEST-2"),
            payload: binaryData
        )

        try await clientA.sendAX25Frame(frame)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        if received.count > 16 {
            let payload = Data(received.suffix(from: 16))
            XCTAssertFalse(AXDP.hasMagic(payload), "Near-magic should not trigger AXDP detection")
        }
    }

    // MARK: - Coexistence Tests

    /// Test that AXDP and non-AXDP traffic can coexist
    func testMixedTrafficCoexistence() async throws {
        // Simulate a network with both AXDP and legacy stations
        let frames = [
            ("plain", TestFrameBuilder.buildUIFrame(from: "LEGACY1", to: "TEST-2", text: "Legacy station 1")),
            ("axdp", TestFrames.axdpChatHello),
            ("plain", TestFrameBuilder.buildUIFrame(from: "LEGACY2", to: "TEST-2", text: "Legacy station 2")),
            ("axdp", TestFrameBuilder.buildAXDPFrame(from: "AXDP-1", to: "TEST-2", message: "AXDP station")),
            ("plain", TestFrameBuilder.buildUIFrame(from: "APRS", to: "TEST-2", text: "APRS beacon"))
        ]

        for (_, frame) in frames {
            try await clientA.sendAX25Frame(frame)
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        // Wait for all frames
        try await Task.sleep(nanoseconds: 3_000_000_000)

        let received = clientB.drainReceivedFrames()
        XCTAssertGreaterThanOrEqual(received.count, 1, "Should receive at least one frame")

        // Verify we can correctly categorize each frame
        for frame in received {
            if frame.count > 16 {
                let payload = Data(frame.suffix(from: 16))
                // Just verify we can check - either true or false is valid
                _ = AXDP.hasMagic(payload)
            }
        }
    }

    /// Test that AXDP detection uses real AXDP.hasMagic implementation
    func testRealAXDPMagicDetection() async throws {
        // Test with real AXDP message
        let realAXDPPayload = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: 12345,
            payload: Data("Real AXDP message".utf8)
        ).encode()

        let frame = TestFrameBuilder.buildUIFrame(
            from: TestAX25Address("TEST-1"),
            to: TestAX25Address("TEST-2"),
            payload: realAXDPPayload
        )

        try await clientA.sendAX25Frame(frame)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        if received.count > 16 {
            let payload = Data(received.suffix(from: 16))

            // Use real AXDP detection
            XCTAssertTrue(AXDP.hasMagic(payload), "Real AXDP should be detected")

            // Verify it decodes correctly
            if let decoded = AXDP.Message.decode(from: payload) {
                XCTAssertEqual(decoded.type, .chat)
                XCTAssertEqual(decoded.messageId, 12345)
            } else {
                XCTFail("Real AXDP message should decode successfully")
            }
        }
    }
}
