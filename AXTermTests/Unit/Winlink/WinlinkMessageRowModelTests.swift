//
//  WinlinkMessageRowModelTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

final class WinlinkMessageRowModelTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func summary(from: String = "K0NTS",
                         to: [String] = ["K0EPI"],
                         direction: WinlinkMessageRecord.Direction = .inbound,
                         subject: String = "Net check-in",
                         bodySize: Int = 512,
                         attachments: Int = 0,
                         isRead: Bool = true,
                         state: WinlinkMessageStateRecord.DeliveryState = .received,
                         on when: Date = Date()) -> WinlinkMessageSummary {
        WinlinkMessageSummary(
            mid: "TESTMID1", direction: direction, date: when,
            fromAddr: from, toAddrs: to, subject: subject,
            bodySize: bodySize, attachmentCount: attachments,
            isRead: isRead, deliveryState: state, folderId: 1, lastError: nil)
    }

    // MARK: - Correspondent

    func testInboundRowShowsTheSender() {
        let model = WinlinkMessageRowModel.make(summary(from: "K0NTS-10", direction: .inbound))
        XCTAssertEqual(model.correspondent, "K0NTS-10")
    }

    func testOutboundRowShowsTheRecipient() {
        let model = WinlinkMessageRowModel.make(
            summary(from: "K0EPI-7", to: ["W0ARP-10"], direction: .outbound))
        // A Sent folder listing senders would show the operator's own call on
        // every row, which is the one fact they already know.
        XCTAssertEqual(model.correspondent, "W0ARP-10")
    }

    func testSMTPTransportPrefixIsStripped() {
        let model = WinlinkMessageRowModel.make(
            summary(from: "SMTP:query-reply@winlink.org"))
        // "SMTP:" says how it travelled, not who sent it, and it pushed the
        // readable half of the address off the end of a one-line row.
        XCTAssertEqual(model.correspondent, "query-reply@winlink.org")
    }

    func testLowercaseSMTPPrefixIsAlsoStripped() {
        XCTAssertEqual(
            WinlinkMessageRowModel.displayAddress("smtp:someone@example.com"),
            "someone@example.com")
    }

    func testAddressThatMerelyStartsWithSMTPLettersIsUntouched() {
        // A callsign is not a transport marker.
        XCTAssertEqual(WinlinkMessageRowModel.displayAddress("SMTPX-7"), "SMTPX-7")
    }

    func testOutboundWithNoRecipientFallsBackToADash() {
        let model = WinlinkMessageRowModel.make(
            summary(to: [], direction: .outbound))
        XCTAssertEqual(model.correspondent, "—")
    }

    // MARK: - Dates

    func testTodayShowsOnlyTheTime() {
        let now = date(2026, 8, 25, 14, 30)
        let label = WinlinkMessageRowModel.dateLabel(
            date(2026, 8, 25, 10, 52), now: now, calendar: calendar)
        XCTAssertFalse(label.contains("Aug"), "Today's mail is placed by time, not date: \(label)")
        XCTAssertTrue(label.contains("52"), "Expected a time-of-day label, got \(label)")
    }

    func testYesterdayIsNamed() {
        let now = date(2026, 8, 25, 14, 30)
        XCTAssertEqual(
            WinlinkMessageRowModel.dateLabel(date(2026, 8, 24, 9, 0), now: now, calendar: calendar),
            "Yesterday")
    }

    func testEarlierThisYearOmitsTheYear() {
        let now = date(2026, 8, 25, 14, 30)
        let label = WinlinkMessageRowModel.dateLabel(
            date(2026, 3, 2, 9, 0), now: now, calendar: calendar)
        XCTAssertTrue(label.contains("2"), label)
        XCTAssertFalse(label.contains("2026"),
                       "The current year is redundant on every row: \(label)")
    }

    func testPreviousYearsCarryTheYear() {
        let now = date(2026, 8, 25, 14, 30)
        let label = WinlinkMessageRowModel.dateLabel(
            date(2025, 3, 2, 9, 0), now: now, calendar: calendar)
        XCTAssertTrue(label.contains("25"),
                      "A message from another year must say so: \(label)")
    }

    // MARK: - Badge suppression

    func testReceivedStateShowsNoBadge() {
        // Every row of an Inbox is received; a badge saying so is furniture.
        XCTAssertNil(WinlinkMessageRowModel.badge(for: .received))
    }

    func testSentStateShowsNoBadge() {
        XCTAssertNil(WinlinkMessageRowModel.badge(for: .sent))
    }

    func testFailedStateShowsABadge() {
        XCTAssertEqual(WinlinkMessageRowModel.badge(for: .failed), .failed)
    }

    func testInFlightAndDraftStatesShowBadges() {
        XCTAssertEqual(WinlinkMessageRowModel.badge(for: .queued), .queued)
        XCTAssertEqual(WinlinkMessageRowModel.badge(for: .sending), .sending)
        XCTAssertEqual(WinlinkMessageRowModel.badge(for: .draft), .draft)
    }

    // MARK: - Subject and size

    func testEmptySubjectIsMarkedAsAPlaceholder() {
        let model = WinlinkMessageRowModel.make(summary(subject: ""))
        XCTAssertEqual(model.subject, "(no subject)")
        XCTAssertTrue(model.subjectIsPlaceholder,
                      "The view greys the placeholder, so it has to be distinguishable")
    }

    func testRealSubjectIsNotAPlaceholder() {
        let model = WinlinkMessageRowModel.make(summary(subject: "INQUIRY: LIST"))
        XCTAssertEqual(model.subject, "INQUIRY: LIST")
        XCTAssertFalse(model.subjectIsPlaceholder)
    }

    func testSmallSizesStayInBytes() {
        // 408 bytes matters on a packet link; "0 KB" would erase it.
        let model = WinlinkMessageRowModel.make(summary(bodySize: 408))
        XCTAssertEqual(model.sizeLabel, "408 B")
    }

    func testKilobyteSizesKeepOneDecimalWhileSmall() {
        XCTAssertEqual(WinlinkExchangeStatus.compact(5 * 1024), "5.0 KB")
    }

    func testLargeKilobyteSizesDropTheDecimal() {
        XCTAssertEqual(WinlinkExchangeStatus.compact(181 * 1024), "181 KB")
    }

    func testUnreadAndAttachmentFlagsArePassedThrough() {
        let model = WinlinkMessageRowModel.make(
            summary(attachments: 2, isRead: false))
        XCTAssertTrue(model.isUnread)
        XCTAssertTrue(model.showsAttachmentIndicator)
    }
}
