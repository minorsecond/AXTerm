import XCTest
@testable import AXTerm

/// The W0ARP-10 download deadlock of 2026-08-24.
///
/// A gateway running four outstanding I-frames talked to a session whose
/// adaptive controller had settled on K=2. Frames more than one ahead of V(R)
/// were discarded rather than buffered, so N(S)=7 — which arrived twice while
/// V(R) was 4 — was thrown away both times. When V(R) reached 7 the frame was
/// gone and had to be requested again; the gateway had already sent it and
/// moved on, and after 60 s of stalemate it disconnected.
///
/// Two independent faults made that unrecoverable, and both are covered here:
/// the receive span was tied to our transmit window, and the REJ recovery
/// timer was disarmed by the peer's keepalive polls.
@MainActor
final class ReceiveWindowDeadlockTests: XCTestCase {

    private var manager: AX25SessionManager!

    override func setUp() {
        super.setUp()
        manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    private let peer = AX25Address(call: "W0ARP", ssid: 10)

    /// Brings up a session with our transmit window pinned to `k`.
    private func connectedSession(k: Int) -> AX25Session {
        manager.getConfigForDestination = { _, _ in
            AX25SessionConfig(windowSize: k, maxRetries: 15)
        }
        _ = manager.handleInboundSABM(
            from: peer, to: manager.localCallsign, path: DigiPath(), channel: 0)
        let session = manager.existingSession(for: peer)!
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.stateMachine.config.windowSize, k)
        return session
    }

    @discardableResult
    private func deliverIFrame(_ session: AX25Session, ns: Int, pf: Bool = false) -> [Data] {
        var delivered = [Data]()
        manager.onDataReceived = { _, data in delivered.append(data) }
        _ = manager.handleInboundIFrame(
            from: peer, path: DigiPath(), channel: 0,
            ns: ns, nr: 0, pf: pf, payload: Data("f\(ns)".utf8))
        return delivered
    }

    // MARK: - Receive span

    /// The exact field sequence: with V(R)=4 the gateway's frames 5, 6 and 7
    /// all arrive before 4 does. All three must be held, so that when 4
    /// finally lands the whole run delivers at once and V(R) jumps to 0.
    func testFramesFromAPeerWithABiggerWindowAreBuffered() {
        let session = connectedSession(k: 2)
        // Walk V(R) to 4 the honest way.
        for ns in 0..<4 { deliverIFrame(session, ns: ns) }
        XCTAssertEqual(session.stateMachine.sequenceState.vr, 4)

        // Early arrivals, out of order, from a peer running more than K=2.
        deliverIFrame(session, ns: 5)
        deliverIFrame(session, ns: 6)
        deliverIFrame(session, ns: 7)
        XCTAssertEqual(session.stateMachine.receiveBuffer.count, 3,
                       "5, 6 and 7 must all be held — discarding them is what deadlocked the link")

        let delivered = deliverIFrame(session, ns: 4)
        XCTAssertEqual(delivered.count, 4, "4, 5, 6 and 7 deliver together")
        XCTAssertEqual(session.stateMachine.sequenceState.vr, 0,
                       "V(R) wraps past the whole run; nothing has to be re-requested")
        XCTAssertTrue(session.stateMachine.receiveBuffer.isEmpty)
    }

    /// The receive span is a property of the sequence space. Shrinking our own
    /// transmit window must not shrink what we are willing to hear.
    func testReceiveSpanDoesNotFollowOurTransmitWindow() {
        for k in 1...7 {
            let session = connectedSession(k: k)
            deliverIFrame(session, ns: 3)
            XCTAssertEqual(session.stateMachine.receiveBuffer.count, 1,
                           "N(S)=3 at V(R)=0 must be buffered at K=\(k)")
            manager.removeSession(session)
        }
    }

    /// Half the modulo is the disambiguation bound: at or past it a number may
    /// be a duplicate from the previous lap, and buffering it as "future"
    /// delivers a lap-old payload when V(R) wraps onto it.
    func testFramesAtOrBeyondHalfTheModuloAreNotBufferedAsFuture() {
        let session = connectedSession(k: 7)
        for ns in [4, 5, 6, 7] {
            deliverIFrame(session, ns: ns)
        }
        XCTAssertTrue(session.stateMachine.receiveBuffer.isEmpty,
                      "distance >= modulo/2 is ambiguous and must be treated as a duplicate")
    }

    /// The buffer has to be able to hold everything the window test accepts —
    /// defaulting its size to K silently undid the wider span.
    func testBufferHoldsAFullReceiveSpan() {
        let session = connectedSession(k: 2)
        deliverIFrame(session, ns: 1)
        deliverIFrame(session, ns: 2)
        deliverIFrame(session, ns: 3)
        XCTAssertEqual(session.stateMachine.receiveBuffer.count, 3,
                       "a K-sized buffer evicted frames the window test had just accepted")
    }

    // MARK: - REJ recovery timer

    /// During a download nothing of ours is outstanding, so T1 exists solely to
    /// time the retransmission our REJ asked for. An inbound RR must not stop
    /// it: W0ARP-10 polls every ~15 s, inside an 18.7 s RTO, so that cancel
    /// meant T1 could never fire and one lost REJ stranded the gap for good.
    func testInboundRRDoesNotDisarmRejRecovery() {
        let session = connectedSession(k: 2)
        deliverIFrame(session, ns: 1)   // gap at 0 → REJ
        XCTAssertTrue(session.stateMachine.rejSent, "a gap must raise REJ")
        XCTAssertEqual(session.stateMachine.sequenceState.outstandingCount, 0,
                       "receive-only: nothing of ours is in flight")

        let actions = session.stateMachine.handle(
            event: .receivedRR(nr: 0, pf: true, isCommand: true))

        XCTAssertFalse(actions.contains { if case .stopT1 = $0 { return true }; return false },
                       "stopping T1 here disarms REJ recovery")
        XCTAssertFalse(actions.contains { if case .startT1 = $0 { return true }; return false },
                       "restarting it is the same stall — each poll would push the deadline out")
    }

    /// With no REJ outstanding an RR that clears the last outstanding frame
    /// should still stop T1, as before.
    func testInboundRRStillStopsT1WhenNoGapIsOutstanding() {
        let session = connectedSession(k: 2)
        deliverIFrame(session, ns: 0)   // in sequence, no gap
        XCTAssertFalse(session.stateMachine.rejSent)

        let actions = session.stateMachine.handle(
            event: .receivedRR(nr: 0, pf: false, isCommand: false))

        XCTAssertTrue(actions.contains { if case .stopT1 = $0 { return true }; return false },
                      "an idle link must not leave T1 running")
    }

    /// Filling the gap clears the REJ condition, so T1 is released again.
    func testFillingTheGapReleasesTheTimer() {
        let session = connectedSession(k: 2)
        deliverIFrame(session, ns: 1)
        XCTAssertTrue(session.stateMachine.rejSent)

        deliverIFrame(session, ns: 0)
        XCTAssertFalse(session.stateMachine.rejSent, "the gap is filled")

        let actions = session.stateMachine.handle(
            event: .receivedRR(nr: 0, pf: false, isCommand: false))
        XCTAssertTrue(actions.contains { if case .stopT1 = $0 { return true }; return false })
    }
}
