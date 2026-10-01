//
//  PacketListFollowTests.swift
//  AXTermTests
//
//  When the touch packet list counts as showing the newest frame, which is
//  what decides whether new frames scroll it.
//

import XCTest
@testable import AXTerm

final class PacketListFollowTests: XCTestCase {
    func testTheBottomAndJustShortOfItCountAsFollowing() {
        XCTAssertTrue(PacketListFollow.isAtBottom(contentHeight: 5_000, visibleMaxY: 5_000))
        XCTAssertTrue(PacketListFollow.isAtBottom(contentHeight: 5_000, visibleMaxY: 4_970),
                      "the last row half on screen is still the bottom")
        XCTAssertTrue(PacketListFollow.isAtBottom(contentHeight: 5_000, visibleMaxY: 5_030),
                      "an overscroll bounce past the end")
    }

    func testScrollingUpToReadStopsFollowing() {
        XCTAssertFalse(PacketListFollow.isAtBottom(contentHeight: 5_000, visibleMaxY: 4_900))
        XCTAssertFalse(PacketListFollow.isAtBottom(contentHeight: 5_000, visibleMaxY: 800))
    }

    func testAListShorterThanTheScreenIsAlwaysAtItsBottom() {
        XCTAssertTrue(PacketListFollow.isAtBottom(contentHeight: 200, visibleMaxY: 900))
        XCTAssertTrue(PacketListFollow.isAtBottom(contentHeight: 0, visibleMaxY: 0))
    }
}

/// What a following list does when its scroll geometry changes: the console
/// and terminal transcript, and the touch packet list. Bug 9 in
/// Docs/LiveRFTest-2026-09-30.md: scrolling back through the session log
/// kept being pulled to the bottom by keep-alive traffic every 30 s.
final class PacketListFollowDecisionTests: XCTestCase {
    private typealias G = PacketListFollow.Geometry

    /// 1,000 points of lines in a 400-point window, scrolled to the end.
    private let atBottom = G(contentHeight: 1_000, visibleMinY: 600, visibleHeight: 400)
    /// The same, scrolled up to read.
    private let readingUp = G(contentHeight: 1_000, visibleMinY: 200, visibleHeight: 400)

    private func decide(_ old: G, _ new: G, following: Bool, scrolling: Bool = false) -> PacketListFollow.Decision {
        PacketListFollow.decide(from: old, to: new, isFollowing: following, userIsScrolling: scrolling)
    }

    func testANewLineAtTheBottomIsFollowed() {
        let grown = G(contentHeight: 1_060, visibleMinY: 600, visibleHeight: 400)
        XCTAssertEqual(decide(atBottom, grown, following: true),
                       .init(isFollowing: true, scrollToNewest: true))
    }

    func testANewLineLeavesAReaderWhereTheyAre() {
        let grown = G(contentHeight: 1_060, visibleMinY: 200, visibleHeight: 400)
        XCTAssertEqual(decide(readingUp, grown, following: false),
                       .init(isFollowing: false, scrollToNewest: false),
                       "keep-alive traffic must not pull a reader back to the bottom")
    }

    func testScrollingUpStopsFollowingEvenWithNoScrollPhase() {
        // A mouse wheel on the Mac may move the view without a scroll phase.
        let up = G(contentHeight: 1_000, visibleMinY: 500, visibleHeight: 400)
        XCTAssertEqual(decide(atBottom, up, following: true),
                       .init(isFollowing: false, scrollToNewest: false))
    }

    func testScrollingUpWhileRowsAreMeasuredStillStopsFollowing() {
        // A lazy stack measures rows as they come into view, so the content
        // height can change in the same step the reader scrolls up.
        let up = G(contentHeight: 1_040, visibleMinY: 500, visibleHeight: 400)
        XCTAssertEqual(decide(atBottom, up, following: true),
                       .init(isFollowing: false, scrollToNewest: false))
    }

    func testAScrollGestureAwayFromTheBottomStopsFollowing() {
        let up = G(contentHeight: 1_000, visibleMinY: 550, visibleHeight: 400)
        XCTAssertEqual(decide(atBottom, up, following: true, scrolling: true),
                       .init(isFollowing: false, scrollToNewest: false))
    }

    func testReturningToTheBottomResumesFollowing() {
        XCTAssertEqual(decide(readingUp, atBottom, following: false),
                       .init(isFollowing: true, scrollToNewest: false))
        XCTAssertEqual(decide(readingUp, atBottom, following: false, scrolling: true),
                       .init(isFollowing: true, scrollToNewest: false))
    }

    func testAShorterWindowWhileFollowingStaysOnTheNewest() {
        let shorter = G(contentHeight: 1_000, visibleMinY: 600, visibleHeight: 300)
        XCTAssertEqual(decide(atBottom, shorter, following: true),
                       .init(isFollowing: true, scrollToNewest: true))
    }

    func testAShorterWindowWhileReadingStaysPut() {
        let shorter = G(contentHeight: 1_000, visibleMinY: 200, visibleHeight: 300)
        XCTAssertEqual(decide(readingUp, shorter, following: false),
                       .init(isFollowing: false, scrollToNewest: false))
    }

    func testAResetToTheTopWithNoScrollIsPutBack() {
        // The iPhone tab view resets a hidden list to the top when its tab
        // comes forward, with nobody scrolling.
        let top = G(contentHeight: 1_000, visibleMinY: 0, visibleHeight: 400)
        XCTAssertEqual(decide(atBottom, top, following: true),
                       .init(isFollowing: true, scrollToNewest: true))
    }

    func testAResetToTheTopWhileReadingIsLeftAlone() {
        let farDown = G(contentHeight: 5_000, visibleMinY: 3_000, visibleHeight: 400)
        let top = G(contentHeight: 5_000, visibleMinY: 0, visibleHeight: 400)
        XCTAssertEqual(decide(farDown, top, following: false),
                       .init(isFollowing: false, scrollToNewest: false))
    }

    func testAJumpToTheNewestDoesNotStopFollowingOnTheWay() {
        // An animated scroll toward the bottom passes through offsets that
        // are not the bottom yet.
        let partWay = G(contentHeight: 1_000, visibleMinY: 400, visibleHeight: 400)
        XCTAssertEqual(decide(readingUp, partWay, following: true),
                       .init(isFollowing: true, scrollToNewest: false))
    }
}
