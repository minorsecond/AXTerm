//
//  SQLiteConsoleStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation
import GRDB

final class SQLiteConsoleStore: ConsoleStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    convenience init() throws {
        try self.init(dbQueue: DatabaseManager.makeDatabaseQueue())
    }

    func append(_ entry: ConsoleEntryRecord) throws {
        try dbQueue.write { db in
            try entry.insert(db)
        }
    }

    func loadRecent(limit: Int) throws -> [ConsoleEntryRecord] {
        try dbQueue.read { db in
            try ConsoleEntryRecord
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func deleteAll() throws {
        try dbQueue.write { db in
            _ = try ConsoleEntryRecord.deleteAll(db)
        }
    }

    func pruneIfNeeded(retentionLimit: Int) throws {
        guard retentionLimit > 0 else { return }
        try dbQueue.write { db in
            let total = try ConsoleEntryRecord.fetchCount(db)
            guard total > retentionLimit else { return }
            let overflow = total - retentionLimit
            if overflow <= 0 { return }
            try db.execute(
                sql: """
                DELETE FROM \(ConsoleEntryRecord.databaseTableName)
                WHERE id IN (
                    SELECT id FROM \(ConsoleEntryRecord.databaseTableName)
                    ORDER BY createdAt ASC
                    LIMIT ?
                )
                """,
                arguments: [overflow]
            )
        }
    }
}
