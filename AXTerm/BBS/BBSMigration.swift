//
//  BBSMigration.swift
//  AXTerm
//
//  Schema for the personal mailbox (migration v18).
//

import Foundation
import GRDB

extension DatabaseManager {

    nonisolated static func createBBSTables(_ db: Database) throws {
        try db.create(table: "bbs_messages") { t in
            // Not auto-incremented: the shell tells the caller the number
            // before the row exists ("Message 12 stored."), so the id is
            // chosen above this layer and asserted here.
            t.primaryKey("id", .integer)
            t.column("fromCall", .text).notNull()
            t.column("toCall", .text).notNull()
            t.column("subject", .text).notNull()
            t.column("body", .text).notNull()
            t.column("receivedAt", .datetime).notNull()
            t.column("readAt", .datetime)
            /// Mail is append-only (CLAUDE.md §7): `K` sets this, and the row
            /// survives so the sysop can undo a mistaken kill.
            t.column("killedAt", .datetime)
        }
        try db.create(index: "idx_bbsMessages_toCall",
                      on: "bbs_messages", columns: ["toCall"])
        try db.create(index: "idx_bbsMessages_receivedAt",
                      on: "bbs_messages", columns: ["receivedAt"])

        try db.create(table: "bbs_calls") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("callsign", .text).notNull()
            t.column("connectedAt", .datetime).notNull()
            t.column("disconnectedAt", .datetime)
            t.column("actions", .text).notNull().defaults(to: "")
            t.column("endedUnexpectedly", .boolean).notNull().defaults(to: false)
        }
        try db.create(index: "idx_bbsCalls_connectedAt",
                      on: "bbs_calls", columns: ["connectedAt"])
    }

    /// White Pages (migration v19).
    ///
    /// One row per (callsign, field) rather than a column per field: every
    /// value carries its own provenance and timestamp, and adding a field
    /// later is a new row rather than a migration.
    nonisolated static func createBBSWhitePages(_ db: Database) throws {
        try db.create(table: "bbs_white_pages") { t in
            t.column("callsign", .text).notNull()
            t.column("field", .text).notNull()
            t.column("value", .text).notNull()
            /// `selfReported` / `fromMessage` / `observed` — see
            /// `WhitePagesEntry.Source`. Testimony must be distinguishable
            /// from inference or the directory degrades every time it is used.
            t.column("source", .text).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.primaryKey(["callsign", "field"])
        }
    }

    /// File areas (migration v20).
    nonisolated static func createBBSFileAreas(_ db: Database) throws {
        try db.create(table: "bbs_file_areas") { t in
            t.primaryKey("name", .text)
            t.column("about", .text).notNull().defaults(to: "")
            /// Security-scoped bookmark. The app is sandboxed, so a path alone
            /// stops resolving at the next launch and the area would quietly
            /// serve nothing.
            t.column("bookmark", .blob)
        }

        try db.create(table: "bbs_file_descriptions") { t in
            t.column("area", .text).notNull()
            t.column("name", .text).notNull()
            t.column("about", .text).notNull()
            t.primaryKey(["area", "name"])
        }
    }

    /// Where uploads land (migration v21).
    ///
    /// One row. Deliberately not a `bbs_file_areas` entry: the inbox must
    /// never be servable, and keeping it in a different table means it cannot
    /// be listed by accident.
    nonisolated static func createBBSUploadInbox(_ db: Database) throws {
        try db.create(table: "bbs_upload_inbox") { t in
            t.column("id", .integer).primaryKey().check { $0 == 1 }
            t.column("bookmark", .blob).notNull()
        }
    }

    /// Withdraws the address/phone/email fields (migration v22).
    ///
    /// Those three were briefly collectable and should not have been: packet
    /// is unencrypted broadcast, and a mailbox that offers to store a home
    /// address is inviting people to put one on the air. The reader already
    /// skips fields it does not recognise, so this changes nothing anyone can
    /// see — but leaving the rows would mean the data outlived the decision to
    /// stop holding it, which is the whole problem in miniature.
    nonisolated static func dropBBSPersonalContactFields(_ db: Database) throws {
        try db.execute(
            sql: "DELETE FROM bbs_white_pages WHERE field IN (?, ?, ?)",
            arguments: ["address", "phone", "email"])
    }
}
