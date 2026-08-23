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

    func appendSessionLog(_ log: WinlinkSessionLogRecord) throws {
        try store.appendSessionLog(log)
    }
}
