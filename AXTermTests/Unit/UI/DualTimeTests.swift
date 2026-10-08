//
//  DualTimeTests.swift
//  AXTermTests
//
//  Lists of files and messages sent or received show when, in local time and
//  in UTC (operator, 2026-10-07). Radio logs run on UTC; the clock on the
//  wall runs on local time, and the operator needs both.
//

import XCTest
@testable import AXTerm

final class DualTimeTests: XCTestCase {
    private let denver = TimeZone(identifier: "America/Denver")!
    private let locale = Locale(identifier: "en_US")

    /// 2026-10-07 20:41:05 UTC, 14:41 in Denver.
    private let afternoon = Date(timeIntervalSince1970: 1_791_405_665)
    /// 2026-10-08 02:15:00 UTC, still the 7th in Denver.
    private let evening = Date(timeIntervalSince1970: 1_791_425_700)

    func testUTCIsTheTimeAloneOnTheSameDay() {
        XCTAssertEqual(DualTime.utc(afternoon, localTimeZone: denver), "20:41 UTC")
    }

    func testUTCCarriesItsDateWhenItIsAlreadyTomorrow() {
        XCTAssertEqual(DualTime.utc(evening, localTimeZone: denver), "Oct 8 02:15 UTC")
    }

    func testLocalIsTheOperatorsOwnClock() {
        let local = DualTime.local(afternoon, timeZone: denver, locale: locale)
        XCTAssertTrue(local.contains("Oct 7"), local)
        XCTAssertTrue(local.contains("2:41"), local)
    }

    func testTheLineShowsBoth() {
        let line = DualTime.line(afternoon, timeZone: denver, locale: locale)
        XCTAssertTrue(line.hasSuffix(" · 20:41 UTC"), line)
        XCTAssertTrue(line.contains("2:41"), line)
    }

    func testTheHelpGivesBothToTheSecond() {
        let help = DualTime.help(afternoon, timeZone: denver, locale: locale)
        XCTAssertTrue(help.contains("2026-10-07 20:41:05 UTC"), help)
        XCTAssertTrue(help.contains("2:41:05"), help)
    }

    func testABubbleShowsTheTimeAloneToday() {
        let line = DualTime.compact(afternoon, now: afternoon.addingTimeInterval(600),
                                    timeZone: denver, locale: locale)
        XCTAssertFalse(line.contains("Oct"), line)
        XCTAssertTrue(line.hasSuffix(" · 20:41 UTC"), line)
    }

    func testABubbleFromAnotherDaySaysWhichDay() {
        let line = DualTime.compact(afternoon, now: afternoon.addingTimeInterval(2 * 86_400),
                                    timeZone: denver, locale: locale)
        XCTAssertTrue(line.contains("Oct 7"), line)
    }
}
