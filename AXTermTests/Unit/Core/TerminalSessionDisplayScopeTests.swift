//
//  TerminalSessionDisplayScopeTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

final class TerminalSessionDisplayScopeTests: XCTestCase {
    func testSelectedPeerReturnsActiveDestinationEvenWhenDisconnected() {
        let peer = TerminalSessionDisplayScope.selectedPeer(
            connectionMode: .connected,
            sessionState: .disconnected,
            activeSessionRecordID: "ax25|PEER1",
            destinationByRecordID: ["ax25|PEER1": "PEER1"],
            connectedPeers: []
        )

        XCTAssertEqual(peer, "PEER1")
    }

    func testSelectedPeerReturnsActiveDestinationWhenConnected() {
        let peer = TerminalSessionDisplayScope.selectedPeer(
            connectionMode: .connected,
            sessionState: .connected,
            activeSessionRecordID: "ax25|PEER1",
            destinationByRecordID: ["ax25|PEER1": "PEER1"],
            connectedPeers: ["PEER1"]
        )

        XCTAssertEqual(peer, "PEER1")
    }

    func testSelectedPeerReturnsNilInDatagramMode() {
        let peer = TerminalSessionDisplayScope.selectedPeer(
            connectionMode: .datagram,
            sessionState: .connected,
            activeSessionRecordID: "ax25|PEER1",
            destinationByRecordID: ["ax25|PEER1": "PEER1"],
            connectedPeers: ["PEER1"]
        )

        XCTAssertNil(peer)
    }

    func testSelectedPeerReturnsNilWhenActiveSessionRecordIDIsNil() {
        let peer = TerminalSessionDisplayScope.selectedPeer(
            connectionMode: .connected,
            sessionState: .connected,
            activeSessionRecordID: nil,
            destinationByRecordID: ["ax25|PEER1": "PEER1"],
            connectedPeers: ["PEER1"]
        )

        XCTAssertNil(peer)
    }
}
