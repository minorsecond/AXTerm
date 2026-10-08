//
//  ListSortTests.swift
//  AXTermTests
//
//  Lists of files and messages can be sorted by any of their columns,
//  either way (operator, 2026-10-07).
//

import XCTest
@testable import AXTerm

final class ListSortTests: XCTestCase {
    private enum Key: String, ListSortKey {
        case date, name, size
        var title: String { rawValue.capitalized }
        var kind: SortKind {
            switch self {
            case .date: return .time
            case .name: return .text
            case .size: return .size
            }
        }
    }

    private struct Item: Equatable {
        var name: String
        var date: Date
        var size: Int
    }

    private let items = [
        Item(name: "photo10.jpg", date: Date(timeIntervalSince1970: 200), size: 30),
        Item(name: "Photo2.jpg", date: Date(timeIntervalSince1970: 300), size: 10),
        Item(name: "notes.txt", date: Date(timeIntervalSince1970: 100), size: 30),
    ]

    func testEachKeyStartsTheUsualWay() {
        XCTAssertFalse(ListSort<Key>.natural(.date).ascending, "newest first")
        XCTAssertTrue(ListSort<Key>.natural(.name).ascending, "A to Z")
        XCTAssertFalse(ListSort<Key>.natural(.size).ascending, "largest first")
    }

    func testTimeSortsBothWays() {
        XCTAssertEqual(ListSort(key: Key.date, ascending: false).sorted(items, by: \.date).map(\.name),
                       ["Photo2.jpg", "photo10.jpg", "notes.txt"])
        XCTAssertEqual(ListSort(key: Key.date, ascending: true).sorted(items, by: \.date).map(\.name),
                       ["notes.txt", "photo10.jpg", "Photo2.jpg"])
    }

    func testTextSortsTheWayFinderDoes() {
        XCTAssertEqual(ListSort(key: Key.name, ascending: true).sorted(items, text: \.name).map(\.name),
                       ["notes.txt", "Photo2.jpg", "photo10.jpg"])
        XCTAssertEqual(ListSort(key: Key.name, ascending: false).sorted(items, text: \.name).map(\.name),
                       ["photo10.jpg", "Photo2.jpg", "notes.txt"])
    }

    func testTiesKeepTheirOrderEitherWay() {
        XCTAssertEqual(ListSort(key: Key.size, ascending: false).sorted(items, by: \.size).map(\.name),
                       ["photo10.jpg", "notes.txt", "Photo2.jpg"])
        XCTAssertEqual(ListSort(key: Key.size, ascending: true).sorted(items, by: \.size).map(\.name),
                       ["Photo2.jpg", "photo10.jpg", "notes.txt"])
    }

    func testTheChoiceSurvivesBeingStored() {
        let sort = ListSort(key: Key.size, ascending: true)
        XCTAssertEqual(sort.rawValue, "size.asc")
        XCTAssertEqual(ListSort<Key>(rawValue: "size.asc"), sort)
        XCTAssertNil(ListSort<Key>(rawValue: "colour.asc"))
        XCTAssertNil(ListSort<Key>(rawValue: "size"))
    }

    func testTheDirectionsAreWordedForTheKey() {
        XCTAssertEqual(ListSort(key: Key.date, ascending: false).orderTitle, "Newest First")
        XCTAssertEqual(ListSort(key: Key.name, ascending: true).orderTitle, "A to Z")
        XCTAssertEqual(ListSort(key: Key.size, ascending: true).orderTitle, "Smallest First")
    }
}
