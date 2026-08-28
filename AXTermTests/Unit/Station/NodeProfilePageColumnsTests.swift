//
//  NodeProfilePageColumnsTests.swift
//  AXTermTests
//
//  The full-profile page deals its section cards into balanced columns —
//  LazyVGrid's row-height coupling left card-sized holes and made the page
//  scroll on displays with room to spare. The dealing is largest-first
//  into the shortest column (in-order greedy let small cards fill the
//  columns before the dominant Link-quality card arrived, which then
//  towered over everything), with reading order restored within columns.
//

import XCTest
@testable import AXTerm

final class NodeProfilePageColumnsTests: XCTestCase {

    func testOneColumnKeepsEverythingInOrder() {
        let assignment = NodeProfileView.distributeSections(
            estimates: [100, 50, 200], into: 1)
        XCTAssertEqual(assignment, [[0, 1, 2]])
    }

    func testADominantCardDoesNotTowerOverTheRest() {
        // The K0NTS-10 field case: a 600pt link card among modest cards.
        // In-order greedy produced columns of 802/508/600; largest-first
        // lands within one small card of even.
        let estimates: [CGFloat] = [110, 160, 600, 242, 188, 160, 130, 320]
        let assignment = NodeProfileView.distributeSections(estimates: estimates, into: 3)
        let heights = assignment.map { $0.reduce(CGFloat(0)) { $0 + estimates[$1] } }
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 150,
            "columns should end within a small card of each other; got \(heights)")
        XCTAssertEqual(assignment.flatMap { $0 }.sorted(), Array(estimates.indices),
                       "every card is dealt exactly once")
    }

    func testReadingOrderSurvivesWithinEachColumn() {
        let estimates: [CGFloat] = [50, 400, 60, 300, 70, 200]
        let assignment = NodeProfileView.distributeSections(estimates: estimates, into: 2)
        for column in assignment {
            XCTAssertEqual(column, column.sorted(),
                           "cards within a column must read top-to-bottom in page order")
        }
    }

    func testEqualCardsDealEvenly() {
        let assignment = NodeProfileView.distributeSections(
            estimates: [100, 100, 100, 100], into: 2)
        XCTAssertEqual(assignment.map(\.count), [2, 2])
        XCTAssertEqual(assignment.flatMap { $0 }.sorted(), [0, 1, 2, 3])
    }

    func testZeroOrNegativeColumnCountIsClampedToOne() {
        XCTAssertEqual(NodeProfileView.distributeSections(estimates: [10], into: 0),
                       [[0]])
    }
}
