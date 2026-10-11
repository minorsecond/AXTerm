//
//  ConsoleScrollTargetTests.swift
//  AXTermTests
//
//  Constitution retest 2026-10-11, finding 2: while plain-text lines
//  arrived, the iPad's history jumped on each one. A new line scrolled to
//  the marker below the padding, which overshoots, and the repin then moved
//  back to the last line. Every scroll to the newest now goes to the same
//  place the repin does.
//

import XCTest
@testable import AXTerm

final class ConsoleScrollTargetTests: XCTestCase {

    func testANewLineGoesToTheLastLineNotTheMarkerBelowThePadding() {
        let last = UUID()
        XCTAssertEqual(ConsoleScrollTarget.newest(hasSendStatus: false, lastLineID: last), .line(last))
    }

    func testWithAStatusRowItIsTheRow() {
        XCTAssertEqual(ConsoleScrollTarget.newest(hasSendStatus: true, lastLineID: UUID()), .sendStatus)
    }

    func testAnEmptyHistoryHasOnlyTheMarker() {
        XCTAssertEqual(ConsoleScrollTarget.newest(hasSendStatus: false, lastLineID: nil), .bottom)
    }
}
