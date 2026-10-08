//
//  RadioUnavailableReasonTests.swift
//  AXTermTests
//
//  Why a radio's page says it cannot connect, and whether Connect is
//  grayed out. The manager records a reason each time it reconciles, but it
//  does not reconcile while the radio's page is open. On 2026-10-08 the
//  operator saved the 705's network password on that page; Test connection
//  reached the radio, yet the page kept the reason recorded before the
//  password existed ("Enter the radio's network password.") and Connect
//  stayed grayed out until the page was left.
//

import XCTest
@testable import AXTerm

final class RadioUnavailableReasonTests: XCTestCase {

    func testWhatTheLiveCheckFindsIsWhatThePageSays() {
        XCTAssertEqual(RadioManager.unavailableReason(live: "Enter the radio's network username.",
                                                      recorded: nil),
                       "Enter the radio's network username.")
    }

    func testASettingsReasonFixedOnThePageNoLongerBlocksConnect() {
        XCTAssertNil(RadioManager.unavailableReason(live: nil,
                                                    recorded: "Enter the radio's network password."),
                     "the live check passed, so the recorded reason is from before the fix")
        XCTAssertNil(RadioManager.unavailableReason(live: nil,
                                                    recorded: "Choose an audio input and output device for this radio."))
    }

    func testALinkThatCouldNotBeMadeStillSaysSo() {
        XCTAssertEqual(RadioManager.unavailableReason(live: nil, recorded: RadioManager.linkCouldNotBeCreated),
                       RadioManager.linkCouldNotBeCreated,
                       "a real failure is not something the live check can see")
    }

    func testNothingWrongMeansNothingSaid() {
        XCTAssertNil(RadioManager.unavailableReason(live: nil, recorded: nil))
    }
}
