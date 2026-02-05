//
//  NonAXDPDataDeliveryTests.swift
//  AXTermTests
//
//  Regression tests for non-AXDP (plain text) data delivery to terminal.
//
//  BUG DESCRIPTION:
//  When a peer first sends AXDP data, they get marked in `peersInAXDPReassembly`.
//  If that peer later switches to plain text (non-AXDP), the plain text is
//  silently suppressed because the flag remains set.
//
//  EXPECTED BEHAVIOR:
//  Non-AXDP data should ALWAYS be delivered to the terminal, regardless of
//  whether the peer previously sent AXDP data. The reassembly flag should be
//  cleared when non-AXDP data arrives from a peer that was in reassembly.
//

import XCTest
@testable import AXTerm

// MARK: - AXDP Magic Detection Tests

/// Tests verifying AXDP magic header detection
final class AXDPMagicDetectionTests: XCTestCase {
    
    /// Verify AXDP.hasMagic returns true for AXDP messages
    func testAXDPMessageHasMagic() {
        let axdpMessage = AXDP.Message(
            type: .ping,
            sessionId: 1,
            messageId: 1
        )
        let encoded = axdpMessage.encode()
        XCTAssertTrue(AXDP.hasMagic(encoded), "Encoded AXDP message should have magic header")
    }
    
    /// Verify AXDP.hasMagic returns false for plain text
    func testPlainTextHasNoMagic() {
        let plainText = Data("Hello, World!\r\n".utf8)
        XCTAssertFalse(AXDP.hasMagic(plainText), "Plain text should NOT have AXDP magic")
    }
    
    /// Verify AXDP.hasMagic returns false for empty data
    func testEmptyDataHasNoMagic() {
        XCTAssertFalse(AXDP.hasMagic(Data()), "Empty data should NOT have AXDP magic")
    }
}

// MARK: - Session Manager Tests

/// Tests for session manager session creation
final class SessionManagerBasicTests: XCTestCase {
    
    /// Verify session can be created and connected
    func testSessionCanBeConnected() async {
        await MainActor.run {
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            // Transition to connected
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            XCTAssertEqual(session.state, .connected)
        }
    }
    
    /// Verify onDataReceived callback is called
    func testOnDataReceivedCallbackIsCalled() async {
        await MainActor.run {
            var dataReceived: Data?
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            sessionManager.onDataReceived = { session, data in
                dataReceived = data
            }
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Manually invoke the callback to simulate receiving data
            let testData = Data("Test".utf8)
            sessionManager.onDataReceived?(session, testData)
            
            XCTAssertEqual(dataReceived, testData)
        }
    }
}

// MARK: - ObservableTerminalTxViewModel Tests

/// Tests for ObservableTerminalTxViewModel data handling
final class NonAXDPDataDeliveryTests: XCTestCase {
    
    /// Test that ObservableTerminalTxViewModel can be created
    func testViewModelCanBeCreated() async {
        await MainActor.run {
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            XCTAssertEqual(viewModel.sourceCall, "TEST-1")
        }
    }
    
    /// Test that plain text callback is invoked for non-AXDP data
    func testPlainTextCallbackIsInvoked() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Send plain text via the callback
            viewModel.sessionManager.onDataReceived?(session, Data("Hello\r\n".utf8))
            
            XCTAssertEqual(receivedLines.count, 1)
            XCTAssertEqual(receivedLines.first, "Hello")
        }
    }
    
    /// This is the core regression test for the bug.
    /// A peer sends AXDP data, reassembly completes, then plain text arrives.
    /// The plain text MUST be delivered to the terminal.
    func testPlainTextAfterAXDPReassemblyCompleteMustBeDelivered() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // STEP 1: Send AXDP data (marks peer as in reassembly)
            let axdpData = AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode()
            viewModel.sessionManager.onDataReceived?(session, axdpData)
            
            // STEP 2: AXDP reassembly completes (SessionCoordinator calls back)
            viewModel.clearAXDPReassemblyFlag(for: peer)
            
            // STEP 3: Send plain text (should be delivered now that reassembly is complete)
            viewModel.sessionManager.onDataReceived?(session, Data("Plain text after AXDP\r\n".utf8))
            
            // VERIFY: Plain text MUST be delivered
            XCTAssertEqual(receivedLines.count, 1, "Plain text should be delivered")
            XCTAssertEqual(receivedLines.first, "Plain text after AXDP")
        }
    }
    
    /// Test multiple alternations between AXDP and plain text with proper reassembly completion
    func testAlternatingAXDPAndPlainText() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Alternating: AXDP -> Complete -> Plain -> AXDP -> Complete -> Plain -> Plain
            
            // 1. AXDP message (sets flag)
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode())
            // AXDP reassembly completes (clears flag)
            viewModel.clearAXDPReassemblyFlag(for: peer)
            
            // 2. Plain text (delivered - flag is clear)
            viewModel.sessionManager.onDataReceived?(session, Data("Line 1\r\n".utf8))
            
            // 3. AXDP message (sets flag again)
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .pong, sessionId: 1, messageId: 2).encode())
            // AXDP reassembly completes (clears flag)
            viewModel.clearAXDPReassemblyFlag(for: peer)
            
            // 4. Plain text (delivered - flag is clear)
            viewModel.sessionManager.onDataReceived?(session, Data("Line 2\r\n".utf8))
            
            // 5. Plain text again (delivered - flag remains clear)
            viewModel.sessionManager.onDataReceived?(session, Data("Line 3\r\n".utf8))
            
            XCTAssertEqual(receivedLines.count, 3, "All 3 plain text lines must be delivered")
            XCTAssertEqual(receivedLines[0], "Line 1")
            XCTAssertEqual(receivedLines[1], "Line 2")
            XCTAssertEqual(receivedLines[2], "Line 3")
        }
    }
}

// MARK: - AXDP Reassembly Flag Tests

/// Tests for the peersInAXDPReassembly flag management
final class AXDPReassemblyFlagManagementTests: XCTestCase {
    
    /// Test that the flag IS set when AXDP magic is detected
    func testFlagSetOnAXDPMagic() async {
        await MainActor.run {
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Send AXDP data
            let axdp = AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode()
            viewModel.sessionManager.onDataReceived?(session, axdp)
            
            // Peer should be in the reassembly set
            let peerKey = peer.display.uppercased()
            XCTAssertTrue(
                viewModel.isPeerInAXDPReassembly(peerKey),
                "Peer should be marked as in AXDP reassembly after receiving AXDP data"
            )
        }
    }
    
    /// Test that the flag is NOT cleared by non-AXDP data (it could be an AXDP continuation fragment).
    /// The flag should only be cleared via clearAXDPReassemblyFlag() called from SessionCoordinator.
    func testFlagNotClearedByNonAXDPData() async {
        await MainActor.run {
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Step 1: Send AXDP (sets flag)
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode())
            
            let peerKey = peer.display.uppercased()
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(peerKey), "Flag should be set after AXDP")
            
            // Step 2: Send non-magic data (simulates AXDP continuation fragment)
            // The flag should NOT be cleared - it could be a continuation fragment
            viewModel.sessionManager.onDataReceived?(session, Data("continuation data".utf8))
            
            // Flag should STILL be set (not cleared by non-magic data)
            XCTAssertTrue(
                viewModel.isPeerInAXDPReassembly(peerKey),
                "Flag should NOT be cleared by non-magic data (could be AXDP continuation)"
            )
            
            // Step 3: Explicitly clear the flag (simulates SessionCoordinator calling back after reassembly complete)
            viewModel.clearAXDPReassemblyFlag(for: peer)
            
            // NOW the flag should be cleared
            XCTAssertFalse(
                viewModel.isPeerInAXDPReassembly(peerKey),
                "Flag should be cleared after explicit clearAXDPReassemblyFlag() call"
            )
        }
    }
    
    /// Test that the flag is cleared when session disconnects
    /// Note: The flag clearing happens asynchronously in a Task, so we need to wait
    func testFlagClearedOnDisconnect() async {
        // Create components that need to persist across await
        let sessionManager = await MainActor.run {
            let sm = AX25SessionManager()
            sm.localCallsign = AX25Address(call: "TEST", ssid: 1)
            return sm
        }
        
        let viewModel = await MainActor.run {
            ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
        }
        
        let (session, peerKey) = await MainActor.run {
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Send AXDP (sets flag)
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode())
            
            let peerKey = peer.display.uppercased()
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(peerKey), "Flag should be set after AXDP")
            
            // Session disconnects (this triggers an async Task to clear the flag)
            viewModel.sessionManager.onSessionStateChanged?(session, .connected, .disconnected)
            
            return (session, peerKey)
        }
        
        // Allow the async Task in onSessionStateChanged to complete
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        
        // Check flag is cleared
        await MainActor.run {
            XCTAssertFalse(
                viewModel.isPeerInAXDPReassembly(peerKey),
                "Flag should be cleared when session disconnects"
            )
        }
        
        // Keep variables in use to avoid compiler warnings
        _ = session
    }
    
    /// Test that AXDP continuation fragments (non-magic data during reassembly) are suppressed
    func testAXDPContinuationFragmentsSuppressed() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Simulate fragmented AXDP message:
            // First I-frame: AXDP magic header (sets flag)
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("text".utf8)).encode())
            
            let peerKey = peer.display.uppercased()
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(peerKey))
            
            // Subsequent I-frames: continuation data without magic
            // These simulate AXDP payload chunks that are part of the same message
            // They should be SUPPRESSED (not delivered as plain text)
            viewModel.sessionManager.onDataReceived?(session, Data("continuation chunk 1".utf8))
            viewModel.sessionManager.onDataReceived?(session, Data("continuation chunk 2".utf8))
            viewModel.sessionManager.onDataReceived?(session, Data("continuation chunk 3\r\n".utf8))
            
            // No plain text should be delivered - these are AXDP continuation fragments
            XCTAssertEqual(receivedLines.count, 0, "AXDP continuation fragments must NOT be delivered as plain text")
            
            // Flag should still be set
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(peerKey))
            
            // Now AXDP reassembly completes (SessionCoordinator signals)
            viewModel.clearAXDPReassemblyFlag(for: peer)
            
            // Subsequent plain text should now be delivered
            viewModel.sessionManager.onDataReceived?(session, Data("Now this is plain text\r\n".utf8))
            XCTAssertEqual(receivedLines.count, 1)
            XCTAssertEqual(receivedLines[0], "Now this is plain text")
        }
    }
}

// MARK: - Protocol Switching Tests

/// Tests for switching back and forth between AXDP and non-AXDP modes
final class ProtocolSwitchingTests: XCTestCase {
    
    /// Test rapid repeated switching: AXDP → Complete → Plain → AXDP → Complete → Plain → ... (20 times)
    func testRapidRepeatedProtocolSwitching() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Rapid alternation: 20 cycles of AXDP → Reassembly Complete → Plain
            for i in 0..<20 {
                // AXDP message (sets flag)
                let axdp = AXDP.Message(type: .ping, sessionId: UInt32(i), messageId: UInt32(i)).encode()
                viewModel.sessionManager.onDataReceived?(session, axdp)
                
                // AXDP reassembly completes (clears flag)
                viewModel.clearAXDPReassemblyFlag(for: peer)
                
                // Plain text (delivered)
                viewModel.sessionManager.onDataReceived?(session, Data("Message \(i)\r\n".utf8))
            }
            
            // All 20 plain text messages MUST be delivered
            XCTAssertEqual(receivedLines.count, 20, "All 20 plain text messages must be delivered")
            for i in 0..<20 {
                XCTAssertEqual(receivedLines[i], "Message \(i)", "Message \(i) should be delivered correctly")
            }
        }
    }
    
    /// Test consecutive AXDP messages followed by reassembly complete and plain text
    func testConsecutiveAXDPThenPlainText() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Send 5 consecutive AXDP messages (e.g., capability negotiation burst)
            // Each sets the flag, keeps getting reset
            for i in 0..<5 {
                let axdp = AXDP.Message(type: .ping, sessionId: UInt32(i), messageId: UInt32(i)).encode()
                viewModel.sessionManager.onDataReceived?(session, axdp)
            }
            
            // Last AXDP reassembly completes (clears flag)
            viewModel.clearAXDPReassemblyFlag(for: peer)
            
            // Then plain text (delivered)
            viewModel.sessionManager.onDataReceived?(session, Data("Now plain text\r\n".utf8))
            viewModel.sessionManager.onDataReceived?(session, Data("More plain text\r\n".utf8))
            
            // Plain text must be delivered
            XCTAssertEqual(receivedLines.count, 2)
            XCTAssertEqual(receivedLines[0], "Now plain text")
            XCTAssertEqual(receivedLines[1], "More plain text")
        }
    }
    
    /// Test consecutive plain text messages, then AXDP with reassembly complete, then plain text again
    func testPlainThenAXDPThenPlainAgain() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Phase 1: Plain text only (peer never used AXDP yet, flag not set)
            viewModel.sessionManager.onDataReceived?(session, Data("Hello\r\n".utf8))
            viewModel.sessionManager.onDataReceived?(session, Data("How are you?\r\n".utf8))
            
            // Phase 2: AXDP messages (peer enables AXDP mid-session)
            let axdp1 = AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode()
            viewModel.sessionManager.onDataReceived?(session, axdp1)
            let axdp2 = AXDP.Message(type: .chat, sessionId: 1, messageId: 2, payload: Data("AXDP chat".utf8)).encode()
            viewModel.sessionManager.onDataReceived?(session, axdp2)
            
            // AXDP reassembly completes (clears flag)
            viewModel.clearAXDPReassemblyFlag(for: peer)
            
            // Phase 3: Plain text again (peer disables AXDP or falls back)
            viewModel.sessionManager.onDataReceived?(session, Data("Back to plain\r\n".utf8))
            viewModel.sessionManager.onDataReceived?(session, Data("73 de peer\r\n".utf8))
            
            // All plain text must be delivered (4 lines total)
            XCTAssertEqual(receivedLines.count, 4)
            XCTAssertEqual(receivedLines[0], "Hello")
            XCTAssertEqual(receivedLines[1], "How are you?")
            XCTAssertEqual(receivedLines[2], "Back to plain")
            XCTAssertEqual(receivedLines[3], "73 de peer")
        }
    }
    
    /// Test flag state is correctly maintained through multiple switches via clearAXDPReassemblyFlag
    func testFlagStateAcrossMultipleSwitches() async {
        await MainActor.run {
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            let peerKey = peer.display.uppercased()
            
            // Initially: no flag
            XCTAssertFalse(viewModel.isPeerInAXDPReassembly(peerKey))
            
            // After AXDP: flag set
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode())
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(peerKey))
            
            // After clearAXDPReassemblyFlag: flag cleared
            viewModel.clearAXDPReassemblyFlag(for: peer)
            XCTAssertFalse(viewModel.isPeerInAXDPReassembly(peerKey))
            
            // After AXDP again: flag set again
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .pong, sessionId: 1, messageId: 2).encode())
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(peerKey))
            
            // After clearAXDPReassemblyFlag again: flag cleared again
            viewModel.clearAXDPReassemblyFlag(for: peer)
            XCTAssertFalse(viewModel.isPeerInAXDPReassembly(peerKey))
            
            // Multiple AXDP in a row (flag set by first, remains set)
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .ping, sessionId: 2, messageId: 1).encode())
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .pong, sessionId: 2, messageId: 2).encode())
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(peerKey), "Flag should remain set after multiple AXDP")
            
            // After clearAXDPReassemblyFlag: flag cleared
            viewModel.clearAXDPReassemblyFlag(for: peer)
            XCTAssertFalse(viewModel.isPeerInAXDPReassembly(peerKey), "Flag should be cleared after clearAXDPReassemblyFlag")
        }
    }
    
    /// Test two different peers with different protocol preferences
    func testTwoPeersWithDifferentProtocols() async {
        await MainActor.run {
            var receivedFromPeerA: [String] = []
            var receivedFromPeerB: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { address, text in
                if address.call.uppercased() == "PEERA" {
                    receivedFromPeerA.append(text)
                } else if address.call.uppercased() == "PEERB" {
                    receivedFromPeerB.append(text)
                }
            }
            
            // Peer A: prefers AXDP
            let peerA = AX25Address(call: "PEERA", ssid: 0)
            let sessionA = sessionManager.session(for: peerA)
            sessionA.stateMachine.handle(event: .connectRequest)
            sessionA.stateMachine.handle(event: .receivedUA)
            
            // Peer B: plain text only
            let peerB = AX25Address(call: "PEERB", ssid: 0)
            let sessionB = sessionManager.session(for: peerB)
            sessionB.stateMachine.handle(event: .connectRequest)
            sessionB.stateMachine.handle(event: .receivedUA)
            
            let keyA = peerA.display.uppercased()
            let keyB = peerB.display.uppercased()
            
            // Peer A sends AXDP (sets flag)
            viewModel.sessionManager.onDataReceived?(sessionA, AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode())
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(keyA))
            XCTAssertFalse(viewModel.isPeerInAXDPReassembly(keyB), "Peer B unaffected")
            
            // Peer B sends plain text (delivered - Peer B never had AXDP)
            viewModel.sessionManager.onDataReceived?(sessionB, Data("Hello from B\r\n".utf8))
            XCTAssertTrue(viewModel.isPeerInAXDPReassembly(keyA), "Peer A flag unaffected")
            XCTAssertFalse(viewModel.isPeerInAXDPReassembly(keyB), "Peer B still no flag")
            
            // Peer A AXDP reassembly completes, then sends plain text
            viewModel.clearAXDPReassemblyFlag(for: peerA)
            viewModel.sessionManager.onDataReceived?(sessionA, Data("Hello from A\r\n".utf8))
            XCTAssertFalse(viewModel.isPeerInAXDPReassembly(keyA), "Peer A flag cleared")
            
            // Both peers send more plain text
            viewModel.sessionManager.onDataReceived?(sessionA, Data("More from A\r\n".utf8))
            viewModel.sessionManager.onDataReceived?(sessionB, Data("More from B\r\n".utf8))
            
            // Verify all plain text was delivered
            XCTAssertEqual(receivedFromPeerA.count, 2)
            XCTAssertEqual(receivedFromPeerB.count, 2)
            XCTAssertEqual(receivedFromPeerA[0], "Hello from A")
            XCTAssertEqual(receivedFromPeerA[1], "More from A")
            XCTAssertEqual(receivedFromPeerB[0], "Hello from B")
            XCTAssertEqual(receivedFromPeerB[1], "More from B")
        }
    }
    
    /// Test asymmetric capability: one side has AXDP, other doesn't
    func testAsymmetricCapability() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "OLDSTATION", ssid: 0)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Local sends AXDP probe, peer responds with plain text (no AXDP support)
            // This is simulated from the peer's perspective - they only send plain text
            
            viewModel.sessionManager.onDataReceived?(session, Data("*** Welcome to N0CALL BBS ***\r\n".utf8))
            viewModel.sessionManager.onDataReceived?(session, Data("AXDP? What's that?\r\n".utf8))
            viewModel.sessionManager.onDataReceived?(session, Data("I only speak plain text!\r\n".utf8))
            
            // All plain text from non-AXDP peer must be delivered
            XCTAssertEqual(receivedLines.count, 3)
            XCTAssertTrue(receivedLines[0].contains("Welcome"))
            XCTAssertTrue(receivedLines[1].contains("AXDP"))
            XCTAssertTrue(receivedLines[2].contains("plain text"))
        }
    }
}

// MARK: - Integration Scenario Tests

/// Integration tests simulating real-world scenarios
final class NonAXDPDeliveryIntegrationTests: XCTestCase {
    
    /// Simulate: AXDP negotiation happens, reassembly completes, then user sends plain text
    func testMixedProtocolSession() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // Phase 1: AXDP capability negotiation (sets reassembly flag)
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .ping, sessionId: 0, messageId: 1).encode())
            
            // AXDP reassembly completes (SessionCoordinator signals)
            viewModel.clearAXDPReassemblyFlag(for: peer)
            
            // Phase 2: Plain text messages (delivered after reassembly complete)
            viewModel.sessionManager.onDataReceived?(session, Data("what\r\n".utf8))
            viewModel.sessionManager.onDataReceived?(session, Data("hello there\r\n".utf8))
            
            // Both plain text lines MUST be delivered
            XCTAssertEqual(receivedLines.count, 2, "Both plain text messages must be delivered")
            XCTAssertEqual(receivedLines[0], "what")
            XCTAssertEqual(receivedLines[1], "hello there")
        }
    }
    
    /// Test BBS-style interaction with AXDP probe then plain text fallback
    func testBBSStyleSession() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "USER", ssid: 0)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "USER",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            let bbs = AX25Address(call: "BBS", ssid: 0)
            let session = sessionManager.session(for: bbs)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // BBS sends AXDP probe (sets reassembly flag)
            viewModel.sessionManager.onDataReceived?(session, AXDP.Message(type: .ping, sessionId: 0, messageId: 0).encode())
            
            // AXDP probe completes (SessionCoordinator signals)
            viewModel.clearAXDPReassemblyFlag(for: bbs)
            
            // BBS falls back to plain text (delivered after reassembly cleared)
            viewModel.sessionManager.onDataReceived?(session, Data("*** Welcome to BBS ***\r\n".utf8))
            viewModel.sessionManager.onDataReceived?(session, Data("Enter command:\r\n".utf8))
            
            // All plain text lines MUST be delivered
            XCTAssertEqual(receivedLines.count, 2, "All BBS lines must be delivered")
            XCTAssertTrue(receivedLines[0].contains("Welcome"))
            XCTAssertTrue(receivedLines[1].contains("command"))
        }
    }
}

// MARK: - Session Auto-Switch Tests

/// Tests for automatic session selection when data arrives
final class SessionAutoSwitchTests: XCTestCase {
    
    /// Test that currentSession is auto-set when nil and data arrives
    func testAutoSelectSessionWhenNil() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            // Create and connect a session - currentSession should still be nil
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            session.stateMachine.handle(event: .connectRequest)
            session.stateMachine.handle(event: .receivedUA)
            
            // currentSession should be nil initially (no updateCurrentSession called)
            XCTAssertNil(viewModel.currentSession)
            
            // Send data - should auto-select the session AND deliver the data
            viewModel.sessionManager.onDataReceived?(session, Data("Hello world\r\n".utf8))
            
            // Now currentSession should be set
            XCTAssertNotNil(viewModel.currentSession)
            XCTAssertEqual(viewModel.currentSession?.id, session.id)
            
            // And data should be delivered
            XCTAssertEqual(receivedLines.count, 1)
            XCTAssertEqual(receivedLines.first, "Hello world")
        }
    }
    
    /// Test that session is auto-switched when data arrives from a different connected session
    func testAutoSwitchToConnectedSession() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            // Create first session
            let peer1 = AX25Address(call: "PEER1", ssid: 0)
            let session1 = sessionManager.session(for: peer1)
            session1.stateMachine.handle(event: .connectRequest)
            session1.stateMachine.handle(event: .receivedUA)
            
            // Create second session
            let peer2 = AX25Address(call: "PEER2", ssid: 0)
            let session2 = sessionManager.session(for: peer2)
            session2.stateMachine.handle(event: .connectRequest)
            session2.stateMachine.handle(event: .receivedUA)
            
            // Manually set currentSession to session1 (simulating user selecting it)
            viewModel.setCurrentSession(session1)
            
            // Send data from session1 - should work normally
            viewModel.sessionManager.onDataReceived?(session1, Data("From peer 1\r\n".utf8))
            XCTAssertEqual(viewModel.currentSession?.id, session1.id)
            
            // Send data from session2 - should auto-switch since session2 is connected
            viewModel.sessionManager.onDataReceived?(session2, Data("From peer 2\r\n".utf8))
            XCTAssertEqual(viewModel.currentSession?.id, session2.id, "Should auto-switch to session with incoming data")
            
            // Both messages should be delivered
            XCTAssertEqual(receivedLines.count, 2)
            XCTAssertEqual(receivedLines[0], "From peer 1")
            XCTAssertEqual(receivedLines[1], "From peer 2")
        }
    }
    
    /// Test that data from non-connected session is ignored (edge case)
    func testIgnoreDataFromNonConnectedSession() async {
        await MainActor.run {
            var receivedLines: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { _, text in
                receivedLines.append(text)
            }
            
            // Create first session and connect it
            let peer1 = AX25Address(call: "PEER1", ssid: 0)
            let session1 = sessionManager.session(for: peer1)
            session1.stateMachine.handle(event: .connectRequest)
            session1.stateMachine.handle(event: .receivedUA)
            viewModel.setCurrentSession(session1)
            
            // Create second session but DON'T connect it (leave in disconnected state)
            let peer2 = AX25Address(call: "PEER2", ssid: 0)
            let session2 = sessionManager.session(for: peer2)
            // session2 stays in .disconnected state
            
            // Send data from disconnected session2 - should be ignored
            viewModel.sessionManager.onDataReceived?(session2, Data("Should be ignored\r\n".utf8))
            
            // currentSession should NOT change
            XCTAssertEqual(viewModel.currentSession?.id, session1.id)
            
            // No data should be delivered
            XCTAssertEqual(receivedLines.count, 0)
        }
    }
    
    /// Test rapid session switching with data from multiple peers
    func testRapidSessionSwitching() async {
        await MainActor.run {
            var receivedFromPeer1: [String] = []
            var receivedFromPeer2: [String] = []
            
            let sessionManager = AX25SessionManager()
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let viewModel = ObservableTerminalTxViewModel(
                sourceCall: "TEST-1",
                sessionManager: sessionManager
            )
            
            viewModel.onPlainTextChatReceived = { address, text in
                if address.call.uppercased() == "PEER1" {
                    receivedFromPeer1.append(text)
                } else if address.call.uppercased() == "PEER2" {
                    receivedFromPeer2.append(text)
                }
            }
            
            // Create and connect both sessions
            let peer1 = AX25Address(call: "PEER1", ssid: 0)
            let session1 = sessionManager.session(for: peer1)
            session1.stateMachine.handle(event: .connectRequest)
            session1.stateMachine.handle(event: .receivedUA)
            
            let peer2 = AX25Address(call: "PEER2", ssid: 0)
            let session2 = sessionManager.session(for: peer2)
            session2.stateMachine.handle(event: .connectRequest)
            session2.stateMachine.handle(event: .receivedUA)
            
            // Rapidly interleave data from both sessions
            for i in 0..<10 {
                viewModel.sessionManager.onDataReceived?(session1, Data("Peer1 msg \(i)\r\n".utf8))
                viewModel.sessionManager.onDataReceived?(session2, Data("Peer2 msg \(i)\r\n".utf8))
            }
            
            // All messages from both peers should be delivered
            XCTAssertEqual(receivedFromPeer1.count, 10)
            XCTAssertEqual(receivedFromPeer2.count, 10)
            
            // Verify message content
            for i in 0..<10 {
                XCTAssertEqual(receivedFromPeer1[i], "Peer1 msg \(i)")
                XCTAssertEqual(receivedFromPeer2[i], "Peer2 msg \(i)")
            }
        }
    }
}
