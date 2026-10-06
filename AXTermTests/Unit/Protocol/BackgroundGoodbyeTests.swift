//
//  BackgroundGoodbyeTests.swift
//  AXTermTests
//
//  iPhone and iPad: AXTerm has no background mode, so iOS suspends it a few
//  seconds after it leaves the screen and its links die without a DISC (the
//  iOS side of smoke run 2026-10-03-1, issue 85). Leaving the screen starts
//  background time; a short grace lets a quick app switch keep the session,
//  then each live link gets its DISC and time to settle before the time
//  runs out.
//

import XCTest
@testable import AXTerm

final class BackgroundGoodbyeTests: XCTestCase {

    func testTheUsualThirtySecondsLeavesAGraceAndTimeToSettle() {
        let plan = BackgroundGoodbye.plan(backgroundTimeRemaining: 30)
        XCTAssertEqual(plan.grace, 10, accuracy: 0.001)
        XCTAssertEqual(plan.settleCap, 12, accuracy: 0.001)
        XCTAssertLessThanOrEqual(plan.grace + plan.settleCap, 30 - BackgroundGoodbye.reserve)
    }

    func testLittleTimeGoesToSettlingFirst() {
        let plan = BackgroundGoodbye.plan(backgroundTimeRemaining: 8)
        XCTAssertEqual(plan.grace, 0, accuracy: 0.001, "no grace when there is barely time to say goodbye")
        XCTAssertEqual(plan.settleCap, 8 - BackgroundGoodbye.reserve, accuracy: 0.001)
    }

    func testNoTimeAtAllStillSendsTheDISCs() {
        let plan = BackgroundGoodbye.plan(backgroundTimeRemaining: 1)
        XCTAssertEqual(plan.grace, 0)
        XCTAssertEqual(plan.settleCap, 0)
    }

    /// In the foreground iOS reports an unbounded remaining time.
    func testAnUnboundedReportIsTreatedAsTheUsualAllowance() {
        let plan = BackgroundGoodbye.plan(backgroundTimeRemaining: .greatestFiniteMagnitude)
        XCTAssertEqual(plan, BackgroundGoodbye.plan(backgroundTimeRemaining: 30))
    }
}
