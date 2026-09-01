import Foundation
import GRDB

/// Sessions that survive a relaunch.
nonisolated protocol TerminalSessionStoring: Sendable {
    func save(_ session: TerminalSession) throws
    func sessions(limit: Int) throws -> [TerminalSession]
    func sessions(withRemote callsign: String) throws -> [TerminalSession]
    func delete(id: UUID) throws
    /// Everything for one station: the operator's "forget what happened with
    /// this node" without touching anyone else's history.
    @discardableResult
    func deleteAll(forRemote callsign: String) throws -> Int
    func setTags(_ tags: [String], for id: UUID) throws
    func setNote(_ note: String?, for id: UUID) throws
    /// Every tag in use, with how many sessions carry it.
    func tagCounts() throws -> [String: Int]
}

nonisolated final class SQLiteTerminalSessionStore: TerminalSessionStoring, @unchecked Sendable {

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Upsert, because a session is written when it opens and again as it
    /// runs. Only the fields that can change are updated: the callsign, path
    /// and start time are what the row *is*.
    func save(_ session: TerminalSession) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO terminal_sessions
                    (id, remote, remoteBase, via, relayDestination, transport,
                     startedAt, endedAt, outcome, framesSent, framesReceived,
                     bytesSent, bytesReceived, transcript, note)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    endedAt = excluded.endedAt,
                    outcome = excluded.outcome,
                    framesSent = excluded.framesSent,
                    framesReceived = excluded.framesReceived,
                    bytesSent = excluded.bytesSent,
                    bytesReceived = excluded.bytesReceived,
                    transcript = excluded.transcript,
                    note = excluded.note
                """, arguments: [
                    session.id.uuidString, session.remote,
                    Self.base(of: session.remote),
                    session.via.joined(separator: ","),
                    session.relayDestination, session.transport,
                    session.startedAt, session.endedAt,
                    session.outcome.rawValue,
                    session.framesSent, session.framesReceived,
                    session.bytesSent, session.bytesReceived,
                    session.transcript, session.note])
            try Self.writeTags(session.tags, for: session.id, in: db)
        }
    }

    func sessions(limit: Int = 500) throws -> [TerminalSession] {
        try dbQueue.read { db in
            try Self.hydrate(Row.fetchAll(db, sql: """
                SELECT * FROM terminal_sessions ORDER BY startedAt DESC LIMIT ?
                """, arguments: [limit]), in: db)
        }
    }

    /// Every session with this station, matched on the base callsign.
    ///
    /// Deliberately looser than the exact address: KB5YZB-1 and KB5YZB-7 are
    /// one operator's mailbox and node, and someone asking "what have I done
    /// with KB5YZB" means both.
    func sessions(withRemote callsign: String) throws -> [TerminalSession] {
        let base = Self.base(of: callsign)
        return try dbQueue.read { db in
            try Self.hydrate(Row.fetchAll(db, sql: """
                SELECT * FROM terminal_sessions
                WHERE remoteBase = ? ORDER BY startedAt DESC
                """, arguments: [base]), in: db)
        }
    }

    func delete(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM terminal_sessions WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    @discardableResult
    func deleteAll(forRemote callsign: String) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM terminal_sessions WHERE remoteBase = ?",
                           arguments: [Self.base(of: callsign)])
            return db.changesCount
        }
    }

    func setTags(_ tags: [String], for id: UUID) throws {
        try dbQueue.write { db in
            try Self.writeTags(TerminalSession.normalized(tags), for: id, in: db)
        }
    }

    func setNote(_ note: String?, for id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET note = ? WHERE id = ?",
                           arguments: [note, id.uuidString])
        }
    }

    func tagCounts() throws -> [String: Int] {
        try dbQueue.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT tag, COUNT(*) AS uses FROM terminal_session_tags GROUP BY tag
                """) {
                guard let tag = row["tag"] as String?,
                      let uses = row["uses"] as Int? else { continue }
                counts[tag] = uses
            }
            return counts
        }
    }

    // MARK: - Plumbing

    private static func writeTags(_ tags: [String], for id: UUID,
                                  in db: Database) throws {
        try db.execute(sql: "DELETE FROM terminal_session_tags WHERE sessionId = ?",
                       arguments: [id.uuidString])
        for tag in tags {
            try db.execute(sql: """
                INSERT OR IGNORE INTO terminal_session_tags (sessionId, tag) VALUES (?, ?)
                """, arguments: [id.uuidString, tag])
        }
    }

    /// One tag query for the whole page rather than one per session.
    private static func hydrate(_ rows: [Row], in db: Database) throws -> [TerminalSession] {
        let ids = rows.compactMap { $0["id"] as String? }
        var tagsBySession: [String: [String]] = [:]
        if !ids.isEmpty {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            for row in try Row.fetchAll(db, sql: """
                SELECT sessionId, tag FROM terminal_session_tags
                WHERE sessionId IN (\(placeholders)) ORDER BY tag
                """, arguments: StatementArguments(ids)) {
                guard let session = row["sessionId"] as String?,
                      let tag = row["tag"] as String? else { continue }
                tagsBySession[session, default: []].append(tag)
            }
        }
        return rows.compactMap { row in
            guard let raw = row["id"] as String?, let id = UUID(uuidString: raw),
                  let remote = row["remote"] as String?,
                  let startedAt = row["startedAt"] as Date? else { return nil }
            return TerminalSession(
                id: id, remote: remote,
                via: (row["via"] as String? ?? "").split(separator: ",").map(String.init),
                relayDestination: row["relayDestination"] as String?,
                transport: row["transport"] as String? ?? "AX.25",
                startedAt: startedAt, endedAt: row["endedAt"] as Date?,
                outcome: TerminalSession.Outcome(rawValue: row["outcome"] as String? ?? "")
                    ?? .closed,
                framesSent: row["framesSent"] as Int? ?? 0,
                framesReceived: row["framesReceived"] as Int? ?? 0,
                bytesSent: row["bytesSent"] as Int? ?? 0,
                bytesReceived: row["bytesReceived"] as Int? ?? 0,
                transcript: row["transcript"] as String? ?? "",
                tags: tagsBySession[raw] ?? [],
                note: row["note"] as String?)
        }
    }

    /// Callsign without SSID, uppercased.
    static func base(of address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces).uppercased()
        return String(trimmed.split(separator: "-").first ?? "")
    }
}
