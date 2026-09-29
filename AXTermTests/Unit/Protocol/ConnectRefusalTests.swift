//
//  ConnectRefusalTests.swift
//  AXTermTests
//
//  A DM answering our SABM is a refusal — an answer, not a path failure.
//  The session records it so the connect wait loop can tell "the station
//  said no" apart from "the path is dead", which is the difference between
//  the strategy ladder stopping (respecting the answer) and falling through
//  to the next family (retrying a dead path a different way).
//

import XCTest
@testable import AXTerm

@MainActor
final class ConnectRefusalTests: XCTestCase {

    private func makeManager() -> AX25SessionManager {
        AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
    }

    func testDMDuringConnectingMarksTheSessionRefused() {
        let manager = makeManager()
        let peer = AX25Address(call: "COSCO", ssid: 0)
        let path = DigiPath()

        XCTAssertNotNil(manager.connect(to: peer, path: path, radio: .primary))
        let session = manager.session(for: peer, path: path, radio: .primary)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertFalse(session.peerRefusedConnect)

        manager.handleInboundDM(from: peer, path: path, radio: .primary)

        XCTAssertEqual(session.state, .disconnected, "§6.3.1: DM aborts the connect cleanly")
        XCTAssertTrue(session.peerRefusedConnect, "the refusal must survive the state transition")
    }

    /// Last hour's DM says nothing about a peer that may have rebooted
    /// since — every fresh attempt starts with a clean verdict.
    func testAFreshConnectClearsTheRefusalFlag() {
        let manager = makeManager()
        let peer = AX25Address(call: "COSCO", ssid: 0)
        let path = DigiPath()

        _ = manager.connect(to: peer, path: path, radio: .primary)
        let refusedSession = manager.session(for: peer, path: path, radio: .primary)
        manager.handleInboundDM(from: peer, path: path, radio: .primary)
        XCTAssertTrue(refusedSession.peerRefusedConnect)

        XCTAssertNotNil(manager.connect(to: peer, path: path, radio: .primary))
        let retried = manager.session(for: peer, path: path, radio: .primary)
        XCTAssertFalse(retried.peerRefusedConnect)
        XCTAssertEqual(retried.state, .connecting)
    }

    /// A DM on an established link is the desync/teardown story, not a
    /// connect refusal — the flag stays down.
    func testDMOnAConnectedLinkIsNotARefusal() {
        let manager = makeManager()
        let peer = AX25Address(call: "NODE", ssid: 0)
        let path = DigiPath()

        _ = manager.connect(to: peer, path: path, radio: .primary)
        manager.handleInboundUA(from: peer, path: path, radio: .primary)
        let session = manager.session(for: peer, path: path, radio: .primary)
        XCTAssertEqual(session.state, .connected)

        manager.handleInboundDM(from: peer, path: path, radio: .primary)
        XCTAssertFalse(session.peerRefusedConnect)
    }
}
