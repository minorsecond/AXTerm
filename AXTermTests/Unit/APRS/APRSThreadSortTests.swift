//
//  APRSThreadSortTests.swift
//  AXTermTests
//
//  APRS conversations sort by their last message or by station, either way
//  (operator, 2026-10-07).
//

import XCTest
@testable import AXTerm

final class APRSThreadSortTests: XCTestCase {
    private let threads: [(peer: String, last: Date)] = [
        ("W0ARP", Date(timeIntervalSince1970: 200)),
        ("K0EPI-2", Date(timeIntervalSince1970: 300)),
        ("AA0A", Date(timeIntervalSince1970: 100)),
    ]

    private func peers(_ sort: ListSort<APRSThreadSortKey>) -> [String] {
        sort.apply(threads, peer: \.peer, last: \.last).map(\.peer)
    }

    func testTheLatestConversationIsFirstByDefault() {
        XCTAssertEqual(peers(.natural(.recent)), ["K0EPI-2", "W0ARP", "AA0A"])
        XCTAssertEqual(peers(ListSort(key: .recent, ascending: true)), ["AA0A", "W0ARP", "K0EPI-2"])
    }

    func testByStationEitherWay() {
        XCTAssertEqual(peers(.natural(.station)), ["AA0A", "K0EPI-2", "W0ARP"])
        XCTAssertEqual(peers(ListSort(key: .station, ascending: false)), ["W0ARP", "K0EPI-2", "AA0A"])
    }
}
