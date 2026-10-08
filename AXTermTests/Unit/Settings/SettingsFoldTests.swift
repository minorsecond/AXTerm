//
//  SettingsFoldTests.swift
//  AXTermTests
//
//  The busiest Settings pages show what an operator needs day to day and
//  fold the rest under Advanced (park rehearsal 2026-10-08: "some of the
//  settings pages have too much"). Nothing is removed, and a link into a
//  folded section still lands there.
//

import XCTest
@testable import AXTerm

final class SettingsFoldTests: XCTestCase {
    private let folded: Set<SettingsSection> = [.radioTiming, .radioReceiveAudio]

    func testAdvancedStaysAsTheOperatorLeftIt() {
        XCTAssertFalse(SettingsFold.showsAdvanced(stored: false, landing: nil, folded: folded))
        XCTAssertTrue(SettingsFold.showsAdvanced(stored: true, landing: nil, folded: folded))
    }

    func testALinkIntoAFoldedSectionOpensAdvanced() {
        XCTAssertTrue(SettingsFold.showsAdvanced(stored: false, landing: .radioTiming, folded: folded))
        XCTAssertTrue(SettingsFold.showsAdvanced(stored: false, landing: .radioReceiveAudio, folded: folded))
    }

    func testALinkElsewhereLeavesItFolded() {
        XCTAssertFalse(SettingsFold.showsAdvanced(stored: false, landing: .radioIdentity, folded: folded))
    }
}
