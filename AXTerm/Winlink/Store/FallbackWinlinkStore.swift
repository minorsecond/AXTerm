import Foundation

/// Inert store used only when the database failed to open, so view
/// models still construct (the UI shows a disabled notice instead).
nonisolated final class FallbackWinlinkStore: WinlinkStore, @unchecked Sendable {
    func folders() throws -> [WinlinkFolderRecord] { [] }
    func folderID(for role: WinlinkFolderRecord.SystemRole) throws -> Int64 {
        throw WinlinkStoreError.missingSystemFolder(role.rawValue)
    }
    func createFolder(name: String) throws -> WinlinkFolderRecord {
        throw WinlinkStoreError.missingSystemFolder("unavailable")
    }
    func renameFolder(id: Int64, name: String) throws { throw WinlinkStoreError.folderNotFound(id) }
    func deleteFolder(id: Int64) throws { throw WinlinkStoreError.folderNotFound(id) }
    func trashOrigin(mid: String) throws -> Int64? { nil }
    func deleteMessages(mids: [String]) throws -> [String] { [] }
    func emptyTrash() throws -> Int { 0 }
    func messageTombstones() throws -> [WinlinkMessageTombstoneRecord] { [] }
    func saveDraft(_ message: WinlinkB2Message) throws { throw WinlinkStoreError.missingSystemFolder("unavailable") }
    func updateDraft(_ message: WinlinkB2Message) throws { throw WinlinkStoreError.messageNotFound(message.mid) }
    func queueDraft(mid: String) throws { throw WinlinkStoreError.messageNotFound(mid) }
    func queuedOutboundMessages() throws -> [WinlinkB2Message] { [] }
    func markSending(mid: String) throws {}
    func markSent(mid: String) throws {}
    func markFailed(mid: String, error: String) throws {}
    func markDeferred(mid: String) throws {}
    func savePartialBody(mid: String, compressedSize: Int, data: Data) throws {}
    func partialBodies() throws -> [WinlinkPartialBodyRecord] { [] }
    func deletePartialBody(mid: String) throws {}
    func revertSendingToQueued() throws {}
    func recordSentOffset(mid: String, offset: Int) throws {}
    func saveInbound(_ message: WinlinkB2Message) throws -> Bool { false }
    func messages(inFolder folderId: Int64) throws -> [WinlinkMessageSummary] { [] }
    func message(mid: String) throws -> WinlinkStoredMessage? { nil }
    func inboundMessages(fromAddr: String, limit: Int) throws -> [WinlinkStoredMessage] { [] }
    func catalogFavorites() throws -> Set<String> { [] }
    func setCatalogFavorite(inquiryId: String, isFavorite: Bool) throws {}
    func callsignRecord(callsign: String) throws -> CallsignDirectoryRecord? { nil }
    func saveCallsignRecord(_ record: CallsignDirectoryRecord) throws {}
    func setRead(mid: String, _ read: Bool) throws {}
    func move(mid: String, toFolder folderId: Int64) throws {}
    func moveToTrash(mid: String) throws {}
    func unreadInboxCount() throws -> Int { 0 }
    func replaceStationCache(_ stations: [WinlinkRMSStationRecord],
                             scope: WinlinkRMSStationRecord.Scope) throws {}
    func stations() throws -> [WinlinkRMSStationRecord] { [] }
    func stations(scope: WinlinkRMSStationRecord.Scope) throws -> [WinlinkRMSStationRecord] { [] }
    func downloadedGridFields() throws -> [(field: String, count: Int)] { [] }
    func clearDownloadedStations() throws {}
    func replaceCatalogCache(_ items: [WinlinkCatalogItemRecord]) throws {}
    func catalogItems() throws -> [WinlinkCatalogItemRecord] { [] }
    func appendSessionLog(_ log: WinlinkSessionLogRecord) throws {}
    func appendSessionLogReturningID(_ log: WinlinkSessionLogRecord) throws -> Int64 { 0 }
    func sessionLogs(limit: Int) throws -> [WinlinkSessionLogRecord] { [] }
    func sessionLog(id: Int64) throws -> WinlinkSessionLogRecord? { nil }
    func sessionLogID(forMessage mid: String) throws -> Int64? { nil }
    func messageIDs(forSessionLog id: Int64) throws -> [String] { [] }
    func linkMessages(mids: [String], toSessionLog id: Int64) throws {}
    func saveSolarConditions(_ conditions: SolarConditions) throws {}
    func solarConditions(forDay day: Date) throws -> SolarConditions? { nil }
    func saveInbound(_ message: WinlinkB2Message, sessionLogID: Int64?) throws -> Bool { false }
}
