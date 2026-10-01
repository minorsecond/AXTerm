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

    private func connectedManager() -> (AX25SessionManager, AX25Session) {
        let manager = AX25SessionManager(localCallsign: local, clock: AX25VirtualClock())
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
}
