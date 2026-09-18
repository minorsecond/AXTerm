import XCTest
@testable import AXTerm

final class ConsoleLineGroupingTests: XCTestCase {
    func testRepeatedMessagesNotCollapsedWithoutDuplicateFlag() {
        let timestamp = Date()
        let lineA = ConsoleLine.packet(
            from: "TEST-1",
            to: "TEST-2",
            text: "Lorem ipsum dolor sit amet.",
            timestamp: timestamp
        )
        let lineB = ConsoleLine.packet(
            from: "TEST-1",
            to: "TEST-2",
            text: "Lorem ipsum dolor sit amet.",
            timestamp: timestamp.addingTimeInterval(5)
        )

        let groups = ConsoleLineGrouper.group([lineA, lineB])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].duplicates.count, 0)
        XCTAssertEqual(groups[1].duplicates.count, 0)
    }

    func testDuplicateFlagCollapsesToPrimary() {
        let timestamp = Date()
        let primary = ConsoleLine.packet(
            from: "TEST-1",
            to: "TEST-2",
            text: "Beacon message",
            timestamp: timestamp
        )
        let duplicate = ConsoleLine.packet(
            from: "TEST-1",
            to: "TEST-2",
            text: "Beacon message",
            timestamp: timestamp.addingTimeInterval(1),
            isDuplicate: true
        )

        let groups = ConsoleLineGrouper.group([primary, duplicate])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].primary.id, primary.id)
        XCTAssertEqual(groups[0].duplicates.count, 1)
        XCTAssertEqual(groups[0].duplicates.first?.id, duplicate.id)
    }

    func testSystemMessagesGroupConsecutively() {
        let lineA = ConsoleLine(kind: .system, text: "System event A", isDuplicate: true)
        let lineB = ConsoleLine(kind: .system, text: "System event A", isDuplicate: true)

        let groups = ConsoleLineGrouper.group([lineA, lineB])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].duplicates.count, 1)
        XCTAssertEqual(groups[0].primary.id, lineA.id)
    }

    /// A recurring fault is the same message over and over; it should stay one
    /// counted line even when other lines fall between its repeats, so a
    /// reconnect storm does not bury the log.
    func testErrorMessagesCollapseEvenWhenNotConsecutive() {
        let first = ConsoleLine.error("Radio control failed")
        let between = ConsoleLine.system("Connected to IC-705")
        let again = ConsoleLine.error("Radio control failed")

        let groups = ConsoleLineGrouper.group([first, between, again])

        XCTAssertEqual(groups.count, 2)
        let errorGroup = groups.first { $0.primary.kind == .error }
        XCTAssertEqual(errorGroup?.primary.id, first.id)
        XCTAssertEqual(errorGroup?.duplicates.count, 1)
        XCTAssertEqual(errorGroup?.duplicates.first?.id, again.id)
    }

    /// Distinct faults are distinct lines; collapsing is by message, not by
    /// kind.
    func testDifferentErrorsStaySeparate() {
        let lost = ConsoleLine.error("Lost the radio")
        let failed = ConsoleLine.error("Connection to IC-705 failed")

        let groups = ConsoleLineGrouper.group([lost, failed])

        XCTAssertEqual(groups.count, 2)
    }

    /// System status collapses only back-to-back, so two sends separated by
    /// something else keep their own place in time rather than folding into an
    /// older row.
    func testSystemMessagesDoNotCollapseWhenSeparated() {
        let firstSend = ConsoleLine.system("Frame sent successfully")
        let between = ConsoleLine.error("Lost the radio")
        let secondSend = ConsoleLine.system("Frame sent successfully")

        let groups = ConsoleLineGrouper.group([firstSend, between, secondSend])

        XCTAssertEqual(groups.count, 3)
    }
}
