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

    // MARK: - Staying put

    /// Cards arrive late. Terrain is computed off the main thread, a licence
    /// lookup lands seconds after the page opens, an activity chart grows a
    /// row. Packing tallest-first re-sorted every card against whichever
    /// estimate had just changed, so the page rearranged itself under the
    /// operator and a page reopened a minute later dealt itself differently.
    /// Reported as "the tiles move every time I open them".
    func testEveryCardIsStillDealtExactlyOnce() {
        let assignment = NodeProfileView.distributeSections(
            estimates: [300, 120, 200, 160, 260], into: 3)
        XCTAssertEqual(assignment.flatMap { $0 }.sorted(), Array(0..<5))
    }

    /// A card growing by a line is not a reason to redeal the page.
    func testACardChangingHeightDoesNotRedealTheRest() {
        // A line's worth of growth, well inside the bucket the card sits in.
        let before = NodeProfileView.distributeSections(
            estimates: [300, 120, 200, 160], into: 2)
        let after = NodeProfileView.distributeSections(
            estimates: [300, 138, 200, 160], into: 2)
        XCTAssertEqual(after, before)
    }

    /// Ranking in buckets is what makes that true. Ordering on exact heights
    /// let one card growing by a few points re-sort every card against it.
    func testTheRankingIsCoarseEnoughToIgnoreSmallGrowth() {
        let quiet = NodeProfileView.distributeSections(
            estimates: [110, 160, 600, 242, 188, 160, 130, 320], into: 3)
        let nudged = NodeProfileView.distributeSections(
            estimates: [110, 172, 600, 249, 188, 160, 130, 320], into: 3)
        XCTAssertEqual(nudged, quiet)
    }

    /// Cards keep the order they were declared in, within a column. Sorting
    /// them back afterwards used to hide that the packer had reordered them.
    func testCardsStayInDeclarationOrderWithinAColumn() {
        let assignment = NodeProfileView.distributeSections(
            estimates: [100, 100, 100, 100, 100, 100], into: 2)
        for column in assignment {
            XCTAssertEqual(column, column.sorted())
        }
    }
}
