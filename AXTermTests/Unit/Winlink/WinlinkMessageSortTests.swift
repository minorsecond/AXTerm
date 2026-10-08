//
//  WinlinkMessageSortTests.swift
//  AXTermTests
//
//  The mailbox sorts by date, correspondent, subject or size, either way,
//  and every row says when in local time and UTC (operator, 2026-10-07).
//

import XCTest
@testable import AXTerm

final class WinlinkMessageSortTests: XCTestCase {

    private func summary(_ mid: String, from: String, subject: String, at seconds: TimeInterval,
                         size: Int, direction: WinlinkMessageRecord.Direction = .inbound,
                         to: [String] = ["K0EPI"]) -> WinlinkMessageSummary {
        WinlinkMessageSummary(
            mid: mid, direction: direction, date: Date(timeIntervalSince1970: seconds),
            fromAddr: from, toAddrs: to, subject: subject,
            bodySize: size, attachmentCount: 0, isRead: true, deliveryState: .received,
            folderId: 1, lastError: nil)
    }

    private lazy var mail = [
        summary("A", from: "W0ARP", subject: "Net report", at: 200, size: 500),
        summary("B", from: "K0EPI-3", subject: "about the park", at: 300, size: 9000),
        summary("C", from: "SMTP:ann@example.com", subject: "Photo", at: 100, size: 2000),
    ]

    func testNewestFirstIsTheDefault() {
        XCTAssertEqual(ListSort.natural(WinlinkMessageSortKey.date).apply(mail).map(\.mid), ["B", "A", "C"])
    }

    func testEachColumnSorts() {
        XCTAssertEqual(ListSort(key: WinlinkMessageSortKey.date, ascending: true).apply(mail).map(\.mid),
                       ["C", "A", "B"])
        XCTAssertEqual(ListSort.natural(WinlinkMessageSortKey.correspondent).apply(mail).map(\.mid),
                       ["C", "B", "A"], "ann@example.com, K0EPI-3, W0ARP: the SMTP: prefix is not sorted on")
        XCTAssertEqual(ListSort.natural(WinlinkMessageSortKey.subject).apply(mail).map(\.mid),
                       ["B", "A", "C"])
        XCTAssertEqual(ListSort.natural(WinlinkMessageSortKey.size).apply(mail).map(\.mid),
                       ["B", "C", "A"])
    }

    func testSentMailSortsByRecipient() {
        let sent = [
            summary("X", from: "K0EPI", subject: "", at: 1, size: 1, direction: .outbound, to: ["W0ARP"]),
            summary("Y", from: "K0EPI", subject: "", at: 2, size: 1, direction: .outbound, to: ["AA0A"]),
        ]
        XCTAssertEqual(ListSort.natural(WinlinkMessageSortKey.correspondent).apply(sent).map(\.mid), ["Y", "X"])
    }

    func testTheRowSaysWhenInUTCToo() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "America/Denver")!
        // 2026-10-07 20:41:05 UTC.
        let row = WinlinkMessageRowModel.make(
            summary("A", from: "W0ARP", subject: "", at: 1_791_405_665, size: 1),
            now: Date(timeIntervalSince1970: 1_791_405_700), calendar: utc)
        XCTAssertEqual(row.utcLabel, "20:41 UTC")
    }
}
