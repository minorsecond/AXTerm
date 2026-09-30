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
