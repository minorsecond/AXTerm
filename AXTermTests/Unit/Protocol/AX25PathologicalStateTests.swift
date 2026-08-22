//
//  AX25PathologicalStateTests.swift
//  AXTermTests
//
//  Tests focusing on protocol edge cases, race conditions, 
//  sequence numbering exhaustion, and simultaneous collisions.
//

import XCTest
@testable import AXTerm

final class AX25PathologicalStateTests: XCTestCase {
    
    // MARK: - Collision Tests
    
    /// Tests simultaneous connection requests where both sides send SABM at the same time.
    /// According to AX.25 v2.2 spec §6.3.3:
    /// "If a SABM command is received while in the Connecting State, a UA response
    /// is sent and the state changes to Connected."
    func testSimultaneousSABMCollision() {
        var smA = AX25StateMachine(config: AX25SessionConfig())
        var smB = AX25StateMachine(config: AX25SessionConfig())
        
        let reqA = smA.handle(event: .connectRequest)
        let reqB = smB.handle(event: .connectRequest)
        
        XCTAssertEqual(smA.state, .connecting)
        XCTAssertEqual(smB.state, .connecting)
        XCTAssertTrue(reqA.contains(.sendSABM))
        XCTAssertTrue(reqB.contains(.sendSABM))
        
        // Node A receives Node B's SABM while connecting
        let collA = smA.handle(event: .receivedSABM)
        XCTAssertEqual(smA.state, .connected, "Node A should transition to connected on SABM collision")
        XCTAssertTrue(collA.contains(.sendUA), "Node A must respond with UA")
        
        // Node B receives Node A's SABM while connecting
        let collB = smB.handle(event: .receivedSABM)
        XCTAssertEqual(smB.state, .connected, "Node B should transition to connected on SABM collision")
        XCTAssertTrue(collB.contains(.sendUA), "Node B must respond with UA")
        
        // They both receive each other's UA
        let finalA = smA.handle(event: .receivedUA)
        let finalB = smB.handle(event: .receivedUA)
        
        // They should remain connected and happy
        XCTAssertEqual(smA.state, .connected)
        XCTAssertEqual(smB.state, .connected)
    }
    
    /// Tests a disconnection collision (both send DISC simultaneously).
    /// SDL C4.3: Received DISC while awaiting release -> send DM -> Disconnected.
    /// §6.3.4: the peer accepts UA or DM as the answer to its DISC.
    func testSimultaneousDISCCollision() {
        var smA = AX25StateMachine(config: AX25SessionConfig())
        _ = smA.handle(event: .connectRequest)
        _ = smA.handle(event: .receivedUA)
        
        var smB = AX25StateMachine(config: AX25SessionConfig())
        _ = smB.handle(event: .connectRequest)
        _ = smB.handle(event: .receivedUA)
        
        // Both request disconnect
        let discA = smA.handle(event: .disconnectRequest)
        let discB = smB.handle(event: .disconnectRequest)
        
        XCTAssertEqual(smA.state, .disconnecting)
        XCTAssertEqual(smB.state, .disconnecting)
        XCTAssertTrue(discA.contains(.sendDISC))
        XCTAssertTrue(discB.contains(.sendDISC))
        
        // Cross-receive DISCs
        let collA = smA.handle(event: .receivedDISC)
        let collB = smB.handle(event: .receivedDISC)
        
        XCTAssertEqual(smA.state, .disconnected)
        XCTAssertEqual(smB.state, .disconnected)
        // SDL C4.3 (awaiting release): a DISC arriving while our own DISC is
        // outstanding is answered with DM. §6.3.4 confirms the peer accepts either
        // UA or DM in reply to its DISC.
        XCTAssertTrue(collA.contains(.sendDM), "SDL C4.3: DISC collision is answered with DM")
        XCTAssertTrue(collB.contains(.sendDM), "SDL C4.3: DISC collision is answered with DM")
        XCTAssertFalse(collA.contains(.sendUA), "UA is the reply for a DISC on an established link, not during teardown")

        // They receive each other's DM (harmless in disconnected state)
        _ = smA.handle(event: .receivedDM)
        _ = smB.handle(event: .receivedDM)
        
        XCTAssertEqual(smA.state, .disconnected)
        XCTAssertEqual(smB.state, .disconnected)
    }
    
    // MARK: - Sequence Pathology Tests
    
    /// Forces a 7 -> 0 sequence wraparound and ensures V(R) and V(S) track correctly without stalling.
    func testSequenceWraparoundDuringContinuousTransfer() {
        var sm = AX25StateMachine(config: AX25SessionConfig(windowSize: 4))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        
        XCTAssertEqual(sm.sequenceState.vs, 0)
        XCTAssertEqual(sm.sequenceState.vr, 0)
        XCTAssertEqual(sm.sequenceState.va, 0)
        
        for idx in 0..<20 {
            // Send out a frame (client action)
            sm.sequenceState.incrementVS()
            
            // Receive an inbound frame (peer action)
            // Using idx modulo 8 because ns must be valid
            let ns = idx % 8
            let nr = sm.sequenceState.vs // Acknowledging what we just sent
            
            let actions = sm.handle(event: .receivedIFrame(ns: ns, nr: nr, pf: false, payload: Data("data".utf8)))
            let didDeliver = actions.contains { action in
                if case .deliverData = action { return true }
                return false
            }
            XCTAssertTrue(didDeliver, "Failed to deliver frame at idx \(idx)")
            
            XCTAssertEqual(sm.sequenceState.vr, (idx + 1) % 8)
            XCTAssertEqual(sm.sequenceState.va, nr)
        }
        
        XCTAssertEqual(sm.sequenceState.vs, 20 % 8)
        XCTAssertEqual(sm.sequenceState.vr, 20 % 8)
    }
    
    /// Simulates dropping all ACKs until the window is absolutely full, 
    /// then receiving a single cumulative ACK right before timeout.
    func testWindowSaturationAndCumulativeACK() {
        var sm = AX25StateMachine(config: AX25SessionConfig(windowSize: 7))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        
        // Fill the window completely
        for _ in 0..<7 {
            sm.sequenceState.incrementVS()
        }
        
        XCTAssertEqual(sm.sequenceState.outstandingCount, 7)
        XCTAssertFalse(sm.sequenceState.canSend(windowSize: 7), "Window should be fully blocked")
        
        // Receive a single RR acknowledging all 7 frames
        let actions = sm.handle(event: .receivedRR(nr: 7))
        
        XCTAssertEqual(sm.sequenceState.va, 7)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
        XCTAssertTrue(sm.sequenceState.canSend(windowSize: 7), "Window should be unblocked")
        XCTAssertTrue(actions.contains(.stopT1), "T1 must be stopped after full cumulative ACK")
    }
    
    // MARK: - Stale Session Recovery
    
    /// Tests a half-open state where one side reconnects before the other side realizes they disconnected.
    func testHalfOpenSessionRecoveryViaSABM() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
        
        // We are connected. The remote peer suddenly sends a SABM (because it rebooted/lost session).
        let actions = sm.handle(event: .receivedSABM)
        
        // We should immediately reset our sequence numbers and send a UA to re-establish.
        XCTAssertEqual(sm.state, .connected)
        XCTAssertTrue(actions.contains(.sendUA))
        XCTAssertEqual(sm.sequenceState.vs, 0)
        XCTAssertEqual(sm.sequenceState.vr, 0)
        XCTAssertEqual(sm.sequenceState.va, 0)
        XCTAssertTrue(sm.receiveBuffer.isEmpty, "Receive buffer should be cleared")
    }
}
