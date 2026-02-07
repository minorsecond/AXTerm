//
//  SQLiteConsoleStoreTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/2/26.
//

import XCTest
import GRDB
@testable import AXTerm

final class SQLiteConsoleStoreTests: XCTestCase {
    func testRoundTripOrderingAndPrune() throws {
        let store = try makeStore()
        let first = ConsoleEntryRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 10),
            level: .info,
            category: .packet,
            message: "First",
            packetID: nil,
            metadataJSON: nil,
            byteCount: nil
        )
        let second = ConsoleEntryRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 20),
            level: .system,
            category: .connection,
            message: "Second",
            packetID: nil,
            metadataJSON: nil,
            byteCount: nil
        )
        try store.append(first)
        try store.append(second)

        let recent = try store.loadRecent(limit: 10)
        XCTAssertEqual(recent.map(\.id), [second.id, first.id])

        try store.pruneIfNeeded(retentionLimit: 1)
        let remaining = try store.loadRecent(limit: 10)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, second.id)
    }

    private func makeStore() throws -> SQLiteConsoleStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteConsoleStore(dbQueue: queue)
    }
}
