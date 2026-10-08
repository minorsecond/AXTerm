//
//  DisconnectPromptTests.swift
//  AXTermTests
//
//  On iPhone and iPad, Disconnect asks first: it sits beside the message
//  field and is easy to tap by mistake (park rehearsal 2026-10-08).
//

import XCTest
@testable import AXTerm

final class DisconnectPromptTests: XCTestCase {

    func testItNamesTheStation() {
        let prompt = SessionDisconnectPrompt(peer: "K0EPI-4")
        XCTAssertEqual(prompt.title, "Disconnect from K0EPI-4?")
        XCTAssertEqual(prompt.confirmLabel, "Disconnect")
    }

    func testOnlyTouchScreensAsk() {
        #if os(iOS)
        XCTAssertTrue(SessionDisconnectPrompt.isNeeded)
        #else
        XCTAssertFalse(SessionDisconnectPrompt.isNeeded, "a click on the Mac is deliberate")
        #endif
    }
}
