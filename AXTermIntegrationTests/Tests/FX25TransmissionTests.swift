//
//  FX25TransmissionTests.swift
//  AXTermIntegrationTests
//
//  Tests for FX.25 (Forward Error Correction) frame handling.
//  FX.25 wraps AX.25 frames with Reed-Solomon error correction.
//

import XCTest
@testable import AXTerm

/// Tests FX.25 frame handling through Direwolf simulation.
/// Note: FX.25 encoding/decoding happens at the TNC (Direwolf) level,
/// so from the application's perspective, we see normal AX.25 frames.
final class FX25TransmissionTests: XCTestCase {

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

    // MARK: - FX.25 Tests

    /// Test that frames are transmitted successfully with FX.25 enabled
    /// (FX.25 is transparent to the application layer)
    func testFX25TransmissionTransparency() async throws {
        let testMessage = "FX.25 test message with error correction"
        let frame = TestFrameBuilder.buildUIFrame(
            from: "TEST-1",
            to: "TEST-2",
            text: testMessage
        )

        // Send frame (Direwolf will wrap it in FX.25)
        try await clientA.sendAX25Frame(frame)

        // Receive frame (Direwolf will decode FX.25 and deliver AX.25)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        // Should receive a valid frame
        XCTAssertFalse(received.isEmpty, "Should receive frame via FX.25")
    }

    /// Test longer frame that benefits more from FEC
    func testFX25LongFrame() async throws {
        // Create a longer payload that would benefit from FEC
        let longText = String(repeating: "Testing FX.25 FEC capability. ", count: 10)
        let frame = TestFrameBuilder.buildUIFrame(
            from: "TEST-1",
            to: "TEST-2",
            text: longText
        )

        try await clientA.sendAX25Frame(frame)
        let received = try await clientB.waitForFrame(timeout: 15.0)

        XCTAssertFalse(received.isEmpty, "Should receive long frame via FX.25")
    }

    /// Test multiple FX.25 frames in sequence
    func testFX25SequentialFrames() async throws {
        var sentCount = 0

        for i in 1...3 {
            let frame = TestFrameBuilder.buildUIFrame(
                from: "TEST-1",
                to: "TEST-2",
                text: "FX.25 sequential frame \(i)"
            )
            try await clientA.sendAX25Frame(frame)
            sentCount += 1

            // Give time for FEC processing
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Wait for frames to arrive
        try await Task.sleep(nanoseconds: 3_000_000_000)

        let received = clientB.drainReceivedFrames()
        XCTAssertGreaterThanOrEqual(received.count, 1, "Should receive at least one FX.25 frame")
    }

    /// Test that FX.25 works in both directions
    func testFX25Bidirectional() async throws {
        // A -> B with FX.25
        let frameAtoB = TestFrameBuilder.buildUIFrame(
            from: "TEST-1",
            to: "TEST-2",
            text: "FX.25 A to B"
        )
        try await clientA.sendAX25Frame(frameAtoB)
        let receivedAtB = try await clientB.waitForFrame(timeout: 10.0)
        XCTAssertFalse(receivedAtB.isEmpty)

        try await Task.sleep(nanoseconds: 500_000_000)

        // B -> A with FX.25
        let frameBtoA = TestFrameBuilder.buildUIFrame(
            from: "TEST-2",
            to: "TEST-1",
            text: "FX.25 B to A"
        )
        try await clientB.sendAX25Frame(frameBtoA)
        let receivedAtA = try await clientA.waitForFrame(timeout: 10.0)
        XCTAssertFalse(receivedAtA.isEmpty)
    }
}
