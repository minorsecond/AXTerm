//
//  QueuedDataDiscardTests.swift
//  AXTermTests
//
//  Dropping data that has not been numbered yet leaves the link's numbered
//  frames alone.
//
//  Smoke run 2026-10-03-1, issue 19: a YAPP cancel went out behind the data
//  already queued, and on a slow link the other station heard it 38 s late.
//  A block still queued whole has never been on the air, so a cancel drops
//  it and the CN goes next. Frames in the window must still be delivered.
//

import XCTest
@testable import AXTerm

@MainActor
final class QueuedDataDiscardTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)
    private let local = AX25Address(call: "K0EPI", ssid: 2)

    func testOnlyUnnumberedDataIsDropped() throws {
        let manager = AX25SessionManager(localCallsign: local, clock: AX25VirtualClock())
        manager.defaultConfig = AX25SessionConfig(windowSize: 1, paclen: 32, initialRto: 3.0)
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))

        let sent = manager.sendData(Data(repeating: 0x41, count: 96), to: peer)
        XCTAssertEqual(sent.count, 1, "the window holds one frame")
        XCTAssertEqual(session.pendingDataQueue.count, 2)
        let vs = session.vs, va = session.va
        let t1 = session.t1StartedAt

        XCTAssertEqual(manager.discardQueuedData(for: session.key), 2)
        XCTAssertTrue(session.pendingDataQueue.isEmpty)
        XCTAssertEqual(session.sendBuffer.count, 1, "the numbered frame is still owed to the peer")
        XCTAssertEqual(session.vs, vs)
        XCTAssertEqual(session.va, va)
        XCTAssertEqual(session.t1StartedAt, t1, "T1 keeps running for it")
        XCTAssertEqual(manager.discardQueuedData(for: session.key), 0)
    }
}
