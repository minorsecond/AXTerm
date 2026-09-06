import Foundation
import GRDB

/// Other devices' mailboxes, kept apart from this one.
///
/// Every device runs its own mailbox: its own message numbers (promises made
/// to callers — "Message 12 stored." — that no other mailbox may reuse), its
/// own callers log, its own append-only history. What another mailbox holds
/// is worth reading from any device, so it travels, *attributed*: filed in
/// its own tables under the device that runs it, never merged into this
/// mailbox's numbering or its log. Same shape as `TerminalSessionReplication`.

// MARK: - Payloads

/// One message from a mailbox, as it crosses the wire and as it is kept.
nonisolated struct BBSMessagePayload: Codable, Equatable, Sendable, Identifiable {
    /// The number the originating mailbox gave it. Unique only within that
    /// mailbox; `provenance.deviceID` makes it unique here.
    var id: Int64
    var from: String
    var to: String
    var subject: String
    var body: String
    var receivedAt: Date
    var readAt: Date?
    var killedAt: Date?
    /// The callsign the originating mailbox answers as.
    var mailbox: String
    var provenance: WinlinkSyncProvenance
    var deviceName: String?

    init(message: BBSMessage, mailbox: String, provenance: WinlinkSyncProvenance, deviceName: String?) {
        id = message.id
        from = message.from
        to = message.to
        subject = message.subject
        body = message.body
        receivedAt = message.receivedAt
        readAt = message.readAt
        killedAt = message.killedAt
        self.mailbox = mailbox
        self.provenance = provenance
        self.deviceName = deviceName
    }

    /// The message as the mailbox screens render it.
    var message: BBSMessage {
        BBSMessage(id: id, from: from, to: to, subject: subject, body: body,
                   receivedAt: receivedAt, readAt: readAt, killedAt: killedAt)
    }

    /// When the record last changed: a read or a kill on the home device
    /// moves this, so the push ledger sends the new state rather than
    /// treating the message as already delivered.
    var modifiedAt: Date {
        [receivedAt, readAt ?? .distantPast, killedAt ?? .distantPast].max() ?? receivedAt
    }
}

/// One finished call to a mailbox.
nonisolated struct BBSCallPayload: Codable, Equatable, Sendable, Identifiable {
    var id: Int64
    var callsign: String
    var connectedAt: Date
    /// Never nil: only finished calls are published.
    var disconnectedAt: Date
    var actions: [String]
    var endedUnexpectedly: Bool
    var mailbox: String
    var provenance: WinlinkSyncProvenance
    var deviceName: String?

    init(call: BBSCall, mailbox: String, provenance: WinlinkSyncProvenance, deviceName: String?) {
        id = call.id
        callsign = call.callsign
        connectedAt = call.connectedAt
        disconnectedAt = call.disconnectedAt ?? call.connectedAt
        actions = call.actions
        endedUnexpectedly = call.endedUnexpectedly
        self.mailbox = mailbox
        self.provenance = provenance
        self.deviceName = deviceName
    }

    var call: BBSCall {
        BBSCall(id: id, callsign: callsign, connectedAt: connectedAt,
                disconnectedAt: disconnectedAt, actions: actions,
                endedUnexpectedly: endedUnexpectedly)
    }
}

// MARK: - Store

/// Read this mailbox for publication; write and read other mailboxes'.
/// No way to write into this mailbox and no way to read both together.
nonisolated protocol BBSMailboxReplicationStore: Sendable {
    func localMessagesForPublication() throws -> [BBSMessage]
    /// Finished calls that ended at or after `endedSince`.
    func localCallsForPublication(endedSince: Date) throws -> [BBSCall]
    func saveRemoteMessages(_ payloads: [BBSMessagePayload]) throws
    func saveRemoteCalls(_ payloads: [BBSCallPayload]) throws
    /// Other mailboxes' messages, newest first.
    func remoteMessages(limit: Int) throws -> [BBSMessagePayload]
    /// Other mailboxes' finished calls, newest first.
    func remoteCalls(limit: Int) throws -> [BBSCallPayload]
}

nonisolated final class SQLiteBBSMailboxReplicationStore: BBSMailboxReplicationStore, @unchecked Sendable {

    private let dbQueue: DatabaseQueue
    /// Local reads go through the mailbox's own store so the row mapping is
    /// written once; that store has no remote methods, so the line cannot be
    /// crossed the other way through this handle.
    private let local: SQLiteBBSMessageStore

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        self.local = SQLiteBBSMessageStore(dbQueue: dbQueue)
    }

    func localMessagesForPublication() throws -> [BBSMessage] {
        try local.allMessages()
    }

    func localCallsForPublication(endedSince: Date) throws -> [BBSCall] {
        try local.recentCalls(limit: 500).filter { call in
            guard let ended = call.disconnectedAt else { return false }
            return ended >= endedSince
        }
    }

    func saveRemoteMessages(_ payloads: [BBSMessagePayload]) throws {
        guard !payloads.isEmpty else { return }
        try dbQueue.write { db in
            for p in payloads {
                try db.execute(sql: """
                    INSERT INTO remote_bbs_messages
                        (deviceID, messageId, mailbox, station, gridSquare, observedAt, deviceName,
                         fromCall, toCall, subject, body, receivedAt, readAt, killedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceID, messageId) DO UPDATE SET
                        mailbox = excluded.mailbox, station = excluded.station,
                        gridSquare = excluded.gridSquare, observedAt = excluded.observedAt,
                        deviceName = excluded.deviceName, fromCall = excluded.fromCall,
                        toCall = excluded.toCall, subject = excluded.subject, body = excluded.body,
                        receivedAt = excluded.receivedAt, readAt = excluded.readAt,
                        killedAt = excluded.killedAt
                    """, arguments: [
                        p.provenance.deviceID, p.id, p.mailbox, p.provenance.station,
                        p.provenance.gridSquare, p.provenance.observedAt, p.deviceName,
                        p.from, p.to, p.subject, p.body, p.receivedAt, p.readAt, p.killedAt,
                    ])
            }
        }
    }

    func saveRemoteCalls(_ payloads: [BBSCallPayload]) throws {
        guard !payloads.isEmpty else { return }
        try dbQueue.write { db in
            for p in payloads {
                let actions = String(decoding: try JSONEncoder().encode(p.actions), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO remote_bbs_calls
                        (deviceID, callId, mailbox, station, gridSquare, observedAt, deviceName,
                         callsign, connectedAt, disconnectedAt, actions, endedUnexpectedly)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceID, callId) DO UPDATE SET
                        mailbox = excluded.mailbox, station = excluded.station,
                        gridSquare = excluded.gridSquare, observedAt = excluded.observedAt,
                        deviceName = excluded.deviceName, callsign = excluded.callsign,
                        connectedAt = excluded.connectedAt, disconnectedAt = excluded.disconnectedAt,
                        actions = excluded.actions, endedUnexpectedly = excluded.endedUnexpectedly
                    """, arguments: [
                        p.provenance.deviceID, p.id, p.mailbox, p.provenance.station,
                        p.provenance.gridSquare, p.provenance.observedAt, p.deviceName,
                        p.callsign, p.connectedAt, p.disconnectedAt, actions, p.endedUnexpectedly,
                    ])
            }
        }
    }

    func remoteMessages(limit: Int) throws -> [BBSMessagePayload] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM remote_bbs_messages ORDER BY receivedAt DESC LIMIT ?",
                             arguments: [limit]).map { row in
                BBSMessagePayload(
                    message: BBSMessage(id: row["messageId"], from: row["fromCall"], to: row["toCall"],
                                        subject: row["subject"], body: row["body"],
                                        receivedAt: row["receivedAt"], readAt: row["readAt"],
                                        killedAt: row["killedAt"]),
                    mailbox: row["mailbox"],
                    provenance: WinlinkSyncProvenance(station: row["station"], deviceID: row["deviceID"],
                                                      gridSquare: row["gridSquare"], observedAt: row["observedAt"]),
                    deviceName: row["deviceName"])
            }
        }
    }

    func remoteCalls(limit: Int) throws -> [BBSCallPayload] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM remote_bbs_calls ORDER BY disconnectedAt DESC LIMIT ?",
                             arguments: [limit]).map { row in
                let actionsText: String = row["actions"]
                let actions = (try? JSONDecoder().decode([String].self, from: Data(actionsText.utf8))) ?? []
                return BBSCallPayload(
                    call: BBSCall(id: row["callId"], callsign: row["callsign"],
                                  connectedAt: row["connectedAt"], disconnectedAt: row["disconnectedAt"],
                                  actions: actions, endedUnexpectedly: row["endedUnexpectedly"]),
                    mailbox: row["mailbox"],
                    provenance: WinlinkSyncProvenance(station: row["station"], deviceID: row["deviceID"],
                                                      gridSquare: row["gridSquare"], observedAt: row["observedAt"]),
                    deviceName: row["deviceName"])
            }
        }
    }

    /// Removes everything one device's mailbox published — the operator
    /// retired a radio, not the mail it took.
    func forgetRemoteMailbox(fromDevice deviceID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM remote_bbs_messages WHERE deviceID = ?", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM remote_bbs_calls WHERE deviceID = ?", arguments: [deviceID])
        }
    }
}

// MARK: - Schema

extension DatabaseManager {
    /// Other devices' mailboxes. Separate tables from `bbs_messages` and
    /// `bbs_calls`, keyed by device and the originating mailbox's own number,
    /// so two mailboxes that both stored "Message 12" are two rows and the
    /// local mailbox's numbering is never disturbed.
    static func createRemoteBBSMailbox(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS remote_bbs_messages (
                deviceID TEXT NOT NULL,
                messageId INTEGER NOT NULL,
                mailbox TEXT NOT NULL,
                station TEXT NOT NULL,
                gridSquare TEXT,
                observedAt DATETIME NOT NULL,
                deviceName TEXT,
                fromCall TEXT NOT NULL,
                toCall TEXT NOT NULL,
                subject TEXT NOT NULL,
                body TEXT NOT NULL,
                receivedAt DATETIME NOT NULL,
                readAt DATETIME,
                killedAt DATETIME,
                PRIMARY KEY (deviceID, messageId)
            )
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_remote_bbs_messages_received
                ON remote_bbs_messages(receivedAt)
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS remote_bbs_calls (
                deviceID TEXT NOT NULL,
                callId INTEGER NOT NULL,
                mailbox TEXT NOT NULL,
                station TEXT NOT NULL,
                gridSquare TEXT,
                observedAt DATETIME NOT NULL,
                deviceName TEXT,
                callsign TEXT NOT NULL,
                connectedAt DATETIME NOT NULL,
                disconnectedAt DATETIME NOT NULL,
                actions TEXT NOT NULL DEFAULT '[]',
                endedUnexpectedly INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (deviceID, callId)
            )
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_remote_bbs_calls_ended
                ON remote_bbs_calls(disconnectedAt)
            """)
    }
}
