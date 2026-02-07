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

    func testDuplicateFlagRequiresSignature() {
        let lineA = ConsoleLine(kind: .system, text: "System event A", isDuplicate: true)
        let lineB = ConsoleLine(kind: .system, text: "System event A", isDuplicate: true)

        let groups = ConsoleLineGrouper.group([lineA, lineB])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].duplicates.count, 0)
        XCTAssertEqual(groups[1].duplicates.count, 0)
    }
}
