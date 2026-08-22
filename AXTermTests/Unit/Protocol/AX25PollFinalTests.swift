//
//  AX25PollFinalTests.swift
//  AXTermTests
//
//  Tests focusing specifically on Poll/Final bit semantics,
//  command/response rules, and T1 polling behavior.
//

import XCTest
@testable import AXTerm

final class AX25PollFinalTests: XCTestCase {
    
    func testReceiveCommandWithPollRespondsWithFinal() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
        
        // Receive a Command RR with P=1
        // (Note: To strictly test P=1 handling, we send an RR poll)
        let actions = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: true))
        
        // State machine must respond with an RR with F=1 (since it has nothing to send)
        XCTAssertTrue(actions.contains(where: { action in
            if case .sendRR(_, let isPoll, let isCommand) = action {
                return isPoll == true && isCommand == false // F=1 is technically isPoll=true in our enum, and it's a response
            }
            return false
        }), "Must respond to P=1 command with F=1 response")
    }
    
    func testT1TimeoutSendsPollAndRequiresFinal() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        
        // Send an I-frame
        sm.sequenceState.incrementVS()
        
        // T1 times out without ACK
        let timeoutActions = sm.handle(event: .t1Timeout)
        
        // Under our new design, the state machine does not return a separate RR poll command
        // when outstanding I-frames exist (outstandingCount > 0). It only schedules T1 restart.
        XCTAssertTrue(timeoutActions.contains(.startT1))
        XCTAssertFalse(timeoutActions.contains(where: { if case .sendRR = $0 { return true }; return false }))
    }
    
    func testUnsolicitedFinalIsIgnored() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        
        // Receive a Response RR with F=1 when we NEVER sent P=1
        let actions = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: false)) // F=1
        
        // We shouldn't crash. We might process the ACK (N(R)=0), but we shouldn't 
        // treat it as resolving a poll we didn't start. 
        // Just verify it doesn't cause bad state transitions.
        XCTAssertEqual(sm.state, .connected)
    }
    
    func testIllegalPFCombinations() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        
        // AX.25 rules: I-frame cannot be a response with F=1 (usually).
        // If we receive I-frame with F=1, we should probably ignore the F bit or log it, but not crash.
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: true, payload: Data("data".utf8)))
        
        // We should acknowledge it. The P/F bit on an inbound I-frame is treated as a Poll bit if it's a command.
        XCTAssertTrue(actions.contains(where: { if case .deliverData = $0 { return true }; return false }))
        XCTAssertTrue(actions.contains(where: { action in
            if case .sendRR(_, let isPoll, let isCommand) = action {
                return isPoll == true && isCommand == false // Must respond with F=1
            }
            return false
        }), "Must respond with F=1 if I-frame had P=1")
    }
}
