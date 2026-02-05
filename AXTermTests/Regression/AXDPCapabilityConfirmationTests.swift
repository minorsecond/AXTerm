//
//  AXDPCapabilityConfirmationTests.swift
//  AXTermTests
//
//  Regression tests for AXDP capability confirmation.
//
//  BUG DESCRIPTION:
//  When the RESPONDER (non-initiator) of a session enables AXDP:
//  1. triggerCapabilityDiscoveryForConnectedInitiators() only sends PING for
//     sessions where we are the initiator.
//  2. The responder never sends PING, so they never get the peer's capability
//     confirmed.
//  3. When the responder tries to send AXDP chat, capabilityStatus is .unknown
//     and messages fall back to plain text.
//
//  Also, when peerAxdpEnabled is received from a peer, it should establish
//  that the peer supports AXDP (they just sent an AXDP message!), but currently
//  it only notifies the UI - it doesn't update the capability store.
//
//  EXPECTED BEHAVIOR:
//  1. When peerAxdpEnabled is received, capability should be implicitly confirmed
//     (or PING/PONG should be triggered).
//  2. triggerCapabilityDiscovery should work for ALL connected sessions, not
//     just those where we are the initiator.
//

import XCTest
@testable import AXTerm

// MARK: - Capability Store Tests

/// Tests for capability store behavior
final class CapabilityStoreBasicTests: XCTestCase {
    
    /// Test that capability store can be accessed
    func testCapabilityStoreExists() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            // hasConfirmedAXDPCapability should return false for unknown peer
            XCTAssertFalse(coordinator.hasConfirmedAXDPCapability(for: "UNKNOWN"))
        }
    }
    
    /// Test that capabilityStatus returns .unknown for new peers
    func testCapabilityStatusUnknownForNewPeers() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let status = coordinator.capabilityStatus(for: "NEWPEER")
            XCTAssertEqual(status, .unknown)
        }
    }
}

// MARK: - peerAxdpEnabled Capability Tests

/// Tests for capability confirmation via peerAxdpEnabled
final class PeerAxdpEnabledCapabilityTests: XCTestCase {
    
    /// After receiving peerAxdpEnabled, capability should be implicitly confirmed.
    func testPeerAxdpEnabledShouldConfirmCapability() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            // Connect the session
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            // Verify peer has NO confirmed capability initially
            XCTAssertFalse(
                coordinator.hasConfirmedAXDPCapability(for: peer.display),
                "Peer should NOT have confirmed capability before receiving AXDP"
            )
            
            // Create and process a peerAxdpEnabled message
            // This simulates the peer sending us a notification that they enabled AXDP
            let peerAxdpEnabledMessage = AXDP.Message(
                type: .peerAxdpEnabled,
                sessionId: 12345,
                messageId: 1
            )
            
            // Use the test helper which goes through the full routing logic
            // This triggers implicit capability confirmation
            coordinator.testHandleAXDPMessage(peerAxdpEnabledMessage, from: peer, path: DigiPath())
            
            // After receiving peerAxdpEnabled (any AXDP message), the peer should be
            // considered AXDP-capable because they literally just sent us an AXDP message!
            XCTAssertTrue(
                coordinator.hasConfirmedAXDPCapability(for: peer.display),
                "Peer should have confirmed AXDP capability after sending peerAxdpEnabled"
            )
            
            // Also verify it's implicitly confirmed
            XCTAssertTrue(
                coordinator.isImplicitlyConfirmedAXDP(for: peer.display),
                "Peer should be marked as implicitly confirmed"
            )
        }
    }
    
    /// Test that receiving ANY valid AXDP message should confirm capability
    func testAnyAXDPMessageShouldConfirmCapability() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            // Connect the session
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            // Verify no capability initially
            XCTAssertFalse(coordinator.hasConfirmedAXDPCapability(for: peer.display))
            
            // Receive a peerAxdpDisabled message (proves they have AXDP)
            let message = AXDP.Message(
                type: .peerAxdpDisabled,
                sessionId: 12345,
                messageId: 1
            )
            
            // Use the test helper which goes through the full routing logic
            coordinator.testHandleAXDPMessage(message, from: peer, path: DigiPath())
            
            // Capability should be confirmed after receiving ANY AXDP message
            XCTAssertTrue(
                coordinator.hasConfirmedAXDPCapability(for: peer.display),
                "Peer capability should be confirmed after receiving any AXDP message"
            )
        }
    }
}

// MARK: - Responder Capability Discovery Tests

/// Tests for capability discovery from the responder's perspective
final class ResponderCapabilityDiscoveryTests: XCTestCase {
    
    /// Test that responder (non-initiator) can trigger capability discovery using the new method
    func testResponderCanTriggerCapabilityDiscovery() async {
        await MainActor.run {
            var pingSentTo: [String] = []
            
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            let localAddress = AX25Address(call: "RESPONDER", ssid: 1)
            sessionManager.localCallsign = localAddress
            
            // Enable AXDP for capability discovery
            coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
            coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
            
            // Track when PING is sent
            coordinator.onCapabilityEvent = { event in
                if event.type == .pingSent {
                    pingSentTo.append(event.peer)
                }
            }
            
            // Properly simulate incoming SABM (creates session with isInitiator: false)
            let initiatorAddress = AX25Address(call: "INITIATOR", ssid: 1)
            _ = sessionManager.handleInboundSABM(
                from: initiatorAddress,
                to: localAddress,
                path: DigiPath(),
                channel: 0
            )
            
            // Get the created session
            guard let session = sessionManager.sessions.values.first(where: {
                $0.remoteAddress.display == initiatorAddress.display
            }) else {
                XCTFail("Session should have been created")
                return
            }
            
            // Session should now be connected, and we are NOT the initiator
            XCTAssertEqual(session.state, .connected)
            XCTAssertFalse(session.isInitiator, "We should NOT be the initiator (we responded to SABM)")
            
            // Use the new method that works for ALL connected sessions
            // (not just sessions where we're the initiator)
            coordinator.triggerCapabilityDiscoveryForAllConnected()
            
            // PING should now be sent even though we're the responder
            XCTAssertTrue(
                pingSentTo.contains("INITIATOR-1"),
                "PING should be sent even when we are the responder"
            )
        }
    }
    
    /// Test that the old initiator-only method still only sends to initiator sessions
    func testInitiatorOnlyMethodDoesNotSendForResponder() async {
        await MainActor.run {
            var pingSentTo: [String] = []
            
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            let localAddress = AX25Address(call: "RESPONDER", ssid: 1)
            sessionManager.localCallsign = localAddress
            
            // Enable AXDP for capability discovery
            coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
            coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
            
            // Track when PING is sent
            coordinator.onCapabilityEvent = { event in
                if event.type == .pingSent {
                    pingSentTo.append(event.peer)
                }
            }
            
            // Properly simulate incoming SABM (creates session with isInitiator: false)
            let initiatorAddress = AX25Address(call: "INITIATOR", ssid: 1)
            _ = sessionManager.handleInboundSABM(
                from: initiatorAddress,
                to: localAddress,
                path: DigiPath(),
                channel: 0
            )
            
            // Get the created session
            guard let session = sessionManager.sessions.values.first(where: {
                $0.remoteAddress.display == initiatorAddress.display
            }) else {
                XCTFail("Session should have been created")
                return
            }
            
            XCTAssertFalse(session.isInitiator)
            
            // Old method should NOT send PING for responder sessions
            coordinator.triggerCapabilityDiscoveryForConnectedInitiators()
            
            XCTAssertFalse(
                pingSentTo.contains("INITIATOR-1"),
                "Initiator-only method should NOT send PING when we are responder"
            )
        }
    }
    
    /// Test that initiator correctly sends PING on connection
    func testInitiatorSendsPINGOnConnection() async {
        await MainActor.run {
            var pingSentTo: [String] = []
            
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "INITIATOR", ssid: 1)
            
            // Enable AXDP and auto-negotiate
            coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
            coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
            
            // Track when PING is sent
            coordinator.onCapabilityEvent = { event in
                if event.type == .pingSent {
                    pingSentTo.append(event.peer)
                }
            }
            
            let responder = AX25Address(call: "RESPONDER", ssid: 1)
            let session = sessionManager.session(for: responder)
            
            // We initiate the connection: send SABM, receive UA
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            XCTAssertEqual(session.state, .connected)
            XCTAssertTrue(session.isInitiator, "We should be the initiator (we sent SABM)")
            
            // Trigger capability discovery
            coordinator.triggerCapabilityDiscoveryForConnectedInitiators()
            
            // PING should be sent for initiator sessions
            XCTAssertTrue(
                pingSentTo.contains("RESPONDER-1"),
                "PING should be sent when we are the initiator"
            )
        }
    }
}

// MARK: - Capability Status After PING/PONG Tests

/// Tests for capability status after PING/PONG exchange
final class CapabilityStatusAfterNegotiationTests: XCTestCase {
    
    /// Test that receiving PING sets capability (even without full PONG exchange)
    func testReceivingPINGSetsCapability() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            // Connect session
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            // No capability initially
            XCTAssertFalse(coordinator.hasConfirmedAXDPCapability(for: peer.display))
            
            // Receive PING from peer (they initiated capability discovery)
            let pingMessage = AXDP.Message(
                type: .ping,
                sessionId: 12345,
                messageId: 1,
                capabilities: AXDPCapability.defaultLocal()
            )
            
            // Use the test helper which goes through the full routing logic
            coordinator.testHandleAXDPMessage(pingMessage, from: peer, path: DigiPath())
            
            // After receiving PING, capability should be confirmed
            // (PING proves they support AXDP, and the message routing marks implicit confirmation)
            XCTAssertTrue(
                coordinator.hasConfirmedAXDPCapability(for: peer.display),
                "Capability should be confirmed after receiving PING"
            )
        }
    }
    
    /// Test that receiving PONG sets capability
    func testReceivingPONGSetsCapability() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            // Connect session
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            // No capability initially
            XCTAssertFalse(coordinator.hasConfirmedAXDPCapability(for: peer.display))
            
            // Receive PONG from peer (response to our PING)
            let pongMessage = AXDP.Message(
                type: .pong,
                sessionId: 12345,
                messageId: 1,
                capabilities: AXDPCapability.defaultLocal()
            )
            
            // Use the test helper which goes through the full routing logic
            coordinator.testHandleAXDPMessage(pongMessage, from: peer, path: DigiPath())
            
            // After receiving PONG, capability should be confirmed
            XCTAssertTrue(
                coordinator.hasConfirmedAXDPCapability(for: peer.display),
                "Capability should be confirmed after receiving PONG"
            )
        }
    }
}

// MARK: - Send Path Capability Check Tests

/// Tests for verifying that the send path correctly checks capability
final class SendPathCapabilityCheckTests: XCTestCase {
    
    /// Test that capabilityStatus returns .confirmed after receiving PING
    func testCapabilityStatusConfirmedAfterPING() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            // Connect session
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            // Initially unknown
            XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .unknown)
            
            // Receive PING
            let pingMessage = AXDP.Message(
                type: .ping,
                sessionId: 12345,
                messageId: 1,
                capabilities: AXDPCapability.defaultLocal()
            )
            // Use the test helper which goes through the full routing logic
            coordinator.testHandleAXDPMessage(pingMessage, from: peer, path: DigiPath())
            
            // Now should be confirmed
            XCTAssertEqual(
                coordinator.capabilityStatus(for: peer.display),
                .confirmed,
                "capabilityStatus should return .confirmed after receiving PING"
            )
        }
    }
    
    /// Test that capabilityStatus returns .confirmed after receiving peerAxdpEnabled
    func testCapabilityStatusConfirmedAfterPeerAxdpEnabled() async {
        await MainActor.run {
            let coordinator = SessionCoordinator()
            let sessionManager = coordinator.sessionManager
            sessionManager.localCallsign = AX25Address(call: "TEST", ssid: 1)
            
            let peer = AX25Address(call: "PEER", ssid: 1)
            let session = sessionManager.session(for: peer)
            
            // Connect session
            _ = session.stateMachine.handle(event: .connectRequest)
            _ = session.stateMachine.handle(event: .receivedUA)
            
            // Initially unknown
            XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .unknown)
            
            // Receive peerAxdpEnabled (peer turned on their AXDP toggle)
            let message = AXDP.Message(
                type: .peerAxdpEnabled,
                sessionId: 12345,
                messageId: 1
            )
            // Use the test helper which goes through the full routing logic
            coordinator.testHandleAXDPMessage(message, from: peer, path: DigiPath())
            
            // Should be confirmed because they sent an AXDP message
            // (implicit capability confirmation via message receipt)
            XCTAssertEqual(
                coordinator.capabilityStatus(for: peer.display),
                .confirmed,
                "capabilityStatus should return .confirmed after receiving peerAxdpEnabled"
            )
        }
    }
}

// MARK: - Bidirectional Capability Tests

/// Tests for bidirectional capability confirmation
final class BidirectionalCapabilityTests: XCTestCase {
    
    /// Test that both sides of a session can have confirmed capability
    func testBothSidesCanHaveConfirmedCapability() async {
        await MainActor.run {
            // Station A (initiator)
            let coordinatorA = SessionCoordinator()
            let sessionManagerA = coordinatorA.sessionManager
            let localA = AX25Address(call: "STATIONA", ssid: 1)
            sessionManagerA.localCallsign = localA
            
            let peerB = AX25Address(call: "STATIONB", ssid: 1)
            let sessionAtoB = sessionManagerA.session(for: peerB)
            
            // A initiates connection (send SABM, receive UA)
            _ = sessionAtoB.stateMachine.handle(event: .connectRequest)
            _ = sessionAtoB.stateMachine.handle(event: .receivedUA)
            XCTAssertTrue(sessionAtoB.isInitiator)
            XCTAssertEqual(sessionAtoB.state, .connected)
            
            // A receives PONG from B (after A sent PING)
            let pongFromB = AXDP.Message(
                type: .pong,
                sessionId: 12345,
                messageId: 1,
                capabilities: AXDPCapability.defaultLocal()
            )
            // Use the test helper which goes through the full routing logic
            coordinatorA.testHandleAXDPMessage(pongFromB, from: peerB, path: DigiPath())
            
            // A should have confirmed capability for B
            XCTAssertTrue(
                coordinatorA.hasConfirmedAXDPCapability(for: peerB.display),
                "Station A should have confirmed capability for Station B"
            )
            
            // Station B (responder)
            let coordinatorB = SessionCoordinator()
            let sessionManagerB = coordinatorB.sessionManager
            let localB = AX25Address(call: "STATIONB", ssid: 1)
            sessionManagerB.localCallsign = localB
            
            let peerA = AX25Address(call: "STATIONA", ssid: 1)
            
            // B receives SABM from A (proper way to become responder)
            _ = sessionManagerB.handleInboundSABM(
                from: peerA,
                to: localB,
                path: DigiPath(),
                channel: 0
            )
            
            // Get the created session
            guard let sessionBtoA = sessionManagerB.sessions.values.first(where: {
                $0.remoteAddress.display == peerA.display
            }) else {
                XCTFail("Session should have been created for B")
                return
            }
            
            XCTAssertFalse(sessionBtoA.isInitiator, "B should NOT be initiator (responded to SABM)")
            XCTAssertEqual(sessionBtoA.state, .connected)
            
            // B receives PING from A
            let pingFromA = AXDP.Message(
                type: .ping,
                sessionId: 12345,
                messageId: 1,
                capabilities: AXDPCapability.defaultLocal()
            )
            // Use the test helper which goes through the full routing logic
            coordinatorB.testHandleAXDPMessage(pingFromA, from: peerA, path: DigiPath())
            
            // B should have confirmed capability for A (from the PING)
            XCTAssertTrue(
                coordinatorB.hasConfirmedAXDPCapability(for: peerA.display),
                "Station B (responder) should have confirmed capability for Station A after receiving PING"
            )
        }
    }
}
