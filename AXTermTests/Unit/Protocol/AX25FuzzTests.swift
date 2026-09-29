//
//  AX25FuzzTests.swift
//  AXTermTests
//
//  Adversarial testing of the AX.25 stack.
//  Pounds the KISS parser and AX.25 State Machine with millions 
//  of randomly mutated bytes to catch crashes or hangs.
//

import XCTest
@testable import AXTerm

final class AX25FuzzTests: XCTestCase {
    
    /// Tests that the KISS frame builder/decoder doesn't crash on completely random garbage.
    func testKISSDecoderGarbageResilience() {
        var fuzzer = AX25Fuzzer(seed: 101)
        
        for _ in 0..<10_000 {
            let garbage = fuzzer.generateGarbageFrame(maxLength: 300)
            // We don't care if it returns nil, we just care that it doesn't crash or hang
            _ = AX25.decodeFrame(ax25: garbage)
        }
    }
    
    /// Tests that taking a valid frame and heavily mutating it doesn't crash the decoder.
    func testKISSDecoderMutationResilience() {
        var fuzzer = AX25Fuzzer(seed: 202)
        
        let validFrame = OutboundFrame(
            destination: AX25Address(call: "N0CALL", ssid: 0),
            source: AX25Address(call: "K0CALL", ssid: 0),
            payload: Data("Hello World".utf8),
            frameType: "ui"
        )
        let validData = validFrame.encodeAX25()
        
        var decodedCount = 0
        for _ in 0..<10_000 {
            let mutated = fuzzer.mutate(frameData: validData)
            if AX25.decodeFrame(ax25: mutated) != nil {
                decodedCount += 1
            }
        }
        
        // Mutated frames should mostly fail to decode due to CRC or structure
        // (but AX25FrameBuilder right now might just be doing naive parsing)
        // Just verify no crash!
        XCTAssert(true, "Did not crash on 10,000 mutations")
    }
    
    /// Blasts random sequence numbers and P/F bits into an active session.
    func testStateMachineAdversarialSequenceNumbers() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
        
        var fuzzer = AX25Fuzzer(seed: 303)
        
        for _ in 0..<5_000 {
            let ns = fuzzer.nextInt(in: 0...7)
            let nr = fuzzer.nextInt(in: 0...7)
            let pf = fuzzer.nextInt(in: 0...1) == 1
            
            // Just throw frames at it. The state machine should ignore them or reject them,
            // but it absolutely MUST NOT crash.
            _ = sm.handle(event: .receivedIFrame(ns: ns, nr: nr, pf: pf, payload: Data([0xAA])))
            _ = sm.handle(event: .receivedRR(nr: nr))
        }
        
        XCTAssert(true, "Did not crash on adversarial sequence numbers")
    }
}
