import Foundation
import GRDB

/// Persistence for APRS message-class exchanges. Small and flat, like the BBS
/// mailbox store: one struct, one protocol, one SQLite class.
protocol APRSMessageStore: Sendable {
    /// Every record, oldest first.
    func all() throws -> [APRSMessageRecord]
    /// Insert or replace a record by id.
    func upsert(_ record: APRSMessageRecord) throws
    /// Mark one record read.
    func markRead(id: String, at date: Date) throws
    /// Mark every incoming message in a thread read.
    func markThreadRead(peer: String, at date: Date) throws
    /// The outgoing message awaiting ack from `peer` with this number, if any
    /// — used to resolve an inbound ack to the message it answers.
    func outgoing(peer: String, number: String) throws -> APRSMessageRecord?
    /// An already-stored incoming message from `peer` with this number — a
    /// re-send of a message we already have. Lets us re-ack a duplicate
    /// without storing or notifying twice.
    func incoming(peer: String, number: String) throws -> APRSMessageRecord?
    /// Outgoing messages whose retransmit is due at or before `now`.
    func duePending(now: Date) throws -> [APRSMessageRecord]
    /// Remove one record.
    func delete(id: String) throws
}

nonisolated final class SQLiteAPRSMessageStore: APRSMessageStore, @unchecked Sendable {

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    private static func record(from row: Row) -> APRSMessageRecord {
        APRSMessageRecord(
            id: row["id"],
            direction: APRSMessageRecord.Direction(rawValue: row["direction"]) ?? .incoming,
            kind: APRSMessageRecord.Kind(rawValue: row["kind"]) ?? .message,
            localCall: row["localCall"],
            peer: row["peer"],
            text: row["text"],
            number: row["number"],
            radioID: row["radioID"],
            path: {
                let raw: String = row["path"]
                return raw.isEmpty ? [] : raw.split(separator: ",").map(String.init)
            }(),
            viaDirect: row["viaDirect"],
            createdAt: row["createdAt"],
            state: APRSMessageRecord.State(rawValue: row["state"]) ?? .received,
            ackedAt: row["ackedAt"],
            attempts: row["attempts"],
            nextRetryAt: row["nextRetryAt"],
            isRead: row["isRead"])
    }

    func all() throws -> [APRSMessageRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM aprs_messages ORDER BY createdAt, id")
                .map(Self.record(from:))
        }
    }

    func upsert(_ r: APRSMessageRecord) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO aprs_messages
                    (id, direction, kind, localCall, peer, text, number, radioID, path,
                     viaDirect, createdAt, state, ackedAt, attempts, nextRetryAt, isRead)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    r.id, r.direction.rawValue, r.kind.rawValue,
                    r.localCall.uppercased(), r.peer.uppercased(), r.text, r.number,
                    r.radioID, r.path.joined(separator: ","), r.viaDirect, r.createdAt, r.state.rawValue,
                    r.ackedAt, r.attempts, r.nextRetryAt, r.isRead])
        }
    }

    func markRead(id: String, at date: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE aprs_messages SET isRead = 1 WHERE id = ?",
                           arguments: [id])
        }
    }

    func markThreadRead(peer: String, at date: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE aprs_messages SET isRead = 1
                WHERE peer = ? AND direction = 'incoming'
                """, arguments: [peer.uppercased()])
        }
    }

    func outgoing(peer: String, number: String) throws -> APRSMessageRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM aprs_messages
                WHERE direction = 'outgoing' AND peer = ? AND number = ?
                ORDER BY createdAt DESC LIMIT 1
                """, arguments: [peer.uppercased(), number]).map(Self.record(from:))
        }
    }

    func incoming(peer: String, number: String) throws -> APRSMessageRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM aprs_messages
                WHERE direction = 'incoming' AND peer = ? AND number = ?
                ORDER BY createdAt DESC LIMIT 1
                """, arguments: [peer.uppercased(), number]).map(Self.record(from:))
        }
    }

    func duePending(now: Date) throws -> [APRSMessageRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM aprs_messages
                WHERE direction = 'outgoing' AND state = 'sent'
                  AND nextRetryAt IS NOT NULL AND nextRetryAt <= ?
                ORDER BY nextRetryAt
                """, arguments: [now]).map(Self.record(from:))
        }
    }

    func delete(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM aprs_messages WHERE id = ?", arguments: [id])
        }
    }
}
