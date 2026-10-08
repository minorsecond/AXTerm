//
//  TNC4TuningSuggestionTextTests.swift
//  AXTermTests
//
//  Park rehearsal 2026-10-08, finding 31: "The TNC4's receive level hasn't
//  been tuned for this radio" read like a fault to the operator chasing a
//  receive problem, when the TNC4 was decoding fine on its own setting.
//

import XCTest
@testable import AXTerm

@MainActor
final class TNC4TuningSuggestionTextTests: XCTestCase {

    func testTheOfferSaysTheTNC4IsOnItsOwnSettingAndTuningIsOptional() {
        let text = TNC4TuningSuggestionRow.message
        XCTAssertTrue(text.contains("own receive level"), text)
        XCTAssertTrue(text.contains("can tune"), text)
        XCTAssertFalse(text.contains("hasn't been tuned"), text)
    }
}
