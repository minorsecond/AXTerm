import Foundation

/// Serializes Winlink store writes off the main actor (CLAUDE.md §12),
/// mirroring the `PersistenceWorker` pattern used for packet persistence.
actor WinlinkPersistenceWorker {

    private let store: WinlinkStore

    init(store: WinlinkStore) {
        self.store = store
    }

    func saveInbound(_ message: WinlinkB2Message) throws -> Bool {
        try store.saveInbound(message)
    }

    func markSending(mid: String) throws {
        try store.markSending(mid: mid)
    }

    func markSent(mid: String) throws {
        try store.markSent(mid: mid)
    }

    func markFailed(mid: String, error: String) throws {
        try store.markFailed(mid: mid, error: error)
    }

    func markDeferred(mid: String) throws {
        try store.markDeferred(mid: mid)
    }

    func revertSendingToQueued() throws {
        try store.revertSendingToQueued()
    }

    func recordSentOffset(mid: String, offset: Int) throws {
        try store.recordSentOffset(mid: mid, offset: offset)
    }

    func queuedOutboundMessages() throws -> [WinlinkB2Message] {
        try store.queuedOutboundMessages()
    }

    /// Append the log and hand back its id, so the mail this exchange
    /// brought in can be tied to it.
    func appendSessionLogReturningID(_ log: WinlinkSessionLogRecord) throws -> Int64 {
        try store.appendSessionLogReturningID(log)
    }

    func linkMessages(mids: [String], toSessionLog id: Int64) throws {
        try store.linkMessages(mids: mids, toSessionLog: id)
    }

    func appendSessionLog(_ log: WinlinkSessionLogRecord) throws {
        try store.appendSessionLog(log)
    }

    func savePartialBody(mid: String, compressedSize: Int, data: Data) throws {
        try store.savePartialBody(mid: mid, compressedSize: compressedSize, data: data)
    }

    func partialBodies() throws -> [WinlinkPartialBodyRecord] {
        try store.partialBodies()
    }

    func replaceCatalogCache(_ items: [WinlinkCatalogItemRecord]) throws {
        try store.replaceCatalogCache(items)
    }

    func deletePartialBody(mid: String) throws {
        try store.deletePartialBody(mid: mid)
    }
}
