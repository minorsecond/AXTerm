import Foundation
import GRDB

/// The operator's own knowledge about a station.
nonisolated struct StationNote: Equatable, Sendable {
    var callsign: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A photo or file the operator attached to a station.
///
/// The bytes are deliberately not carried in the list form: a profile shows
/// several attachments and must not read every image to draw their names.
nonisolated struct StationAttachment: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case photo
        case file
    }

    var id: Int64
    var callsign: String
    var kind: Kind
    var name: String
    var addedAt: Date
    var byteCount: Int
}

nonisolated protocol StationNoteStore: Sendable {
    func note(for callsign: String) throws -> StationNote?
    /// Saving an empty body deletes the note rather than storing a blank one.
    func saveNote(callsign: String, body: String, now: Date) throws
    func attachments(for callsign: String) throws -> [StationAttachment]
    /// Returns the stored record so the caller can show it immediately.
    @discardableResult
    func addAttachment(callsign: String, kind: StationAttachment.Kind,
                       name: String, data: Data, now: Date) throws -> StationAttachment
    func attachmentData(id: Int64) throws -> Data?
    func deleteAttachment(id: Int64) throws
    /// Metres above ground, or nil where nobody has recorded it.
    func antennaHeight(for callsign: String) throws -> Double?
    /// Nil clears it back to unknown. Terrain forecasts fall back to the
    /// stated assumption rather than to a stale guess.
    func saveAntennaHeight(callsign: String, metres: Double?, now: Date) throws
    /// Every station with a recorded height, for the terrain pass.
    func antennaHeights() throws -> [String: Double]
}

nonisolated final class SQLiteStationNoteStore: StationNoteStore, @unchecked Sendable {

    /// Refuses anything that would bloat the database beyond what a note is
    /// for. A packet operator's reference photo of an antenna is well under
    /// this; a video is not a note.
    static let maximumAttachmentBytes = 8 * 1024 * 1024

    enum StoreError: Error, Equatable {
        case attachmentTooLarge(Int)
    }

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    private static func key(_ callsign: String) -> String {
        callsign.trimmingCharacters(in: .whitespaces).uppercased()
    }

    func note(for callsign: String) throws -> StationNote? {
        let key = Self.key(callsign)
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM station_notes WHERE callsign = ?",
                arguments: [key]) else { return nil }
            return StationNote(callsign: row["callsign"], body: row["body"],
                               createdAt: row["createdAt"], updatedAt: row["updatedAt"])
        }
    }

    func saveNote(callsign: String, body: String, now: Date = Date()) throws {
        let key = Self.key(callsign)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbQueue.write { db in
            guard !trimmed.isEmpty else {
                // An emptied note is a deletion. Keeping a blank row would
                // make the profile show an empty note section forever — but
                // the row may also carry a recorded antenna height, which the
                // operator did not ask to delete. Blank the text and keep the
                // row when there is anything else in it.
                try db.execute(sql: """
                    DELETE FROM station_notes
                    WHERE callsign = ? AND antennaHeightMetres IS NULL
                    """, arguments: [key])
                try db.execute(sql: """
                    UPDATE station_notes SET body = '', updatedAt = ?
                    WHERE callsign = ?
                    """, arguments: [now, key])
                return
            }
            try db.execute(sql: """
                INSERT INTO station_notes (callsign, body, createdAt, updatedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(callsign) DO UPDATE SET body = excluded.body,
                                                    updatedAt = excluded.updatedAt
                """, arguments: [key, trimmed, now, now])
        }
    }

    func antennaHeight(for callsign: String) throws -> Double? {
        let key = Self.key(callsign)
        return try dbQueue.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT antennaHeightMetres FROM station_notes WHERE callsign = ?",
                arguments: [key])
        }
    }

    func antennaHeights() throws -> [String: Double] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT callsign, antennaHeightMetres FROM station_notes
                WHERE antennaHeightMetres IS NOT NULL
                """)
            return Dictionary(rows.compactMap { row -> (String, Double)? in
                guard let metres: Double = row["antennaHeightMetres"] else { return nil }
                return (row["callsign"], metres)
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    func saveAntennaHeight(callsign: String, metres: Double?, now: Date = Date()) throws {
        let key = Self.key(callsign)
        try dbQueue.write { db in
            guard let metres, metres > 0 else {
                // Clearing the height must not delete a note that shares the
                // row. Blank both and the row goes on the next note save.
                try db.execute(sql: """
                    UPDATE station_notes SET antennaHeightMetres = NULL, updatedAt = ?
                    WHERE callsign = ?
                    """, arguments: [now, key])
                return
            }
            try db.execute(sql: """
                INSERT INTO station_notes (callsign, body, createdAt, updatedAt,
                                           antennaHeightMetres)
                VALUES (?, '', ?, ?, ?)
                ON CONFLICT(callsign) DO UPDATE SET
                    antennaHeightMetres = excluded.antennaHeightMetres,
                    updatedAt = excluded.updatedAt
                """, arguments: [key, now, now, metres])
        }
    }

    func attachments(for callsign: String) throws -> [StationAttachment] {
        let key = Self.key(callsign)
        return try dbQueue.read { db in
            // Newest first, and deliberately without `data` — the list draws
            // names and sizes, not images.
            try Row.fetchAll(db, sql: """
                SELECT id, callsign, kind, name, addedAt, byteCount
                FROM station_attachments WHERE callsign = ?
                ORDER BY addedAt DESC
                """, arguments: [key]).map { row in
                StationAttachment(
                    id: row["id"], callsign: row["callsign"],
                    kind: StationAttachment.Kind(rawValue: row["kind"]) ?? .file,
                    name: row["name"], addedAt: row["addedAt"],
                    byteCount: row["byteCount"])
            }
        }
    }

    @discardableResult
    func addAttachment(callsign: String, kind: StationAttachment.Kind,
                       name: String, data: Data, now: Date = Date()) throws -> StationAttachment {
        guard data.count <= Self.maximumAttachmentBytes else {
            throw StoreError.attachmentTooLarge(data.count)
        }
        let key = Self.key(callsign)
        let id = try dbQueue.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO station_attachments
                (callsign, kind, name, addedAt, byteCount, data)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [key, kind.rawValue, name, now, data.count, data])
            return db.lastInsertedRowID
        }
        return StationAttachment(id: id, callsign: key, kind: kind, name: name,
                                 addedAt: now, byteCount: data.count)
    }

    func attachmentData(id: Int64) throws -> Data? {
        try dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM station_attachments WHERE id = ?",
                              arguments: [id])
        }
    }

    func deleteAttachment(id: Int64) throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM station_attachments WHERE id = ?", arguments: [id])
        }
    }
}
