//
//  LinkEndedTransitionTests.swift
//  AXTermTests
//
//  The main app's History held a record for every connect to K0EPI-3 that
//  closed 70 ms after it opened, with nothing in it, while the session it
//  named carried lines both ways. A new session waits in .disconnected
//  while its XID is out, and the terminal took that level for the end of
//  the link: it closed the record and dropped it as the active one, so
//  nothing was recorded on it. Only a transition from a state the link
//  reached ends it (smoke run 2026-10-03-1, test 10.4, issue 102).
//

import XCTest
@testable import AXTerm

final class LinkEndedTransitionTests: XCTestCase {
    func testOnlyALinkThatExistedCanEnd() {
        XCTAssertFalse(TerminalLinkLifecycle.linkEnded(onDisconnectFrom: nil),
                       "a session just created, waiting on its XID")
        XCTAssertFalse(TerminalLinkLifecycle.linkEnded(onDisconnectFrom: .disconnected))
        XCTAssertTrue(TerminalLinkLifecycle.linkEnded(onDisconnectFrom: .connecting),
                      "a connect the peer refused or never answered")
        XCTAssertTrue(TerminalLinkLifecycle.linkEnded(onDisconnectFrom: .connected))
        XCTAssertTrue(TerminalLinkLifecycle.linkEnded(onDisconnectFrom: .disconnecting))
    }
}
