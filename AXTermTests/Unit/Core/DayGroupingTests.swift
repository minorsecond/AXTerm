//
//  DayGroupingTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/2/26.
//

import XCTest
@testable import AXTerm

final class DayGroupingTests: XCTestCase {
    func testGroupingAcrossMidnight() {
        let calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(secondsFromGMT: 0) ?? .current
        var fixedCalendar = calendar
        fixedCalendar.timeZone = zone

        let items = [
            TestItem(id: UUID(), date: Date(timeIntervalSince1970: 1_000)),
            TestItem(id: UUID(), date: Date(timeIntervalSince1970: 2_000)),
            TestItem(id: UUID(), date: Date(timeIntervalSince1970: 86_401))
        ]

        let grouped = DayGrouping.group(items: items, date: { $0.date }, calendar: fixedCalendar)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.first?.items.count, 2)
        XCTAssertEqual(grouped.last?.items.count, 1)
    }

    func testGroupingStableInTimezone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600) ?? .current

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            TestItem(id: UUID(), date: base),
            TestItem(id: UUID(), date: base.addingTimeInterval(60 * 60))
        ]

        let grouped = DayGrouping.group(items: items, date: { $0.date }, calendar: calendar)
        XCTAssertEqual(grouped.count, 1)
    }

    private struct TestItem: Identifiable {
        let id: UUID
        let date: Date
    }
}
