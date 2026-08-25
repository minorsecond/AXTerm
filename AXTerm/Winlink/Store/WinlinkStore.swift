import Foundation

/// One row of a mailbox list — content trimmed for table display.
nonisolated struct WinlinkMessageSummary: Hashable, Sendable, Identifiable {
    var id: String { mid }
    var mid: String
    var direction: WinlinkMessageRecord.Direction
    var date: Date
    var fromAddr: String
    var toAddrs: [String]
    var subject: String
    var bodySize: Int
    var attachmentCount: Int
    var isRead: Bool
    var deliveryState: WinlinkMessageStateRecord.DeliveryState
    var folderId: Int64
    var lastError: String?
}

/// A fully loaded message with its mutable state and attachments.
nonisolated struct WinlinkStoredMessage: Hashable, Sendable {
    var message: WinlinkB2Message
    var direction: WinlinkMessageRecord.Direction
    var state: WinlinkMessageStateRecord
}

nonisolated enum WinlinkStoreError: Error, Equatable {
    case messageNotFound(String)
    case notADraft(String)
    case notQueued(String)
    case folderNotFound(Int64)
    case cannotModifySystemFolder
    case missingSystemFolder(String)
}

/// Persistence facade for the Winlink mail subsystem.
///
/// Content rows are append-only: once a message leaves the `draft` state
/// its `winlinkMessage` row never changes again — only the companion
/// state row (folder, read flag, delivery state) may move.
nonisolated protocol WinlinkStore: Sendable {

    // Folders
    func folders() throws -> [WinlinkFolderRecord]
    func folderID(for role: WinlinkFolderRecord.SystemRole) throws -> Int64
    @discardableResult
    func createFolder(name: String) throws -> WinlinkFolderRecord
    func renameFolder(id: Int64, name: String) throws
    func deleteFolder(id: Int64) throws

    // Compose / drafts
    func saveDraft(_ message: WinlinkB2Message) throws
    func updateDraft(_ message: WinlinkB2Message) throws
    func queueDraft(mid: String) throws

    // Exchange lifecycle
    func queuedOutboundMessages() throws -> [WinlinkB2Message]
    func markSending(mid: String) throws
    func markSent(mid: String) throws
    func markFailed(mid: String, error: String) throws
    func markDeferred(mid: String) throws
    func revertSendingToQueued() throws
    func recordSentOffset(mid: String, offset: Int) throws
    /// Persists an inbound message into the Inbox. Returns false when a
    /// message with the same MID already exists (gateway re-send after an
    /// interrupted session) — the first copy wins.
    @discardableResult
    func saveInbound(_ message: WinlinkB2Message) throws -> Bool

    // B2F resume: partially received compressed bodies
    func savePartialBody(mid: String, compressedSize: Int, data: Data) throws
    func partialBodies() throws -> [WinlinkPartialBodyRecord]
    func deletePartialBody(mid: String) throws

    // Mailbox reading
    func messages(inFolder folderId: Int64) throws -> [WinlinkMessageSummary]
    func message(mid: String) throws -> WinlinkStoredMessage?
    /// Newest-first inbound messages from one sender — the catalog code
    /// scans SERVICE mail for the inquiry server's LIST reply.
    func inboundMessages(fromAddr: String, limit: Int) throws -> [WinlinkStoredMessage]
    func setRead(mid: String, _ read: Bool) throws
    func move(mid: String, toFolder folderId: Int64) throws
    func moveToTrash(mid: String) throws
    func unreadInboxCount() throws -> Int

    // RMS station + catalog caches
    func replaceStationCache(_ stations: [WinlinkRMSStationRecord],
                             scope: WinlinkRMSStationRecord.Scope) throws
    func stations() throws -> [WinlinkRMSStationRecord]
    func stations(scope: WinlinkRMSStationRecord.Scope) throws -> [WinlinkRMSStationRecord]
    /// Grid fields covered by the downloaded set, with gateway counts.
    func downloadedGridFields() throws -> [(field: String, count: Int)]
    func clearDownloadedStations() throws
    func replaceCatalogCache(_ items: [WinlinkCatalogItemRecord]) throws
    func catalogItems() throws -> [WinlinkCatalogItemRecord]

    /// InquiryIds the operator starred. Survives `replaceCatalogCache`,
    /// so it may name products the current index no longer carries.
    func catalogFavorites() throws -> Set<String>
    func setCatalogFavorite(inquiryId: String, isFavorite: Bool) throws

    /// Cached callsign-directory answers, keyed by base callsign.
    func callsignRecord(callsign: String) throws -> CallsignDirectoryRecord?
    func saveCallsignRecord(_ record: CallsignDirectoryRecord) throws

    // Session log
    func appendSessionLog(_ log: WinlinkSessionLogRecord) throws
    func sessionLogs(limit: Int) throws -> [WinlinkSessionLogRecord]
}
