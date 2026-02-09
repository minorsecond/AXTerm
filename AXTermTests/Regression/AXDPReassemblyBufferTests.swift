//
//  AXDPReassemblyBufferTests.swift
//  AXTermTests
//
//  Regression tests for AXDP reassembly buffer management.
//
//  BUG DESCRIPTION:
//  Large multi-fragment AXDP messages are sometimes truncated when switching
//  AXDP on/off between stations. This is caused by:
//
//  1. Reassembly buffer not cleared on session disconnect - stale fragments
//     from a previous session corrupt new messages when station reconnects
//
//  2. Reassembly buffer not cleared when AXDP is toggled - partial fragments
//     remain and corrupt messages when AXDP is re-enabled
//
//  3. Double flag clearing race condition - the peersInAXDPReassembly flag
//     is cleared in two places which can cause timing issues
//
//  EXPECTED BEHAVIOR:
//  - Reassembly buffer MUST be cleared when session disconnects
//  - Reassembly buffer MUST be cleared when AXDP capabilities change
//  - Multi-fragment messages MUST be fully delivered without truncation
//

import XCTest
@testable import AXTerm

// MARK: - Reassembly Buffer Lifecycle Tests

/// Tests verifying reassembly buffer is properly cleared on session lifecycle events
final class ReassemblyBufferLifecycleTests: XCTestCase {
    
    /// Test that reassembly buffer is cleared when session disconnects
    /// This is the core bug: buffer was NOT being cleared on disconnect
    func testReassemblyBufferClearedOnSessionDisconnect() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 2)
            
            let peer = AX25Address(call: "TEST", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            // Connect the session
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            XCTAssertEqual(session.state, .connected)
            
            // Send partial AXDP data (first fragment of multi-fragment message)
            let partialAXDP = createPartialAXDPData(payloadSize: 1000)
            sessionManager.onDataDeliveredForReassembly?(session, partialAXDP)
            
            // Verify buffer has data
            let reassemblyKey = "\(peer.display)-"
            let bufferStateBefore = coordinator.testReassemblyBufferState
            XCTAssertGreaterThan(bufferStateBefore[reassemblyKey] ?? 0, 0, 
                "Buffer should have partial AXDP data before disconnect")
            
            // Disconnect the session - handle state machine transition
            _ = session.stateMachine.handle(event: .receivedDISC)
            XCTAssertEqual(session.state, .disconnected)
            
            // Manually invoke the onSessionStateChanged callback to simulate disconnect notification
            // (The state machine doesn't automatically call this; it's wired up via AX25SessionManager)
            sessionManager.onSessionStateChanged?(session, .connected, .disconnected)
            
            // EXPECTED: Buffer should be cleared after disconnect
            let bufferStateAfter = coordinator.testReassemblyBufferState
            XCTAssertEqual(bufferStateAfter[reassemblyKey] ?? 0, 0, 
                "Buffer MUST be cleared when session disconnects")
        }
    }
    
    /// Test that stale buffer data does NOT corrupt new messages after reconnect
    func testStaleBufferDoesNotCorruptNewMessages() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 2)
            
            var chatMessagesReceived: [(String, String)] = []
            coordinator.onAXDPChatReceived = { from, text in
                chatMessagesReceived.append((from.display, text))
            }
            
            let peer = AX25Address(call: "TEST", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            // === Session 1: Connect, send partial AXDP, disconnect ===
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            // Send incomplete AXDP message (will leave partial data in buffer)
            let partialAXDP = createPartialAXDPData(payloadSize: 500)
            sessionManager.onDataDeliveredForReassembly?(session, partialAXDP)
            
            // Disconnect without completing the message - trigger callback
            _ = session.stateMachine.handle(event: .receivedDISC)
            sessionManager.onSessionStateChanged?(session, .connected, .disconnected)
            
            // === Session 2: Reconnect and send a complete new message ===
            // Create new session for same peer
            let newSession = sessionManager.session(for: peer)
            _ = newSession.stateMachine.handle(event: .connectRequest)
            _ = newSession.stateMachine.handle(event: .receivedUA)
            
            // Send a complete AXDP chat message
            let completeMessage = createCompleteAXDPChatMessage(text: "New message after reconnect")
            sessionManager.onDataDeliveredForReassembly?(newSession, completeMessage)
            
            // EXPECTED: New message should be delivered correctly without corruption
            XCTAssertEqual(chatMessagesReceived.count, 1, 
                "Complete message should be delivered")
            XCTAssertEqual(chatMessagesReceived.first?.1, "New message after reconnect",
                "Message content should NOT be corrupted by stale buffer data")
        }
    }
    
    /// Test that multi-fragment messages are fully delivered when switching between stations
    func testMultiFragmentMessageWithStationSwitch() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "LOCAL", ssid: 1)
            
            var chatMessagesReceived: [(String, String)] = []
            coordinator.onAXDPChatReceived = { from, text in
                chatMessagesReceived.append((from.display, text))
            }
            
            // Two stations sending alternating messages
            let stationA = AX25Address(call: "STAA", ssid: 1)
            let stationB = AX25Address(call: "STAB", ssid: 1)
            
            let sessionA = sessionManager.session(for: stationA)
            let sessionB = sessionManager.session(for: stationB)
            
            // Connect both sessions
            _ = sessionA.stateMachine.handle(event: .connectRequest)
            _ = sessionA.stateMachine.handle(event: .receivedUA)
            _ = sessionB.stateMachine.handle(event: .connectRequest)
            _ = sessionB.stateMachine.handle(event: .receivedUA)
            
            // Station A: Send first fragment of multi-fragment message
            let longText = String(repeating: "A", count: 2000)
            let fragmentsA = createMultiFragmentAXDPChat(text: longText, fragmentSize: 128)
            
            // Send first half of Station A's fragments
            for fragment in fragmentsA.prefix(fragmentsA.count / 2) {
                sessionManager.onDataDeliveredForReassembly?(sessionA, fragment)
            }
            
            // Station B: Send a complete short message (interleaved)
            let completeMessageB = createCompleteAXDPChatMessage(text: "Message from Station B")
            sessionManager.onDataDeliveredForReassembly?(sessionB, completeMessageB)
            
            // Station A: Complete remaining fragments
            for fragment in fragmentsA.suffix(fragmentsA.count - fragmentsA.count / 2) {
                sessionManager.onDataDeliveredForReassembly?(sessionA, fragment)
            }
            
            // EXPECTED: Both messages should be fully delivered
            XCTAssertEqual(chatMessagesReceived.count, 2, 
                "Both messages should be delivered")
            
            // Station B's message should arrive first (it completed first)
            XCTAssertEqual(chatMessagesReceived[0].0, "STAB-1",
                "Station B's message should arrive first")
            XCTAssertEqual(chatMessagesReceived[0].1, "Message from Station B")
            
            // Station A's long message should be complete
            XCTAssertEqual(chatMessagesReceived[1].0, "STAA-1",
                "Station A's message should be from Station A")
            XCTAssertEqual(chatMessagesReceived[1].1, longText,
                "Station A's message should NOT be truncated")
        }
    }
    
    // MARK: - Helper Methods
    
    /// Create a partial AXDP message (header + incomplete payload)
    private func createPartialAXDPData(payloadSize: Int) -> Data {
        // Create AXDP header with a long payload length but only partial data
        let fullPayload = String(repeating: "X", count: payloadSize)
        let message = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: UInt32.random(in: 0..<UInt32.max),
            payload: fullPayload.data(using: .utf8)!
        )
        let fullData = message.encode()
        // Return only partial data (header + partial payload)
        return fullData.prefix(fullData.count / 2)
    }
    
    /// Create a complete AXDP chat message
    private func createCompleteAXDPChatMessage(text: String) -> Data {
        let message = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: UInt32.random(in: 0..<UInt32.max),
            payload: text.data(using: .utf8)!
        )
        return message.encode()
    }
    
    /// Create multi-fragment AXDP chat (simulating fragmentation over AX.25 I-frames)
    private func createMultiFragmentAXDPChat(text: String, fragmentSize: Int) -> [Data] {
        let message = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: UInt32.random(in: 0..<UInt32.max),
            payload: text.data(using: .utf8)!
        )
        let fullData = message.encode()
        
        // Split into fragments
        var fragments: [Data] = []
        var offset = 0
        while offset < fullData.count {
            let end = min(offset + fragmentSize, fullData.count)
            fragments.append(fullData[offset..<end])
            offset = end
        }
        return fragments
    }
}

// MARK: - Flag Clearing Race Condition Tests

/// Tests verifying the peersInAXDPReassembly flag is handled correctly
final class FlagClearingRaceConditionTests: XCTestCase {
    
    /// Test that flag is cleared properly when AXDP chat is delivered
    func testFlagClearedOnAXDPChatDelivery() async {
        await MainActor.run {
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 2)

            let settings = AppSettingsStore()
            let viewModel = ObservableTerminalTxViewModel(
                client: PacketEngine(settings: settings),
                settings: settings,
                sourceCall: "TEST-2",
                sessionManager: sessionManager
            )
            viewModel.setupSessionCallbacks()

            let peer = AX25Address(call: "TEST", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            viewModel.setCurrentSession(session)
            
            // Send AXDP data to set the flag
            let axdpData = AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode()
            viewModel.sessionManager.onDataReceived?(session, axdpData)
            
            // Verify flag is set
            let peerKey = peer.display.uppercased()
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(peerKey),
                "Flag should be set after receiving AXDP data")
            
            // Simulate AXDP chat delivery — flag stays set to suppress raw bytes from same I-frame
            viewModel.appendAXDPChatToTranscript(from: peer, text: "Chat message")
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(peerKey),
                "Flag must remain set after appendAXDPChatToTranscript to suppress raw bytes")

            // Simulate async reassembly-complete callback clearing the flag
            viewModel.clearAXDPReassemblyFlag(for: peer)

            // EXPECTED: Flag should now be cleared
            XCTAssertFalse(viewModel.isPeerInAXDPReassembly(peerKey),
                "Flag MUST be cleared after clearAXDPReassemblyFlag")
        }
    }
    
    /// Test that plain text is delivered after AXDP chat completes (no suppression)
    func testPlainTextDeliveredAfterAXDPChatCompletion() async {
        await MainActor.run {
            var receivedLines: [String] = []

            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 2)

            let settings = AppSettingsStore()
            let viewModel = ObservableTerminalTxViewModel(
                client: PacketEngine(settings: settings),
                settings: settings,
                sourceCall: "TEST-2",
                sessionManager: sessionManager
            )
            viewModel.setupSessionCallbacks()

            viewModel.onPlainTextChatReceived = { _, text, _ in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "TEST", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            viewModel.setCurrentSession(session)
            
            // Step 1: Send AXDP data (sets flag)
            let axdpData = AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode()
            viewModel.sessionManager.onDataReceived?(session, axdpData)
            
            // Step 2: AXDP chat delivered (flag stays set to suppress raw bytes from same I-frame)
            viewModel.appendAXDPChatToTranscript(from: peer, text: "AXDP Chat")

            // Step 2b: Simulate async reassembly-complete callback clearing the flag
            viewModel.clearAXDPReassemblyFlag(for: peer)

            // Step 3: Plain text arrives (should be delivered, not suppressed)
            viewModel.sessionManager.onDataReceived?(session, Data("Plain text after AXDP\r\n".utf8))
            
            // EXPECTED: Plain text MUST be delivered
            XCTAssertEqual(receivedLines.count, 2, 
                "Both AXDP chat and plain text should be delivered")
            XCTAssertEqual(receivedLines[0], "AXDP Chat",
                "AXDP chat should be first")
            XCTAssertEqual(receivedLines[1], "Plain text after AXDP",
                "Plain text should be delivered and not suppressed")
        }
    }
    
    /// Test that flag is not prematurely cleared causing fragment leak
    func testFlagNotPrematurelyClearedDuringReassembly() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 2)
            
            let settings = AppSettingsStore()
            let viewModel = ObservableTerminalTxViewModel(
                client: PacketEngine(settings: settings),
                settings: settings,
                sourceCall: "TEST-2",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text, _ in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "TEST", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            viewModel.setCurrentSession(session)
            
            // Send AXDP data (sets flag)
            let axdpData = AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode()
            viewModel.sessionManager.onDataReceived?(session, axdpData)
            
            // Send continuation fragment (no magic header) - should be suppressed
            let continuationFragment = Data("continuation data without magic".utf8)
            viewModel.sessionManager.onDataReceived?(session, continuationFragment)
            
            // EXPECTED: Continuation fragment should NOT appear as plain text
            // Only AXDP data should be in the line buffer (not delivered as complete line yet)
            XCTAssertTrue(receivedLines.isEmpty || receivedLines.allSatisfy { !$0.contains("continuation") },
                "AXDP continuation fragments should NOT leak as plain text")
        }
    }
}

// MARK: - Multi-Fragment Message Integrity Tests

/// Tests verifying multi-fragment AXDP messages are fully delivered
final class MultiFragmentMessageIntegrityTests: XCTestCase {
    
    /// Test that a large multi-fragment AXDP message is fully delivered
    func testLargeMultiFragmentMessageFullyDelivered() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 2)
            
            var chatMessagesReceived: [(String, String)] = []
            coordinator.onAXDPChatReceived = { from, text in
                chatMessagesReceived.append((from.display, text))
            }
            
            let peer = AX25Address(call: "TEST", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Create a large message (like Lorem Ipsum from the bug report)
            let longText = """
            Lorem ipsum dolor sit amet, consectetur adipiscing elit. Praesent bibendum \
            quam in gravida vestibulum. Quisque metus risus, pretium ut pretium in, \
            eleifend tempus tortor. Donec in nisi pretium, dictum metus ut, consectetur \
            mauris. Maecenas eleifend ante eu dui porttitor, sit amet pharetra lectus \
            efficitur. Fusce consequat, ligula sed gravida maximus, dui ex rhoncus lacus, \
            quis euismod enim purus ac leo. Nunc a sem tellus. Curabitur at odio odio. \
            In consectetur ornare eros ut faucibus. Etiam molestie felis non molestie \
            interdum. Integer bibendum interdum massa nec iaculis. Mauris a tellus vel \
            eros tempus condimentum. Aenean vestibulum urna et sem cursus rhoncus. Ut \
            luctus mi luctus blandit pretium. Quisque ut ligula egestas leo, vite pulvinar \
            lectus. Suspendisse ut felis imperdiet, imperdiet massa ut, ullamcorper est.
            """
            
            // Fragment the message (simulating 128-byte I-frames)
            let fullMessage = createAXDPChatMessage(text: longText)
            let fragments = fragmentData(fullMessage, fragmentSize: 128)
            
            // Deliver all fragments
            for fragment in fragments {
                sessionManager.onDataDeliveredForReassembly?(session, fragment)
            }
            
            // EXPECTED: Full message should be delivered
            XCTAssertEqual(chatMessagesReceived.count, 1, 
                "Message should be delivered exactly once")
            XCTAssertEqual(chatMessagesReceived.first?.1, longText,
                "Full message content should be delivered without truncation")
        }
    }
    
    /// Test that rapid station switching doesn't cause message loss
    func testRapidStationSwitchingNoMessageLoss() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "LOCAL", ssid: 1)
            
            var chatMessagesReceived: [(String, String)] = []
            coordinator.onAXDPChatReceived = { from, text in
                chatMessagesReceived.append((from.display, text))
            }
            
            // Create multiple stations
            let stations = (1...5).map { AX25Address(call: "STA\($0)", ssid: 1) }
            let sessions = stations.map { sessionManager.session(for: $0) }
            
            // Connect all sessions
            for session in sessions {
                session.stateMachine.handle(event: .connectRequest)
                session.stateMachine.handle(event: .receivedUA)
            }
            
            // Each station sends a complete message
            for (index, session) in sessions.enumerated() {
                let message = createAXDPChatMessage(text: "Message from Station \(index + 1)")
                sessionManager.onDataDeliveredForReassembly?(session, message)
            }
            
            // EXPECTED: All messages should be delivered
            XCTAssertEqual(chatMessagesReceived.count, 5, 
                "All 5 messages should be delivered")
            
            for i in 0..<5 {
                XCTAssertEqual(chatMessagesReceived[i].1, "Message from Station \(i + 1)",
                    "Message from Station \(i + 1) should be intact")
            }
        }
    }
    
    /// Test alternating AXDP on/off per station (the exact scenario from bug report)
    func testAlternatingAXDPOnOffPerStation() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "LOCAL", ssid: 1)
            
            var chatMessagesReceived: [(String, String)] = []
            var plainTextReceived: [(String, String)] = []
            
            coordinator.onAXDPChatReceived = { from, text in
                chatMessagesReceived.append((from.display, text))
            }
            
            // Station sends AXDP, then plain text, then AXDP again
            let station = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: station)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Round 1: AXDP message
            let axdpMessage1 = createAXDPChatMessage(text: "AXDP Message 1")
            sessionManager.onDataDeliveredForReassembly?(session, axdpMessage1)
            
            // The reassembly buffer should now be empty after extracting message
            let reassemblyKey = "\(station.display)-"
            XCTAssertEqual(coordinator.testReassemblyBufferState[reassemblyKey] ?? 0, 0,
                "Buffer should be empty after complete message extraction")
            
            // Round 2: Plain text (directly sent, bypasses reassembly)
            // Note: In real app this would go through onDataReceived not onDataDeliveredForReassembly
            
            // Round 3: Another AXDP message
            let axdpMessage2 = createAXDPChatMessage(text: "AXDP Message 2")
            sessionManager.onDataDeliveredForReassembly?(session, axdpMessage2)
            
            // EXPECTED: Both AXDP messages delivered correctly
            XCTAssertEqual(chatMessagesReceived.count, 2, 
                "Both AXDP messages should be delivered")
            XCTAssertEqual(chatMessagesReceived[0].1, "AXDP Message 1")
            XCTAssertEqual(chatMessagesReceived[1].1, "AXDP Message 2")
        }
    }
    
    // MARK: - Helper Methods
    
    private func createAXDPChatMessage(text: String) -> Data {
        let message = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: UInt32.random(in: 0..<UInt32.max),
            payload: text.data(using: .utf8)!
        )
        return message.encode()
    }
    
    private func fragmentData(_ data: Data, fragmentSize: Int) -> [Data] {
        var fragments: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + fragmentSize, data.count)
            fragments.append(data[offset..<end])
            offset = end
        }
        return fragments
    }
}

// MARK: - SessionCoordinator Buffer Clearing Tests

/// Tests verifying SessionCoordinator properly clears buffers
final class SessionCoordinatorBufferClearingTests: XCTestCase {
    
    /// Test that buffer is cleared for disconnected session's peer
    func testBufferClearedForDisconnectedPeer() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 2)
            
            let peer = AX25Address(call: "TEST", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            // Send partial AXDP data
            let partialData = createPartialAXDPData()
            sessionManager.onDataDeliveredForReassembly?(session, partialData)
            
            let reassemblyKey = "\(peer.display)-"
            XCTAssertGreaterThan(coordinator.testReassemblyBufferState[reassemblyKey] ?? 0, 0,
                "Buffer should have data before disconnect")
            
            // Disconnect - trigger callback
            _ = session.stateMachine.handle(event: .receivedDISC)
            sessionManager.onSessionStateChanged?(session, .connected, .disconnected)
            
            // EXPECTED: Buffer should be cleared
            XCTAssertEqual(coordinator.testReassemblyBufferState[reassemblyKey] ?? 0, 0,
                "Buffer MUST be cleared when session disconnects")
        }
    }
    
    /// Test that multiple sessions' buffers are independent
    func testMultipleSessionBuffersAreIndependent() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 2)
            
            let peerA = AX25Address(call: "PEERA", ssid: 1)
            let peerB = AX25Address(call: "PEERB", ssid: 1)
            
            let sessionA = sessionManager.session(for: peerA)
            let sessionB = sessionManager.session(for: peerB)
            
            _ = sessionA.stateMachine.handle(event: .connectRequest)
            _ = sessionA.stateMachine.handle(event: .receivedUA)
            _ = sessionB.stateMachine.handle(event: .connectRequest)
            _ = sessionB.stateMachine.handle(event: .receivedUA)
            
            // Send partial data to both
            sessionManager.onDataDeliveredForReassembly?(sessionA, createPartialAXDPData())
            sessionManager.onDataDeliveredForReassembly?(sessionB, createPartialAXDPData())
            
            let keyA = "\(peerA.display)-"
            let keyB = "\(peerB.display)-"
            
            XCTAssertGreaterThan(coordinator.testReassemblyBufferState[keyA] ?? 0, 0)
            XCTAssertGreaterThan(coordinator.testReassemblyBufferState[keyB] ?? 0, 0)
            
            // Disconnect only session A - trigger callback
            _ = sessionA.stateMachine.handle(event: .receivedDISC)
            sessionManager.onSessionStateChanged?(sessionA, .connected, .disconnected)
            
            // EXPECTED: Only A's buffer should be cleared
            XCTAssertEqual(coordinator.testReassemblyBufferState[keyA] ?? 0, 0,
                "Session A's buffer should be cleared")
            XCTAssertGreaterThan(coordinator.testReassemblyBufferState[keyB] ?? 0, 0,
                "Session B's buffer should still have data")
        }
    }
    
    // MARK: - Helper Methods
    
    private func createPartialAXDPData() -> Data {
        let message = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: UInt32.random(in: 0..<UInt32.max),
            payload: String(repeating: "X", count: 500).data(using: .utf8)!
        )
        let fullData = message.encode()
        return fullData.prefix(fullData.count / 2)
    }
}

// MARK: - Reassembly Resync Tests

final class ReassemblyResyncTests: XCTestCase {
    
    /// Test that a corrupted buffer (leading garbage before AXDP magic)
    /// can resync and still decode a complete message.
    func testResyncSkipsLeadingGarbageBeforeMagic() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 2)
            
            var received: [(String, String)] = []
            coordinator.onAXDPChatReceived = { from, text in
                received.append((from.display, text))
            }
            
            let peer = AX25Address(call: "TEST", ssid: 1)
            let session = sessionManager.session(for: peer)
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            let message = AXDP.Message(
                type: .chat,
                sessionId: 0,
                messageId: 1,
                payload: Data("Resync message".utf8)
            )
            let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
            var corruptedBuffer = garbage
            corruptedBuffer.append(message.encode())
            
            #if DEBUG
            coordinator.testInjectReassemblyBuffer(for: peer, data: corruptedBuffer)
            // Trigger a reassembly pass with an empty delivery (existing buffer should decode)
            sessionManager.onDataDeliveredForReassembly?(session, Data())
            #endif
            
            XCTAssertEqual(received.count, 1, "Expected one AXDP message after resync")
            XCTAssertEqual(received.first?.1, "Resync message")
        }
    }
}
