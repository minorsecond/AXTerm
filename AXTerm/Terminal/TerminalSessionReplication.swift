import Foundation
import GRDB

/// Terminal history from the operator's other devices.
///
/// A transcript is what was said over the air — not a measurement of the
/// air, which is why it may travel where a Winlink session log may not
/// (`WinlinkSyncPolicy.disposition(for: .sessionLog)`). But it was recorded
/// by a different radio in a different place, so it arrives *attributed* and
/// is kept in its own table, reachable only through this type. The local
/// history store cannot see these rows, and this type cannot write local
/// ones: separation is a fact about the code, not a rule anyone remembers.
///
/// See Docs/UnifiedMailbox.md §2 for the policy and `StationActivityStore`
/// for the pattern this follows.

// MARK: - Payload

/// One finished session as it crosses the wire and as it is kept once it
/// has arrived. Codable, unlike `TerminalSession`, and carrying who sent it.
nonisolated struct TerminalSessionPayload: Codable, Equatable, Sendable, Identifiable {

    /// The most transcript that travels. CloudKit caps a record at 1 MB and
    /// the transport moves anything over 700 KB as an asset; JSON escaping
    /// can inflate a transcript full of control characters severalfold, so
    /// the ceiling sits well under both. A cut transcript says so
    /// (`transcriptTruncated`) rather than passing for a whole one.
    static let transcriptByteLimit = 200 * 1024

    var id: UUID
    var remote: String
    var via: [String]
    var relayDestination: String?
    var transport: String
    var startedAt: Date
    /// Never nil: only finished sessions are published.
    var endedAt: Date
    var outcome: TerminalSession.Outcome
    var framesSent: Int
    var framesReceived: Int
    var bytesSent: Int
    var bytesReceived: Int
    var transcript: String
    var transcriptTruncated: Bool
    /// Which station, which installation, where, and when it was recorded.
    var provenance: WinlinkSyncProvenance
    /// The name a person would recognise — "Ross's Mac", "iPad". Optional
    /// because not every platform will say; the installation ID in the
    /// provenance still identifies the device when it does not.
    var deviceName: String?

    /// Wraps a finished local session for publication.
    ///
    /// Tags and the note are left behind on purpose: they are how the
    /// operator annotates history on *one* device, and an annotation made on
    /// the Mac editing itself onto the iPad's copy would be two devices
    /// arguing over one sentence. A live session is published as ended at
    /// its start time only if forced; callers should not pass one.
    init(session: TerminalSession, provenance: WinlinkSyncProvenance, deviceName: String?) {
        id = session.id
        remote = session.remote
        via = session.via
        // Empty is nil: a blank relay destination would make the row read
        // "via KB5YZB-7" with no correspondent at all.
        relayDestination = session.relayDestination.flatMap { $0.isEmpty ? nil : $0 }
        transport = session.transport
        startedAt = session.startedAt
        endedAt = session.endedAt ?? session.startedAt
        outcome = session.outcome == .live ? .lost : session.outcome
        framesSent = session.framesSent
        framesReceived = session.framesReceived
        bytesSent = session.bytesSent
        bytesReceived = session.bytesReceived
        let cut = Self.truncated(session.transcript)
        transcript = cut.text
        transcriptTruncated = cut.wasCut
        self.provenance = provenance
        self.deviceName = deviceName
    }

    /// The session as the History screen renders it, so remote rows use the
    /// same row view as local ones. No tags and no note: those never
    /// travelled (see `init`).
    var session: TerminalSession {
        TerminalSession(id: id, remote: remote, via: via,
                        relayDestination: relayDestination, transport: transport,
                        startedAt: startedAt, endedAt: endedAt, outcome: outcome,
                        framesSent: framesSent, framesReceived: framesReceived,
                        bytesSent: bytesSent, bytesReceived: bytesReceived,
                        transcript: transcript, tags: [], note: nil)
    }

    /// Cuts on a line boundary where one exists inside the limit, so the
    /// last thing shown is a whole line rather than half of one.
    static func truncated(_ transcript: String) -> (text: String, wasCut: Bool) {
        guard transcript.utf8.count > transcriptByteLimit else { return (transcript, false) }
        let bytes = transcript.utf8
        let cutIndex = bytes.index(bytes.startIndex, offsetBy: transcriptByteLimit)
        // Back up to a character boundary, then to the last newline if
        // there is one in the kept part.
        var end = cutIndex
        while end > transcript.startIndex, !transcript.indices.contains(end) {
            end = bytes.index(before: end)
        }
        let kept = String(transcript[..<end])
        if let newline = kept.lastIndex(of: "\n"), newline > kept.startIndex {
            return (String(kept[..<newline]), true)
        }
        return (kept, true)
    }
}

/// `Outcome` is a string-backed enum; the payload needs it on the wire.
extension TerminalSession.Outcome: Codable {}

// MARK: - Store

/// Read this device's finished sessions for publication; write and read
/// other devices'. Deliberately no way to write a local session and no way
/// to read local and remote together.
nonisolated protocol TerminalSessionReplicationStore: Sendable {
    /// This device's sessions that have ended at or after `endedSince`.
    /// Never a live one — a session still open is rewritten when it closes.
    func localSessionsForPublication(endedSince: Date) throws -> [TerminalSession]
    /// Stores sessions that arrived from other devices, replacing any
    /// earlier copy of the same session from the same device.
    func saveRemoteSessions(_ payloads: [TerminalSessionPayload]) throws
    /// Other devices' sessions, newest first.
    func remoteSessions(limit: Int) throws -> [TerminalSessionPayload]
}

/// The SQLite implementation: `terminal_sessions` for the local read,
/// `remote_terminal_sessions` for everything else.
nonisolated final class SQLiteTerminalSessionReplicationStore: TerminalSessionReplicationStore,
                                                                @unchecked Sendable {

    private let dbQueue: DatabaseQueue
    /// Reuses the local store's row mapping rather than duplicating it; the
    /// local store has no remote methods, so this handle cannot be used to
    /// cross the line in the other direction.
    private let local: SQLiteTerminalSessionStore

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        self.local = SQLiteTerminalSessionStore(dbQueue: dbQueue)
    }

    func localSessionsForPublication(endedSince: Date) throws -> [TerminalSession] {
        try local.sessions(limit: 500).filter { session in
            guard session.outcome != .live, let endedAt = session.endedAt else { return false }
            return endedAt >= endedSince
        }
    }

    func saveRemoteSessions(_ payloads: [TerminalSessionPayload]) throws {
        guard !payloads.isEmpty else { return }
        try dbQueue.write { db in
            for payload in payloads {
                try db.execute(sql: """
                    INSERT INTO remote_terminal_sessions
                        (deviceID, sessionId, station, gridSquare, observedAt, deviceName,
                         remote, via, relayDestination, transport, startedAt, endedAt, outcome,
                         framesSent, framesReceived, bytesSent, bytesReceived,
                         transcript, transcriptTruncated)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceID, sessionId) DO UPDATE SET
                        station = excluded.station,
                        gridSquare = excluded.gridSquare,
                        observedAt = excluded.observedAt,
                        deviceName = excluded.deviceName,
                        remote = excluded.remote,
                        via = excluded.via,
                        relayDestination = excluded.relayDestination,
                        transport = excluded.transport,
                        startedAt = excluded.startedAt,
                        endedAt = excluded.endedAt,
                        outcome = excluded.outcome,
                        framesSent = excluded.framesSent,
                        framesReceived = excluded.framesReceived,
                        bytesSent = excluded.bytesSent,
                        bytesReceived = excluded.bytesReceived,
                        transcript = excluded.transcript,
                        transcriptTruncated = excluded.transcriptTruncated
                    """, arguments: [
                        payload.provenance.deviceID, payload.id.uuidString,
                        payload.provenance.station, payload.provenance.gridSquare,
                        payload.provenance.observedAt, payload.deviceName,
                        payload.remote, payload.via.joined(separator: ","),
                        payload.relayDestination, payload.transport,
                        payload.startedAt, payload.endedAt, payload.outcome.rawValue,
                        payload.framesSent, payload.framesReceived,
                        payload.bytesSent, payload.bytesReceived,
                        payload.transcript, payload.transcriptTruncated,
                    ])
            }
        }
    }

    func remoteSessions(limit: Int) throws -> [TerminalSessionPayload] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM remote_terminal_sessions
                ORDER BY endedAt DESC LIMIT ?
                """, arguments: [limit]).compactMap(Self.payload(from:))
        }
    }

    /// Removes everything one device published — the operator retired a
    /// radio, not the history it saw. Returns how many rows went.
    @discardableResult
    func forgetRemoteSessions(fromDevice deviceID: String) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM remote_terminal_sessions WHERE deviceID = ?",
                           arguments: [deviceID])
            return db.changesCount
        }
    }

    private static func payload(from row: Row) -> TerminalSessionPayload? {
        guard let id = UUID(uuidString: row["sessionId"]),
              let outcome = TerminalSession.Outcome(rawValue: row["outcome"]) else { return nil }
        let via: String = row["via"]
        let relay: String? = row["relayDestination"]
        let session = TerminalSession(
            id: id, remote: row["remote"],
            via: via.isEmpty ? [] : via.split(separator: ",").map(String.init),
            relayDestination: (relay?.isEmpty ?? true) ? nil : relay, transport: row["transport"],
            startedAt: row["startedAt"], endedAt: row["endedAt"], outcome: outcome,
            framesSent: row["framesSent"], framesReceived: row["framesReceived"],
            bytesSent: row["bytesSent"], bytesReceived: row["bytesReceived"],
            transcript: row["transcript"])
        var payload = TerminalSessionPayload(
            session: session,
            provenance: WinlinkSyncProvenance(
                station: row["station"], deviceID: row["deviceID"],
                gridSquare: row["gridSquare"], observedAt: row["observedAt"]),
            deviceName: row["deviceName"])
        // The stored flag is the truth about the *original* cut; the row's
        // transcript is already short enough that re-wrapping would not cut.
        payload.transcriptTruncated = row["transcriptTruncated"]
        return payload
    }
}
