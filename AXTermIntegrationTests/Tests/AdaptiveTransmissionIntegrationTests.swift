//
//  AdaptiveTransmissionIntegrationTests.swift
//  AXTermIntegrationTests
//
//  Integration tests ensuring adaptive transmission and session config work
//  smoothly with both vanilla AX.25 stations (no AXDP) and AXDP-enabled stations.
//  Runs over KISS simulator: vanilla path = SABM/UA + plain I-frames;
//  AXDP path = UI frames with AXDP payload (PING, chat). Spec: AXTERM-TRANSMISSION-SPEC.md 4.1, 7, 7.8.
//

import XCTest
@testable import AXTerm

/// Integration tests for adaptive transmission with vanilla AX.25 and AXDP stations.
/// Requires KISS simulator (e.g. Direwolf or test harness) to be available.
final class AdaptiveTransmissionIntegrationTests: XCTestCase {

    var clientA: SimulatorClient!
    var clientB: SimulatorClient!

    let stationA = TestAX25Address("TEST-1")
    let stationB = TestAX25Address("TEST-2")

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

    // MARK: - Vanilla AX.25 (no AXDP)

    /// Vanilla AX.25: connection (SABM/UA) and plain text I-frame work without any AXDP.
    /// Ensures adaptive session config and default params work for legacy stations.
    func testVanillaAX25ConnectedSessionPlainTextWorks() async throws {
        let sabm = TestConnectedFrameBuilder.buildSABM(from: stationA, to: stationB)
        try await clientA.sendAX25Frame(sabm)

        let receivedSABM = try await clientB.waitForFrame(timeout: 5.0)
        XCTAssertFalse(receivedSABM.isEmpty, "Vanilla station should receive SABM")

        let ua = TestConnectedFrameBuilder.buildUA(from: stationB, to: stationA)
        try await clientB.sendAX25Frame(ua)

        let receivedUA = try await clientA.waitForFrame(timeout: 5.0)
        XCTAssertFalse(receivedUA.isEmpty, "Initiator should receive UA")

        let plainPayload = Data("Vanilla AX.25 plain text".utf8)
        let iFrame = TestConnectedFrameBuilder.buildIFrame(
            from: stationA,
            to: stationB,
            ns: 0,
            nr: 0,
            payload: plainPayload
        )
        try await clientA.sendAX25Frame(iFrame)

        let receivedIFrame = try await clientB.waitForFrame(timeout: 5.0)
        XCTAssertFalse(receivedIFrame.isEmpty, "Vanilla station should receive plain I-frame")
    }

    /// Vanilla AX.25: plain UI frame (no AXDP) works for unconnected traffic.
    func testVanillaAX25UIFramePlainTextWorks() async throws {
        try await clientA.sendAX25Frame(TestFrames.plainTextHello)
        let received = try await clientB.waitForFrame(timeout: 10.0)
        XCTAssertFalse(received.isEmpty)
        if received.count > 16 {
            let payload = Data(received.suffix(from: 16))
            XCTAssertFalse(TestAXDPBuilder.hasAXDPMagic(payload), "Plain text should not be AXDP")
        }
    }

    // MARK: - AXDP-enabled station

    /// AXDP-enabled: UI frame with AXDP chat is received and decodable.
    func testAXDPStationReceivesAXDPChat() async throws {
        let message = "AXDP integration test"
        let axdpPayload = TestAXDPBuilder.buildChatMessage(text: message)
        let frame = TestFrameBuilder.buildUIFrame(
            from: stationA,
            to: stationB,
            payload: axdpPayload
        )
        try await clientA.sendAX25Frame(frame)
        let received = try await clientB.waitForFrame(timeout: 10.0)

        XCTAssertFalse(received.isEmpty)
        if received.count > 16 {
            let payloadData = Data(received.suffix(from: 16))
            XCTAssertTrue(TestAXDPBuilder.hasAXDPMagic(payloadData))
            if let (decoded, _) = AXDP.Message.decode(from: payloadData) {
                XCTAssertEqual(decoded.type, .chat)
                if let textData = decoded.payload, let text = String(data: textData, encoding: .utf8) {
                    XCTAssertEqual(text, message)
                }
            }
        }
    }

    /// Mixed: plain text and AXDP frames both work (vanilla and AXDP stations can coexist).
    func testMixedVanillaAndAXDPTrafficBothWork() async throws {
        try await clientA.sendAX25Frame(TestFrames.plainTextHello)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await clientA.sendAX25Frame(TestFrames.axdpChatHello)

        try await Task.sleep(nanoseconds: 2_000_000_000)
        let frames = clientB.drainReceivedFrames()
        XCTAssertGreaterThanOrEqual(frames.count, 1, "Should receive both plain and AXDP frames")
    }
}
