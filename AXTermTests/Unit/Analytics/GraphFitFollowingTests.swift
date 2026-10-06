//
//  GraphFitFollowingTests.swift
//  AXTermTests
//
//  A station that joined the graph was laid out past its right edge and
//  stayed hidden until Fit was pressed (smoke run 2026-10-03-1, issue 92).
//

import XCTest
@testable import AXTerm

final class GraphFitFollowingTests: XCTestCase {
    func testANewStationRefitsTheView() {
        XCTAssertTrue(GraphFitFollowing.shouldRefit(framed: ["K0EPI-2"], shown: ["K0EPI-2", "K0EPI-3"]))
    }

    func testTheSameOrFewerStationsLeaveTheViewAlone() {
        XCTAssertFalse(GraphFitFollowing.shouldRefit(framed: ["K0EPI-2", "K0EPI-3"], shown: ["K0EPI-2", "K0EPI-3"]))
        XCTAssertFalse(GraphFitFollowing.shouldRefit(framed: ["K0EPI-2", "K0EPI-3"], shown: ["K0EPI-2"]))
    }
}
