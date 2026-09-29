//
//  SQLiteRawStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation
import GRDB

nonisolated final class SQLiteRawStore: RawStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    convenience init() throws {
        try self.init(dbQueue: DatabaseManager.makeDatabaseQueue())
    }

    func append(_ entry: RawEntryRecord) throws {
        try dbQueue.write { db in
            try entry.insert(db)
        }
    }

    func loadRecent(limit: Int) throws -> [RawEntryRecord] {
        try dbQueue.read { db in
            try RawEntryRecord
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func deleteAll() throws {
        try dbQueue.write { db in
            _ = try RawEntryRecord.deleteAll(db)
            // Reclaim disk space immediately
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
    }

    func pruneIfNeeded(retentionLimit: Int) throws {
        guard retentionLimit > 0 else { return }
        try dbQueue.write { db in
            let total = try RawEntryRecord.fetchCount(db)
            guard total > retentionLimit else { return }
            let overflow = total - retentionLimit
            if overflow <= 0 { return }
            try db.execute(
                sql: """
                DELETE FROM \(RawEntryRecord.databaseTableName)
                WHERE id IN (
                    SELECT id FROM \(RawEntryRecord.databaseTableName)
                    ORDER BY createdAt ASC
                    LIMIT ?
                )
                """,
                arguments: [overflow]
            )
            // Reclaim disk space incrementally (up to 100 pages ~400KB at a time)
            try db.execute(sql: "PRAGMA incremental_vacuum(100)")
        }
    }
}
