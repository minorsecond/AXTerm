import XCTest
@testable import AXTerm

/// A node's greeting that arrives with its first frame missing.
///
/// Field capture 2026-08-27: KB5YZB-7 accepted the link, then its banner came
/// in as N(S)=1 with N(S)=0 lost on air. AXTerm sent REJ(0); the node never
/// resent. The greeting sat in the receive buffer undelivered, the relay
/// handshake timed out with the prompt in hand but unread, and the operator was
/// told the node "never sent its prompt".
final class RelayReceiveGapTests: XCTestCase {

    private func connectedMachine() -> AX25StateMachine {
        var machine = AX25StateMachine(config: AX25SessionConfig())
        _ = machine.handle(event: .connectRequest)
        _ = machine.handle(event: .receivedUA)
        XCTAssertEqual(machine.state, .connected)
        return machine
    }

    /// The deadlock itself: frame 1 arrives, frame 0 never does, and nothing
    /// reaches the application.
    func testAFrameAheadOfTheGapIsNotDelivered() {
        var machine = connectedMachine()
        let actions = machine.handle(
            event: .receivedIFrame(ns: 1, nr: 0, pf: true, payload: Data("BANNER".utf8)))

        XCTAssertFalse(actions.contains { if case .deliverData = $0 { return true }; return false },
                       "out-of-sequence data is withheld until the gap heals")
        XCTAssertTrue(actions.contains { if case .sendREJ = $0 { return true }; return false },
                      "and the missing frame is asked for")
        XCTAssertEqual(machine.sequenceState.vr, 0, "V(R) stays put")
    }

    /// Clearing the gap releases it — which is all the handshake was waiting
    /// for, since any first frame from the node counts as its greeting.
    func testClearingTheGapReleasesTheBanner() {
        var machine = connectedMachine()
        _ = machine.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: true, payload: Data("BANNER".utf8)))

        let delivered = machine.skipReceiveGapForHandshake().compactMap { action -> Data? in
            if case let .deliverData(data, _) = action { return data }
            return nil
        }
        XCTAssertEqual(delivered, [Data("BANNER".utf8)])
        XCTAssertEqual(machine.sequenceState.vr, 2, "V(R) moves past the skipped frame")
        XCTAssertTrue(machine.receiveBuffer.isEmpty)
    }

    /// Everything stranded comes through, not just the first of them.
    func testEveryStrandedFrameIsReleased() {
        var machine = connectedMachine()
        for ns in 1...3 {
            _ = machine.handle(event: .receivedIFrame(ns: ns, nr: 0, pf: false,
                                               payload: Data("F\(ns)".utf8)))
        }
        let delivered = machine.skipReceiveGapForHandshake().compactMap { action -> Data? in
            if case let .deliverData(data, _) = action { return data }
            return nil
        }
        XCTAssertEqual(delivered, [Data("F1".utf8), Data("F2".utf8), Data("F3".utf8)])
        XCTAssertEqual(machine.sequenceState.vr, 4)
    }

    /// A silent node has nothing stranded, so the caller learns to prod it
    /// rather than silently doing nothing.
    func testNothingStrandedReportsNothingToRelease() {
        var machine = connectedMachine()
        XCTAssertTrue(machine.skipReceiveGapForHandshake().isEmpty)
    }

    /// In-sequence delivery is untouched — the flush is not on that path.
    func testAnInSequenceFrameStillArrivesNormally() {
        var machine = connectedMachine()
        let actions = machine.handle(
            event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data("HELLO".utf8)))
        XCTAssertTrue(actions.contains { if case .deliverData = $0 { return true }; return false })
        XCTAssertEqual(machine.sequenceState.vr, 1)
        XCTAssertTrue(machine.skipReceiveGapForHandshake().isEmpty)
    }
}
