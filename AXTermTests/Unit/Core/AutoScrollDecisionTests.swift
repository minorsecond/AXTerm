import XCTest
@testable import AXTerm

final class AutoScrollDecisionTests: XCTestCase {
    func testShouldAutoScrollWhenExplicitlyRequested() {
        XCTAssertTrue(AutoScrollDecision.shouldAutoScroll(isUserAtTarget: false, followNewest: false, didRequestScrollToTarget: true))
    }

    func testShouldAutoScrollWhenFollowingAndAtTarget() {
        XCTAssertTrue(AutoScrollDecision.shouldAutoScroll(isUserAtTarget: true, followNewest: true, didRequestScrollToTarget: false))
    }

    func testShouldNotAutoScrollWhenFollowingButScrolledAway() {
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(isUserAtTarget: false, followNewest: true, didRequestScrollToTarget: false))
    }

    func testShouldNotAutoScrollWhenAtTargetButNotFollowing() {
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(isUserAtTarget: true, followNewest: false, didRequestScrollToTarget: false))
    }

    func testShouldNotAutoScrollWhenAllFalse() {
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(isUserAtTarget: false, followNewest: false, didRequestScrollToTarget: false))
    }
}
