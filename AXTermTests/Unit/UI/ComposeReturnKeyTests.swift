//
//  ComposeReturnKeyTests.swift
//  AXTermTests
//
//  On the iPad a hardware keyboard's Return did not send the message: the
//  field's submit and the Send button's Return shortcut both claim the key,
//  and on iPadOS neither sent (smoke run 2026-10-03-1, 13.4, issue 111). The
//  field now takes a plain Return itself. Return with a modifier is left to
//  the system and to other shortcuts.
//

import SwiftUI
import XCTest
@testable import AXTerm

final class ComposeReturnKeyTests: XCTestCase {

    func testAPlainReturnSends() {
        XCTAssertTrue(ComposeReturnKey.sends(modifiers: [], canSend: true))
    }

    func testNothingSendsWhenSendingIsOff() {
        XCTAssertFalse(ComposeReturnKey.sends(modifiers: [], canSend: false))
    }

    func testReturnWithAModifierIsLeftAlone() {
        XCTAssertFalse(ComposeReturnKey.sends(modifiers: .shift, canSend: true))
        XCTAssertFalse(ComposeReturnKey.sends(modifiers: .command, canSend: true))
    }
}
