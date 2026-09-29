//
//  WinlinkUnreadBadgeTests.swift
//  AXTermTests
//
//  Reported 2026-08-25: the Mail tab badge stayed lit after every message had
//  been read. `WinlinkContext` keeps its own `unreadCount` for the badge —
//  it outlives any one mailbox screen — and reading a message only updated the
//  view model's copy. Nothing bridged the two, so on iOS, where opening a
//  message never calls `refresh()`, the badge went stale until an unrelated
//  action happened to refresh it.
//

import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class WinlinkUnreadBadgeTests: XCTestCase {

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func deliver(_ store: SQLiteWinlinkStore, mid: String,
                         subject: String = "Net check-in") throws {
        try store.saveInbound(WinlinkB2Message(
            mid: mid,
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/25 12:00")!,
            type: .privateMessage,
            from: "K0NTS-10",
            to: ["K0EPI-7"],
            cc: [],
            subject: subject,
            mbo: "K0NTS-10",
            body: Data("hello\r\n".utf8),
            attachments: []))
    }

    // MARK: - The bridge exists

    func testReadingAMessageAnnouncesTheNewUnreadCount() async throws {
        let store = try makeStore()
        try deliver(store, mid: "MIDAAAAAAAA1")
        let vm = WinlinkMailboxViewModel(store: store, myCallsign: { "K0EPI-7" })
        XCTAssertEqual(vm.unreadCount, 1)

        var announced = 0
        vm.onUnreadCountChanged = { announced += 1 }

        vm.selectedMID = "MIDAAAAAAAA1"

        XCTAssertEqual(vm.unreadCount, 0, "reading the only unread message clears the count")
        XCTAssertEqual(announced, 1, "the owner of the badge has to be told")
    }

    func testTheAnnouncementCarriesTheClearedCountToAnObserver() async throws {
        let store = try makeStore()
        try deliver(store, mid: "MIDAAAAAAAA1")
        let vm = WinlinkMailboxViewModel(store: store, myCallsign: { "K0EPI-7" })

        // Stands in for WinlinkContext.refreshUnread(), which re-reads the
        // store rather than trusting a number passed to it.
        var badge = try store.unreadInboxCount()
        vm.onUnreadCountChanged = { badge = (try? store.unreadInboxCount()) ?? badge }
        XCTAssertEqual(badge, 1)

        vm.selectedMID = "MIDAAAAAAAA1"

        XCTAssertEqual(badge, 0, "The badge must go dark once the mail is read")
    }

    // MARK: - It does not over-fire

    func testReopeningAnAlreadyReadMessageAnnouncesNothing() async throws {
        let store = try makeStore()
        try deliver(store, mid: "MIDAAAAAAAA1")
        let vm = WinlinkMailboxViewModel(store: store, myCallsign: { "K0EPI-7" })
        vm.selectedMID = "MIDAAAAAAAA1"

        var announced = 0
        vm.onUnreadCountChanged = { announced += 1 }
        vm.selectedMID = nil
        vm.selectedMID = "MIDAAAAAAAA1"

        // The count did not move, so neither should the badge.
        XCTAssertEqual(announced, 0)
    }

    func testReadingOneOfSeveralLeavesTheRestCounted() async throws {
        let store = try makeStore()
        try deliver(store, mid: "MIDAAAAAAAA1")
        try deliver(store, mid: "MIDAAAAAAAA2")
        try deliver(store, mid: "MIDAAAAAAAA3")
        let vm = WinlinkMailboxViewModel(store: store, myCallsign: { "K0EPI-7" })
        XCTAssertEqual(vm.unreadCount, 3)

        var latest = vm.unreadCount
        vm.onUnreadCountChanged = { latest = vm.unreadCount }
        vm.selectedMID = "MIDAAAAAAAA2"

        XCTAssertEqual(latest, 2, "the badge counts what is still unread, not what was opened")
    }

    // MARK: - Marking unread relights it

    func testMarkingUnreadAnnouncesTheCountAgain() async throws {
        let store = try makeStore()
        try deliver(store, mid: "MIDAAAAAAAA1")
        let vm = WinlinkMailboxViewModel(store: store, myCallsign: { "K0EPI-7" })
        vm.selectedMID = "MIDAAAAAAAA1"
        XCTAssertEqual(vm.unreadCount, 0)

        var latest = vm.unreadCount
        vm.onUnreadCountChanged = { latest = vm.unreadCount }
        vm.markUnread(mid: "MIDAAAAAAAA1")

        // The swipe action has to relight the badge as surely as reading dims it.
        XCTAssertEqual(latest, 1)
    }
}
