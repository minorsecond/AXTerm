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

    // MARK: - B2F resume (partial inbound bodies)

    /// Kept partials expire after this long — a gateway rarely re-proposes
    /// the same MID much later, and stale blobs should not accumulate.
    private static let partialBodyLifetime: TimeInterval = 14 * 24 * 3600

    func savePartialBody(mid: String, compressedSize: Int, data: Data) throws {
        try dbQueue.write { [now] db in
            let stamp = now()
            try WinlinkPartialBodyRecord(
                mid: mid, compressedSize: compressedSize, data: data, updatedAt: stamp)
                .save(db)
            try WinlinkPartialBodyRecord
                .filter(Column("updatedAt") < stamp.addingTimeInterval(-Self.partialBodyLifetime))
                .deleteAll(db)
        }
    }

    func partialBodies() throws -> [WinlinkPartialBodyRecord] {
        try dbQueue.read { [now] db in
            try WinlinkPartialBodyRecord
                .filter(Column("updatedAt") >= now().addingTimeInterval(-Self.partialBodyLifetime))
                .fetchAll(db)
        }
    }

    func deletePartialBody(mid: String) throws {
        _ = try dbQueue.write { db in
            try WinlinkPartialBodyRecord.deleteOne(db, key: mid)
        }
    }

    @discardableResult
    func saveInbound(_ message: WinlinkB2Message) throws -> Bool {
        try dbQueue.write { [now] db in
            if try WinlinkMessageRecord.exists(db, key: message.mid) {
                return false
            }
            // Downloading a message again is a deliberate act — the operator
            // chose it in the download picker — so it outranks having
            // deleted it earlier. Dropping the tombstone is what makes that
            // stick: leaving it would let the next sync round delete the
            // message the operator just spent airtime on.
            try WinlinkMessageTombstoneRecord.deleteOne(db, key: message.mid)
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
            // Deliberately unordered here: the state row's `updatedAt`
            // is bumped by marking a message read, so ordering by it
            // made a message jump to the top of the list the moment it
            // was clicked. The list is sorted below by the date the
            // column actually shows.
            let states = try WinlinkMessageStateRecord
                .filter(Column("folderId") == folderId)
                .fetchAll(db)

            let summaries = try states.compactMap { state -> WinlinkMessageSummary? in
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
                    lastError: state.lastError,
                    trashedAt: state.trashedAt)
            }
            // Newest first by the message's own timestamp — the value the
            // Date column shows. MID breaks ties so two reads of the same
            // folder never disagree about order.
            return summaries.sorted { ($0.date, $0.mid) > ($1.date, $1.mid) }
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

    func inboundMessages(fromAddr: String, limit: Int) throws -> [WinlinkStoredMessage] {
        try dbQueue.read { db in
            let records = try WinlinkMessageRecord
                .filter(Column("direction") == WinlinkMessageRecord.Direction.inbound.rawValue)
                .filter(sql: "UPPER(fromAddr) = ?", arguments: [fromAddr.uppercased()])
                .order(Column("dateUtc").desc)
                .limit(limit)
                .fetchAll(db)
            return try records.compactMap { record -> WinlinkStoredMessage? in
                guard let state = try WinlinkMessageStateRecord.fetchOne(db, key: record.id),
                      let message = try Self.loadB2Message(mid: record.id, db: db)
                else { return nil }
                return WinlinkStoredMessage(
                    message: message,
                    direction: WinlinkMessageRecord.Direction(rawValue: record.direction) ?? .inbound,
                    state: state)
            }
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
            let trashId = try Self.folderID(for: .trash, db: db)
            if folderId == trashId {
                // Only on the way *in*. Moving between folders inside the
                // Trash is not possible, but re-trashing something already
                // there must not overwrite when it went or where it came
                // from with "the Trash".
                if state.folderId != trashId {
                    state.trashedAt = now()
                    state.trashedFromFolderId = state.folderId
                }
            } else {
                // Out of the Trash: it has not been deleted, and a stale
                // origin would send a later Put Back somewhere wrong.
                state.trashedAt = nil
                state.trashedFromFolderId = nil
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

    /// Where a trashed message came from, for Put Back and for undo.
    /// Nil when it is not in the Trash, or predates the origin being
    /// recorded.
    func trashOrigin(mid: String) throws -> Int64? {
        try dbQueue.read { db in
            try WinlinkMessageStateRecord.fetchOne(db, key: mid)?.trashedFromFolderId
        }
    }

    // MARK: - Permanent deletion

    @discardableResult
    func deleteMessages(mids: [String]) throws -> [String] {
        guard !mids.isEmpty else { return [] }
        return try dbQueue.write { [now] db in
            try Self.delete(mids: mids, at: now(), db: db)
        }
    }

    @discardableResult
    func emptyTrash() throws -> Int {
        try dbQueue.write { [now] db in
            let trashID = try Self.folderID(for: .trash, db: db)
            let mids = try WinlinkMessageStateRecord
                .filter(Column("folderId") == trashID)
                .fetchAll(db)
                .map(\.messageId)
            return try Self.delete(mids: mids, at: now(), db: db).count
        }
    }

    func messageTombstones() throws -> [WinlinkMessageTombstoneRecord] {
        try dbQueue.read { db in
            try WinlinkMessageTombstoneRecord.fetchAll(db)
        }
    }

    /// Removes the message rows and leaves a tombstone behind.
    ///
    /// The state row and the attachments go with the message: both cascade
    /// from `winlinkMessage`, which is also why the tombstone cannot simply
    /// be a flag on the state row — deleting the message would take the flag
    /// with it.
    ///
    /// A partial body is dropped too. It is a half-received copy of a
    /// message the operator has just destroyed; resuming it later would
    /// spend airtime rebuilding exactly what they threw away.
    private static func delete(mids: [String], at timestamp: Date, db: Database) throws -> [String] {
        var removed = [String]()
        for mid in mids {
            guard try WinlinkMessageRecord.exists(db, key: mid) else { continue }
            try WinlinkMessageRecord.deleteOne(db, key: mid)
            try WinlinkPartialBodyRecord.deleteOne(db, key: mid)
            removed.append(mid)
        }
        // Tombstone every requested MID, not just the rows that were here.
        // A device asked to delete something it never had still has to
        // remember the decision, or the next sync brings it in.
        for mid in mids {
            try WinlinkMessageTombstoneRecord(messageId: mid, deletedAt: timestamp)
                .insert(db, onConflict: .replace)
        }
        return removed
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

    /// Replaces one scope's rows, leaving the other alone.
    ///
    /// The old version deleted every row, so refreshing at home with a
    /// 100-mile radius destroyed a wide list downloaded for a trip — the one
    /// thing that list exists to survive. The primary key is
    /// callsign+frequency, so a gateway that is both near home and inside a
    /// downloaded region can only hold one row; local wins, because it
    /// carries a distance measured from where the operator actually is.
    func replaceStationCache(_ stations: [WinlinkRMSStationRecord],
                             scope: WinlinkRMSStationRecord.Scope = .local) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM \(WinlinkRMSStationRecord.databaseTableName) WHERE scope = ?",
                arguments: [scope.rawValue])
            for station in stations {
                var row = station
                row.scope = scope
                if scope == .global {
                    // Never overwrite a local row with a global one.
                    let exists = try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM \(WinlinkRMSStationRecord.databaseTableName) WHERE callsign = ? AND frequencyHz = ? AND scope = 'local')",
                        arguments: [row.callsign, row.frequencyHz]) ?? false
                    if exists { continue }
                }
                try row.insert(db)
            }
        }
    }

    /// Every cached gateway, both scopes.
    func stations() throws -> [WinlinkRMSStationRecord] {
        try dbQueue.read { db in
            try WinlinkRMSStationRecord
                .order(Column("distanceMiles"), Column("callsign"))
                .fetchAll(db)
        }
    }

    func stations(scope: WinlinkRMSStationRecord.Scope) throws -> [WinlinkRMSStationRecord] {
        try dbQueue.read { db in
            try WinlinkRMSStationRecord
                .filter(Column("scope") == scope.rawValue)
                .order(Column("distanceMiles"), Column("callsign"))
                .fetchAll(db)
        }
    }

    /// Which grid fields the downloaded set covers, and how many gateways in
    /// each — what answers "have I actually got Wyoming?".
    func downloadedGridFields() throws -> [(field: String, count: Int)] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT SUBSTR(UPPER(gridSquare), 1, 2) AS field, COUNT(*) AS count FROM \(WinlinkRMSStationRecord.databaseTableName) WHERE scope = 'global' GROUP BY field ORDER BY count DESC"
            ).map { (field: $0["field"], count: $0["count"]) }
        }
    }

    /// Drops the downloaded set, leaving the local one intact.
    func clearDownloadedStations() throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM \(WinlinkRMSStationRecord.databaseTableName) WHERE scope = 'global'")
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

    func catalogFavorites() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try WinlinkCatalogFavoriteRecord.fetchAll(db).map(\.inquiryId))
        }
    }

    func setCatalogFavorite(inquiryId: String, isFavorite: Bool) throws {
        try dbQueue.write { db in
            if isFavorite {
                // Re-starring an existing favourite must not move its
                // date; `save` would overwrite `addedAt`.
                try WinlinkCatalogFavoriteRecord(inquiryId: inquiryId, addedAt: Date())
                    .insert(db, onConflict: .ignore)
            } else {
                _ = try WinlinkCatalogFavoriteRecord.deleteOne(db, key: inquiryId)
            }
        }
    }

    func callsignRecord(callsign: String) throws -> CallsignDirectoryRecord? {
        let key = CallsignQuery.normalize(callsign)
        return try dbQueue.read { db in
            try CallsignDirectoryRecord.fetchOne(db, key: key)
        }
    }

    func saveCallsignRecord(_ record: CallsignDirectoryRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
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

// MARK: - Sync

/// The narrow surface `WinlinkSyncEngine` needs.
///
/// Kept in this file because it reaches the private database queue, and
/// separate from `WinlinkStore` because a device with no database has
/// nothing to sync — that should be a missing conformance, not a set of
/// methods that throw.
extension SQLiteWinlinkStore: WinlinkSyncStore {

    func syncMessageStates() throws -> [WinlinkMessageStateRecord] {
        try dbQueue.read { db in
            try WinlinkMessageStateRecord.fetchAll(db)
        }
    }

    func syncStoredMessage(mid: String) throws -> WinlinkStoredMessage? {
        try message(mid: mid)
    }

    /// Inserts mail that arrived from another device.
    ///
    /// An existing MID is left untouched: message content is immutable once
    /// delivered (CLAUDE.md §7), so a second copy of the same MID is the
    /// same message and overwriting it could only lose something.
    func syncInsertMessage(_ message: WinlinkB2Message,
                           direction: WinlinkMessageRecord.Direction,
                           state: WinlinkMessageStateRecord) throws {
        try dbQueue.write { [now] db in
            guard try !WinlinkMessageRecord.exists(db, key: message.mid) else { return }

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
                createdAt: now())
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

            var state = state
            state.messageId = message.mid
            try state.insert(db)
        }
    }

    func syncUpdateState(_ state: WinlinkMessageStateRecord) throws {
        try dbQueue.write { db in
            guard try WinlinkMessageStateRecord.exists(db, key: state.messageId) else { return }
            try state.update(db)
        }
    }

    func syncTombstones() throws -> [WinlinkMessageTombstoneRecord] {
        try messageTombstones()
    }

    func syncIsDeleted(mid: String) throws -> Bool {
        try dbQueue.read { db in
            try WinlinkMessageTombstoneRecord.exists(db, key: mid)
        }
    }

    /// Honours another device's deletion.
    ///
    /// The tombstone is recorded whether or not the message is here — a
    /// device that never received it still has to remember the decision, or
    /// the content record files it as new mail.
    ///
    /// Deletion is monotonic and keeps the *earliest* timestamp it has seen.
    /// Two devices deleting the same message independently then converge on
    /// one answer rather than trading later stamps forever.
    @discardableResult
    func syncApplyDeletion(mid: String, at deletedAt: Date) throws -> Bool {
        try dbQueue.write { db in
            let existing = try WinlinkMessageTombstoneRecord.fetchOne(db, key: mid)
            let removed = try WinlinkMessageRecord.exists(db, key: mid)
            if removed {
                try WinlinkMessageRecord.deleteOne(db, key: mid)
                try WinlinkPartialBodyRecord.deleteOne(db, key: mid)
            }
            let stamp = min(deletedAt, existing?.deletedAt ?? deletedAt)
            guard removed || existing == nil || existing?.deletedAt != stamp else { return false }
            try WinlinkMessageTombstoneRecord(messageId: mid, deletedAt: stamp)
                .insert(db, onConflict: .replace)
            return true
        }
    }
}
