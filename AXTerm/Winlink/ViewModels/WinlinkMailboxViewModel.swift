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
    /// Every selected message.
    ///
    /// The list is a real multi-selection table, so this is the truth and
    /// `selectedMID` is derived from it. Storing one optional here and
    /// collapsing the table's `Set` into it — which is what this was —
    /// makes Select All, shift-click and command-click all appear to
    /// select exactly one row.
    @Published var selectedMIDs: Set<String> = [] {
        didSet {
            guard selectedMIDs != oldValue else { return }
            loadSelectedMessage()
        }
    }

    /// The one selected message, when exactly one is selected. Nil for an
    /// empty selection *and* for a multiple one: the reading pane can only
    /// show a message, and showing an arbitrary member of a selection would
    /// be a lie about which.
    var selectedMID: String? {
        get { selectedMIDs.count == 1 ? selectedMIDs.first : nil }
        set { selectedMIDs = newValue.map { [$0] } ?? [] }
    }

    var selectionCount: Int { selectedMIDs.count }
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
            // Drop anything that just left the folder, keeping the rest of
            // the selection intact.
            let present = Set(messages.map(\.mid))
            if !selectedMIDs.isSubset(of: present) {
                selectedMIDs = selectedMIDs.intersection(present)
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
        move(mids: [mid], toFolder: folderID)
    }

    func trash(mid: String) {
        trash(mids: [mid])
    }

    func markUnread(mid: String) {
        markUnread(mids: [mid])
    }

    // Bulk forms. One `perform` for the whole batch, so the list reloads
    // once rather than once per message — moving twenty messages should not
    // rebuild the table twenty times.

    func move(mids: Set<String>, toFolder folderID: Int64) {
        guard !mids.isEmpty else { return }
        perform {
            for mid in mids { try self.store.move(mid: mid, toFolder: folderID) }
        }
    }

    /// Moving mail to the Trash is Mail.app's ⌫ behaviour, and it asks no
    /// question because it can be taken back. Recording where each message
    /// came from is what makes that true — see `undoLastTrash`.
    func trash(mids: Set<String>) {
        guard !mids.isEmpty else { return }
        perform {
            for mid in mids { try self.store.moveToTrash(mid: mid) }
        }
        // Read the origins back from the store rather than from `messages`,
        // which holds only the folder on screen — a selection can include
        // mail the visible list has never seen.
        var origins = [String: Int64]()
        for mid in mids {
            if let folder = try? store.trashOrigin(mid: mid) {
                origins[mid] = folder
            }
        }
        lastTrashed = origins.isEmpty ? nil : origins
    }

    /// The last batch moved to the Trash, and the folder each came from.
    ///
    /// One step, not a stack: this backs ⌘Z immediately after a delete,
    /// which is the moment the mistake is noticed. A deeper history would
    /// imply the app can walk back an arbitrary sequence of mailbox edits,
    /// which it cannot.
    private var lastTrashed: [String: Int64]?

    var canUndoTrash: Bool { lastTrashed?.isEmpty == false }

    /// Puts specific messages back where they were trashed from.
    ///
    /// Independent of the undo stack: this works on anything sitting in the
    /// Trash with a recorded origin, however long ago it went in. Messages
    /// trashed before origins were recorded have nowhere known to go, so
    /// they are left alone rather than dropped in the Inbox.
    func putBack(mids: Set<String>) {
        guard !mids.isEmpty else { return }
        perform {
            for mid in mids {
                guard let origin = try self.store.trashOrigin(mid: mid) else { continue }
                try self.store.move(mid: mid, toFolder: origin)
            }
        }
    }

    /// Puts the last trashed batch back where it came from.
    ///
    /// Each message goes to *its own* origin. Sending them all to the Inbox
    /// would be tidy and wrong: a message filed in Archive and deleted from
    /// there has never been in the Inbox.
    func undoLastTrash() {
        guard let origins = lastTrashed, !origins.isEmpty else { return }
        lastTrashed = nil
        perform {
            for (mid, folder) in origins {
                try self.store.move(mid: mid, toFolder: folder)
            }
        }
    }

    func markUnread(mids: Set<String>) {
        guard !mids.isEmpty else { return }
        perform {
            for mid in mids { try self.store.setRead(mid: mid, false) }
        }
    }

    /// True while looking at the Trash, where Delete destroys rather than
    /// files.
    var isViewingTrash: Bool {
        folders.first { $0.id == selectedFolderID }?.role == .trash
    }

    /// Whether `trash(mids:)` would do anything from here. Inside the Trash
    /// there is nowhere further to file mail — `deleteForever` is what
    /// applies there instead.
    var canTrashSelection: Bool {
        !selectedMIDs.isEmpty && !isViewingTrash
    }

    /// Destroys the selection outright. There is no undo, so every caller
    /// confirms first.
    func deleteForever(mids: Set<String>) {
        guard !mids.isEmpty else { return }
        // Nothing here can be undone, and leaving the undo armed would
        // offer to restore messages that no longer exist.
        lastTrashed = nil
        perform { _ = try self.store.deleteMessages(mids: Array(mids)) }
    }

    /// Destroys everything in the Trash, wherever the operator is looking.
    func emptyTrash() {
        lastTrashed = nil
        perform { _ = try self.store.emptyTrash() }
    }

    /// How many messages `emptyTrash()` would destroy — so the confirmation
    /// can say, rather than ask about an unknown quantity.
    func trashedMessageCount() -> Int {
        guard let id = folders.first(where: { $0.role == .trash })?.id else { return 0 }
        return (try? store.messages(inFolder: id).count) ?? 0
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
