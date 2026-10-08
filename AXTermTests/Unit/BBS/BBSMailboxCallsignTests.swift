//
//  BBSMailboxCallsignTests.swift
//  AXTermTests
//
//  The mailbox answers to the callsign set for it. On 2026-10-08 that
//  setting was saved as "K0EPI-4" with a line break after it, and only
//  spaces were trimmed, so the mailbox would have answered to an address no
//  caller can type. A callsign pasted from elsewhere often carries one.
//

import XCTest
@testable import AXTerm

@MainActor
final class BBSMailboxCallsignTests: XCTestCase {

    func testALineBreakAroundTheCallsignIsNotPartOfIt() {
        let settings = BBSSettings(defaults: TestDefaults.make("bbs-mailbox-callsign-newline"))
        settings.callsign = "k0epi-4\n"
        XCTAssertEqual(settings.effectiveCallsign(stationCallsign: "K0EPI-2"), "K0EPI-4")
        settings.callsign = " \n"
        XCTAssertEqual(settings.effectiveCallsign(stationCallsign: "K0EPI-2"), "K0EPI-2",
                       "only whitespace means answer as the station")
    }
}
