//
//  AX25LinkResetTests.swift
//  AXTermTests
//
//  A SABM on a connected link is a link reset. AX.25 2.2's data-link SDL
//  (appendix C4, connected and timer-recovery states) answers it with UA,
//  zeroes the state variables, and when frames were still unacknowledged
//  (V(S) != V(A)) discards the I-frame queue and gives layer 3 a DL-CONNECT
//  indication: the old conversation's data in flight is gone, and the layer
//  above must know.
//
//  Found by ConnectedModeStressTests (restart-reconnect family): a peer that
//  crashed mid-transfer and called straight back reset the survivor's link.
//  The survivor dropped its unacknowledged frames, kept sending its queue on
//  the new link, and told nobody, so the far end received a stream with a
//  hole in it and both applications believed the transfer was intact.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25LinkResetTests: XCTestCase {

    private let local = AX25Address(call: "K0AAA", ssid: 1)
    private let peer = AX25Address(call: "K0BBB", ssid: 2)

    private func connectedManager(clock: AX25VirtualClock? = nil) -> (AX25SessionManager, AX25Session) {
        let manager = AX25SessionManager(localCallsign: local, clock: clock ?? AX25VirtualClock())
        manager.defaultConfig = AX25SessionConfig(windowSize: 2, paclen: 64)
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
        return (manager, session)
    }

    func testAResetWithFramesUnacknowledgedTellsTheLayerAboveAndDropsTheQueue() {
        let (manager, session) = connectedManager()
        var changes: [(AX25SessionState, AX25SessionState)] = []
        manager.onSessionStateChanged = { _, from, to in changes.append((from, to)) }
        // Two frames on the air (K=2), three more queued behind them.
        _ = manager.sendData(Data(repeating: 0x41, count: 64 * 5), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.outstandingCount, 2)
        XCTAssertEqual(session.pendingDataQueue.count, 3)

        let ua = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)

        XCTAssertEqual(ua?.displayInfo, "UA")
        XCTAssertEqual(session.state, .connected, "the link is up again, reset")
        XCTAssertEqual(session.vs, 0)
        XCTAssertEqual(session.va, 0)
        XCTAssertTrue(session.pendingDataQueue.isEmpty,
                      "the I-frame queue belongs to the old link and is discarded")
        XCTAssertEqual(changes.map { "\($0.0.rawValue)>\($0.1.rawValue)" },
                       ["connected>disconnected", "disconnected>connected"],
                       "the layer above sees the old link end and a new one begin")
    }

    func testAResetWithEverythingAcknowledgedKeepsQuiet() {
        let (manager, session) = connectedManager()
        var changes: [(AX25SessionState, AX25SessionState)] = []
        manager.onSessionStateChanged = { _, from, to in changes.append((from, to)) }
        _ = manager.sendData(Data(repeating: 0x41, count: 10), to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: 1, isPoll: false)
        XCTAssertEqual(session.outstandingCount, 0)

        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)

        XCTAssertEqual(session.state, .connected)
        XCTAssertTrue(changes.isEmpty, "nothing was lost, so there is nothing to report")
    }

    // MARK: - An unexpected UA (live test log, bug 39)

    /// AX.25 2.2 SDL, connected and timer-recovery states: a UA is
    /// unexpected (error C). The station establishes the data link again
    /// (clear exception conditions, RC := 0, SABM with P=1, stop T3, start
    /// T1), clears "layer 3 initiated" and goes to awaiting connection. The
    /// layer above is told nothing yet.
    ///
    /// Field case 2026-10-02: A's T1 fired while Warbler held its first SABM
    /// 3.6 s before keying, so A sent a second. B answered the first, then
    /// reset its link for the second and answered that too. A ignored the
    /// second UA and the two sides' sequence numbers parted.
    func testAUAWhileConnectedEstablishesTheLinkAgain() {
        let (manager, session) = connectedManager()
        var changes: [String] = []
        manager.onSessionStateChanged = { _, from, to in changes.append("\(from.rawValue)>\(to.rawValue)") }

        let frames = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)

        XCTAssertEqual(frames.map(\.displayInfo), ["SABM"])
        XCTAssertEqual(frames.first?.controlByte.map { $0 & 0x10 }, 0x10, "the SABM polls")
        XCTAssertEqual(session.state, .connecting, "awaiting connection")
        XCTAssertFalse(session.stateMachine.layer3Initiated)
        XCTAssertEqual(changes, [], "no indication until the link is up again")
    }

    /// The UA that answers that SABM: frames were unacknowledged, so the
    /// I-frame queue is discarded and layer 3 gets DL-CONNECT indication,
    /// which the layer above sees as the old link ending and a new one
    /// beginning.
    func testReestablishingWithFramesUnacknowledgedTellsTheLayerAbove() {
        let (manager, session) = connectedManager()
        var changes: [String] = []
        manager.onSessionStateChanged = { _, from, to in changes.append("\(from.rawValue)>\(to.rawValue)") }
        _ = manager.sendData(Data(repeating: 0x41, count: 64 * 5), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.outstandingCount, 2)

        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.vs, 0)
        XCTAssertEqual(session.va, 0)
        XCTAssertEqual(session.vr, 0)
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertTrue(session.pendingDataQueue.isEmpty, "the queue belonged to the old link")
        XCTAssertEqual(changes, ["connected>disconnected", "disconnected>connected"])
    }

    /// Nothing was outstanding, so the SDL gives layer 3 no indication: the
    /// link is re-established with V(S) = V(A) = V(R) = 0 and nobody above
    /// is told.
    func testReestablishingWithEverythingAcknowledgedKeepsQuiet() {
        let (manager, session) = connectedManager()
        var changes: [String] = []
        manager.onSessionStateChanged = { _, from, to in changes.append("\(from.rawValue)>\(to.rawValue)") }
        _ = manager.sendData(Data(repeating: 0x41, count: 10), to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: 1, isPoll: false)
        XCTAssertEqual(session.vs, 1)

        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.vs, 0)
        XCTAssertEqual(session.vr, 0)
        XCTAssertEqual(changes, [])
    }

    /// If the peer never answers, N2 runs out as for any connect, and the
    /// layer above, which last heard the link was up, hears it went down.
    func testAnUnansweredReestablishmentReportsTheLinkLost() {
        let clock = AX25VirtualClock()
        let (manager, session) = connectedManager(clock: clock)
        var changes: [String] = []
        manager.onSessionStateChanged = { _, from, to in changes.append("\(from.rawValue)>\(to.rawValue)") }

        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        for _ in 0..<200 where session.state == .connecting { clock.advance(by: 30) }

        XCTAssertNotEqual(session.state, .connecting)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.hasPrefix("connected>"), true, "\(changes)")
    }

    /// A normal connect we asked for is still layer-3 initiated.
    func testAConnectWeAskedForIsLayer3Initiated() {
        let (_, session) = connectedManager()
        XCTAssertTrue(session.stateMachine.layer3Initiated)
    }

    /// §6.3.1: "The originating TNC sending a SABM(E) command ignores and
    /// discards any frames except SABM, DISC, UA and DM frames from the
    /// distant TNC." While the link is re-established the old frames are
    /// still held for the answering UA to decide on, so an ack or a REJ must
    /// neither release them nor send them again. Found by
    /// AX25SessionStatePropertyTests: a REJ made the manager retransmit an
    /// I-frame while connecting.
    func testWhileReestablishingSupervisoryAndIFramesAreDiscarded() {
        let (manager, session) = connectedManager()
        _ = manager.sendData(Data(repeating: 0x41, count: 64 * 2), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.outstandingCount, 2)
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connecting)
        var delivered = 0
        manager.onDataReceived = { _, _ in delivered += 1 }

        XCTAssertTrue(manager.handleInboundREJ(from: peer, path: DigiPath(), radio: .primary, nr: 1).isEmpty)
        XCTAssertTrue(manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                    nr: 2, pf: true, isCommand: true).isEmpty)
        XCTAssertTrue(manager.handleInboundRNR(from: peer, path: DigiPath(), radio: .primary, nr: 2).isEmpty)
        XCTAssertNil(manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                                 ns: 0, nr: 2, pf: true, payload: Data("x".utf8)))

        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(session.va, 0, "nothing was released")
        XCTAssertEqual(session.vs, 2)
        XCTAssertEqual(session.state, .connecting)
    }
}

