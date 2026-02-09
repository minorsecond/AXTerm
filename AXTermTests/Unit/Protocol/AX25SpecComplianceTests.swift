//
//  AX25SpecComplianceTests.swift
//  AXTermTests
//
//  Comprehensive AX.25 v2.2 spec compliance test suite.
//  Each test references the specific AX.25 spec section it validates.
//  Tests the state machine (AX25StateMachine) directly via handle(event:)
//  and the session manager (AX25SessionManager) for send-buffer-level behavior.
//

import XCTest
@testable import AXTerm

// MARK: - State Machine Tests (no @MainActor needed)

final class AX25SpecComplianceTests: XCTestCase {

    // MARK: - Helpers

    private func makeConnectedStateMachine(
        config: AX25SessionConfig = AX25SessionConfig()
    ) -> AX25StateMachine {
        var sm = AX25StateMachine(config: config)
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
        return sm
    }

    private func extractDeliveredData(from actions: [AX25SessionAction]) -> [Data] {
        actions.compactMap { action in
            if case .deliverData(let data) = action { return data }
            return nil
        }
    }

    private func containsAction(
        _ actions: [AX25SessionAction],
        matching predicate: (AX25SessionAction) -> Bool
    ) -> Bool {
        actions.contains(where: predicate)
    }

    private func containsRR(_ actions: [AX25SessionAction], nr: Int, pf: Bool? = nil) -> Bool {
        actions.contains { action in
            if case .sendRR(let n, let p) = action {
                if let expectedPF = pf { return n == nr && p == expectedPF }
                return n == nr
            }
            return false
        }
    }

    private func containsREJ(_ actions: [AX25SessionAction], nr: Int, pf: Bool? = nil) -> Bool {
        actions.contains { action in
            if case .sendREJ(let n, let p) = action {
                if let expectedPF = pf { return n == nr && p == expectedPF }
                return n == nr
            }
            return false
        }
    }

    private func containsAnyREJ(_ actions: [AX25SessionAction]) -> Bool {
        actions.contains { if case .sendREJ = $0 { return true }; return false }
    }

    private func containsAnyRR(_ actions: [AX25SessionAction]) -> Bool {
        actions.contains { if case .sendRR = $0 { return true }; return false }
    }

    private func containsNotifyError(_ actions: [AX25SessionAction]) -> Bool {
        actions.contains { if case .notifyError = $0 { return true }; return false }
    }

    // MARK: - Section 1: Connection Establishment (AX.25 §4.3.3, §6.3)

    /// §6.3.1: SABM command initiates connection; T1 started
    func testSABMFromDisconnectedSendsFrameAndStartsT1() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        XCTAssertEqual(sm.state, .disconnected)

        let actions = sm.handle(event: .connectRequest)

        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(actions.contains(.sendSABM))
        XCTAssertTrue(actions.contains(.startT1))
        XCTAssertEqual(sm.retryCount, 0)
    }

    /// §6.3.1: T1 timeout while connecting resends SABM
    func testSABMRetryOnT1Timeout() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 5))
        _ = sm.handle(event: .connectRequest)

        let actions = sm.handle(event: .t1Timeout)

        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(actions.contains(.sendSABM))
        XCTAssertTrue(actions.contains(.startT1))
        XCTAssertEqual(sm.retryCount, 1)
    }

    /// §6.3.1: N2+1 SABM retries exceeded → error state
    func testSABMRetriesExhaustedGoesError() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 2))
        _ = sm.handle(event: .connectRequest)

        _ = sm.handle(event: .t1Timeout)  // retry 1
        _ = sm.handle(event: .t1Timeout)  // retry 2
        let actions = sm.handle(event: .t1Timeout)  // retry 3 > maxRetries(2)

        XCTAssertEqual(sm.state, .error)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(containsNotifyError(actions))
    }

    /// §6.3.1: UA received while connecting → connected + T3 started
    func testUAWhileConnectingTransitionsToConnected() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)

        let actions = sm.handle(event: .receivedUA)

        XCTAssertEqual(sm.state, .connected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.startT3))
        XCTAssertTrue(actions.contains(.notifyConnected))
        XCTAssertEqual(sm.retryCount, 0)
    }

    /// §6.3.1: DM received while connecting → disconnected + error notification
    func testDMWhileConnectingGoesDisconnected() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)

        let actions = sm.handle(event: .receivedDM)

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(containsNotifyError(actions))
    }

    /// §6.3.2: Inbound SABM while disconnected accepts connection (responder)
    func testInboundSABMWhileDisconnectedAcceptsConnection() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        let actions = sm.handle(event: .receivedSABM)

        XCTAssertEqual(sm.state, .connected)
        XCTAssertTrue(actions.contains(.sendUA))
        XCTAssertTrue(actions.contains(.startT3))
        XCTAssertTrue(actions.contains(.notifyConnected))
    }

    /// §6.3.4: SABM while connected resets V(S), V(R), V(A) (re-establishment)
    func testSABMWhileConnectedResetsSequenceState() {
        var sm = makeConnectedStateMachine()

        // Simulate activity
        sm.sequenceState.incrementVS()  // vs=1
        sm.sequenceState.incrementVR()  // vr=1
        XCTAssertEqual(sm.sequenceState.vs, 1)
        XCTAssertEqual(sm.sequenceState.vr, 1)

        let actions = sm.handle(event: .receivedSABM)

        XCTAssertEqual(sm.state, .connected)
        XCTAssertEqual(sm.sequenceState.vs, 0)
        XCTAssertEqual(sm.sequenceState.vr, 0)
        XCTAssertEqual(sm.sequenceState.va, 0)
        XCTAssertTrue(actions.contains(.sendUA))
        XCTAssertTrue(actions.contains(.startT3))
    }

    /// §6.3.4: SABM while connected clears receive buffer
    func testSABMWhileConnectedClearsReceiveBuffer() {
        var sm = makeConnectedStateMachine()

        // Buffer an out-of-sequence frame
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("buffered".utf8)))
        XCTAssertFalse(sm.receiveBuffer.isEmpty)

        _ = sm.handle(event: .receivedSABM)

        XCTAssertTrue(sm.receiveBuffer.isEmpty, "Receive buffer must be cleared on re-establishment")
    }

    /// §6.3: Force disconnect while connecting cancels connect attempt
    func testDisconnectRequestWhileConnectingCancels() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        XCTAssertEqual(sm.state, .connecting)

        let actions = sm.handle(event: .forceDisconnect)  // Changed from disconnectRequest

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
    }

    /// §6.3: UA in error state must be ignored — recovery requires explicit connectRequest
    func testErrorIgnoresUA() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 1))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .t1Timeout)  // retry 1
        _ = sm.handle(event: .t1Timeout)  // exceeds → error
        XCTAssertEqual(sm.state, .error)

        let actions = sm.handle(event: .receivedUA)
        XCTAssertTrue(actions.isEmpty, "UA in error must be ignored per spec")
        XCTAssertEqual(sm.state, .error)
    }

    /// Manager-level forceRecoverFromLateUA() overrides spec-strict behavior
    func testForceRecoverFromLateUA() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 1))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .t1Timeout)
        _ = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.state, .error)

        let actions = sm.forceRecoverFromLateUA()
        XCTAssertEqual(sm.state, .connected)
        XCTAssertTrue(actions.contains(.startT3))
        XCTAssertTrue(actions.contains(.notifyConnected))
    }

    // MARK: - Section 2: Disconnection (AX.25 §4.3.4, §6.4)

    /// §6.4.1: Disconnect request sends DISC and starts T1
    func testDisconnectSendsDISCAndStartsT1() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .disconnectRequest)

        XCTAssertEqual(sm.state, .disconnecting)
        XCTAssertTrue(actions.contains(.sendDISC))
        XCTAssertTrue(actions.contains(.startT1))
        XCTAssertTrue(actions.contains(.stopT3))
    }

    /// §6.4.1: T1 timeout while disconnecting re-sends DISC
    func testDISCRetryOnT1Timeout() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .disconnectRequest)

        let actions = sm.handle(event: .t1Timeout)

        XCTAssertEqual(sm.state, .disconnecting)
        XCTAssertTrue(actions.contains(.sendDISC))
        XCTAssertTrue(actions.contains(.startT1))
        XCTAssertEqual(sm.retryCount, 1)
    }

    /// §6.4.1: DISC retries exhausted → forced disconnect
    func testDISCRetriesExhaustedGoesDisconnected() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 2))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        _ = sm.handle(event: .disconnectRequest)

        _ = sm.handle(event: .t1Timeout)  // retry 1
        _ = sm.handle(event: .t1Timeout)  // retry 2
        let actions = sm.handle(event: .t1Timeout)  // exceeds

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
    }

    /// §6.4.1: UA while disconnecting completes disconnect
    func testUAWhileDisconnectingCompletes() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .disconnectRequest)

        let actions = sm.handle(event: .receivedUA)

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
    }

    /// §6.4.1: DM while disconnecting completes disconnect (same as UA per spec)
    func testDMWhileDisconnectingCompletes() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .disconnectRequest)

        let actions = sm.handle(event: .receivedDM)

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
    }

    /// §6.4: Inbound DISC while connected → send UA + transition disconnected
    func testInboundDISCWhileConnectedRespondsUA() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedDISC)

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.sendUA))
        XCTAssertTrue(actions.contains(.stopT3))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
    }

    /// §6.4: Inbound DM while connected → disconnected + error
    func testInboundDMWhileConnectedDisconnects() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedDM)

        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT3))
        XCTAssertTrue(containsNotifyError(actions))
    }

    // MARK: - Section 3: I-Frame Transfer (AX.25 §4.3.2, §6.4.1-6.4.4)

    /// §6.4.1: In-sequence I-frame delivers data and sends RR
    func testInSequenceIFrameDeliversAndSendsRR() {
        var sm = makeConnectedStateMachine()

        let payload = Data("Hello".utf8)
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: payload))

        let delivered = extractDeliveredData(from: actions)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first, payload)
        XCTAssertTrue(containsRR(actions, nr: 1))
    }

    /// §6.4.1: In-sequence I-frame increments V(R)
    func testInSequenceIFrameIncrementsVR() {
        var sm = makeConnectedStateMachine()
        XCTAssertEqual(sm.sequenceState.vr, 0)

        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))

        XCTAssertEqual(sm.sequenceState.vr, 1)
    }

    /// §6.4.1: Piggybacked N(R) in I-frame acknowledges our sent frames
    func testIFramePiggybacksNRAcknowledgment() {
        var sm = makeConnectedStateMachine()

        // Simulate sending 2 frames
        sm.sequenceState.incrementVS()  // vs=1
        sm.sequenceState.incrementVS()  // vs=2
        XCTAssertEqual(sm.sequenceState.outstandingCount, 2)

        // Receive I-frame with nr=2 (acks our frames 0,1)
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 2, pf: false, payload: Data("reply".utf8)))

        XCTAssertEqual(sm.sequenceState.va, 2)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
    }

    /// §6.4.1: Consecutive in-sequence I-frames deliver in order
    func testConsecutiveInSequenceIFramesDeliverInOrder() {
        var sm = makeConnectedStateMachine()
        var allDelivered: [Data] = []

        for i in 0..<4 {
            let payload = Data("Frame\(i)".utf8)
            let actions = sm.handle(event: .receivedIFrame(ns: i, nr: 0, pf: false, payload: payload))
            allDelivered.append(contentsOf: extractDeliveredData(from: actions))
        }

        XCTAssertEqual(allDelivered.count, 4)
        for i in 0..<4 {
            XCTAssertEqual(String(data: allDelivered[i], encoding: .utf8), "Frame\(i)")
        }
        XCTAssertEqual(sm.sequenceState.vr, 4)
    }

    /// §6.2: I-frame with P=1 gets RR with F=1
    func testIFrameWithPollBitGetsRRWithFinalBit() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: true, payload: Data("poll".utf8)))

        XCTAssertTrue(containsRR(actions, nr: 1, pf: true),
            "In-sequence I-frame with P=1 must respond with RR(F=1)")
    }

    /// §6.4.1: I-frame stops T1 when all frames acknowledged
    func testIFrameStopsT1WhenAllAcked() {
        var sm = makeConnectedStateMachine()

        // Simulate sending 1 frame
        sm.sequenceState.incrementVS()
        XCTAssertEqual(sm.sequenceState.outstandingCount, 1)

        // Receive I-frame with nr=1 (acks our frame)
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 1, pf: false, payload: Data("ack".utf8)))

        XCTAssertTrue(actions.contains(.stopT1))
    }

    /// §6.4.1: startT3 after in-sequence delivery
    func testIFrameStartsT3AfterDelivery() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("data".utf8)))

        XCTAssertTrue(actions.contains(.startT3))
    }

    // MARK: - Section 4: Receive Window & Out-of-Sequence (AX.25 §6.4.4)

    /// §6.4.4: Out-of-sequence I-frame buffered, not delivered
    func testOutOfSequenceIFrameBufferedNotDelivered() {
        var sm = makeConnectedStateMachine()

        // Receive ns=1 when expecting ns=0
        let actions = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("ooo".utf8)))

        let delivered = extractDeliveredData(from: actions)
        XCTAssertEqual(delivered.count, 0, "Out-of-sequence frame should not be delivered")
        XCTAssertFalse(sm.receiveBuffer.isEmpty, "Frame should be buffered")
    }

    /// §6.4.4: Out-of-sequence triggers REJ
    func testOutOfSequenceTriggersREJ() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("gap".utf8)))

        XCTAssertTrue(containsREJ(actions, nr: 0), "Should send REJ(V(R)=0)")
    }

    /// §6.4.4: No multiple REJs for same gap
    func testNoMultipleREJsForSameGap() {
        var sm = makeConnectedStateMachine()

        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("A".utf8)))
        XCTAssertTrue(sm.rejSent)

        let actions2 = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("B".utf8)))

        XCTAssertFalse(containsAnyREJ(actions2), "Should not send duplicate REJ")
    }

    /// §6.4.4: REJ flag cleared on in-sequence delivery
    func testREJFlagClearedOnInSequenceDelivery() {
        var sm = makeConnectedStateMachine()

        // Create gap: receive ns=1, miss ns=0
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))
        XCTAssertTrue(sm.rejSent)

        // Fill gap
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))
        XCTAssertFalse(sm.rejSent, "rejSent must be cleared when gap is filled")
    }

    /// §6.4.4: New gap after recovery sends new REJ
    func testNewGapAfterRecoverySendsNewREJ() {
        var sm = makeConnectedStateMachine()

        // First gap at ns=0
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))
        // Fill it
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))
        XCTAssertEqual(sm.sequenceState.vr, 2)

        // New gap: receive ns=3, expecting ns=2
        let actions = sm.handle(event: .receivedIFrame(ns: 3, nr: 0, pf: false, payload: Data("D".utf8)))

        XCTAssertTrue(containsREJ(actions, nr: 2), "Should REJ for new gap at V(R)=2")
    }

    /// §6.4.4: P=1 while rejSent → RR(F=1) instead of duplicate REJ
    func testOutOfSequenceWithPollBitAndREJAlreadySentRespondsRR() {
        var sm = makeConnectedStateMachine()

        // First out-of-sequence sends REJ
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("A".utf8)))
        XCTAssertTrue(sm.rejSent)

        // Second out-of-sequence with P=1 should respond RR(F=1), not another REJ
        let actions = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: true, payload: Data("B".utf8)))

        XCTAssertFalse(containsAnyREJ(actions), "Should not send duplicate REJ")
        XCTAssertTrue(containsRR(actions, nr: 0, pf: true),
            "Should respond with RR(V(R), F=1) when rejSent and P=1")
    }

    /// §6.4.4: Outside window I-frame re-acks with RR
    func testOutsideWindowIFrameReAcksWithRR() {
        var sm = makeConnectedStateMachine(config: AX25SessionConfig(windowSize: 2))

        // Receive frames 0,1 (V(R) = 2)
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))
        XCTAssertEqual(sm.sequenceState.vr, 2)

        // ns=0 is now outside the window [2, 3]
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("dup".utf8)))

        XCTAssertTrue(containsRR(actions, nr: 2), "Outside window should re-ack with RR(V(R))")
        XCTAssertEqual(extractDeliveredData(from: actions).count, 0, "Should not deliver outside-window frame")
    }

    /// §6.4.4: Outside window + P=1 → RR(F=1)
    func testOutsideWindowIFrameWithPollRespondsWithFinal() {
        var sm = makeConnectedStateMachine(config: AX25SessionConfig(windowSize: 2))

        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))

        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: true, payload: Data("dup".utf8)))

        XCTAssertTrue(containsRR(actions, nr: 2, pf: true))
    }

    /// Duplicate I-frame not delivered twice
    func testDuplicateIFrameNotDeliveredTwice() {
        var sm = makeConnectedStateMachine()

        let payload = Data("unique".utf8)
        let actions1 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: payload))
        XCTAssertEqual(extractDeliveredData(from: actions1).count, 1)

        // Duplicate
        let actions2 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: payload))
        XCTAssertEqual(extractDeliveredData(from: actions2).count, 0, "Duplicate must not deliver")
    }

    /// Duplicate buffered frame not overwritten
    func testDuplicateBufferedFrameNotOverwritten() {
        var sm = makeConnectedStateMachine()

        // Buffer ns=2 with original payload
        _ = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("original".utf8)))
        // Duplicate ns=2 with different payload
        _ = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("duplicate".utf8)))

        XCTAssertEqual(sm.receiveBuffer[2]?.payload, Data("original".utf8),
            "Buffer should keep original, not overwrite with duplicate")
    }

    /// Buffer full: evicts frame farthest from V(R), not nearest
    func testReceiveBufferEvictsFrameFarthestFromVR() {
        // maxReceiveBufferSize=2, window=4
        var sm = makeConnectedStateMachine(config: AX25SessionConfig(windowSize: 4, maxReceiveBufferSize: 2))

        // Buffer ns=1 and ns=3 (V(R)=0, so distances are 1 and 3)
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("near".utf8)))
        _ = sm.handle(event: .receivedIFrame(ns: 3, nr: 0, pf: false, payload: Data("far".utf8)))
        XCTAssertEqual(sm.receiveBuffer.count, 2)

        // Buffer ns=2 — buffer full, must evict farthest (ns=3)
        _ = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("mid".utf8)))

        XCTAssertNotNil(sm.receiveBuffer[1], "ns=1 (nearest) should be kept")
        XCTAssertNotNil(sm.receiveBuffer[2], "ns=2 (new) should be kept")
        XCTAssertNil(sm.receiveBuffer[3], "ns=3 (farthest) should be evicted")
    }

    // MARK: - Section 5: RR Supervisory Frame (AX.25 §6.4.1)

    /// §6.4.1: RR advances V(A) and acks frames
    func testRRAdvancesVAAndAcksFrames() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()  // vs=1
        sm.sequenceState.incrementVS()  // vs=2

        _ = sm.handle(event: .receivedRR(nr: 2))

        XCTAssertEqual(sm.sequenceState.va, 2)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
    }

    /// §6.4.1: RR stops T1 when all acked
    func testRRStopsT1WhenAllAcked() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()

        let actions = sm.handle(event: .receivedRR(nr: 1))

        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.startT3))
    }

    /// §6.4.1: RR does not stop T1 when frames still outstanding
    func testRRDoesNotStopT1WhenFramesStillOutstanding() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()  // vs=1
        sm.sequenceState.incrementVS()  // vs=2

        // Partial ack: ack only frame 0
        let actions = sm.handle(event: .receivedRR(nr: 1))

        XCTAssertFalse(actions.contains(.stopT1), "T1 should not stop with frames still outstanding")
        XCTAssertEqual(sm.sequenceState.outstandingCount, 1)
    }

    /// KB5YZB-7: RR resets retryCount when V(A) advances
    func testRRResetsRetryCountWhenVAAdvances() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()

        _ = sm.handle(event: .t1Timeout)
        _ = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.retryCount, 2)

        _ = sm.handle(event: .receivedRR(nr: 1))

        XCTAssertEqual(sm.retryCount, 0, "retryCount must reset when V(A) advances")
    }

    /// KB5YZB-7: RR does not reset retryCount when V(A) unchanged (duplicate RR)
    func testRRDoesNotResetRetryCountWhenVAUnchanged() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()

        _ = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.retryCount, 1)

        // RR with nr=0 doesn't advance V(A) (still 0)
        _ = sm.handle(event: .receivedRR(nr: 0))

        XCTAssertEqual(sm.retryCount, 1, "retryCount should not reset on stale RR")
    }

    /// RR with wrap: V(A)=6, RR(2) acks 6,7,0,1
    func testRRWithWrapAcknowledgesCorrectRange() {
        var sm = makeConnectedStateMachine()

        // Set up: va=6, vs=2 (sent frames 6,7,0,1)
        sm.sequenceState.va = 6
        sm.sequenceState.vs = 2
        XCTAssertEqual(sm.sequenceState.outstandingCount, 4)

        _ = sm.handle(event: .receivedRR(nr: 2))

        XCTAssertEqual(sm.sequenceState.va, 2)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
    }

    /// Sequential RRs progressively ack
    func testSequentialRRsProgressivelyAck() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()  // vs=1
        sm.sequenceState.incrementVS()  // vs=2
        sm.sequenceState.incrementVS()  // vs=3

        _ = sm.handle(event: .receivedRR(nr: 1))
        XCTAssertEqual(sm.sequenceState.va, 1)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 2)

        _ = sm.handle(event: .receivedRR(nr: 2))
        XCTAssertEqual(sm.sequenceState.va, 2)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 1)

        _ = sm.handle(event: .receivedRR(nr: 3))
        XCTAssertEqual(sm.sequenceState.va, 3)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
    }

    // MARK: - Section 6: RNR Supervisory Frame (AX.25 §6.4.2)

    /// §6.4.2: RNR acknowledges up to N(R)
    func testRNRAcknowledgesUpToNR() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()  // vs=1
        sm.sequenceState.incrementVS()  // vs=2

        _ = sm.handle(event: .receivedRNR(nr: 1))

        XCTAssertEqual(sm.sequenceState.va, 1, "RNR should advance V(A)")
    }

    /// §6.4.2: RNR stops T1
    func testRNRStopsT1() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()

        let actions = sm.handle(event: .receivedRNR(nr: 1))

        XCTAssertTrue(actions.contains(.stopT1))
    }

    /// §6.4.2: RNR does not start T3 (peer is busy, not idle)
    func testRNRDoesNotStartT3() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()

        let actions = sm.handle(event: .receivedRNR(nr: 1))

        XCTAssertFalse(actions.contains(.startT3),
            "RNR should not start T3 — peer is busy, not idle")
    }

    /// §6.4.2: RNR followed by RR resumes normal operation
    func testRNRFollowedByRRResumesNormalOperation() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()  // vs=1
        sm.sequenceState.incrementVS()  // vs=2

        // RNR acks first frame
        _ = sm.handle(event: .receivedRNR(nr: 1))
        XCTAssertEqual(sm.sequenceState.va, 1)

        // RR acks remaining frame — resumes normal
        let actions = sm.handle(event: .receivedRR(nr: 2))

        XCTAssertEqual(sm.sequenceState.va, 2)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.startT3))
    }

    /// §6.4.2: Multiple RNRs with same N(R) are idempotent
    func testMultipleRNRsDoNotCorruptState() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()

        _ = sm.handle(event: .receivedRNR(nr: 1))
        let va1 = sm.sequenceState.va

        _ = sm.handle(event: .receivedRNR(nr: 1))
        XCTAssertEqual(sm.sequenceState.va, va1, "Repeated RNR(same nr) should be idempotent")
    }

    // MARK: - Section 7: REJ Supervisory Frame (AX.25 §6.4.3)

    /// §6.4.3: REJ acknowledges up to N(R)
    func testREJAcknowledgesUpToNR() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()  // vs=1
        sm.sequenceState.incrementVS()  // vs=2

        _ = sm.handle(event: .receivedREJ(nr: 1))

        XCTAssertEqual(sm.sequenceState.va, 1, "REJ should advance V(A) to N(R)")
    }

    /// §6.4.3: REJ starts T1 for retransmission
    func testREJStartsT1ForRetransmission() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()

        let actions = sm.handle(event: .receivedREJ(nr: 0))

        XCTAssertTrue(actions.contains(.startT1))
    }

    // MARK: - Section 8: FRMR Frame Reject (AX.25 §6.4.5)

    /// §6.4.5: FRMR while connected goes error state
    func testFRMRWhileConnectedGoesErrorState() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedFRMR)

        XCTAssertEqual(sm.state, .error)
        XCTAssertTrue(actions.contains(.stopT3))
        XCTAssertTrue(containsNotifyError(actions))
    }

    /// §6.4.5: FRMR stops T3
    func testFRMRStopsT3() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedFRMR)

        XCTAssertTrue(actions.contains(.stopT3))
    }

    /// §6.4.5: FRMR notifies error
    func testFRMRNotifiesError() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedFRMR)

        XCTAssertTrue(containsNotifyError(actions))
    }

    /// Recovery from FRMR via reconnect
    func testRecoveryFromFRMRViaReconnect() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .receivedFRMR)
        XCTAssertEqual(sm.state, .error)

        let actions = sm.handle(event: .connectRequest)

        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(actions.contains(.sendSABM))
        XCTAssertTrue(actions.contains(.startT1))
    }

    // MARK: - Section 9: P/F Bit Handling (AX.25 §6.2)

    /// §6.2: In-sequence I-frame with P=1 → RR(F=1)
    func testIFramePollBitTriggersRRFinalForInSequence() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: true, payload: Data("p".utf8)))

        XCTAssertTrue(containsRR(actions, nr: 1, pf: true))
    }

    /// §6.2: Out-of-sequence I-frame with P=1 → REJ(F=1) (first gap)
    func testIFramePollBitTriggersREJFinalForOutOfSequence() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: true, payload: Data("ooo".utf8)))

        XCTAssertTrue(containsREJ(actions, nr: 0, pf: true),
            "First out-of-sequence with P=1 should send REJ(V(R), F=1)")
    }

    /// §6.2: Outside window I-frame with P=1 → RR(F=1)
    func testIFramePollBitTriggersRRFinalForOutsideWindow() {
        var sm = makeConnectedStateMachine(config: AX25SessionConfig(windowSize: 2))

        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))

        // ns=0 is now outside window [2,3]
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: true, payload: Data("dup".utf8)))

        XCTAssertTrue(containsRR(actions, nr: 2, pf: true))
    }

    /// §6.2: I-frame with P=0 → response has F=0
    func testIFrameNoPollNoPollResponse() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("np".utf8)))

        XCTAssertTrue(containsRR(actions, nr: 1, pf: false))
    }

    /// §6.2: rejSent + P=1 → RR(V(R), F=1)
    func testOutOfSequenceREJAlreadySentPollGetsRRFinal() {
        var sm = makeConnectedStateMachine()

        // First out-of-sequence: REJ sent
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("A".utf8)))
        XCTAssertTrue(sm.rejSent)

        // Second out-of-sequence with P=1
        let actions = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: true, payload: Data("B".utf8)))

        XCTAssertTrue(containsRR(actions, nr: 0, pf: true),
            "rejSent + P=1 must respond RR(V(R), F=1)")
        XCTAssertFalse(containsAnyREJ(actions))
    }

    /// §6.7.1.2: T3 timeout sends RR for link check
    func testT3TimeoutSendsRR() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .t3Timeout)

        XCTAssertTrue(containsAnyRR(actions), "T3 timeout should send RR for link check")
        XCTAssertTrue(actions.contains(.startT1))
    }

    /// §6.4.11: T1 timeout in connected sends RR poll (P=1) when outstanding > 0
    func testT1TimeoutInConnectedSendsRRPoll() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()  // outstanding = 1

        let actions = sm.handle(event: .t1Timeout)

        XCTAssertTrue(containsRR(actions, nr: sm.sequenceState.vr, pf: true),
            "T1 timeout with outstanding frames must send RR poll (P=1)")
    }

    // MARK: - Section 10: Timer Behavior (AX.25 §6.7)

    /// §6.7: T1 timeout in connecting retries SABM
    func testT1TimeoutInConnectingRetriesSABM() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 5))
        _ = sm.handle(event: .connectRequest)

        let actions = sm.handle(event: .t1Timeout)

        XCTAssertTrue(actions.contains(.sendSABM))
        XCTAssertTrue(actions.contains(.startT1))
    }

    /// §6.7: T1 timeout in connected with outstanding sends RR poll
    func testT1TimeoutInConnectedWithOutstandingSendsRRPoll() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()

        let actions = sm.handle(event: .t1Timeout)

        let hasRRPoll = actions.contains { action in
            if case .sendRR(_, let pf) = action { return pf == true }
            return false
        }
        XCTAssertTrue(hasRRPoll)
    }

    /// §6.7: T1 timeout in connected with no outstanding does not send RR poll
    func testT1TimeoutInConnectedWithNoOutstandingNoRRPoll() {
        var sm = makeConnectedStateMachine()
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)

        let actions = sm.handle(event: .t1Timeout)

        XCTAssertFalse(actions.contains { action in
            if case .sendRR(_, let pf) = action { return pf == true }
            return false
        }, "No RR poll should be sent when nothing outstanding")
    }

    /// §6.7: T1 timeout in disconnecting retries DISC
    func testT1TimeoutInDisconnectingRetriesDISC() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .disconnectRequest)

        let actions = sm.handle(event: .t1Timeout)

        XCTAssertTrue(actions.contains(.sendDISC))
        XCTAssertTrue(actions.contains(.startT1))
    }

    /// §6.7: retryCount incremented on each timeout
    func testT1RetryCountIncrementedOnEachTimeout() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 10))
        _ = sm.handle(event: .connectRequest)

        for i in 1...3 {
            _ = sm.handle(event: .t1Timeout)
            XCTAssertEqual(sm.retryCount, i)
        }
    }

    /// §6.7: T1 retry exceeds N2 in connected → error
    func testT1RetryExceedsN2InConnectedGoesError() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 2))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        _ = sm.handle(event: .t1Timeout)  // 1
        _ = sm.handle(event: .t1Timeout)  // 2
        let actions = sm.handle(event: .t1Timeout)  // 3 > N2

        XCTAssertEqual(sm.state, .error)
        XCTAssertTrue(containsNotifyError(actions))
    }

    /// §6.7: T1 retry exceeds N2 in disconnecting → disconnected (not error)
    func testT1RetryExceedsN2InDisconnectingGoesDisconnected() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 2))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        _ = sm.handle(event: .disconnectRequest)

        _ = sm.handle(event: .t1Timeout)  // 1
        _ = sm.handle(event: .t1Timeout)  // 2
        let actions = sm.handle(event: .t1Timeout)  // 3 > N2

        XCTAssertEqual(sm.state, .disconnected, "Disconnecting retry exceeded should go to disconnected, not error")
        XCTAssertTrue(actions.contains(.notifyDisconnected))
    }

    /// §6.7: T3 timeout starts T1
    func testT3TimeoutStartsT1() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .t3Timeout)

        XCTAssertTrue(actions.contains(.startT1))
    }

    /// §6.7: Timer backoff doubles RTO
    func testTimerBackoffDoublesRTO() {
        var timers = AX25SessionTimers()
        let initial = timers.rto

        timers.backoff()

        XCTAssertEqual(timers.rto, min(initial * 2, 30.0), accuracy: 0.01)
    }

    // MARK: - Section 11: Window Management (AX.25 §4.3.2.1)

    /// §4.3.2.1: Cannot send when window is full
    func testCannotSendWhenWindowFull() {
        var seq = AX25SequenceState(modulo: 8)
        let windowSize = 4

        // Fill window
        for _ in 0..<windowSize {
            seq.incrementVS()
        }

        XCTAssertFalse(seq.canSend(windowSize: windowSize))
    }

    /// §4.3.2.1: Can send after RR acks a frame
    func testCanSendAfterRRAcksFrame() {
        var seq = AX25SequenceState(modulo: 8)
        let windowSize = 4

        for _ in 0..<windowSize {
            seq.incrementVS()
        }
        XCTAssertFalse(seq.canSend(windowSize: windowSize))

        seq.ackUpTo(nr: 1)
        XCTAssertTrue(seq.canSend(windowSize: windowSize))
    }

    /// §4.3.2.1: Window size clamped to modulo max
    func testWindowSizeClampedToModulo() {
        let config = AX25SessionConfig(windowSize: 10)  // mod-8 max is 7
        XCTAssertEqual(config.windowSize, 7)
    }

    /// Outstanding count wraparound: V(A)=6, V(S)=2 → outstanding=4
    func testOutstandingCountWraparound() {
        var seq = AX25SequenceState(modulo: 8)
        seq.va = 6
        seq.vs = 2

        XCTAssertEqual(seq.outstandingCount, 4)
    }

    /// Outstanding count zero when fully acked
    func testOutstandingCountZeroWhenFullyAcked() {
        var seq = AX25SequenceState(modulo: 8)
        seq.vs = 5
        seq.va = 5

        XCTAssertEqual(seq.outstandingCount, 0)
    }

    // MARK: - Section 12: Sequence Number Wraparound (AX.25 §4.2.5)

    /// §4.2.5: V(S) wraps at 7 to 0 for mod-8
    func testVSWrapsAt7ToZero() {
        var seq = AX25SequenceState(modulo: 8)
        for _ in 0..<7 {
            seq.incrementVS()
        }
        XCTAssertEqual(seq.vs, 7)

        seq.incrementVS()
        XCTAssertEqual(seq.vs, 0)
    }

    /// §4.2.5: V(R) wraps at 7 to 0 for mod-8
    func testVRWrapsAt7ToZero() {
        var seq = AX25SequenceState(modulo: 8)
        for _ in 0..<7 {
            seq.incrementVR()
        }
        XCTAssertEqual(seq.vr, 7)

        seq.incrementVR()
        XCTAssertEqual(seq.vr, 0)
    }

    /// §4.2.5: ackUpTo(nr:0) when va=6 works correctly
    func testAckUpToWrapsCorrectly() {
        var seq = AX25SequenceState(modulo: 8)
        seq.va = 6
        seq.vs = 0  // Sent frames 6,7 → vs wrapped to 0

        seq.ackUpTo(nr: 0)

        XCTAssertEqual(seq.va, 0)
        XCTAssertEqual(seq.outstandingCount, 0)
    }

    /// Progressive RR acks through full wrap
    func testSendBufferAckWithFullWrap() {
        var seq = AX25SequenceState(modulo: 8)

        // Send 8 frames (full wrap)
        for _ in 0..<8 {
            seq.incrementVS()
        }
        XCTAssertEqual(seq.vs, 0)  // wrapped

        // Ack progressively
        seq.ackUpTo(nr: 4)
        XCTAssertEqual(seq.va, 4)

        seq.ackUpTo(nr: 0)
        XCTAssertEqual(seq.va, 0)
        XCTAssertEqual(seq.outstandingCount, 0)
    }

    // MARK: - Section 13: Extended Mode / Modulo-128 (AX.25 §4.3.2.2)

    /// §4.3.2.2: Mod-128 V(S) wraps at 127 to 0
    func testMod128SequenceStateWrapsAt127() {
        var seq = AX25SequenceState(modulo: 128)
        for _ in 0..<127 {
            seq.incrementVS()
        }
        XCTAssertEqual(seq.vs, 127)

        seq.incrementVS()
        XCTAssertEqual(seq.vs, 0)
    }

    /// §4.3.2.2: Mod-128 allows window up to 127
    func testMod128WindowSizeAllowsUpTo127() {
        let config = AX25SessionConfig(windowSize: 32, extended: true)
        XCTAssertEqual(config.windowSize, 32)

        let maxConfig = AX25SessionConfig(windowSize: 127, extended: true)
        XCTAssertEqual(maxConfig.windowSize, 127)

        let overConfig = AX25SessionConfig(windowSize: 200, extended: true)
        XCTAssertEqual(overConfig.windowSize, 127, "Should clamp to 127 for mod-128")
    }

    /// §4.3.2.2: Mod-128 outstanding count across wrap
    func testMod128OutstandingCountCorrectAcrossWrap() {
        var seq = AX25SequenceState(modulo: 128)
        seq.va = 120
        seq.vs = 5

        XCTAssertEqual(seq.outstandingCount, 13)
    }

    /// §4.3.2.2: Mod-128 ackUpTo wraps correctly
    func testMod128AckUpToWrapsCorrectly() {
        var seq = AX25SequenceState(modulo: 128)
        seq.va = 120
        seq.vs = 5

        seq.ackUpTo(nr: 5)

        XCTAssertEqual(seq.va, 5)
        XCTAssertEqual(seq.outstandingCount, 0)
    }

    /// §4.3.2.2: Extended config sets correct modulo
    func testMod128ConfigSetsCorrectModulo() {
        let config = AX25SessionConfig(extended: true)
        XCTAssertEqual(config.modulo, 128)
        XCTAssertTrue(config.extended)

        let standardConfig = AX25SessionConfig(extended: false)
        XCTAssertEqual(standardConfig.modulo, 8)
    }

    // MARK: - Section 14: State Machine Exhaustive — Events Ignored in Wrong State

    /// Disconnected state ignores RR
    func testDisconnectedIgnoresRR() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        let actions = sm.handle(event: .receivedRR(nr: 1))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnected)
    }

    /// Disconnected state ignores RNR
    func testDisconnectedIgnoresRNR() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        let actions = sm.handle(event: .receivedRNR(nr: 1))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnected)
    }

    /// Disconnected state ignores REJ
    func testDisconnectedIgnoresREJ() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        let actions = sm.handle(event: .receivedREJ(nr: 1))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnected)
    }

    /// Disconnected state ignores I-frame
    func testDisconnectedIgnoresIFrame() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("test".utf8)))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnected)
    }

    /// Disconnected state ignores T1 timeout
    func testDisconnectedIgnoresT1Timeout() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        let actions = sm.handle(event: .t1Timeout)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnected)
    }

    /// Disconnected state ignores T3 timeout
    func testDisconnectedIgnoresT3Timeout() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        let actions = sm.handle(event: .t3Timeout)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnected)
    }

    /// §6.3: UA in disconnected state must be ignored (unsolicited UA)
    func testDisconnectedIgnoresUA() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        let actions = sm.handle(event: .receivedUA)
        XCTAssertTrue(actions.isEmpty, "UA in disconnected must be ignored per §6.3")
        XCTAssertEqual(sm.state, .disconnected)
    }

    /// Connecting state ignores I-frame
    func testConnectingIgnoresIFrame() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("x".utf8)))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .connecting)
    }

    /// Connecting state ignores RR
    func testConnectingIgnoresRR() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        let actions = sm.handle(event: .receivedRR(nr: 0))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .connecting)
    }

    /// Connecting state ignores RNR
    func testConnectingIgnoresRNR() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        let actions = sm.handle(event: .receivedRNR(nr: 0))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .connecting)
    }

    /// Connecting state ignores REJ
    func testConnectingIgnoresREJ() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        let actions = sm.handle(event: .receivedREJ(nr: 0))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .connecting)
    }

    /// Connecting state ignores T3 timeout
    func testConnectingIgnoresT3Timeout() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        let actions = sm.handle(event: .t3Timeout)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .connecting)
    }

    /// Disconnecting state ignores I-frame
    func testDisconnectingIgnoresIFrame() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .disconnectRequest)
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("x".utf8)))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnecting)
    }

    /// Disconnecting state ignores RR
    func testDisconnectingIgnoresRR() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .disconnectRequest)
        let actions = sm.handle(event: .receivedRR(nr: 0))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnecting)
    }

    /// Disconnecting state ignores SABM
    func testDisconnectingIgnoresSABM() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .disconnectRequest)
        let actions = sm.handle(event: .receivedSABM)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnecting)
    }

    /// Disconnecting state ignores T3 timeout
    func testDisconnectingIgnoresT3Timeout() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .disconnectRequest)
        let actions = sm.handle(event: .t3Timeout)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .disconnecting)
    }

    /// Error state ignores RR
    func testErrorIgnoresRR() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .receivedFRMR)
        XCTAssertEqual(sm.state, .error)
        let actions = sm.handle(event: .receivedRR(nr: 0))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .error)
    }

    /// Error state ignores I-frame
    func testErrorIgnoresIFrame() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .receivedFRMR)
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("x".utf8)))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .error)
    }

    /// Error state ignores T1 timeout
    func testErrorIgnoresT1Timeout() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .receivedFRMR)
        let actions = sm.handle(event: .t1Timeout)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sm.state, .error)
    }

    // MARK: - Section 15: Multi-Step Scenario Tests (State Machine Level)

    /// Full session lifecycle: SABM→UA→I-frames→DISC→UA
    func testFullSessionLifecycle_ConnectExchangeDisconnect() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Connect
        let connectActions = sm.handle(event: .connectRequest)
        XCTAssertEqual(sm.state, .connecting)
        XCTAssertTrue(connectActions.contains(.sendSABM))

        let uaActions = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
        XCTAssertTrue(uaActions.contains(.notifyConnected))

        // Exchange I-frames
        let rx = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("data".utf8)))
        XCTAssertEqual(extractDeliveredData(from: rx).count, 1)

        // Disconnect
        let discActions = sm.handle(event: .disconnectRequest)
        XCTAssertEqual(sm.state, .disconnecting)
        XCTAssertTrue(discActions.contains(.sendDISC))

        let discUAActions = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(discUAActions.contains(.notifyDisconnected))
    }

    /// BPQ node scenario: connect, send command, receive multi-frame response
    func testBPQNodeScenario_ConnectSendCommandReceiveMultiFrameResponse() {
        var sm = AX25StateMachine(config: AX25SessionConfig(windowSize: 4))

        // Connect
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)

        // Send a command (increment vs manually)
        sm.sequenceState.incrementVS()  // vs=1

        // Receive multi-frame welcome response
        var delivered: [Data] = []
        for i in 0..<4 {
            let payload = Data("Line \(i)\r".utf8)
            let actions = sm.handle(event: .receivedIFrame(ns: i, nr: 1, pf: false, payload: payload))
            delivered.append(contentsOf: extractDeliveredData(from: actions))
        }

        XCTAssertEqual(delivered.count, 4)
        XCTAssertEqual(sm.sequenceState.vr, 4)
        // N(R)=1 in each acks our command
        XCTAssertEqual(sm.sequenceState.va, 1)
    }

    /// Frame loss, T1 retry, RR poll, recovery
    func testDigipeatedPathWithLoss_T1RetransmitAndRecovery() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 5))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Send I-frame
        sm.sequenceState.incrementVS()  // vs=1, outstanding=1

        // T1 fires (frame lost in transit)
        let t1Actions = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.retryCount, 1)
        XCTAssertTrue(self.actions(t1Actions, containRRPoll: true))

        // Peer responds to poll with RR(F=1) acking our frame
        let rrActions = sm.handle(event: .receivedRR(nr: 1))
        XCTAssertEqual(sm.retryCount, 0, "retryCount reset on successful ack")
        XCTAssertTrue(rrActions.contains(.stopT1))
    }

    /// Window full, then ack drains pending queue (state machine level)
    func testWindowFullThenAckDrainsPendingQueue() {
        var sm = AX25StateMachine(config: AX25SessionConfig(windowSize: 2))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Fill window
        sm.sequenceState.incrementVS()  // 0→1
        sm.sequenceState.incrementVS()  // 1→2
        XCTAssertFalse(sm.sequenceState.canSend(windowSize: 2))

        // RR acks both
        _ = sm.handle(event: .receivedRR(nr: 2))
        XCTAssertTrue(sm.sequenceState.canSend(windowSize: 2))
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
    }

    /// Multiple T1 timeouts with interleaved RRs
    func testMultipleT1TimeoutsWithInterleavedRRs() {
        var sm = AX25StateMachine(config: AX25SessionConfig(maxRetries: 10))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        sm.sequenceState.incrementVS()  // vs=1
        sm.sequenceState.incrementVS()  // vs=2

        // T1 fires
        _ = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.retryCount, 1)

        // Partial ack
        _ = sm.handle(event: .receivedRR(nr: 1))
        XCTAssertEqual(sm.retryCount, 0)  // reset
        XCTAssertEqual(sm.sequenceState.outstandingCount, 1)

        // T1 fires again
        _ = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.retryCount, 1)

        // Full ack
        _ = sm.handle(event: .receivedRR(nr: 2))
        XCTAssertEqual(sm.retryCount, 0)
        XCTAssertEqual(sm.sequenceState.outstandingCount, 0)
    }

    /// Re-establishment (SABM) while I-frames outstanding resets everything
    func testReestablishmentWhileIFramesOutstanding() {
        var sm = makeConnectedStateMachine()

        // Send some frames and buffer some received
        sm.sequenceState.incrementVS()
        sm.sequenceState.incrementVS()
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))
        XCTAssertEqual(sm.sequenceState.vr, 1)

        // Remote sends SABM (re-establishment)
        _ = sm.handle(event: .receivedSABM)

        XCTAssertEqual(sm.sequenceState.vs, 0)
        XCTAssertEqual(sm.sequenceState.vr, 0)
        XCTAssertEqual(sm.sequenceState.va, 0)
        XCTAssertTrue(sm.receiveBuffer.isEmpty)
        XCTAssertFalse(sm.rejSent)
    }

    /// Buffered out-of-order frames cleared on SABM re-establishment
    func testReceiveBufferFlushOnReestablishment() {
        var sm = makeConnectedStateMachine()

        // Buffer out-of-sequence frames
        _ = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("C".utf8)))
        _ = sm.handle(event: .receivedIFrame(ns: 3, nr: 0, pf: false, payload: Data("D".utf8)))
        XCTAssertEqual(sm.receiveBuffer.count, 2)

        _ = sm.handle(event: .receivedSABM)

        XCTAssertTrue(sm.receiveBuffer.isEmpty)
    }

    /// Back-to-back sessions reuse clean state
    func testBackToBackSessionsReuseCleanState() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // First session
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        sm.sequenceState.incrementVS()
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 1, pf: false, payload: Data("hi".utf8)))
        _ = sm.handle(event: .disconnectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .disconnected)

        // Second session
        _ = sm.handle(event: .connectRequest)
        XCTAssertEqual(sm.sequenceState.vs, 0, "V(S) must be 0 for new session")
        XCTAssertEqual(sm.sequenceState.vr, 0, "V(R) must be 0 for new session")
        XCTAssertEqual(sm.sequenceState.va, 0, "V(A) must be 0 for new session")

        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
    }

    // MARK: - Section 16: Edge Cases & Robustness

    /// N(R) == V(A) is no-op
    func testNREqualsVAIsNoOp() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()
        XCTAssertEqual(sm.sequenceState.va, 0)

        _ = sm.handle(event: .receivedRR(nr: 0))

        XCTAssertEqual(sm.sequenceState.va, 0, "RR with nr==va should not change anything")
        XCTAssertEqual(sm.sequenceState.outstandingCount, 1, "Outstanding count unchanged")
    }

    /// Zero-payload I-frame delivers empty Data
    func testZeroPayloadIFrame() {
        var sm = makeConnectedStateMachine()

        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data()))

        let delivered = extractDeliveredData(from: actions)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first, Data())
    }

    /// Max-payload (256-byte) I-frame delivered intact
    func testMaxPayloadIFrame() {
        var sm = makeConnectedStateMachine()

        let payload = Data(repeating: 0xAB, count: 256)
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: payload))

        let delivered = extractDeliveredData(from: actions)
        XCTAssertEqual(delivered.first, payload)
    }

    /// All 8×8 sequence number combinations for I-frame control byte (mod-8)
    func testAllSequenceNumberCombinationsForControlByte() {
        for ns in 0..<8 {
            for nr in 0..<8 {
                var sm = makeConnectedStateMachine()

                // Advance V(R) to ns so it's in-sequence
                for _ in 0..<ns {
                    sm.sequenceState.incrementVR()
                }

                let payload = Data([UInt8(ns), UInt8(nr)])
                let actions = sm.handle(event: .receivedIFrame(ns: ns, nr: nr, pf: false, payload: payload))
                let delivered = extractDeliveredData(from: actions)
                XCTAssertEqual(delivered.count, 1, "ns=\(ns), nr=\(nr) should deliver")
            }
        }
    }

    /// RR with N(R) beyond V(S) handled without crash
    func testRRWithNRBeyondVSIgnoredOrHandled() {
        var sm = makeConnectedStateMachine()
        sm.sequenceState.incrementVS()  // vs=1

        // RR(5) when vs=1 — N(R) beyond what we've sent
        // Should not crash; behavior is implementation-defined
        let actions = sm.handle(event: .receivedRR(nr: 5))

        // Main assertion: no crash, state still connected
        XCTAssertEqual(sm.state, .connected)
        _ = actions  // Consume; we just verify no crash
    }

    /// Send buffer empty after full window ack
    func testSendBufferEmptyAfterFullWindowAck() {
        var seq = AX25SequenceState(modulo: 8)

        // Send 7 frames (max window for mod-8)
        for _ in 0..<7 {
            seq.incrementVS()
        }
        XCTAssertEqual(seq.outstandingCount, 7)

        // Ack all
        seq.ackUpTo(nr: 7)
        XCTAssertEqual(seq.outstandingCount, 0)
    }

    /// Multiple disconnect requests while disconnecting are safe
    func testMultipleDisconnectRequestsIdempotent() {
        var sm = makeConnectedStateMachine()
        _ = sm.handle(event: .disconnectRequest)
        XCTAssertEqual(sm.state, .disconnecting)

        // Second disconnect while already disconnecting
        let actions = sm.handle(event: .disconnectRequest)
        XCTAssertTrue(actions.isEmpty, "Disconnect while disconnecting should be ignored")
        XCTAssertEqual(sm.state, .disconnecting)
    }

    // MARK: - Private helper for verifying RR poll in actions

    private func actions(_ actions: [AX25SessionAction], containRRPoll: Bool) -> Bool {
        let hasRRPoll = actions.contains { action in
            if case .sendRR(_, let pf) = action { return pf == true }
            return false
        }
        return hasRRPoll == containRRPoll
    }
}

// MARK: - Session Manager Level Tests (@MainActor)

@MainActor
final class AX25SpecComplianceManagerTests: XCTestCase {

    // MARK: - Helpers

    private func makeManager() -> AX25SessionManager {
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        return manager
    }

    private let destination = AX25Address(call: "N0HI", ssid: 7)
    private let path = DigiPath.from(["W0ARP-7"])

    private func connectSession(
        manager: AX25SessionManager,
        destination: AX25Address? = nil,
        path: DigiPath? = nil,
        channel: UInt8 = 0
    ) -> AX25Session {
        let dest = destination ?? self.destination
        let p = path ?? self.path
        _ = manager.connect(to: dest, path: p, channel: channel)
        let session = manager.session(for: dest, path: p, channel: channel)
        manager.handleInboundUA(from: dest, path: p, channel: channel)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    // MARK: - Section 5 (cont.): RR Poll Response at Manager Level

    /// At manager level: RR(P=1) → RR(F=1)
    func testRRPollResponseSendsRRFinal() {
        let manager = makeManager()
        let session = connectSession(manager: manager)

        // Send a frame so there's something to ack
        _ = manager.sendData(Data("test".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)

        // Inbound RR with poll=true
        let response = manager.handleInboundRR(
            from: destination, path: path, channel: 0, nr: 1, isPoll: true
        )


        XCTAssertNotNil(response, "Should respond to RR poll")
        XCTAssertEqual(response?.frameType, "s")
    }

    // MARK: - Section 7 (cont.): REJ at Manager Level

    /// REJ at manager level retransmits from N(R)
    func testREJAtManagerLevelRetransmitsFromNR() {
        let manager = makeManager()
        _ = connectSession(manager: manager)

        // Send 3 frames
        _ = manager.sendData(Data("A".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("B".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("C".utf8), to: destination, path: path, channel: 0)

        // REJ(1) — retransmit from ns=1 onwards
        let retransmitFrames = manager.handleInboundREJ(
            from: destination, path: path, channel: 0, nr: 1
        )


        // Should retransmit frames 1,2 (frame 0 was acked by REJ(1))
        let iFrames = retransmitFrames.filter { $0.frameType == "i" }
        XCTAssertEqual(iFrames.count, 2)
    }

    /// REJ retransmitted frames have current N(R)
    func testREJRetransmittedFramesHaveCurrentNR() {
        let manager = makeManager()
        let session = connectSession(manager: manager)

        _ = manager.sendData(Data("A".utf8), to: destination, path: path, channel: 0)

        // Receive 2 I-frames → V(R) advances to 2
        _ = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 0, nr: 0, pf: false, payload: Data("x".utf8)
        )
        _ = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 1, nr: 0, pf: false, payload: Data("y".utf8)
        )
        XCTAssertEqual(session.vr, 2)

        let retransmitFrames = manager.handleInboundREJ(
            from: destination, path: path, channel: 0, nr: 0
        )


        let iFrames = retransmitFrames.filter { $0.frameType == "i" }
        for frame in iFrames {
            XCTAssertEqual(frame.nr, 2, "Retransmitted frame must use current V(R)")
        }
    }

    /// REJ does not retransmit already-acked frames
    func testREJDoesNotRetransmitAlreadyAckedFrames() {
        let manager = makeManager()
        let session = connectSession(manager: manager)

        // Send 3 frames
        _ = manager.sendData(Data("A".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("B".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("C".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 3)

        // REJ(2) acks frames 0,1 and requests retransmit from 2
        let retransmitFrames = manager.handleInboundREJ(
            from: destination, path: path, channel: 0, nr: 2
        )


        let iFrames = retransmitFrames.filter { $0.frameType == "i" }
        XCTAssertEqual(iFrames.count, 1, "Should only retransmit frame 2")
    }

    // MARK: - Section 15 (cont.): Multi-Step Manager Scenarios

    /// Full session lifecycle at manager level
    func testFullSessionLifecycleManager() {
        let manager = makeManager()
        var receivedData: [Data] = []
        manager.onDataReceived = { _, data in receivedData.append(data) }

        // Connect
        let session = connectSession(manager: manager)

        // Send data
        let frames = manager.sendData(Data("Hello\r".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(frames.count, 1)

        // Receive response
        let inboundResponse = manager.handleInboundIFrame(
            from: destination, path: path, channel: 0,
            ns: 0, nr: 1, pf: false, payload: Data("Welcome".utf8)
        )
        // Check immediate ACK
        XCTAssertNotNil(inboundResponse)
        XCTAssertEqual(inboundResponse?.frameType, "s")
        
        XCTAssertEqual(receivedData.count, 1)

        // Disconnect
        let disc = manager.disconnect(session: session)
        XCTAssertNotNil(disc)
        XCTAssertEqual(session.state, .disconnecting)
    }

    /// Window full then ack drains pending queue at manager level
    func testWindowFullThenAckDrainsPendingQueueManager() {
        let manager = makeManager()
        manager.defaultConfig = AX25SessionConfig(windowSize: 2)
        let session = connectSession(manager: manager)

        // Send 4 chunks — only 2 fit in window, rest queued
        _ = manager.sendData(Data("A".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("B".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 2)
        _ = manager.sendData(Data("C".utf8), to: destination, path: path, channel: 0)
        _ = manager.sendData(Data("D".utf8), to: destination, path: path, channel: 0)
        XCTAssertEqual(session.pendingDataQueue.count, 2)

        // RR acks both outstanding frames — should drain pending queue
        // Capture any frames sent immediately (clearing queue sends I-frames)
        let sentFrames = manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 2)
        
        // Technically handleInboundRR returns a single frame if it generates one (like an updated RR or REJ),
        // but draining the queue happens as a side effect within the state machine or session.
        // The `handleInboundRR` might not return the *newly transmitted* I-frames directly if they are
        // sent via `sendFrame` internally.
        // However, looking at SessionManager, `processActions` for `sendFram` calls `sendFrame(frame)`.
        // If `AX25SessionManager` was refactored to *return* frames instead of using callbacks/delegates,
        // then `handleInboundRR` (which calls `processActions`) should probably return a list of frames?
        // Wait, the previous refactors suggests `handle...` returns `OutboundFrame?` (singular).
        // If multiple I-frames are sent due to queue draining, how are they returned?
        //
        // Let's re-read `AX25SessionManager.swift` to see how `handleInboundRR` handles multiple actions.
        // If it returns only one, we might miss others.
        // But let's check the assertion. The assertion checks state (`outstandingCount`, `pendingDataQueue`).
        // It doesn't check `sentFrames`. So we might not need to capture them for *this* test,
        // unless the test depended on `onSendFrame` to verify they were sent.
        // The original check was: `XCTAssertEqual(session.outstandingCount, 2)`.
        // This implies the frames MOVED from pending to outstanding.
        // So checking side effects on `session` is sufficient.
        
        XCTAssertEqual(session.outstandingCount, 2, "Drained chunks should now be outstanding")
        XCTAssertEqual(session.pendingDataQueue.count, 0, "Queue should be empty after drain")
    }

    /// T1 timeout retransmit preserves payload integrity
    func testRetransmitPreservesPayloadIntegrity() {
        let manager = makeManager()
        let session = connectSession(manager: manager)

        let payload = Data("Important data".utf8)
        _ = manager.sendData(payload, to: destination, path: path, channel: 0)

        let retransmitFrames = manager.handleT1Timeout(session: session)

        let iFrames = retransmitFrames.filter { $0.frameType == "i" }

        XCTAssertFalse(iFrames.isEmpty)
        for frame in iFrames {
            XCTAssertEqual(frame.payload, payload, "Retransmitted payload must match original")
        }
    }

    // MARK: - Section 12 (cont.): Retransmit from Wrapped V(A)

    /// framesToRetransmit with wrapped V(A) returns correct frames
    func testRetransmitFromWrappedVA() {
        let manager = makeManager()
        // Use window=7 so all 7 frames fit without queuing
        manager.defaultConfig = AX25SessionConfig(windowSize: 7)
        let session = connectSession(manager: manager)

        // Send 4 frames (ns=0,1,2,3), ack all
        for _ in 0..<4 {
            _ = manager.sendData(Data("X".utf8), to: destination, path: path, channel: 0)
        }
        manager.handleInboundRR(from: destination, path: path, channel: 0, nr: 4)
        XCTAssertEqual(session.va, 4)
        XCTAssertEqual(session.outstandingCount, 0)

        // Send 4 more (ns=4,5,6,0) which wraps around 7
        // Actually, modulo is 8 usually.
        // Let's rely on standard modulo 8 behavior.
        // WE need to send enough to wrap.
        // ns=4
        _ = manager.sendData(Data("4".utf8), to: destination, path: path, channel: 0)
        // ns=5
        _ = manager.sendData(Data("5".utf8), to: destination, path: path, channel: 0)
        // ns=6
        _ = manager.sendData(Data("6".utf8), to: destination, path: path, channel: 0)
        // ns=7
        _ = manager.sendData(Data("7".utf8), to: destination, path: path, channel: 0)
        // ns=0
        _ = manager.sendData(Data("0".utf8), to: destination, path: path, channel: 0)
        
        // Check outstanding count
        XCTAssertEqual(session.outstandingCount, 5)

        // Capture retransmits
        let retransmitFrames = manager.handleT1Timeout(session: session)

        let iFrames = retransmitFrames.filter { $0.frameType == "i" }
        XCTAssertEqual(iFrames.count, 5)
        
        let nsValues = iFrames.map { $0.ns }
        XCTAssertEqual(nsValues, [4, 5, 6, 7, 0], "Should retransmit in correct wrapped order")
    }
}
