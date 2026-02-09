//
//  AX25KeepaliveTests.swift
//  AXTermTests
//
//  Tests for T3 keepalive behavior and retry count management.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25KeepaliveTests: XCTestCase {

    // MARK: - T3 Keepalive Tests

    func testT3TimeoutSendsPollAndStartsT1() {
        // Bug reproduction: T3 should send P=1 (poll), but currently sends P=0
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)

        // Trigger T3 timeout
        let actions = sm.handle(event: .t3Timeout)

        // It should start T1 to wait for response
        XCTAssertTrue(actions.contains(.startT1))

        // It SHOULD send RR with P=1 (Poll)
        XCTAssertTrue(actions.contains{
            if case .sendRR(_, let pf) = $0 { return pf }
            return false
        }, "T3 timeout must send P=1 (Poll)")
    }

    func testKeepaliveCycleIncrementsRetryCount() {
        // Bug reproduction: T3(P=0) -> T1 Timeout -> RetryCount=1.
        // Peer responds to retry (P=1) -> RetryCount NOT reset because VA didn't change.

        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // 1. T3 Timeout fires
        _ = sm.handle(event: .t3Timeout)

        // 2. T1 Timeout fires (because P=0 RR was ignored or lost)
        _ = sm.handle(event: .t1Timeout)

        XCTAssertEqual(sm.retryCount, 1, "Retry count should increment on T1 timeout")

        // 3. Peer responds with RR(F=1) - simulating response to the SECOND probe (which was P=1)
        // Or just a normal RR.
        let actions = sm.handle(event: .receivedRR(nr: 0, pf: true)) // F=1 response to our poll

        XCTAssertEqual(sm.state, .connected)

        // Retry count should be reset when we receive a valid response to our poll
        XCTAssertEqual(sm.retryCount, 0, "Retry count should be reset when peer responds to poll")
    }

    // MARK: - I-Frame Retry Tests

    func testIFrameAckResetsRetryCount() {
        // Bug reproduction: Retrying I-frame -> Peer Acks -> RetryCount should reset

        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Send an I-frame (simulated)
        // We manually advance VS/VA to simulate pending state if needed,
        // but StateMachine tracks SequenceState.
        // Let's use handle(.t1Timeout) to increment retry count directly,
        // assuming we have outstanding frames.

        // 1. Send I-Frame (vs=0 -> vs=1)
        sm.sequenceState.incrementVS() // vs=1, va=0, outstanding=1

        // 2. T1 Timeout (Retry=1)
        _ = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.retryCount, 1)

        // 3. Receive ACK (RR nr=1)
        _ = sm.handle(event: .receivedRR(nr: 1, pf: false))

        // This actually WORKS in current code because VA changes (0->1) inside handleRR
        XCTAssertEqual(sm.retryCount, 0, "Retry count SHOULD be reset when VA advances via RR")
    }

    func testIFrameAckViaPiggybackResetsRetryCount() {
        // Bug: If ACK comes via I-Frame piggyback, does it reset?

        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // 1. Send I-Frame (vs=0 -> vs=1)
        sm.sequenceState.incrementVS() // vs=1, va=0

        // 2. T1 Timeout (Retry=1)
        _ = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.retryCount, 1)

        // 3. Receive I-Frame with NR=1 (Acking our frame)
        let payload = Data([0x01])
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 1, pf: false, payload: payload))

        XCTAssertEqual(sm.sequenceState.va, 1, "VA should have advanced")

        // BUG: handleIFrame does NOT reset retryCount
        XCTAssertEqual(sm.retryCount, 0, "Retry count should be reset when VA advances via I-Frame")
    }
}
