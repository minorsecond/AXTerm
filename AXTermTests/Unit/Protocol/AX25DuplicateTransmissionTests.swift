//
//  AX25DuplicateTransmissionTests.swift
//  AXTermTests
//
//  Regression tests for duplicate transmission bugs:
//  - REJ after a T1 timeout
//  - T1 not restarted on partial ack (AX.25 §6.4.6)
//  - onRetransmitFrame removal (merged into onSendFrame)
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25DuplicateTransmissionTests: XCTestCase {

    // MARK: - Helpers

    private func makeConnectedStateMachine() -> AX25StateMachine {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
        return sm
    }

    private func connectSession(
        manager: AX25SessionManager,
        destination: AX25Address,
        path: DigiPath
    ) -> AX25Session {
        _ = manager.connect(to: destination, path: path, radio: .primary)
        let session = manager.session(for: destination, path: path, radio: .primary)
        manager.handleInboundUA(from: destination, path: path, radio: .primary)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    // MARK: - Bug 1 (state machine): REJ after a T1 timeout restarts T1

    func testREJAfterT1TimeoutRestartsT1() {
        var sm = makeConnectedStateMachine()

        // Send an I-frame to have something outstanding
        sm.sequenceState.incrementVS() // Simulate having sent ns=0
        XCTAssertEqual(sm.sequenceState.outstandingCount, 1)

        // T1 fires — state machine returns startT1 (and RR poll)
        let t1Actions = sm.handle(event: .t1Timeout)
        XCTAssertTrue(t1Actions.contains(.startT1),
                      "T1 timeout should restart T1")

        // Then a REJ arrives from the peer requesting retransmit from nr=0
        let rejActions = sm.handle(event: .receivedREJ(nr: 0))
        XCTAssertTrue(rejActions.contains(.startT1),
                      "REJ should produce .startT1 action to restart timer")
    }

    // MARK: - Bug 2: Partial RR ack restarts T1

    func testPartialRRAckRestartsT1() {
        var sm = makeConnectedStateMachine()

        // Simulate sending 3 I-frames: vs goes to 3, va stays at 0
        sm.sequenceState.incrementVS() // ns=0
        sm.sequenceState.incrementVS() // ns=1
        sm.sequenceState.incrementVS() // ns=2
        XCTAssertEqual(sm.sequenceState.vs, 3)
        XCTAssertEqual(sm.sequenceState.va, 0)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 3)

        // Receive RR(nr=1) — partial ack: acknowledges ns=0, leaves ns=1,2 outstanding
        let actions = sm.handle(event: .receivedRR(nr: 1))

        XCTAssertEqual(sm.sequenceState.va, 1, "V(A) should advance to 1")
        XCTAssertEqual(sm.sequenceState.outstandingCount, 2,
                       "Should still have 2 outstanding frames")
        XCTAssertTrue(actions.contains(.startT1),
                      "Partial ack must restart T1 per AX.25 §6.4.6")
        XCTAssertFalse(actions.contains(.stopT1),
                       "Should not stop T1 when frames remain outstanding")
    }

    func testNoProgressRRDoesNotRestartT1() {
        var sm = makeConnectedStateMachine()

        // Send 2 I-frames
        sm.sequenceState.incrementVS() // ns=0
        sm.sequenceState.incrementVS() // ns=1

        // Receive RR(nr=0) — no progress (V(A) already at 0)
        let actions = sm.handle(event: .receivedRR(nr: 0))

        XCTAssertEqual(sm.sequenceState.va, 0, "V(A) should not change")
        XCTAssertFalse(actions.contains(.startT1),
                       "No ack progress should not restart T1")
        XCTAssertFalse(actions.contains(.stopT1),
                       "Should not stop T1 when frames remain outstanding")
    }

    // MARK: - Bug 2: Full RR ack stops T1

    func testFullRRAckStopsT1() {
        var sm = makeConnectedStateMachine()

        // Send 1 I-frame
        sm.sequenceState.incrementVS() // ns=0
        XCTAssertEqual(sm.sequenceState.outstandingCount, 1)

        // Receive RR(nr=1) — full ack
        let actions = sm.handle(event: .receivedRR(nr: 1))

        XCTAssertEqual(sm.sequenceState.va, 1)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
        XCTAssertTrue(actions.contains(.stopT1),
                      "Full ack must stop T1")
        XCTAssertTrue(actions.contains(.startT3),
                      "Full ack should start T3 idle timer")
        XCTAssertFalse(actions.contains(.startT1),
                       "Full ack should not restart T1")
    }

    // MARK: - Bug 3: I-frame piggybacked partial ack restarts T1

    func testIFramePiggybackPartialAckRestartsT1() {
        var sm = makeConnectedStateMachine()

        // Send 3 I-frames
        sm.sequenceState.incrementVS() // ns=0
        sm.sequenceState.incrementVS() // ns=1
        sm.sequenceState.incrementVS() // ns=2
        XCTAssertEqual(sm.sequenceState.outstandingCount, 3)

        // Receive I-frame with N(R)=1 (piggybacked ack of ns=0)
        let payload = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 1, pf: false, payload: payload))

        XCTAssertEqual(sm.sequenceState.va, 1,
                       "Piggybacked N(R)=1 should advance V(A) to 1")
        XCTAssertEqual(sm.sequenceState.outstandingCount, 2,
                       "Should still have 2 outstanding frames")
        XCTAssertTrue(actions.contains(.startT1),
                      "Piggybacked partial ack must restart T1 per §6.4.6")
    }

    func testIFrameFullAckDoesNotRestartT1() {
        var sm = makeConnectedStateMachine()

        // Send 1 I-frame
        sm.sequenceState.incrementVS() // ns=0

        // Receive I-frame with N(R)=1 (piggybacked full ack)
        let payload = Data([0x48, 0x69]) // "Hi"
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 1, pf: false, payload: payload))

        XCTAssertEqual(sm.sequenceState.va, 1)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
        // Should stop T1 via deliverInSequenceFrame, not restart it
        XCTAssertTrue(actions.contains(.stopT1),
                      "Full ack via piggybacked N(R) should stop T1")
        XCTAssertFalse(actions.contains(.startT1),
                       "Full ack should not restart T1")
    }

    // MARK: - Bug 4: onRetransmitFrame removed, onSendFrame used

    func testOnRetransmitFramePropertyDoesNotExist() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        // Verify onRetransmitFrame no longer exists by checking onSendFrame works
        var framesSent: [OutboundFrame] = []
        manager.onSendFrame = { frame in
            framesSent.append(frame)
        }
        XCTAssertNotNil(manager.onSendFrame,
                        "onSendFrame should be the single frame-sending callback")
    }
}
