import Foundation
import GRDB

extension DatabaseManager {

    /// The APRS message store (migration v32). One row per message-class
    /// exchange — incoming/outgoing text, bulletins, queries — with the
    /// outgoing delivery state and retry cursor kept inline, mirroring the
    /// BBS mailbox's flat shape.
    nonisolated static func createAPRSMessages(_ db: Database) throws {
        try db.create(table: "aprs_messages") { t in
            t.primaryKey("id", .text)
            t.column("direction", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("localCall", .text).notNull()
            t.column("peer", .text).notNull()
            t.column("text", .text).notNull()
            t.column("number", .text)
            t.column("radioID", .text)
            t.column("path", .text).notNull().defaults(to: "")
            t.column("viaDirect", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .datetime).notNull()
            t.column("state", .text).notNull()
            t.column("ackedAt", .datetime)
            t.column("attempts", .integer).notNull().defaults(to: 0)
            t.column("nextRetryAt", .datetime)
            t.column("isRead", .boolean).notNull().defaults(to: false)
        }
        // Threads are read by peer, newest first.
        try db.create(index: "idx_aprsMessages_peer",
                      on: "aprs_messages", columns: ["peer", "createdAt"])
        // The retry sweep scans for outgoing messages whose ack is overdue.
        try db.create(index: "idx_aprsMessages_retry",
                      on: "aprs_messages", columns: ["state", "nextRetryAt"])
    }

    /// Add the `path` column if an earlier build created the table without it
    /// (migration v33). Idempotent: a no-op on a fresh install where v32
    /// already made the column, and the fix on a database that ran a v32
    /// predating it. A migration body must never change once applied, so the
    /// column is added here rather than by editing v32.
    nonisolated static func addPathToAPRSMessages(_ db: Database) throws {
        let columns = try db.columns(in: "aprs_messages").map(\.name)
        guard !columns.contains("path") else { return }
        try db.alter(table: "aprs_messages") { t in
            t.add(column: "path", .text).notNull().defaults(to: "")
        }
    }
}
