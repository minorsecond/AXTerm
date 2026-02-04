//
//  AXDPChatDisplayTests.swift
//  AXTermTests
//
//  Tests that AXDP chat messages are delivered to the terminal transcript
//  regardless of receiver's AXDP badge state (per AXTERM-TRANSMISSION-SPEC).
//

import XCTest
@testable import AXTerm

@MainActor
final class AXDPChatDisplayTests: XCTestCase {

    // MARK: - SessionCoordinator invokes onAXDPChatReceived when receiving AXDP chat I-frame

    /// When SessionCoordinator receives an I-frame with AXDP chat payload addressed to us,
    /// it MUST invoke onAXDPChatReceived with the decoded text—regardless of AXDP badge state.
    func testSessionCoordinatorInvokesOnAXDPChatReceivedWhenReceivingAXDPChatIFrame() async throws {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "TEST-2"

        let client = PacketEngine(
            maxPackets: 100,
            maxConsoleLines: 100,
            maxRawChunks: 100,
            settings: settings
        )

        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.packetEngine = client
        coordinator.localCallsign = "TEST-2"
        coordinator.subscribeToPackets(from: client)

        var capturedFrom: AX25Address?
        var capturedText: String?
        coordinator.onAXDPChatReceived = { from, text in
            capturedFrom = from
            capturedText = text
        }

        // Build AXDP chat payload (same format TerminalTxViewModel uses)
        let messageText = "test with axdp on at sender"
        let axdpPayload = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: UInt32.random(in: 1...UInt32.max),
            payload: Data(messageText.utf8)
        ).encode()

        // Build I-frame packet: TEST-1 -> TEST-2 with AXDP chat
        let packet = Packet(
            timestamp: Date(),
            from: AX25Address(call: "TEST", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 2),
            via: [],
            frameType: .i,
            control: 0x00,  // I-frame N(S)=0 N(R)=0
            controlByte1: nil,
            pid: 0xF0,
            info: axdpPayload,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )

        client.handleIncomingPacket(packet)

        // Allow async sink to process (coordinator receives on main)
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        XCTAssertNotNil(capturedFrom, "onAXDPChatReceived should be called")
        XCTAssertEqual(capturedFrom?.display, "TEST-1")
        XCTAssertEqual(capturedText, messageText)
    }

    /// AXDP chat over UI frame also triggers callback (SessionCoordinator handles UI in handleUFrame)
    func testSessionCoordinatorInvokesOnAXDPChatReceivedWhenReceivingAXDPChatUIFrame() async throws {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "TEST-2"

        let client = PacketEngine(
            maxPackets: 100,
            maxConsoleLines: 100,
            maxRawChunks: 100,
            settings: settings
        )

        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.packetEngine = client
        coordinator.localCallsign = "TEST-2"
        coordinator.subscribeToPackets(from: client)

        var capturedText: String?
        coordinator.onAXDPChatReceived = { _, text in
            capturedText = text
        }

        let messageText = "AXDP over UI"
        let axdpPayload = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: 12345,
            payload: Data(messageText.utf8)
        ).encode()

        let packet = Packet(
            timestamp: Date(),
            from: AX25Address(call: "TEST", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 2),
            via: [],
            frameType: .ui,
            control: 0x03,
            controlByte1: nil,
            pid: 0xF0,
            info: axdpPayload,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )

        client.handleIncomingPacket(packet)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(capturedText, messageText)
    }
}
