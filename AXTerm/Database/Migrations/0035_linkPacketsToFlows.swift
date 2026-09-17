//
//  0035_linkPacketsToFlows.swift
//  AXTerm
//

import Foundation
import GRDB

extension DatabaseManager {

    /// Ties a logged frame to the exchange it belonged to.
    ///
    /// `packets` records frames and nothing else, so a connected exchange
    /// reads as unrelated rows: `terminal_sessions` keeps only totals, and
    /// `outbound_message` knows our half. Neither can show a conversation in
    /// order, with the retries visible as the separate frames they are.
    ///
    /// Both columns are nullable and always will be. Most traffic belongs to
    /// no session and no message: a beacon, a NET/ROM broadcast, a frame
    /// from a station we are not talking to. A row with both null is the
    /// normal case, not a gap.
    static func linkPacketsToFlows(_ db: Database) throws {
        try db.alter(table: "packets") { table in
            /// The `terminal_sessions` row this frame belonged to.
            table.add(column: "sessionId", .text)
            /// The `outbound_message` this frame was part of delivering.
            /// One message costs many frames, and every retry is its own
            /// row here, which is what makes the cost visible.
            table.add(column: "messageId", .text)
        }

        // Reading a flow means "this session, in time order", so the index
        // carries the sort with it.
        try db.create(index: "idx_packets_session", on: "packets",
                      columns: ["sessionId", "receivedAt"])
        try db.create(index: "idx_packets_message", on: "packets",
                      columns: ["messageId"])
    }

    /// Lets a queued message exist outside a connected session.
    ///
    /// `sessionId` was NOT NULL, which confined the queue to AX.25 sessions.
    /// Unconnected AXDP transfers have app-level acknowledgement and retries
    /// with no session underneath (transmission spec 6.4), so they need the
    /// queue's semantics and have no session to name.
    ///
    /// SQLite cannot drop a NOT NULL, so the table is rebuilt. It carries no
    /// rows anywhere yet, but the copy is written as though it does: a
    /// migration that quietly discards data because it happened to be empty
    /// on the machine it was written on is a trap for the next database.
    static func allowSessionlessOutboundMessages(_ db: Database) throws {
        try db.create(table: "outbound_message_new") { table in
            table.column("id", .text).primaryKey()
            table.column("sessionId", .text)
            table.column("destCallsign", .text).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("payload", .blob).notNull()
            table.column("mode", .text).notNull()
            table.column("state", .text).notNull()
            table.column("attemptCount", .integer).notNull()
            table.column("lastError", .text)
            table.column("bytesTotal", .integer).notNull()
            table.column("bytesAcked", .integer).notNull()
            table.column("sentAt", .datetime)
            table.column("ackedAt", .datetime)
        }
        try db.execute(sql: """
            INSERT INTO outbound_message_new
            SELECT id, sessionId, destCallsign, createdAt, payload, mode, state,
                   attemptCount, lastError, bytesTotal, bytesAcked, sentAt, ackedAt
            FROM outbound_message
            """)
        try db.drop(table: "outbound_message")
        try db.rename(table: "outbound_message_new", to: "outbound_message")

        try db.create(index: "idx_outbound_session_created", on: "outbound_message",
                      columns: ["sessionId", "createdAt"])
        try db.create(index: "idx_outbound_state_session", on: "outbound_message",
                      columns: ["state", "sessionId"])
    }
}
