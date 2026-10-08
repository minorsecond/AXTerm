//
//  TransferListSortTests.swift
//  AXTermTests
//
//  The transfer list sorts by time, name, station or size, either way, and
//  every row says who and when in local time and UTC (operator, 2026-10-07).
//

import XCTest
@testable import AXTerm

final class TransferListSortTests: XCTestCase {

    private func transfer(_ name: String, peer: String, size: Int, finished: TimeInterval?,
                          direction: TransferDirection = .outbound) -> BulkTransfer {
        var transfer = BulkTransfer(id: UUID(), fileName: name, fileSize: size, destination: peer,
                                    direction: direction)
        if let finished {
            transfer.startedAt = Date(timeIntervalSince1970: finished - 60)
            transfer.completedAt = Date(timeIntervalSince1970: finished)
        }
        return transfer
    }

    private lazy var transfers = [
        transfer("photo10.jpg", peer: "K0EPI-2", size: 12_000, finished: 200),
        transfer("notes.txt", peer: "W0ARP", size: 800, finished: 300),
        transfer("Photo2.jpg", peer: "AA0A", size: 25_000, finished: 100),
    ]

    private func names(_ sort: ListSort<TransferSortKey>) -> [String] {
        sort.apply(transfers).map(\.fileName)
    }

    func testEachColumnSorts() {
        XCTAssertEqual(names(.natural(.date)), ["notes.txt", "photo10.jpg", "Photo2.jpg"])
        XCTAssertEqual(names(ListSort(key: .date, ascending: true)), ["Photo2.jpg", "photo10.jpg", "notes.txt"])
        XCTAssertEqual(names(.natural(.name)), ["notes.txt", "Photo2.jpg", "photo10.jpg"])
        XCTAssertEqual(names(.natural(.station)), ["Photo2.jpg", "photo10.jpg", "notes.txt"])
        XCTAssertEqual(names(.natural(.size)), ["Photo2.jpg", "photo10.jpg", "notes.txt"])
    }

    func testOneNotStartedYetIsNewest() {
        let waiting = transfer("queued.bin", peer: "K0EPI-2", size: 1, finished: nil)
        XCTAssertEqual(ListSort.natural(TransferSortKey.date).apply(transfers + [waiting]).first?.fileName,
                       "queued.bin")
    }

    func testTheRowSaysWhoAndWhenInBothTimes() {
        let denver = TimeZone(identifier: "America/Denver")!
        // Finished 2026-10-07 20:41:05 UTC.
        let sent = transfer("photo.jpg", peer: "K0EPI-2", size: 1, finished: 1_791_405_665)
        let line = TransferRowTime.line(sent, timeZone: denver, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(line?.hasPrefix("To K0EPI-2 · ") == true, line ?? "nil")
        XCTAssertTrue(line?.hasSuffix(" · 20:41 UTC") == true, line ?? "nil")

        let received = transfer("photo.jpg", peer: "K0EPI-2", size: 1, finished: 1_791_405_665,
                                direction: .inbound)
        XCTAssertTrue(TransferRowTime.line(received, timeZone: denver)?.hasPrefix("From K0EPI-2 · ") == true)
        XCTAssertNil(TransferRowTime.line(transfer("q", peer: "K0EPI-2", size: 1, finished: nil)),
                     "nothing to say before it starts")
    }
}
