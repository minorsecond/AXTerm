import Foundation
import Combine

/// Drives the three-pane mailbox: folders, message list, reading pane.
@MainActor
final class WinlinkMailboxViewModel: ObservableObject {

    @Published private(set) var folders: [WinlinkFolderRecord] = []
    @Published var selectedFolderID: Int64? {
        didSet { reloadMessages() }
    }
    @Published private(set) var messages: [WinlinkMessageSummary] = []
    @Published var searchText: String = "" {
        didSet { applyFilter() }
    }
    @Published private(set) var filteredMessages: [WinlinkMessageSummary] = []
    @Published var selectedMID: String? {
        didSet { loadSelectedMessage() }
    }
    @Published private(set) var selectedMessage: WinlinkStoredMessage?
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var lastError: String?

    private let store: WinlinkStore
    private let myCallsign: () -> String

    /// Fired whenever the number of unread messages may have changed.
    ///
    /// `WinlinkContext` keeps its own `unreadCount` for the tab badge,
    /// because the badge outlives any one mailbox screen. Reading a message
    /// updates this view model's count and nothing else, so before this
    /// existed the badge stayed lit until some unrelated action happened to
    /// call `refreshUnread()` — on iOS, opening a message never did.
    var onUnreadCountChanged: (() -> Void)?

    init(store: WinlinkStore, myCallsign: @escaping () -> String) {
        self.store = store
        self.myCallsign = myCallsign
        refresh()
        if selectedFolderID == nil {
            selectedFolderID = folders.first(where: { $0.role == .inbox })?.id
        }
    }

    // MARK: - Loading

    func refresh() {
        do {
            folders = try store.folders()
            setUnreadCount(try store.unreadInboxCount())
            reloadMessages()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Single place the count is written, so no path can update it silently.
    private func setUnreadCount(_ value: Int) {
        let changed = unreadCount != value
        unreadCount = value
        if changed { onUnreadCountChanged?() }
    }

    private func reloadMessages() {
        guard let folderID = selectedFolderID else {
            messages = []
            filteredMessages = []
            return
        }
        do {
            messages = try store.messages(inFolder: folderID)
            applyFilter()
            if let selectedMID, !messages.contains(where: { $0.mid == selectedMID }) {
                self.selectedMID = nil
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    private func applyFilter() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            filteredMessages = messages
            return
        }
        filteredMessages = messages.filter { summary in
            summary.subject.lowercased().contains(query)
                || summary.fromAddr.lowercased().contains(query)
                || summary.toAddrs.contains { $0.lowercased().contains(query) }
        }
    }

    private func loadSelectedMessage() {
        guard let mid = selectedMID else {
            selectedMessage = nil
            return
        }
        do {
            let stored = try store.message(mid: mid)
            selectedMessage = stored
            if let stored, !stored.state.isRead {
                try store.setRead(mid: mid, true)
                setUnreadCount(try store.unreadInboxCount())
                reloadMessages()
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Message actions

    func move(mid: String, toFolder folderID: Int64) {
        perform { try self.store.move(mid: mid, toFolder: folderID) }
    }

    func trash(mid: String) {
        perform { try self.store.moveToTrash(mid: mid) }
    }

    func markUnread(mid: String) {
        perform { try self.store.setRead(mid: mid, false) }
    }

    // MARK: - Folder actions

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        perform { _ = try self.store.createFolder(name: trimmed) }
    }

    func renameFolder(id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        perform { try self.store.renameFolder(id: id, name: trimmed) }
    }

    func deleteFolder(id: Int64) {
        perform {
            try self.store.deleteFolder(id: id)
            if self.selectedFolderID == id {
                self.selectedFolderID = self.folders.first(where: { $0.role == .inbox })?.id
            }
        }
    }

    // MARK: - Reply / forward prefill

    /// Builds an unsaved draft replying to `stored`. The caller feeds it
    /// into the compose window.
    func replyDraft(to stored: WinlinkStoredMessage, replyAll: Bool) -> WinlinkB2Message {
        let original = stored.message
        let me = myCallsign()

        var recipients = [original.from]
        var cc = [String]()
        if replyAll {
            let others = (original.to + original.cc).filter {
                $0.caseInsensitiveCompare(me) != .orderedSame
                    && $0.caseInsensitiveCompare(original.from) != .orderedSame
            }
            cc = others
        }

        let subject = original.subject.hasPrefix("Re:") ? original.subject : "Re: \(original.subject)"
        return WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: me),
            date: Date(),
            type: .privateMessage,
            from: me,
            to: recipients,
            cc: cc,
            subject: String(subject.prefix(WinlinkB2Message.maxSubjectLength)),
            mbo: me,
            body: Self.quotedBody(of: original),
            attachments: [])
    }

    func forwardDraft(of stored: WinlinkStoredMessage) -> WinlinkB2Message {
        let original = stored.message
        let me = myCallsign()
        let subject = original.subject.hasPrefix("Fw:") ? original.subject : "Fw: \(original.subject)"
        return WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: me),
            date: Date(),
            type: .privateMessage,
            from: me,
            to: [],
            cc: [],
            subject: String(subject.prefix(WinlinkB2Message.maxSubjectLength)),
            mbo: me,
            body: Self.quotedBody(of: original),
            attachments: original.attachments)
    }

    private static func quotedBody(of original: WinlinkB2Message) -> Data {
        let originalText = String(data: original.body, encoding: .isoLatin1) ?? ""
        let quoted = originalText
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" })
            .map { "> \($0)" }
            .joined(separator: "\r\n")
        let header = "\r\n\r\n----- Original message from \(original.from) -----\r\n"
        return Data((header + quoted + "\r\n").unicodeScalars.map { UInt8($0.value & 0xff) })
    }

    // MARK: - Helpers

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            refresh()
        } catch {
            lastError = String(describing: error)
        }
    }
}
