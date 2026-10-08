//
//  BBSMessageSortTests.swift
//  AXTermTests
//
//  The operator's mailbox sorts by received time, sender or subject, either
//  way (operator, 2026-10-07).
//

import XCTest
@testable import AXTerm

final class BBSMessageSortTests: XCTestCase {

    private func message(_ id: Int64, from: String, subject: String, at seconds: TimeInterval) -> BBSMessage {
        BBSMessage(id: id, from: from, to: "ALL", subject: subject, body: "",
                   receivedAt: Date(timeIntervalSince1970: seconds))
    }

    private lazy var messages = [
        message(1, from: "W0ARP", subject: "Net tonight", at: 200),
        message(2, from: "K0EPI-9", subject: "park photos", at: 300),
        message(3, from: "AA0A", subject: "Antenna", at: 100),
    ]

    private func ids(_ sort: ListSort<BBSMessageSortKey>) -> [Int64] {
        BBSMessageList.visible(messages, filter: .all, sysop: "K0EPI", sort: sort).map(\.id)
    }

    func testNewestFirstIsTheDefault() {
        XCTAssertEqual(BBSMessageList.visible(messages, filter: .all, sysop: "K0EPI").map(\.id), [2, 1, 3])
    }

    func testEachColumnSortsEitherWay() {
        XCTAssertEqual(ids(ListSort(key: .date, ascending: true)), [3, 1, 2])
        XCTAssertEqual(ids(.natural(.from)), [3, 2, 1])
        XCTAssertEqual(ids(ListSort(key: .from, ascending: false)), [1, 2, 3])
        XCTAssertEqual(ids(.natural(.subject)), [3, 1, 2])
    }

    func testOtherMailboxesSortTheSameWay() {
        let sections = BBSUnifiedListing.messageSections(
            local: messages, remote: [], showsOtherInstances: false, filter: .all, sysop: "K0EPI",
            sort: .natural(.from))
        XCTAssertEqual(sections.first?.rows.map(\.message.id), [3, 2, 1])
    }
}
