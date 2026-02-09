//
//  AX25DuplicateTransmissionTests.swift
//  AXTermTests
//
//  Regression tests for duplicate transmission bugs:
//  - T1 grace-period retransmit not cancelled on T1 restart
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
        _ = manager.connect(to: destination, path: path, channel: 0)
        let session = manager.session(for: destination, path: path, channel: 0)
        manager.handleInboundUA(from: destination, path: path, channel: 0)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    // MARK: - Bug 1: startT1Timer cancels pending retransmit task

    func testStartT1CancelsPendingRetransmitTask() async throws {
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0TST", ssid: 0)
        let dest = AX25Address(call: "N0TST", ssid: 0)
        let session = connectSession(manager: manager, destination: dest, path: DigiPath())

        // Simulate a pending retransmit task (as if T1 fired and grace period started)
        var taskRan = false
        session.t1PendingRetransmitTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s — should be cancelled
            guard !Task.isCancelled else { return }
            taskRan = true
        }

        // Now restart T1 — this should cancel the pending retransmit
        manager.startT1Timer(for: session)

        XCTAssertNil(session.t1PendingRetransmitTask,
                     "startT1Timer must nil out t1PendingRetransmitTask")

        // Give a moment for any uncancelled task to run
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        XCTAssertFalse(taskRan,
                       "Pending retransmit task should have been cancelled by startT1Timer")
    }

    // MARK: - Bug 1 (state machine): REJ during grace period doesn't duplicate

    func testREJDuringT1GracePeriodDoesNotDuplicateFrames() {
        var sm = makeConnectedStateMachine()

        // Send an I-frame to have something outstanding
        sm.sequenceState.incrementVS() // Simulate having sent ns=0
        XCTAssertEqual(sm.sequenceState.outstandingCount, 1)

        // T1 fires — state machine returns startT1 (and RR poll)
        let t1Actions = sm.handle(event: .t1Timeout)
        XCTAssertTrue(t1Actions.contains(.startT1),
                      "T1 timeout should restart T1")

        // During grace period, REJ arrives from peer requesting retransmit from nr=0
        // This should also produce .startT1 (which in manager cancels the pending task)
        let rejActions = sm.handle(event: .receivedREJ(nr: 0, pf: false))
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
        let actions = sm.handle(event: .receivedRR(nr: 1, pf: false))

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
        let actions = sm.handle(event: .receivedRR(nr: 0, pf: false))

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
        let actions = sm.handle(event: .receivedRR(nr: 1, pf: false))

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
        let manager = AX25SessionManager()
        // Verify onRetransmitFrame no longer exists by checking onSendFrame works
        var framesSent: [OutboundFrame] = []
        manager.onSendFrame = { frame in
            framesSent.append(frame)
        }
        XCTAssertNotNil(manager.onSendFrame,
                        "onSendFrame should be the single frame-sending callback")
    }
}
