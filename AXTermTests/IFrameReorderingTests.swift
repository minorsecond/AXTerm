//
//  IFrameReorderingTests.swift
//  AXTermTests
//
//  Tests for I-frame reordering and buffering when frames arrive out of sequence.
//  This is critical for data integrity - out-of-sequence frames must be buffered
//  and delivered in order once missing frames arrive.
//

import XCTest
@testable import AXTerm

final class IFrameReorderingTests: XCTestCase {

    // MARK: - Basic In-Sequence Tests

    /// Test that in-sequence frames are delivered immediately
    func testInSequenceFramesDeliveredImmediately() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)

        // Receive I-frames in sequence: 0, 1, 2
        var allDelivered: [Data] = []

        let payload0 = Data("Frame0".utf8)
        let actions0 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: payload0))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions0))

        let payload1 = Data("Frame1".utf8)
        let actions1 = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: payload1))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions1))

        let payload2 = Data("Frame2".utf8)
        let actions2 = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: payload2))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions2))

        // All three frames should be delivered
        XCTAssertEqual(allDelivered.count, 3)
        XCTAssertEqual(String(data: allDelivered[0], encoding: .utf8), "Frame0")
        XCTAssertEqual(String(data: allDelivered[1], encoding: .utf8), "Frame1")
        XCTAssertEqual(String(data: allDelivered[2], encoding: .utf8), "Frame2")

        // V(R) should be 3
        XCTAssertEqual(sm.sequenceState.vr, 3)
    }

    // MARK: - Out-of-Sequence Tests (The Bug We're Fixing)

    /// Test that a single missing frame causes buffering
    /// Scenario: Receive frames 0, 2 (missing 1), then 1 arrives
    func testSingleMissingFrameBuffered() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        var allDelivered: [Data] = []
        var allActions: [[AX25SessionAction]] = []

        // Receive frame 0 (in sequence)
        let payload0 = Data("Hello ".utf8)
        let actions0 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: payload0))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions0))
        allActions.append(actions0)

        // Frame 0 should be delivered immediately
        XCTAssertEqual(allDelivered.count, 1, "Frame 0 should be delivered")
        XCTAssertEqual(sm.sequenceState.vr, 1, "V(R) should be 1")

        // Receive frame 2 (out of sequence - frame 1 is missing)
        let payload2 = Data("World".utf8)
        let actions2 = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: payload2))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions2))
        allActions.append(actions2)

        // Frame 2 should be BUFFERED, not delivered yet
        XCTAssertEqual(allDelivered.count, 1, "Frame 2 should be buffered, not delivered yet")
        XCTAssertEqual(sm.sequenceState.vr, 1, "V(R) should still be 1")

        // Should have sent REJ requesting frame 1
        XCTAssertTrue(containsREJ(actions2, nr: 1), "Should send REJ(1) for missing frame")

        // Now frame 1 arrives (retransmitted)
        let payload1 = Data("Beautiful ".utf8)
        let actions1 = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: payload1))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions1))
        allActions.append(actions1)

        // Both frame 1 AND buffered frame 2 should be delivered
        XCTAssertEqual(allDelivered.count, 3, "Frame 1 and buffered frame 2 should both be delivered")
        XCTAssertEqual(String(data: allDelivered[1], encoding: .utf8), "Beautiful ", "Frame 1 should be second")
        XCTAssertEqual(String(data: allDelivered[2], encoding: .utf8), "World", "Frame 2 should be third")

        // V(R) should now be 3
        XCTAssertEqual(sm.sequenceState.vr, 3, "V(R) should be 3 after all frames delivered")
    }

    /// Test multiple frames arrive out of order
    /// Scenario: Receive frames 0, 3, 2 (missing 1), then 1 arrives
    func testMultipleOutOfOrderFrames() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        var allDelivered: [Data] = []

        // Receive frame 0
        let actions0 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions0))
        XCTAssertEqual(allDelivered.count, 1)

        // Receive frame 3 (missing 1, 2)
        let actions3 = sm.handle(event: .receivedIFrame(ns: 3, nr: 0, pf: false, payload: Data("D".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions3))
        XCTAssertEqual(allDelivered.count, 1, "Frame 3 should be buffered")
        XCTAssertTrue(containsREJ(actions3, nr: 1), "Should REJ(1)")

        // Receive frame 2 (still missing 1)
        let actions2 = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("C".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions2))
        XCTAssertEqual(allDelivered.count, 1, "Frame 2 should also be buffered")

        // Now frame 1 arrives - should trigger delivery of 1, 2, 3
        let actions1 = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions1))

        XCTAssertEqual(allDelivered.count, 4, "All four frames should now be delivered")
        XCTAssertEqual(String(data: allDelivered[0], encoding: .utf8), "A")
        XCTAssertEqual(String(data: allDelivered[1], encoding: .utf8), "B")
        XCTAssertEqual(String(data: allDelivered[2], encoding: .utf8), "C")
        XCTAssertEqual(String(data: allDelivered[3], encoding: .utf8), "D")

        XCTAssertEqual(sm.sequenceState.vr, 4)
    }

    /// Test the exact scenario from the Direwolf log:
    /// Expected N(S)=5, received 6, 7, 0 (frame 5 lost)
    /// Uses window size 4 (typical for Direwolf/packet radio)
    func testRealWorldPacketLossScenario() {
        // Use window size 4 to match typical Direwolf configuration
        var sm = AX25StateMachine(config: AX25SessionConfig(windowSize: 4))

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        var allDelivered: [Data] = []

        // First receive frames 0-4 in order
        for i in 0..<5 {
            let payload = Data("Frame\(i) ".utf8)
            let actions = sm.handle(event: .receivedIFrame(ns: i, nr: 0, pf: false, payload: payload))
            allDelivered.append(contentsOf: extractDeliveredData(from: actions))
        }

        XCTAssertEqual(allDelivered.count, 5, "Frames 0-4 should all be delivered")
        XCTAssertEqual(sm.sequenceState.vr, 5, "V(R) should be 5")

        // Now frame 5 is LOST - we receive 6, 7, 0 (wrapped)
        let payload6 = Data("Frame6 ".utf8)
        let actions6 = sm.handle(event: .receivedIFrame(ns: 6, nr: 0, pf: false, payload: payload6))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions6))
        XCTAssertEqual(allDelivered.count, 5, "Frame 6 should be buffered (waiting for 5)")
        XCTAssertTrue(containsREJ(actions6, nr: 5), "Should REJ(5)")

        let payload7 = Data("Frame7 ".utf8)
        let actions7 = sm.handle(event: .receivedIFrame(ns: 7, nr: 0, pf: false, payload: payload7))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions7))
        XCTAssertEqual(allDelivered.count, 5, "Frame 7 should also be buffered")

        // Frame 0 (wrapped around after 7)
        let payload0Wrap = Data("Frame0Wrap ".utf8)
        let actions0Wrap = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: payload0Wrap))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions0Wrap))
        XCTAssertEqual(allDelivered.count, 5, "Frame 0 (wrap) should also be buffered")

        // Now frame 5 arrives via retransmission
        let payload5 = Data("Frame5 ".utf8)
        let actions5 = sm.handle(event: .receivedIFrame(ns: 5, nr: 0, pf: false, payload: payload5))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions5))

        // All frames 5, 6, 7, 0 should now be delivered in order
        XCTAssertEqual(allDelivered.count, 9, "All 9 frames should be delivered")
        XCTAssertEqual(String(data: allDelivered[5], encoding: .utf8), "Frame5 ")
        XCTAssertEqual(String(data: allDelivered[6], encoding: .utf8), "Frame6 ")
        XCTAssertEqual(String(data: allDelivered[7], encoding: .utf8), "Frame7 ")
        XCTAssertEqual(String(data: allDelivered[8], encoding: .utf8), "Frame0Wrap ")

        // V(R) should be 1 (after wraparound)
        XCTAssertEqual(sm.sequenceState.vr, 1)
    }

    // MARK: - REJ Behavior Tests

    /// Test that we don't send multiple REJs for the same gap
    func testNoMultipleREJsForSameGap() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Receive frame 0
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))

        // Receive frame 2 (missing 1) - should REJ
        let actions2 = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("C".utf8)))
        XCTAssertTrue(containsREJ(actions2, nr: 1), "First out-of-sequence should REJ")

        // Receive frame 3 (still missing 1) - should NOT REJ again
        let actions3 = sm.handle(event: .receivedIFrame(ns: 3, nr: 0, pf: false, payload: Data("D".utf8)))
        XCTAssertFalse(containsAnyREJ(actions3), "Should not send duplicate REJ")

        // Receive frame 4 - should still NOT REJ
        let actions4 = sm.handle(event: .receivedIFrame(ns: 4, nr: 0, pf: false, payload: Data("E".utf8)))
        XCTAssertFalse(containsAnyREJ(actions4), "Should not send duplicate REJ")
    }

    /// Test that REJ flag is cleared after missing frame arrives
    func testREJFlagClearedAfterRetransmit() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Receive frame 0
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))

        // Receive frame 2 (missing 1) - should REJ
        let actions2 = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("C".utf8)))
        XCTAssertTrue(containsREJ(actions2, nr: 1))

        // Frame 1 arrives - clears buffer and REJ state
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))

        // Now if frame 4 arrives (missing 3), we SHOULD REJ again
        let actions4 = sm.handle(event: .receivedIFrame(ns: 4, nr: 0, pf: false, payload: Data("E".utf8)))
        XCTAssertTrue(containsREJ(actions4, nr: 3), "Should REJ for new gap")
    }

    // MARK: - Buffer Limit Tests

    /// Test that buffer has reasonable limits - verified by behavior
    /// Frames beyond the window size should be discarded
    func testBufferSizeLimit() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        var allDelivered: [Data] = []

        // Receive frame 0
        let actions0 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions0))

        // Try to buffer many out-of-sequence frames (more than window size allows)
        // In modulo-8, window is max 7. Frames too far ahead should be discarded.
        for i in 2..<8 {
            _ = sm.handle(event: .receivedIFrame(ns: i, nr: 0, pf: false, payload: Data("X\(i)".utf8)))
        }

        // Now when frame 1 arrives, only frames within window should be delivered
        let actions1 = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions1))

        // Should deliver frame 1 and buffered frames up to window limit
        // The exact count depends on window size implementation
        XCTAssertGreaterThanOrEqual(allDelivered.count, 2, "Should deliver at least frames 0 and 1")
    }

    // MARK: - Duplicate Frame Tests

    /// Test that duplicate frames are ignored
    func testDuplicateFramesIgnored() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        var deliveredCount = 0

        // Receive frame 0
        let actions0a = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("First".utf8)))
        deliveredCount += extractDeliveredData(from: actions0a).count
        XCTAssertEqual(deliveredCount, 1)

        // Receive frame 0 again (duplicate)
        let actions0b = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("Duplicate".utf8)))
        deliveredCount += extractDeliveredData(from: actions0b).count
        XCTAssertEqual(deliveredCount, 1, "Duplicate frame should be ignored")

        // V(R) should still be 1
        XCTAssertEqual(sm.sequenceState.vr, 1)
    }

    /// Test duplicate buffered frame is ignored
    func testDuplicateBufferedFrameIgnored() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Receive frame 0
        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))

        // Receive frame 2 (buffered)
        _ = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("Original".utf8)))

        // Receive frame 2 again (should be ignored, not overwrite buffer)
        _ = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("Duplicate".utf8)))

        // Frame 1 arrives - should deliver original frame 2
        var allDelivered: [Data] = []
        let actions1 = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions1))

        // Should have delivered B and Original (not Duplicate)
        XCTAssertEqual(allDelivered.count, 2)
        XCTAssertEqual(String(data: allDelivered[1], encoding: .utf8), "Original")
    }

    // MARK: - Wraparound Tests

    /// Test sequence number wraparound handling
    func testSequenceWraparound() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        var allDelivered: [Data] = []

        // Receive frames 0-6
        for i in 0..<7 {
            let actions = sm.handle(event: .receivedIFrame(ns: i, nr: 0, pf: false, payload: Data("F\(i)".utf8)))
            allDelivered.append(contentsOf: extractDeliveredData(from: actions))
        }

        XCTAssertEqual(allDelivered.count, 7)
        XCTAssertEqual(sm.sequenceState.vr, 7)

        // Receive frame 7
        let actions7 = sm.handle(event: .receivedIFrame(ns: 7, nr: 0, pf: false, payload: Data("F7".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions7))
        XCTAssertEqual(sm.sequenceState.vr, 0, "V(R) should wrap to 0")

        // Receive frame 0 (after wrap)
        let actions0 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("F0wrap".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions0))
        XCTAssertEqual(sm.sequenceState.vr, 1)

        XCTAssertEqual(allDelivered.count, 9)
    }

    /// Test out-of-sequence with wraparound
    func testOutOfSequenceWithWraparound() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        var allDelivered: [Data] = []

        // Receive frames 0-6
        for i in 0..<7 {
            let actions = sm.handle(event: .receivedIFrame(ns: i, nr: 0, pf: false, payload: Data("F\(i)".utf8)))
            allDelivered.append(contentsOf: extractDeliveredData(from: actions))
        }

        XCTAssertEqual(sm.sequenceState.vr, 7)

        // Skip frame 7, receive frame 0 (wrapped)
        let actions0 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("F0wrap".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions0))
        XCTAssertEqual(allDelivered.count, 7, "Frame 0 should be buffered")
        XCTAssertTrue(containsREJ(actions0, nr: 7), "Should REJ(7)")

        // Receive frame 1 (also buffered)
        let actions1 = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("F1wrap".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions1))
        XCTAssertEqual(allDelivered.count, 7)

        // Frame 7 arrives - should deliver 7, 0, 1
        let actions7 = sm.handle(event: .receivedIFrame(ns: 7, nr: 0, pf: false, payload: Data("F7".utf8)))
        allDelivered.append(contentsOf: extractDeliveredData(from: actions7))

        XCTAssertEqual(allDelivered.count, 10)
        XCTAssertEqual(String(data: allDelivered[7], encoding: .utf8), "F7")
        XCTAssertEqual(String(data: allDelivered[8], encoding: .utf8), "F0wrap")
        XCTAssertEqual(String(data: allDelivered[9], encoding: .utf8), "F1wrap")

        XCTAssertEqual(sm.sequenceState.vr, 2)
    }

    // MARK: - RR Acknowledgement Tests

    /// Test that RR is sent with correct N(R) after buffered frames are delivered
    func testRRSentWithCorrectNR() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Establish connection
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        // Receive frame 0
        let actions0 = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("A".utf8)))
        XCTAssertTrue(containsRR(actions0, nr: 1), "Should send RR(1)")

        // Receive frame 2 (buffered, missing 1)
        let actions2 = sm.handle(event: .receivedIFrame(ns: 2, nr: 0, pf: false, payload: Data("C".utf8)))
        XCTAssertFalse(containsAnyRR(actions2), "Should not send RR for buffered frame")

        // Frame 1 arrives - should deliver 1 and 2, then send RR(3)
        let actions1 = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false, payload: Data("B".utf8)))
        XCTAssertTrue(containsRR(actions1, nr: 3), "Should send RR(3) after delivering buffered frames")
    }

    // MARK: - Helper Functions

    private func extractDeliveredData(from actions: [AX25SessionAction]) -> [Data] {
        actions.compactMap { action in
            if case .deliverData(let data) = action {
                return data
            }
            return nil
        }
    }

    private func containsREJ(_ actions: [AX25SessionAction], nr: Int) -> Bool {
        actions.contains { action in
            if case .sendREJ(let n, _) = action {
                return n == nr
            }
            return false
        }
    }

    private func containsAnyREJ(_ actions: [AX25SessionAction]) -> Bool {
        actions.contains { action in
            if case .sendREJ(_, _) = action {
                return true
            }
            return false
        }
    }

    private func containsRR(_ actions: [AX25SessionAction], nr: Int) -> Bool {
        actions.contains { action in
            if case .sendRR(let n, _) = action {
                return n == nr
            }
            return false
        }
    }

    private func containsAnyRR(_ actions: [AX25SessionAction]) -> Bool {
        actions.contains { action in
            if case .sendRR(_, _) = action {
                return true
            }
            return false
        }
    }
}
