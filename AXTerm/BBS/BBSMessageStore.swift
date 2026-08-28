//
//  BBSMessageStore.swift
//  AXTerm
//
//  Persistence for the personal mailbox: messages, and a log of who called.
//

import Foundation
import GRDB

/// One caller's visit, whether or not they did anything.
///
/// The log exists because the operator is asleep for most of what the mailbox
/// does. "Somebody called at 03:12, read the net bulletin and left" is the
/// question a sysop actually has, and no amount of message list answers it —
/// a caller who reads and leaves nothing behind is otherwise invisible.
nonisolated struct BBSCall: Equatable, Sendable, Identifiable {
    var id: Int64
    var callsign: String
    var connectedAt: Date
    var disconnectedAt: Date?
    /// What they did, in the order they did it: "read 7", "left mail for K0EPI".
    var actions: [String]
    /// Set when the link dropped rather than the caller saying B.
    var endedUnexpectedly: Bool

    var duration: TimeInterval? {
        disconnectedAt.map { $0.timeIntervalSince(connectedAt) }
    }
    var isLive: Bool { disconnectedAt == nil }
}

nonisolated protocol BBSMessageStore: Sendable {
    /// Every message, killed ones included — the app's own UI shows them so a
    /// mistaken `K` can be undone.
    func allMessages() throws -> [BBSMessage]

    /// The snapshot the shell reasons over.
    func mailbox() throws -> BBSShell.Mailbox

    /// Stores at the id the shell already told the caller. Throws if that id
    /// is taken, which would mean two callers were served at once.
    func store(_ message: BBSMessage) throws

    func kill(id: Int64, at date: Date) throws
    /// Sysop-only, from the app's UI: mail is append-only, so a kill is a flag
    /// and clearing the flag brings the message back.
    func restore(id: Int64) throws
    func markRead(id: Int64, at date: Date) throws
    /// Removes a message for good. Only the sysop can reach this, and only
    /// deliberately.
    func purge(id: Int64) throws

    /// The whole directory, keyed by base callsign.
    func whitePages() throws -> [String: WhitePagesEntry]

    /// Records one learned field under `WhitePagesEntry.replaces` — stronger
    /// provenance wins, and inference never overwrites testimony. Returns
    /// whether anything changed.
    @discardableResult
    func learnWhitePages(callsign: String,
                         key: WhitePagesEntry.Key,
                         value: String,
                         source: WhitePagesEntry.Source,
                         at date: Date) throws -> Bool

    /// Sysop edit from the app. Recorded as self-reported: the operator is a
    /// person stating a fact, same as a caller typing it at the prompt.
    func setWhitePagesField(callsign: String,
                            key: WhitePagesEntry.Key,
                            value: String,
                            at date: Date) throws

    func deleteWhitePages(callsign: String) throws

    /// Folders the operator shares, with their security-scoped bookmarks.
    func fileAreas() throws -> [BBSFileArea]
    func saveFileArea(_ area: BBSFileArea) throws
    func deleteFileArea(name: String) throws

    /// Per-file descriptions, keyed `AREA/name`. Kept in the database rather
    /// than beside the files: the shared folder belongs to the operator and
    /// nothing here should write into it.
    func fileDescriptions() throws -> [String: String]
    func setFileDescription(area: String, name: String, about: String) throws

    /// When this callsign last called, ignoring the call in progress. Drives
    /// `FN`, which is the listing a regular caller actually wants.
    func lastVisit(callsign: String, excluding callId: Int64) throws -> Date?

    /// Where uploads land. A bookmark, not a path: the app is sandboxed.
    func uploadInbox() throws -> Data?
    func setUploadInbox(_ bookmark: Data?) throws

    @discardableResult
    func beginCall(callsign: String, at date: Date) throws -> Int64
    func appendAction(callId: Int64, action: String) throws
    func endCall(id: Int64, at date: Date, unexpected: Bool) throws
    func recentCalls(limit: Int) throws -> [BBSCall]
    /// Clears any call left open by a crash or a power cut, so the UI does not
    /// show a caller who has not been connected since last Tuesday.
    func closeOrphanedCalls(at date: Date) throws
}

nonisolated final class SQLiteBBSMessageStore: BBSMessageStore, @unchecked Sendable {

    enum StoreError: Error, Equatable {
        case messageNumberTaken(Int64)
    }

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Messages

    private static func message(from row: Row) -> BBSMessage {
        BBSMessage(
            id: row["id"],
            from: row["fromCall"],
            to: row["toCall"],
            subject: row["subject"],
            body: row["body"],
            receivedAt: row["receivedAt"],
            readAt: row["readAt"],
            killedAt: row["killedAt"])
    }

    func allMessages() throws -> [BBSMessage] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM bbs_messages ORDER BY id")
                .map(Self.message(from:))
        }
    }

    func mailbox() throws -> BBSShell.Mailbox {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM bbs_messages ORDER BY id")
            let highest = try Int64.fetchOne(
                db, sql: "SELECT MAX(id) FROM bbs_messages") ?? 0
            return BBSShell.Mailbox(messages: rows.map(Self.message(from:)),
                                    nextID: highest + 1)
        }
    }

    func store(_ message: BBSMessage) throws {
        try dbQueue.write { db in
            let taken = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM bbs_messages WHERE id = ?)",
                arguments: [message.id]) ?? false
            // The shell promised this number to the caller before the write.
            // If it is gone, two callers were served at once and the listener's
            // `.busy` rule failed — worth an error rather than a silent renumber
            // that leaves the caller quoting a number nobody else can see.
            guard !taken else { throw StoreError.messageNumberTaken(message.id) }
            try db.execute(sql: """
                INSERT INTO bbs_messages
                    (id, fromCall, toCall, subject, body, receivedAt, readAt, killedAt)
                VALUES (?, ?, ?, ?, ?, ?, NULL, NULL)
                """, arguments: [message.id, message.from.uppercased(),
                                 message.to.uppercased(), message.subject,
                                 message.body, message.receivedAt])
        }
    }

    func kill(id: Int64, at date: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE bbs_messages SET killedAt = ? WHERE id = ?",
                arguments: [date, id])
        }
    }

    func restore(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE bbs_messages SET killedAt = NULL WHERE id = ?",
                arguments: [id])
        }
    }

    func markRead(id: Int64, at date: Date) throws {
        try dbQueue.write { db in
            // Never re-stamp: the first read is the fact worth keeping.
            try db.execute(sql: """
                UPDATE bbs_messages SET readAt = ? WHERE id = ? AND readAt IS NULL
                """, arguments: [date, id])
        }
    }

    func purge(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM bbs_messages WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - White pages

    func whitePages() throws -> [String: WhitePagesEntry] {
        try dbQueue.read { db in
            var directory: [String: WhitePagesEntry] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM bbs_white_pages") {
                let callsign: String = row["callsign"]
                guard let key = WhitePagesEntry.Key(rawValue: row["field"]),
                      let source = WhitePagesEntry.Source(rawValue: row["source"])
                else { continue }
                var entry = directory[callsign] ?? WhitePagesEntry(callsign: callsign)
                entry.fields[key] = WhitePagesEntry.Field(
                    value: row["value"], source: source, updatedAt: row["updatedAt"])
                directory[callsign] = entry
            }
            return directory
        }
    }

    @discardableResult
    func learnWhitePages(callsign: String,
                         key: WhitePagesEntry.Key,
                         value: String,
                         source: WhitePagesEntry.Source,
                         at date: Date) throws -> Bool {
        let call = BBSMessage.baseCall(callsign)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !call.isEmpty, !trimmed.isEmpty else { return false }

        return try dbQueue.write { db in
            // Read-decide-write inside one transaction: the merge rule compares
            // against what is stored, and a concurrent write between the read
            // and the write would let a weaker source land.
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT value, source, updatedAt FROM bbs_white_pages"
                   + " WHERE callsign = ? AND field = ?",
                arguments: [call, key.rawValue]
            ).flatMap { row -> WhitePagesEntry.Field? in
                guard let source = WhitePagesEntry.Source(rawValue: row["source"])
                else { return nil }
                return WhitePagesEntry.Field(
                    value: row["value"], source: source, updatedAt: row["updatedAt"])
            }

            let candidate = WhitePagesEntry.Field(
                value: trimmed, source: source, updatedAt: date)
            guard WhitePagesEntry.replaces(candidate, existing: existing) else { return false }

            try db.execute(
                sql: "INSERT INTO bbs_white_pages (callsign, field, value, source, updatedAt)"
                   + " VALUES (?, ?, ?, ?, ?)"
                   + " ON CONFLICT(callsign, field) DO UPDATE SET"
                   + " value = excluded.value, source = excluded.source,"
                   + " updatedAt = excluded.updatedAt",
                arguments: [call, key.rawValue, trimmed, source.rawValue, date])
            return true
        }
    }

    func setWhitePagesField(callsign: String,
                            key: WhitePagesEntry.Key,
                            value: String,
                            at date: Date) throws {
        let call = BBSMessage.baseCall(callsign)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbQueue.write { db in
            guard !trimmed.isEmpty else {
                try db.execute(
                    sql: "DELETE FROM bbs_white_pages WHERE callsign = ? AND field = ?",
                    arguments: [call, key.rawValue])
                return
            }
            // Unconditional: the operator editing their own directory is not
            // subject to the merge rule, which exists to stop *inference*
            // overwriting testimony.
            try db.execute(
                sql: "INSERT INTO bbs_white_pages (callsign, field, value, source, updatedAt)"
                   + " VALUES (?, ?, ?, ?, ?)"
                   + " ON CONFLICT(callsign, field) DO UPDATE SET"
                   + " value = excluded.value, source = excluded.source,"
                   + " updatedAt = excluded.updatedAt",
                arguments: [call, key.rawValue, trimmed,
                            WhitePagesEntry.Source.selfReported.rawValue, date])
        }
    }

    func deleteWhitePages(callsign: String) throws {
        let call = BBSMessage.baseCall(callsign)
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM bbs_white_pages WHERE callsign = ?",
                           arguments: [call])
        }
    }

    // MARK: - File areas

    func fileAreas() throws -> [BBSFileArea] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM bbs_file_areas ORDER BY name")
                .map { row in
                    BBSFileArea(name: row["name"], about: row["about"],
                                bookmark: row["bookmark"])
                }
        }
    }

    func saveFileArea(_ area: BBSFileArea) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO bbs_file_areas (name, about, bookmark) VALUES (?, ?, ?)"
                   + " ON CONFLICT(name) DO UPDATE SET about = excluded.about,"
                   + " bookmark = excluded.bookmark",
                arguments: [area.name, area.about, area.bookmark])
        }
    }

    func deleteFileArea(name: String) throws {
        let key = BBSFileArea.normalize(name)
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM bbs_file_areas WHERE name = ?", arguments: [key])
            // Descriptions belong to the area; leaving them would resurrect
            // stale text if the operator later shares a folder of the same name.
            try db.execute(sql: "DELETE FROM bbs_file_descriptions WHERE area = ?",
                           arguments: [key])
        }
    }

    func fileDescriptions() throws -> [String: String] {
        try dbQueue.read { db in
            var result: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM bbs_file_descriptions") {
                let area: String = row["area"]
                let name: String = row["name"]
                result["\(area)/\(name)"] = row["about"]
            }
            return result
        }
    }

    func setFileDescription(area: String, name: String, about: String) throws {
        let key = BBSFileArea.normalize(area)
        let trimmed = about.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbQueue.write { db in
            guard !trimmed.isEmpty else {
                try db.execute(
                    sql: "DELETE FROM bbs_file_descriptions WHERE area = ? AND name = ?",
                    arguments: [key, name])
                return
            }
            try db.execute(
                sql: "INSERT INTO bbs_file_descriptions (area, name, about) VALUES (?, ?, ?)"
                   + " ON CONFLICT(area, name) DO UPDATE SET about = excluded.about",
                arguments: [key, name, trimmed])
        }
    }

    func lastVisit(callsign: String, excluding callId: Int64) throws -> Date? {
        let key = callsign.uppercased()
        return try dbQueue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT MAX(connectedAt) FROM bbs_calls"
                   + " WHERE callsign = ? AND id <> ?",
                arguments: [key, callId])
        }
    }

    func uploadInbox() throws -> Data? {
        try dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT bookmark FROM bbs_upload_inbox WHERE id = 1")
        }
    }

    func setUploadInbox(_ bookmark: Data?) throws {
        try dbQueue.write { db in
            guard let bookmark else {
                try db.execute(sql: "DELETE FROM bbs_upload_inbox WHERE id = 1")
                return
            }
            try db.execute(
                sql: "INSERT INTO bbs_upload_inbox (id, bookmark) VALUES (1, ?)"
                   + " ON CONFLICT(id) DO UPDATE SET bookmark = excluded.bookmark",
                arguments: [bookmark])
        }
    }

    // MARK: - Calls

    @discardableResult
    func beginCall(callsign: String, at date: Date) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO bbs_calls (callsign, connectedAt, actions, endedUnexpectedly)
                VALUES (?, ?, '', 0)
                """, arguments: [callsign.uppercased(), date])
            return db.lastInsertedRowID
        }
    }

    func appendAction(callId: Int64, action: String) throws {
        try dbQueue.write { db in
            // Newline-joined rather than a child table: the log is a sentence
            // the operator reads, never a thing anything queries into.
            try db.execute(sql: """
                UPDATE bbs_calls
                SET actions = CASE WHEN actions = '' THEN ? ELSE actions || char(10) || ? END
                WHERE id = ?
                """, arguments: [action, action, callId])
        }
    }

    func endCall(id: Int64, at date: Date, unexpected: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE bbs_calls SET disconnectedAt = ?, endedUnexpectedly = ?
                WHERE id = ? AND disconnectedAt IS NULL
                """, arguments: [date, unexpected, id])
        }
    }

    func recentCalls(limit: Int) throws -> [BBSCall] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM bbs_calls ORDER BY connectedAt DESC LIMIT ?
                """, arguments: [limit]).map { row in
                let joined: String = row["actions"]
                return BBSCall(
                    id: row["id"],
                    callsign: row["callsign"],
                    connectedAt: row["connectedAt"],
                    disconnectedAt: row["disconnectedAt"],
                    actions: joined.isEmpty ? [] : joined.components(separatedBy: "\n"),
                    endedUnexpectedly: row["endedUnexpectedly"])
            }
        }
    }

    func closeOrphanedCalls(at date: Date) throws {
        try dbQueue.write { db in
            // A call still open at launch ended when the app did, whenever that
            // was. Stamping it "now" would invent a caller who stayed for three
            // days, so the connect time is used and the row is flagged.
            try db.execute(sql: """
                UPDATE bbs_calls
                SET disconnectedAt = connectedAt, endedUnexpectedly = 1
                WHERE disconnectedAt IS NULL
                """)
        }
    }
}
