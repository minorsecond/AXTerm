import XCTest
@testable import AXTerm

/// Which console rows print their time.
///
/// A busy exchange puts five or six lines inside one second, and the leftmost
/// column then repeats "1:31:28 PM" down the screen. Printing it once per
/// second loses nothing: the timestamp renders to second resolution, so the
/// suppressed copies are the same string, not a different fact.
final class ConsoleTimestampRulerTests: XCTestCase {

    private struct Row: Identifiable {
        let id: Int
        let stamp: String
    }

    private func printing(_ stamps: [String]) -> Set<Int> {
        let rows = stamps.enumerated().map { Row(id: $0.offset, stamp: $0.element) }
        return ConsoleTimestampRuler.printingRows(rows, timestamp: \.stamp)
    }

    func testARunOfOneSecondPrintsOnce() {
        XCTAssertEqual(printing(["1:31:28", "1:31:28", "1:31:28"]), [0])
    }

    func testEachNewSecondPrintsAgain() {
        XCTAssertEqual(printing(["1:31:28", "1:31:28", "1:31:32", "1:31:32", "1:31:34"]),
                       [0, 2, 4])
    }

    /// Suppression is against the row directly above, not against every row
    /// seen. A second that comes back after a gap is new information again.
    func testATimeThatReturnsAfterAGapPrintsAgain() {
        XCTAssertEqual(printing(["1:31:28", "1:31:29", "1:31:28"]), [0, 1, 2])
    }

    func testEveryRowPrintsWhenNoTwoShareASecond() {
        XCTAssertEqual(printing(["1:31:28", "1:31:29", "1:31:30"]), [0, 1, 2])
    }

    func testTheFirstRowAlwaysPrints() {
        XCTAssertEqual(printing(["1:31:28"]), [0])
        XCTAssertTrue(printing([]).isEmpty)
    }

    /// Called once per block that is drawn together, so a day separator
    /// starts a fresh run and the row after it prints even if the clock time
    /// matches the row before the separator.
    func testEachBlockIsIndependent() {
        let yesterday = printing(["11:59:59", "11:59:59"])
        let today = printing(["11:59:59", "12:00:00"])
        XCTAssertEqual(yesterday, [0])
        XCTAssertEqual(today, [0, 1])
    }
}
