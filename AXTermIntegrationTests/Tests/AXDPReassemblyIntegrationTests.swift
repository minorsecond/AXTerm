//
//  AXDPReassemblyIntegrationTests.swift
//  AXTermIntegrationTests
//
//  Integration tests for AXDP message reassembly across fragmented I-frames.
//  These tests monitor the reassembly buffer state and verify that fragmented
//  messages are correctly reassembled and delivered.
//

import XCTest
import Combine
@testable import AXTerm

/// Integration test for AXDP reassembly that monitors buffer state
@MainActor
final class AXDPReassemblyIntegrationTests: XCTestCase {

    var coordinator: SessionCoordinator!
    var packetEngine: PacketEngine!
    var cancellables: Set<AnyCancellable> = []
    
    // Reassembly monitoring state
    var reassemblyEvents: [(key: String, bufferSize: Int, extracted: Bool)] = []
    var receivedChatMessages: [(from: String, text: String)] = []

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "TEST-2"
        settings.axdpExtensionsEnabled = true
        settings.axdpAutoNegotiateCapabilities = true

        packetEngine = PacketEngine(
            maxPackets: 100,
            maxConsoleLines: 100,
            maxRawChunks: 100,
            settings: settings
        )

        coordinator = SessionCoordinator()
        SessionCoordinator.shared = coordinator
        coordinator.packetEngine = packetEngine
        coordinator.localCallsign = "TEST-2"
        coordinator.subscribeToPackets(from: packetEngine)
        
        // Hook into reassembly monitoring
        coordinator.onReassemblyEvent = { [weak self] key, bufferSize, extracted in
            self?.reassemblyEvents.append((key: key, bufferSize: bufferSize, extracted: extracted))
        }
        
        // Hook into chat message delivery
        coordinator.onAXDPChatReceived = { [weak self] from, text in
            self?.receivedChatMessages.append((from: from.display, text: text))
        }
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        coordinator?.onReassemblyEvent = nil
        coordinator?.onAXDPChatReceived = nil
        SessionCoordinator.shared = nil
        coordinator = nil
        packetEngine = nil
        reassemblyEvents.removeAll()
        receivedChatMessages.removeAll()
    }

    // MARK: - Fragmented Chat Message Tests

    /// Test that a long chat message fragmented across multiple I-frames is correctly reassembled
    /// This test monitors the reassembly buffer state to verify correct behavior
    func testFragmentedChatMessageReassembly() async throws {
        // Create a long message that will be fragmented
        let longMessage = String(repeating: "Contrary to popular belief, Lorem Ipsum is not simply random text. ", count: 20)
        let messagePayload = Data(longMessage.utf8)
        
        // Create AXDP chat message
        let axdpMessage = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: 1,
            payload: messagePayload
        )
        let encodedMessage = axdpMessage.encode()
        
        // Establish connected session first
        let from = AX25Address(call: "TEST", ssid: 1)
        let to = AX25Address(call: "TEST", ssid: 2)
        
        let sabmPacket = Packet(
            timestamp: Date(),
            from: from,
            to: to,
            via: [],
            frameType: .u,
            control: 0x2F,  // SABM
            controlByte1: nil,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
        packetEngine.handleIncomingPacket(sabmPacket)
        
        // Wait for session to be created
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Fragment the encoded message into I-frames (simulating paclen fragmentation)
        let paclen = 128  // Typical paclen
        var fragments: [Data] = []
        var offset = 0
        
        while offset < encodedMessage.count {
            let end = min(offset + paclen, encodedMessage.count)
            let fragment = encodedMessage.subdata(in: offset..<end)
            fragments.append(fragment)
            offset = end
        }
        
        XCTAssertGreaterThan(fragments.count, 1, "Message should be fragmented into multiple chunks")
        
        // Clear monitoring state
        reassemblyEvents.removeAll()
        receivedChatMessages.removeAll()
        
        // Inject fragments as I-frames with sequential N(S)
        for (index, fragment) in fragments.enumerated() {
            let ns = UInt8(index % 8)  // Sequence number wraps at 8
            let nr: UInt8 = 0  // Acknowledge nothing initially
            
            let packet = Packet(
                timestamp: Date(),
                from: from,
                to: to,
                via: [],
                frameType: .i,
                control: UInt8((Int(ns) << 1) | (Int(nr) << 5)),
                controlByte1: nil,
                pid: 0xF0,
                info: fragment,
                rawAx25: Data(),
                kissEndpoint: nil,
                infoText: nil
            )
            
            packetEngine.handleIncomingPacket(packet)
            
            // Small delay between fragments
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        
        // Wait for reassembly and delivery
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        
        // Verify reassembly buffer state
        let bufferState = coordinator.testReassemblyBufferState
        let reassemblyKey = "TEST-1-"
        
        // After successful extraction, buffer should be empty (or contain remaining data if multiple messages)
        // But we should have seen extraction events
        let extractionEvents = reassemblyEvents.filter { $0.extracted }
        XCTAssertGreaterThan(extractionEvents.count, 0, "Should have extracted at least one complete message")
        
        // Verify that buffer accumulated fragments before extraction
        let appendEvents = reassemblyEvents.filter { !$0.extracted }
        XCTAssertGreaterThanOrEqual(appendEvents.count, fragments.count, "Should have appended all fragments")
        
        // Verify buffer size increased as fragments were added
        var maxBufferSize = 0
        for event in reassemblyEvents {
            if event.bufferSize > maxBufferSize {
                maxBufferSize = event.bufferSize
            }
        }
        XCTAssertGreaterThan(maxBufferSize, paclen, "Buffer should have accumulated more than one fragment")
        
        // Verify chat message was delivered
        XCTAssertEqual(receivedChatMessages.count, 1, "Should receive exactly one chat message")
        XCTAssertEqual(receivedChatMessages[0].text, longMessage, "Received message should match sent message")
        XCTAssertEqual(receivedChatMessages[0].from, "TEST-1", "Message should be from TEST-1")
        
        // Verify final buffer state - should be empty after successful extraction
        let finalBufferSize = bufferState[reassemblyKey] ?? 0
        XCTAssertEqual(finalBufferSize, 0, "Buffer should be empty after successful extraction")
    }

    /// Test that reassembly buffer only consumes bytes actually used by decoded message
    func testReassemblyConsumesOnlyDecodedBytes() async throws {
        // Create two short messages that will be sent back-to-back
        let message1 = "First message"
        let message2 = "Second message"
        
        let msg1 = AXDP.Message(type: .chat, sessionId: 0, messageId: 1, payload: Data(message1.utf8))
        let msg2 = AXDP.Message(type: .chat, sessionId: 0, messageId: 2, payload: Data(message2.utf8))
        
        let encoded1 = msg1.encode()
        let encoded2 = msg2.encode()
        
        // Establish session
        let from = AX25Address(call: "TEST", ssid: 1)
        let to = AX25Address(call: "TEST", ssid: 2)
        
        let sabmPacket = Packet(
            timestamp: Date(),
            from: from,
            to: to,
            via: [],
            frameType: .u,
            control: 0x2F,
            controlByte1: nil,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
        packetEngine.handleIncomingPacket(sabmPacket)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Clear monitoring
        reassemblyEvents.removeAll()
        receivedChatMessages.removeAll()
        
        // Send both messages concatenated in a single I-frame (simulating two complete messages)
        let combinedPayload = encoded1 + encoded2
        
        let packet = Packet(
            timestamp: Date(),
            from: from,
            to: to,
            via: [],
            frameType: .i,
            control: 0x00,
            controlByte1: nil,
            pid: 0xF0,
            info: combinedPayload,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
        
        packetEngine.handleIncomingPacket(packet)
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Verify both messages were extracted
        XCTAssertEqual(receivedChatMessages.count, 2, "Should extract both messages")
        XCTAssertEqual(receivedChatMessages[0].text, message1, "First message should match")
        XCTAssertEqual(receivedChatMessages[1].text, message2, "Second message should match")
        
        // Verify extraction events show correct consumption
        let extractionEvents = reassemblyEvents.filter { $0.extracted }
        XCTAssertGreaterThanOrEqual(extractionEvents.count, 2, "Should have extracted both messages")
        
        // Verify buffer was properly managed - after first extraction, buffer should contain second message
        // After second extraction, buffer should be empty
        let bufferState = coordinator.testReassemblyBufferState
        let reassemblyKey = "TEST-1-"
        let finalBufferSize = bufferState[reassemblyKey] ?? 0
        XCTAssertEqual(finalBufferSize, 0, "Buffer should be empty after extracting both messages")
    }
}
