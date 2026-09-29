import XCTest
@testable import AXTerm

/// The size budget under the compose window.
///
/// It sits beside a progress bar in a footer, so it has to be short and it has
/// to be a number. `ByteCountFormatter` spells zero as "Zero KB" — three words
/// where one belongs, and enough of them to wrap the footer onto three lines
/// on an iPad.
final class WinlinkComposeSizeTests: XCTestCase {

    private func size(_ bytes: Int) -> String {
        WinlinkComposeWindow.compactSize(bytes)
    }

    /// The case that started it: an empty draft reads "0 KB", not "Zero KB".
    func testAnEmptyDraftReadsAsZero() {
        XCTAssertEqual(size(0), "0 KB")
    }

    /// Negative is not a size. Clamped rather than printed, since a minus
    /// sign in a budget reads as "you have room" when something is wrong.
    func testANegativeCountIsTreatedAsEmpty() {
        XCTAssertEqual(size(-1), "0 KB")
    }

    /// Something too small to round to a kilobyte is still *something*, and
    /// must not read as an empty message.
    func testATinyMessageIsNotReportedAsEmpty() {
        XCTAssertEqual(size(200), "<1 KB")
        XCTAssertNotEqual(size(200), size(0))
    }

    func testKilobytesKeepOneDecimalWhileSmall() {
        XCTAssertEqual(size(1536), "1.5 KB")
    }

    /// Past a point the decimal is noise in a footer this narrow.
    func testLargerKilobytesDropTheDecimal() {
        XCTAssertEqual(size(200 * 1024), "200 KB")
    }

    func testMegabytesAreLabelledAsSuch() {
        XCTAssertEqual(size(2 * 1024 * 1024), "2.0 MB")
    }

    /// Every value fits on one line — the whole reason this exists.
    func testEveryFormattedSizeIsShort() {
        for bytes in [0, 1, 512, 1024, 100_000, 5_000_000, 900_000_000] {
            XCTAssertLessThanOrEqual(size(bytes).count, 8, "\(bytes) formatted too long")
        }
    }
}
