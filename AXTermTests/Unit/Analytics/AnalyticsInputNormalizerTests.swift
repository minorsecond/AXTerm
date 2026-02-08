import XCTest
@testable import AXTerm

final class AnalyticsInputNormalizerTests: XCTestCase {
    func testMinEdgeCountClampsToRange() {
        XCTAssertEqual(AnalyticsInputNormalizer.minEdgeCount(0), 1)
        XCTAssertEqual(AnalyticsInputNormalizer.minEdgeCount(5), 5)
        XCTAssertEqual(AnalyticsInputNormalizer.minEdgeCount(50), 20)
    }

    func testMaxNodesClampsToRange() {
        XCTAssertEqual(AnalyticsInputNormalizer.maxNodes(1), AnalyticsStyle.Graph.minNodes)
        XCTAssertEqual(AnalyticsInputNormalizer.maxNodes(150), 150)
        XCTAssertEqual(AnalyticsInputNormalizer.maxNodes(800), 500)
    }
}
