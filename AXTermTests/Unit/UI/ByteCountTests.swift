import XCTest
@testable import AXTerm

/// `ByteCountFormatter` spells zero as "Zero KB" out of the box. That is the
/// whole reason this type exists, so it is the first thing tested.
final class ByteCountTests: XCTestCase {

    func testZeroIsANumberNotAWord() {
        let formatted = ByteCount.string(0)
        XCTAssertFalse(formatted.lowercased().contains("zero"),
                       "formatted zero as \(formatted)")
        XCTAssertTrue(formatted.contains("0"), "formatted zero as \(formatted)")
    }

    /// The axis label that started this: the payload chart's baseline.
    func testAChartBaselineReadsAsANumber() {
        XCTAssertEqual(ByteCount.string(0).first, "0")
    }

    func testSmallCountsStayInBytes() {
        XCTAssertTrue(ByteCount.string(408).contains("408"))
    }

    func testLargerCountsUseAUnit() {
        let formatted = ByteCount.string(54_000)
        XCTAssertTrue(formatted.contains("KB"), "formatted 54,000 as \(formatted)")
    }

    /// Int and Int64 must agree; the call sites use both.
    func testTheTwoOverloadsAgree() {
        XCTAssertEqual(ByteCount.string(4096), ByteCount.string(Int64(4096)))
    }
}
