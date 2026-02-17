//
//  TerminalSessionDisplayScopeTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

final class TerminalSessionDisplayScopeTests: XCTestCase {
    func testSelectedPeerReturnsNilWhenNotConnected() {
        let peer = TerminalSessionDisplayScope.selectedPeer(
            sessionState: .disconnected,
            activeSessionRecordID: "ax25|PEER1",
            destinationByRecordID: ["ax25|PEER1": "PEER1"]
        )

        XCTAssertNil(peer)
    }

    func testSelectedPeerReturnsActiveDestinationWhenConnected() {
        let peer = TerminalSessionDisplayScope.selectedPeer(
            sessionState: .connected,
            activeSessionRecordID: "ax25|PEER1",
            destinationByRecordID: ["ax25|PEER1": "PEER1"]
        )

        XCTAssertEqual(peer, "PEER1")
    }
}
