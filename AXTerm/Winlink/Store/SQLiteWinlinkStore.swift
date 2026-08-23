import Foundation
import GRDB

/// GRDB-backed WinlinkStore. All multi-row operations run inside one
/// write transaction (CLAUDE.md §12: batched DB writes).
nonisolated final class SQLiteWinlinkStore: WinlinkStore, @unchecked Sendable {

    private let dbQueue: DatabaseQueue
    private let now: @Sendable () -> Date

    init(dbQueue: DatabaseQueue, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbQueue = dbQueue
        self.now = now
    }

    // MARK: - Folders

    func folders() throws -> [WinlinkFolderRecord] {
        try dbQueue.read { db in
            try WinlinkFolderRecord
                .order(Column("sortOrder"), Column("name"))
                .fetchAll(db)
        }
    }

    func folderID(for role: WinlinkFolderRecord.SystemRole) throws -> Int64 {
        try dbQueue.read { db in
            try Self.folderID(for: role, db: db)
        }
    }

    private static func folderID(for role: WinlinkFolderRecord.SystemRole, db: Database) throws -> Int64 {
        guard let folder = try WinlinkFolderRecord
            .filter(Column("systemRole") == role.rawValue)
            .fetchOne(db),
            let id = folder.id
        else { throw WinlinkStoreError.missingSystemFolder(role.rawValue) }
        return id
    }

    @discardableResult
    func createFolder(name: String) throws -> WinlinkFolderRecord {
        try dbQueue.write { db in
            let maxOrder = try Int.fetchOne(
                db, sql: "SELECT MAX(sortOrder) FROM \(WinlinkFolderRecord.databaseTableName)") ?? 0
            var folder = WinlinkFolderRecord(id: nil, name: name, systemRole: nil, sortOrder: maxOrder + 1)
            try folder.insert(db)
            return folder
        }
    }

    func renameFolder(id: Int64, name: String) throws {
        try dbQueue.write { db in
            guard var folder = try WinlinkFolderRecord.fetchOne(db, key: id) else {
                throw WinlinkStoreError.folderNotFound(id)
            }
            guard folder.systemRole == nil else { throw WinlinkStoreError.cannotModifySystemFolder }
            folder.name = name
            try folder.update(db)
        }
    }

    func deleteFolder(id: Int64) throws {
        try dbQueue.write { [now] db in
            guard let folder = try WinlinkFolderRecord.fetchOne(db, key: id) else {
                throw WinlinkStoreError.folderNotFound(id)
            }
            guard folder.systemRole == nil else { throw WinlinkStoreError.cannotModifySystemFolder }

            // Messages survive folder deletion by moving to Archive.
            let archiveID = try Self.folderID(for: .archive, db: db)
            try db.execute(
                sql: """
                    UPDATE \(WinlinkMessageStateRecord.databaseTableName)
                    SET folderId = ?, updatedAt = ?
                    WHERE folderId = ?
                    """,
                arguments: [archiveID, now(), id])
            try folder.delete(db)
        }
    }

    // MARK: - Compose / drafts

    func saveDraft(_ message: WinlinkB2Message) throws {
        try dbQueue.write { [now] db in
            let draftsID = try Self.folderID(for: .drafts, db: db)
            try Self.insertMessageRows(
                message, direction: .outbound, folderId: draftsID,
                deliveryState: .draft, isRead: true, timestamp: now(), db: db)
        }
    }

    func updateDraft(_ message: WinlinkB2Message) throws {
        try dbQueue.write { [now] db in
            guard let state = try WinlinkMessageStateRecord.fetchOne(db, key: message.mid) else {
                throw WinlinkStoreError.messageNotFound(message.mid)
            }
            guard state.state == .draft else { throw WinlinkStoreError.notADraft(message.mid) }

            try WinlinkAttachmentRecord
                .filter(Column("messageId") == message.mid)
                .deleteAll(db)
            try WinlinkMessageRecord.deleteOne(db, key: message.mid)
            try Self.insertMessageRows(
                message, direction: .outbound, folderId: state.folderId,
                deliveryState: .draft, isRead: true, timestamp: now(), db: db)
        }
    }

    func queueDraft(mid: String) throws {
        try dbQueue.write { [now] db in
            guard var state = try WinlinkMessageStateRecord.fetchOne(db, key: mid) else {
                throw WinlinkStoreError.messageNotFound(mid)
            }
            guard state.state == .draft else { throw WinlinkStoreError.notADraft(mid) }
            state.deliveryState = WinlinkMessageStateRecord.DeliveryState.queued.rawValue
            state.folderId = try Self.folderID(for: .outbox, db: db)
            state.updatedAt = now()
            try state.update(db)
        }
    }

    // MARK: - Exchange lifecycle

    func queuedOutboundMessages() throws -> [WinlinkB2Message] {
        try dbQueue.read { db in
            let states = try WinlinkMessageStateRecord
                .filter(Column("deliveryState") == WinlinkMessageStateRecord.DeliveryState.queued.rawValue)
                .order(Column("updatedAt"))
                .fetchAll(db)
            return try states.compactMap { state in
                try Self.loadB2Message(mid: state.messageId, db: db)
            }
        }
    }

    func markSending(mid: String) throws {
        try setDeliveryState(mid: mid, to: .sending, folder: nil, error: nil)
    }

    func markSent(mid: String) throws {
        try setDeliveryState(mid: mid, to: .sent, folder: .sent, error: nil)
    }

    func markFailed(mid: String, error: String) throws {
        try setDeliveryState(mid: mid, to: .failed, folder: nil, error: error)
    }

    func markDeferred(mid: String) throws {
        try setDeliveryState(mid: mid, to: .queued, folder: nil, error: nil)
    }

    func revertSendingToQueued() throws {
        try dbQueue.write { [now] db in
            try db.execute(
                sql: """
                    UPDATE \(WinlinkMessageStateRecord.databaseTableName)
                    SET deliveryState = ?, updatedAt = ?
                    WHERE deliveryState = ?
                    """,
                arguments: [
                    WinlinkMessageStateRecord.DeliveryState.queued.rawValue,
                    now(),
                    WinlinkMessageStateRecord.DeliveryState.sending.rawValue,
                ])
        }
    }

    func recordSentOffset(mid: String, offset: Int) throws {
        try dbQueue.write { [now] db in
            guard var state = try WinlinkMessageStateRecord.fetchOne(db, key: mid) else {
                throw WinlinkStoreError.messageNotFound(mid)
            }
            state.sentOffset = offset
            state.updatedAt = now()
            try state.update(db)
        }
    }

    @discardableResult
    func saveInbound(_ message: WinlinkB2Message) throws -> Bool {
        try dbQueue.write { [now] db in
            if try WinlinkMessageRecord.exists(db, key: message.mid) {
                return false
            }
            let inboxID = try Self.folderID(for: .inbox, db: db)
            try Self.insertMessageRows(
                message, direction: .inbound, folderId: inboxID,
                deliveryState: .received, isRead: false, timestamp: now(), db: db)
            return true
        }
    }

    // MARK: - Mailbox reading

    func messages(inFolder folderId: Int64) throws -> [WinlinkMessageSummary] {
        try dbQueue.read { db in
            let states = try WinlinkMessageStateRecord
                .filter(Column("folderId") == folderId)
                .order(Column("updatedAt").desc)
                .fetchAll(db)

            return try states.compactMap { state -> WinlinkMessageSummary? in
                guard let record = try WinlinkMessageRecord.fetchOne(db, key: state.messageId) else {
                    return nil
                }
                let attachmentCount = try WinlinkAttachmentRecord
                    .filter(Column("messageId") == state.messageId)
                    .fetchCount(db)
                return WinlinkMessageSummary(
                    mid: record.id,
                    direction: WinlinkMessageRecord.Direction(rawValue: record.direction) ?? .inbound,
                    date: record.dateUtc,
                    fromAddr: record.fromAddr,
                    toAddrs: record.toAddressList,
                    subject: record.subject,
                    bodySize: record.body.count,
                    attachmentCount: attachmentCount,
                    isRead: state.isRead,
                    deliveryState: state.state ?? .received,
                    folderId: state.folderId,
                    lastError: state.lastError)
            }
        }
    }

    func message(mid: String) throws -> WinlinkStoredMessage? {
        try dbQueue.read { db in
            guard let record = try WinlinkMessageRecord.fetchOne(db, key: mid),
                  let state = try WinlinkMessageStateRecord.fetchOne(db, key: mid),
                  let message = try Self.loadB2Message(mid: mid, db: db)
            else { return nil }
            return WinlinkStoredMessage(
                message: message,
                direction: WinlinkMessageRecord.Direction(rawValue: record.direction) ?? .inbound,
                state: state)
        }
    }

    func setRead(mid: String, _ read: Bool) throws {
        try dbQueue.write { [now] db in
            guard var state = try WinlinkMessageStateRecord.fetchOne(db, key: mid) else {
                throw WinlinkStoreError.messageNotFound(mid)
            }
            state.isRead = read
            state.updatedAt = now()
            try state.update(db)
        }
    }

    func move(mid: String, toFolder folderId: Int64) throws {
        try dbQueue.write { [now] db in
            guard try WinlinkFolderRecord.exists(db, key: folderId) else {
                throw WinlinkStoreError.folderNotFound(folderId)
            }
            guard var state = try WinlinkMessageStateRecord.fetchOne(db, key: mid) else {
                throw WinlinkStoreError.messageNotFound(mid)
            }
            state.folderId = folderId
            state.updatedAt = now()
            try state.update(db)
        }
    }

    func moveToTrash(mid: String) throws {
        let trashID = try folderID(for: .trash)
        try move(mid: mid, toFolder: trashID)
    }

    func unreadInboxCount() throws -> Int {
        try dbQueue.read { db in
            let inboxID = try Self.folderID(for: .inbox, db: db)
            return try WinlinkMessageStateRecord
                .filter(Column("folderId") == inboxID && Column("isRead") == false)
                .fetchCount(db)
        }
    }

    // MARK: - Caches

    func replaceStationCache(_ stations: [WinlinkRMSStationRecord]) throws {
        try dbQueue.write { db in
            try WinlinkRMSStationRecord.deleteAll(db)
            for station in stations {
                try station.insert(db)
            }
        }
    }

    func stations() throws -> [WinlinkRMSStationRecord] {
        try dbQueue.read { db in
            try WinlinkRMSStationRecord
                .order(Column("distanceMiles"), Column("callsign"))
                .fetchAll(db)
        }
    }

    func replaceCatalogCache(_ items: [WinlinkCatalogItemRecord]) throws {
        try dbQueue.write { db in
            try WinlinkCatalogItemRecord.deleteAll(db)
            for item in items {
                try item.insert(db)
            }
        }
    }

    func catalogItems() throws -> [WinlinkCatalogItemRecord] {
        try dbQueue.read { db in
            try WinlinkCatalogItemRecord
                .order(Column("category"), Column("subject"))
                .fetchAll(db)
        }
    }

    // MARK: - Session log

    func appendSessionLog(_ log: WinlinkSessionLogRecord) throws {
        try dbQueue.write { db in
            var record = log
            try record.insert(db)
        }
    }

    func sessionLogs(limit: Int) throws -> [WinlinkSessionLogRecord] {
        try dbQueue.read { db in
            try WinlinkSessionLogRecord
                .order(Column("startedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Shared helpers

    private func setDeliveryState(
        mid: String,
        to newState: WinlinkMessageStateRecord.DeliveryState,
        folder: WinlinkFolderRecord.SystemRole?,
        error: String?
    ) throws {
        try dbQueue.write { [now] db in
            guard var state = try WinlinkMessageStateRecord.fetchOne(db, key: mid) else {
                throw WinlinkStoreError.messageNotFound(mid)
            }
            state.deliveryState = newState.rawValue
            state.lastError = error
            if let folder {
                state.folderId = try Self.folderID(for: folder, db: db)
            }
            state.updatedAt = now()
            try state.update(db)
        }
    }

    private static func insertMessageRows(
        _ message: WinlinkB2Message,
        direction: WinlinkMessageRecord.Direction,
        folderId: Int64,
        deliveryState: WinlinkMessageStateRecord.DeliveryState,
        isRead: Bool,
        timestamp: Date,
        db: Database
    ) throws {
        let record = WinlinkMessageRecord(
            id: message.mid,
            direction: direction.rawValue,
            dateUtc: message.date,
            messageType: message.type.rawValue,
            fromAddr: message.from,
            toAddrs: WinlinkMessageRecord.encodeAddresses(message.to),
            ccAddrs: WinlinkMessageRecord.encodeAddresses(message.cc),
            subject: message.subject,
            mbo: message.mbo,
            body: message.body,
            createdAt: timestamp)
        try record.insert(db)

        for (index, attachment) in message.attachments.enumerated() {
            var row = WinlinkAttachmentRecord(
                id: nil,
                messageId: message.mid,
                position: index,
                name: attachment.name,
                size: attachment.data.count,
                data: attachment.data)
            try row.insert(db)
        }

        let state = WinlinkMessageStateRecord(
            messageId: message.mid,
            folderId: folderId,
            isRead: isRead,
            deliveryState: deliveryState.rawValue,
            sentOffset: 0,
            lastError: nil,
            updatedAt: timestamp)
        try state.insert(db)
    }

    private static func loadB2Message(mid: String, db: Database) throws -> WinlinkB2Message? {
        guard let record = try WinlinkMessageRecord.fetchOne(db, key: mid) else { return nil }
        let attachmentRows = try WinlinkAttachmentRecord
            .filter(Column("messageId") == mid)
            .order(Column("position"))
            .fetchAll(db)

        return WinlinkB2Message(
            mid: record.id,
            date: record.dateUtc,
            type: WinlinkB2Message.MessageType(rawValue: record.messageType) ?? .privateMessage,
            from: record.fromAddr,
            to: record.toAddressList,
            cc: record.ccAddressList,
            subject: record.subject,
            mbo: record.mbo,
            body: record.body,
            attachments: attachmentRows.map { .init(name: $0.name, data: $0.data) })
    }
}
