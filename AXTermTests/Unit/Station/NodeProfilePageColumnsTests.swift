//
//  NodeProfilePageColumnsTests.swift
//  AXTermTests
//
//  The full-profile page deals its section cards into balanced columns —
//  LazyVGrid's row-height coupling left card-sized holes and made the page
//  scroll on displays with room to spare. The dealing rule worth pinning:
//  reading order is preserved within a column, each card lands in the
//  currently shortest column, and ties go left.
//

import XCTest
@testable import AXTerm

final class NodeProfilePageColumnsTests: XCTestCase {

    func testOneColumnKeepsEverythingInOrder() {
        let assignment = NodeProfileView.distributeSections(
            estimates: [100, 50, 200], into: 1)
        XCTAssertEqual(assignment, [[0, 1, 2]])
    }

    func testCardsGoToTheShortestColumn() {
        // 200 left, 50 right, then 60 lands right (50 < 200), 100 lands
        // right again (110 < 200), and the last card returns left.
        let assignment = NodeProfileView.distributeSections(
            estimates: [200, 50, 60, 100, 40], into: 2)
        XCTAssertEqual(assignment, [[0, 4], [1, 2, 3]])
    }

    func testTiesGoLeftAndOrderIsPreservedWithinColumns() {
        let assignment = NodeProfileView.distributeSections(
            estimates: [100, 100, 100, 100], into: 2)
        XCTAssertEqual(assignment, [[0, 2], [1, 3]])
        for column in assignment {
            XCTAssertEqual(column, column.sorted(), "reading order must survive")
        }
    }

    func testColumnsAreRoughlyBalanced() {
        let estimates: [CGFloat] = [268, 110, 160, 250, 240, 160, 130, 260]
        let assignment = NodeProfileView.distributeSections(estimates: estimates, into: 3)
        let heights = assignment.map { $0.reduce(CGFloat(0)) { $0 + estimates[$1] } }
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 268,
            "no column should exceed another by more than the largest card")
        XCTAssertEqual(assignment.flatMap { $0 }.sorted(), Array(estimates.indices),
                       "every card is dealt exactly once")
    }

    func testZeroOrNegativeColumnCountIsClampedToOne() {
        XCTAssertEqual(NodeProfileView.distributeSections(estimates: [10], into: 0),
                       [[0]])
    }
}
