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
    /// NOTE: I-frames require an established session to be delivered. This test first establishes
    /// a session via SABM/UA handshake before sending the I-frame.
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

        // First, establish a session by sending SABM from TEST-1
        // This is required because I-frames are only processed for established sessions
        let sabmPacket = Packet(
            timestamp: Date(),
            from: AX25Address(call: "TEST", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 2),
            via: [],
            frameType: .u,
            control: 0x2F,  // SABM P=1
            controlByte1: nil,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
        client.handleIncomingPacket(sabmPacket)
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms for session setup

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

    // MARK: - peerAxdpEnabled notification (TDD: receive path)

    /// When SessionCoordinator receives an I-frame with AXDP peerAxdpEnabled payload,
    /// it MUST invoke onPeerAxdpEnabled with the peer address.
    /// NOTE: I-frames require an established session to be delivered.
    func testSessionCoordinatorInvokesOnPeerAxdpEnabledWhenReceivingPeerAxdpEnabledIFrame() async throws {
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
        coordinator.onPeerAxdpEnabled = { from in
            capturedFrom = from
        }

        // First, establish a session by sending SABM from TEST-1
        let sabmPacket = Packet(
            timestamp: Date(),
            from: AX25Address(call: "TEST", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 2),
            via: [],
            frameType: .u,
            control: 0x2F,  // SABM P=1
            controlByte1: nil,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
        client.handleIncomingPacket(sabmPacket)
        try await Task.sleep(nanoseconds: 50_000_000)

        let axdpPayload = AXDP.Message(
            type: .peerAxdpEnabled,
            sessionId: 0,
            messageId: UInt32.random(in: 1...UInt32.max)
        ).encode()

        let packet = Packet(
            timestamp: Date(),
            from: AX25Address(call: "TEST", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 2),
            via: [],
            frameType: .i,
            control: 0x00,
            controlByte1: nil,
            pid: 0xF0,
            info: axdpPayload,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )

        client.handleIncomingPacket(packet)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotNil(capturedFrom, "onPeerAxdpEnabled should be called")
        XCTAssertEqual(capturedFrom?.display, "TEST-1")
    }

    /// peerAxdpEnabled over UI frame also triggers callback.
    func testSessionCoordinatorInvokesOnPeerAxdpEnabledWhenReceivingPeerAxdpEnabledUIFrame() async throws {
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
        coordinator.onPeerAxdpEnabled = { from in
            capturedFrom = from
        }

        let axdpPayload = AXDP.Message(
            type: .peerAxdpEnabled,
            sessionId: 0,
            messageId: 123
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

        XCTAssertNotNil(capturedFrom, "onPeerAxdpEnabled should be called for UI frame")
        XCTAssertEqual(capturedFrom?.display, "TEST-1")
    }

    // MARK: - peerAxdpDisabled notification

    /// NOTE: I-frames require an established session to be delivered.
    func testSessionCoordinatorInvokesOnPeerAxdpDisabledWhenReceivingPeerAxdpDisabledIFrame() async throws {
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
        coordinator.onPeerAxdpDisabled = { from in
            capturedFrom = from
        }

        // First, establish a session by sending SABM from TEST-1
        let sabmPacket = Packet(
            timestamp: Date(),
            from: AX25Address(call: "TEST", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 2),
            via: [],
            frameType: .u,
            control: 0x2F,  // SABM P=1
            controlByte1: nil,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
        client.handleIncomingPacket(sabmPacket)
        try await Task.sleep(nanoseconds: 50_000_000)

        let axdpPayload = AXDP.Message(
            type: .peerAxdpDisabled,
            sessionId: 0,
            messageId: 999
        ).encode()

        let packet = Packet(
            timestamp: Date(),
            from: AX25Address(call: "TEST", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 2),
            via: [],
            frameType: .i,
            control: 0x00,
            controlByte1: nil,
            pid: 0xF0,
            info: axdpPayload,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )

        client.handleIncomingPacket(packet)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotNil(capturedFrom, "onPeerAxdpDisabled should be called")
        XCTAssertEqual(capturedFrom?.display, "TEST-1")
    }
}
