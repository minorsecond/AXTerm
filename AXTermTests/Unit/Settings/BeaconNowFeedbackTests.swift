//
//  BeaconNowFeedbackTests.swift
//  AXTermTests
//
//  "Send one now" says when it sent, and why it can't.
//

import XCTest
@testable import AXTerm

final class BeaconNowFeedbackTests: XCTestCase {

    func testTheBeaconsOwnProblemComesFirst() {
        XCTAssertEqual(BeaconNowFeedback.blocker(obstacle: "No station position yet.", linkUp: false),
                       "No station position yet.")
        XCTAssertEqual(BeaconNowFeedback.blocker(obstacle: "No station position yet.", linkUp: true),
                       "No station position yet.")
    }

    func testARadioThatIsNotConnectedCannotSend() throws {
        let why = try XCTUnwrap(BeaconNowFeedback.blocker(obstacle: nil, linkUp: false))
        XCTAssertTrue(why.contains("isn't connected"))
    }

    func testNothingInTheWay() {
        XCTAssertNil(BeaconNowFeedback.blocker(obstacle: nil, linkUp: true))
    }

    func testTheConfirmationGivesTheTime() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 9 * 3600 + 32 * 60 + 22)
        XCTAssertEqual(BeaconNowFeedback.sentLine(at: date, timeZone: utc), "Sent at 09:32:22")
    }
}
