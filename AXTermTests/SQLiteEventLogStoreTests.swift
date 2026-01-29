//
//  SQLiteEventLogStoreTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/2/26.
//

import XCTest
import GRDB
@testable import AXTerm

final class SQLiteEventLogStoreTests: XCTestCase {
    func testRoundTripOrderingAndPrune() throws {
        let store = try makeStore()
        let first = AppEventRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 3),
            level: .info,
            category: .settings,
            message: "First",
            metadataJSON: nil
        )
        let second = AppEventRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 7),
            level: .error,
            category: .connection,
            message: "Second",
            metadataJSON: nil
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

    private func makeStore() throws -> SQLiteEventLogStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteEventLogStore(dbQueue: queue)
    }
}
