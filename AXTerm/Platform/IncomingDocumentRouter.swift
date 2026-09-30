import Foundation

/// A file another app handed to AXTerm ("Open in AXTerm", the share sheet,
/// a drop on the app icon), and what can be done with it.
///
/// The file is copied into the app's own temporary folder first. What iOS
/// passes may be a security-scoped URL into another app's storage that stops
/// working when the scope is released, or a copy iOS put in the app's
/// `Documents/Inbox`, which is visible in the Files app and would pile up
/// there. Copying once, at the door, means everything after works on a file
/// the app owns.
///
/// The choices are plain data so the rules (packet only while a session is
/// connected, one choice per connected station) are decided here and tested,
/// and the sheet only draws them.
nonisolated enum IncomingDocumentRouter {

    /// A file copied into the app's inbox, ready to be used.
    struct StagedFile: Identifiable, Equatable, Sendable {
        let id: UUID
        /// The copy. Its folder is `folder`, one per staged file, so two files
        /// with one name cannot collide.
        var url: URL
        var folder: URL
        var name: String
        var byteCount: Int
        var isImage: Bool
    }

    enum Choice: Identifiable, Hashable, Sendable {
        /// Start a Winlink message with the file attached.
        case winlink(shrinksImage: Bool)
        /// Send the file over a connected packet session.
        case packet(callsign: String)

        var id: String {
            switch self {
            case .winlink: "winlink"
            case .packet(let callsign): "packet-\(callsign)"
            }
        }
    }

    /// What can be done with `file` right now.
    ///
    /// Winlink needs a mailbox (a store). Packet needs a connected session:
    /// offering "send over packet" with nobody on the other end would start a
    /// transfer that can only fail. One choice per connected station, in the
    /// order given, with duplicates (the same station on two radios)
    /// collapsed.
    ///
    /// A file that is not a photo and is far past Winlink's limit is not
    /// offered for Winlink at all: it could never be queued, and reading
    /// a video into memory to show a red gauge helps nobody. A photo of any
    /// size is offered, since it gets shrunk.
    static func choices(for file: StagedFile, winlinkAvailable: Bool,
                        connectedCallsigns: [String]) -> [Choice] {
        var choices: [Choice] = []
        if winlinkAvailable, file.isImage || file.byteCount <= maxWinlinkIntakeBytes {
            let overBudget = file.byteCount > WinlinkComposeViewModel.messageSizeBudget
            choices.append(.winlink(shrinksImage: file.isImage && overBudget))
        }
        var seen = Set<String>()
        for raw in connectedCallsigns {
            let callsign = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard !callsign.isEmpty, seen.insert(callsign).inserted else { continue }
            choices.append(.packet(callsign: callsign))
        }
        return choices
    }

    /// The largest non-photo file offered for Winlink. Well past the 120 KB
    /// limit, so a file the zip step might bring under it is still offered.
    static let maxWinlinkIntakeBytes = 2 * 1024 * 1024

    static func title(for choice: Choice) -> String {
        switch choice {
        case .winlink: "Attach to a new Winlink message"
        case .packet(let callsign): "Send to \(callsign) over packet"
        }
    }

    /// A line under the title saying what will happen, when there is
    /// something worth saying.
    static func detail(for choice: Choice, file: StagedFile) -> String? {
        switch choice {
        case .winlink(let shrinks):
            if shrinks {
                return "The photo is shrunk to fit Winlink's \(WinlinkComposeViewModel.messageSizeBudget / 1024) KB limit. You can still send the original."
            }
            if file.byteCount > WinlinkComposeViewModel.messageSizeBudget {
                return "At \(ByteCount.string(file.byteCount)) it is over Winlink's \(WinlinkComposeViewModel.messageSizeBudget / 1024) KB limit, so the message cannot be queued as it is."
            }
            return nil
        case .packet:
            return "Starts a file transfer on the connected session. Progress shows in the Terminal."
        }
    }

    // MARK: - Staging

    static let inboxFolderName = "Incoming Files"

    static func inbox(base: URL = FileManager.default.temporaryDirectory) -> URL {
        base.appendingPathComponent(inboxFolderName, isDirectory: true)
    }

    /// Copies `url` into `inbox`, taking and releasing the security scope
    /// another app lent. When the source is the copy iOS left in this app's
    /// own `Documents/Inbox`, that copy is removed, since the Files app shows
    /// that folder and nobody asked for a second copy there.
    static func stage(_ url: URL, inbox: URL, ownInbox: URL? = defaultOwnInbox) throws -> StagedFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let folder = inbox.appendingPathComponent(id.uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = ComposeAttachmentIntake.sanitized(url.lastPathComponent)
        let destination = folder.appendingPathComponent(name)
        do {
            try fm.copyItem(at: url, to: destination)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        if let ownInbox, isInside(url, folder: ownInbox) {
            try? fm.removeItem(at: url)
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return StagedFile(id: id, url: destination, folder: folder, name: name,
                          byteCount: size, isImage: ImageShrinker.isImage(named: name))
    }

    /// Where iOS drops files other apps "copy to" this one.
    static var defaultOwnInbox: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    static func isInside(_ url: URL, folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Reads a staged file for attaching to a message.
    static func contents(of file: StagedFile) -> ComposeIncomingFile? {
        guard let data = try? Data(contentsOf: file.url) else { return nil }
        return ComposeIncomingFile(name: file.name, data: data)
    }

    /// Removes a staged file once it has been used or the operator canceled.
    static func discard(_ file: StagedFile) {
        try? FileManager.default.removeItem(at: file.folder)
    }

    /// Removes staged files older than `age`. A file handed to a packet
    /// transfer is left in place while the transfer may still read it, and
    /// cleared by this on a later launch.
    static func purge(inbox: URL, olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? .distantPast
            if now.timeIntervalSince(created) > age {
                try? fm.removeItem(at: folder)
            }
        }
    }
}
