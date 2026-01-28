//
//  SQLitePacketStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
import GRDB

final class SQLitePacketStore: PacketStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    convenience init() throws {
        try self.init(dbQueue: DatabaseManager.makeDatabaseQueue())
    }

    func save(_ packet: Packet) throws {
        let record = PacketRecord(packet: packet)
        try dbQueue.write { db in
            try record.insert(db)
        }
    }

    func loadRecent(limit: Int) throws -> [PacketRecord] {
        try dbQueue.read { db in
            try PacketRecord
                .order(Column("receivedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func deleteAll() throws {
        try dbQueue.write { db in
            _ = try PacketRecord.deleteAll(db)
        }
    }

    func setPinned(packetId: UUID, pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(PacketRecord.databaseTableName) SET pinned = ? WHERE id = ?",
                arguments: [pinned, packetId.uuidString]
            )
        }
    }

    func pruneIfNeeded(retentionLimit: Int) throws {
        guard retentionLimit > 0 else { return }
        try dbQueue.write { db in
            let total = try PacketRecord.fetchCount(db)
            guard total > retentionLimit else { return }
            let overflow = total - retentionLimit
            if overflow <= 0 { return }
            try db.execute(
                sql: """
                DELETE FROM \(PacketRecord.databaseTableName)
                WHERE id IN (
                    SELECT id FROM \(PacketRecord.databaseTableName)
                    ORDER BY receivedAt ASC
                    LIMIT ?
                )
                """,
                arguments: [overflow]
            )
        }
    }

    func count() throws -> Int {
        try dbQueue.read { db in
            try PacketRecord.fetchCount(db)
        }
    }
}
