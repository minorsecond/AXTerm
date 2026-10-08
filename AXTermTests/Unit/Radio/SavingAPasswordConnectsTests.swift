//
//  SavingAPasswordConnectsTests.swift
//  AXTermTests
//
//  Saving a radio's network password connects it (park rehearsal
//  2026-10-08). The password lives in the Keychain, not the radio's
//  settings, so leaving the page saw nothing changed and skipped the
//  reconnect, and A (705) sat disconnected with a working password.
//

import XCTest
@testable import AXTerm

final class SavingAPasswordConnectsTests: XCTestCase {

    func testSavingAPasswordConnectsARadioThatShouldBeUp() {
        XCTAssertTrue(ConnectionTransportViewModel.connectsAfterSavingPassword(
            stored: true, enabled: true, autoConnect: true, connected: false, heldClosed: false))
    }

    func testItLeavesAloneWhatTheOperatorChose() {
        XCTAssertFalse(ConnectionTransportViewModel.connectsAfterSavingPassword(
            stored: false, enabled: true, autoConnect: true, connected: false, heldClosed: false),
                       "a cleared password connects nothing")
        XCTAssertFalse(ConnectionTransportViewModel.connectsAfterSavingPassword(
            stored: true, enabled: false, autoConnect: true, connected: false, heldClosed: false),
                       "a radio switched off stays off")
        XCTAssertFalse(ConnectionTransportViewModel.connectsAfterSavingPassword(
            stored: true, enabled: true, autoConnect: false, connected: false, heldClosed: false),
                       "a radio set not to connect by itself waits for Connect")
        XCTAssertFalse(ConnectionTransportViewModel.connectsAfterSavingPassword(
            stored: true, enabled: true, autoConnect: true, connected: false, heldClosed: true),
                       "after Disconnect, only Connect brings it back")
        XCTAssertFalse(ConnectionTransportViewModel.connectsAfterSavingPassword(
            stored: true, enabled: true, autoConnect: true, connected: true, heldClosed: false),
                       "already up")
    }
}
