//
//  SQLiteRawStoreTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/2/26.
//

import XCTest
import GRDB
@testable import AXTerm

final class SQLiteRawStoreTests: XCTestCase {
    func testRoundTripOrderingAndPrune() throws {
        let store = try makeStore()
        let data = Data([0x01, 0x02])
        let first = RawEntryRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 5),
            source: "kiss",
            direction: "rx",
            kind: .bytes,
            rawHex: RawEntryEncoding.encodeHex(data),
            byteCount: data.count,
            packetID: nil,
            metadataJSON: nil
        )
        let second = RawEntryRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 15),
            source: "kiss",
            direction: "rx",
            kind: .bytes,
            rawHex: RawEntryEncoding.encodeHex(Data([0x03])),
            byteCount: 1,
            packetID: nil,
            metadataJSON: nil
        )
        try store.append(first)
        try store.append(second)

        let recent = try store.loadRecent(limit: 10)
        XCTAssertEqual(recent.map(\.id), [second.id, first.id])
        XCTAssertEqual(recent.last?.rawHex, RawEntryEncoding.encodeHex(data))
        XCTAssertEqual(recent.last?.toRawChunk().data, data)

        try store.pruneIfNeeded(retentionLimit: 1)
        let remaining = try store.loadRecent(limit: 10)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, second.id)
    }

    private func makeStore() throws -> SQLiteRawStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteRawStore(dbQueue: queue)
    }
}
