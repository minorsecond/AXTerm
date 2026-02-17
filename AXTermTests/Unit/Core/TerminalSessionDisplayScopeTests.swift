//
//  TerminalSessionDisplayScopeTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

final class TerminalSessionDisplayScopeTests: XCTestCase {
    func testSelectedPeerReturnsNilWhenNotConnected() {
        let peer = TerminalSessionDisplayScope.selectedPeer(
            connectionMode: .connected,
            sessionState: .disconnected,
            activeSessionRecordID: "ax25|PEER1",
            destinationByRecordID: ["ax25|PEER1": "PEER1"],
            connectedPeers: ["PEER1"]
        )

        XCTAssertNil(peer)
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

    func testSelectedPeerReturnsNilWhenRecordIsNotConnected() {
        let peer = TerminalSessionDisplayScope.selectedPeer(
            connectionMode: .connected,
            sessionState: .connected,
            activeSessionRecordID: "ax25|PEER1",
            destinationByRecordID: ["ax25|PEER1": "PEER1"],
            connectedPeers: ["PEER2"]
        )

        XCTAssertNil(peer)
    }
}
