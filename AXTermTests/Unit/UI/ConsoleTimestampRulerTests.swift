import XCTest
@testable import AXTerm

/// Which console rows print their time, and how the rest are tied to it.
///
/// A busy exchange puts five or six lines inside one second, and the leftmost
/// column repeats "2:07:49 PM" down the screen. Printing it once per run
/// loses nothing — the timestamp renders to second resolution, so the
/// suppressed copies are the same string — but a bare blank reads as missing
/// rather than inherited, so each row also knows where it sits in the run.
final class ConsoleTimestampRulerTests: XCTestCase {

    private typealias Position = ConsoleTimestampRuler.RunPosition

    private struct Row: Identifiable {
        let id: Int
        let stamp: String
    }

    private func positions(_ stamps: [String]) -> [Position] {
        let rows = stamps.enumerated().map { Row(id: $0.offset, stamp: $0.element) }
        let map = ConsoleTimestampRuler.runPositions(rows, timestamp: \.stamp)
        return rows.map { map[$0.id] ?? .alone }
    }

    /// The shape that matters: one time printed, a thread down to the rows
    /// that share it, closed at the last one.
    func testARunPrintsOnceAndHangsTheRest() {
        XCTAssertEqual(positions(["2:07:49", "2:07:49", "2:07:49", "2:07:49"]),
                       [.start, .middle, .middle, .end])
    }

    func testATwoRowRunHasNoMiddle() {
        XCTAssertEqual(positions(["2:07:49", "2:07:49"]), [.start, .end])
    }

    /// A row with nobody to share its time neither prints a thread nor hangs
    /// from one.
    func testASolitaryRowStandsAlone() {
        XCTAssertEqual(positions(["2:07:49", "2:07:50", "2:07:51"]),
                       [.alone, .alone, .alone])
    }

    func testRunsAreDelimitedByTheTimeChanging() {
        XCTAssertEqual(positions(["2:07:49", "2:07:49", "2:07:50", "2:07:51", "2:07:51"]),
                       [.start, .end, .alone, .start, .end])
    }

    /// Grouping is against the row directly above, not against every row
    /// seen: a second that comes back after a gap is new information again.
    func testATimeThatReturnsAfterAGapStartsAFreshRun() {
        XCTAssertEqual(positions(["2:07:49", "2:07:50", "2:07:49"]),
                       [.alone, .alone, .alone])
    }

    func testTheEndsOfTheListAreHandled() {
        XCTAssertEqual(positions([]), [])
        XCTAssertEqual(positions(["2:07:49"]), [.alone])
    }

    /// Exactly the rows that start a run print the time; exactly the rows
    /// that inherit it draw the thread. Nothing does both or neither.
    func testPrintingAndInheritingPartitionTheRun() {
        let run = positions(["a", "a", "a"])
        XCTAssertEqual(run.map(\.printsTimestamp), [true, false, false])
        XCTAssertEqual(run.map(\.isContinuation), [false, true, true])
        for position in [Position.alone, .start, .middle, .end] {
            XCTAssertNotEqual(position.printsTimestamp, position.isContinuation,
                              "\(position) must be one or the other")
        }
    }

    /// Called once per contiguous block, so a day separator starts a fresh
    /// run and the row after it prints even when the clock reads the same.
    func testEachBlockIsIndependent() {
        XCTAssertEqual(positions(["11:59:59", "11:59:59"]), [.start, .end])
        XCTAssertEqual(positions(["11:59:59"]), [.alone])
    }
}
