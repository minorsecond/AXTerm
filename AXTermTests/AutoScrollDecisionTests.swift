import XCTest
@testable import AXTerm

final class AutoScrollDecisionTests: XCTestCase {
    func testShouldAutoScrollWhenRequested() {
        XCTAssertTrue(AutoScrollDecision.shouldAutoScroll(isUserAtTop: false, followNewest: false, didRequestScrollToTop: true))
    }

    func testShouldAutoScrollWhenFollowingNewest() {
        XCTAssertTrue(AutoScrollDecision.shouldAutoScroll(isUserAtTop: false, followNewest: true, didRequestScrollToTop: false))
    }

    func testShouldAutoScrollWhenUserAtTop() {
        XCTAssertTrue(AutoScrollDecision.shouldAutoScroll(isUserAtTop: true, followNewest: false, didRequestScrollToTop: false))
    }

    func testShouldNotAutoScrollWhenUserScrolledAway() {
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(isUserAtTop: false, followNewest: false, didRequestScrollToTop: false))
    }
}
