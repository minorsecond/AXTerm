import Foundation
import UniformTypeIdentifiers

/// What the operator can do with a received attachment, per platform.
///
/// The actions are data so that which ones appear where is decided once and
/// tested, and the view only draws them. The platforms differ on purpose: a
/// Mac hands a file to another app with Open and to the Finder with Show in
/// Finder; iOS has no Finder and hands files on through the share sheet.
nonisolated enum AttachmentAction: String, CaseIterable, Sendable {
    case quickLook
    case share
    case open
    case showInFinder
    case save
    case addToMap

    var title: String {
        switch self {
        case .quickLook: "Quick Look"
        case .share: "Share\u{2026}"
        case .open: "Open"
        case .showInFinder: "Show in Finder"
        case .save: "Save\u{2026}"
        case .addToMap: "Add to Map"
        }
    }

    var systemImage: String {
        switch self {
        case .quickLook: "eye"
        case .share: "square.and.arrow.up"
        case .open: "arrow.up.forward.app"
        case .showInFinder: "folder"
        case .save: "square.and.arrow.down"
        case .addToMap: "map"
        }
    }
}

nonisolated enum AttachmentActions {

    enum Platform: Sendable {
        case mac, iOS

        static var current: Platform {
            #if os(macOS)
            .mac
            #else
            .iOS
            #endif
        }
    }

    /// The actions offered for one attachment, in menu order. Quick Look
    /// first because it is what a tap does.
    static func available(canAddToMap: Bool, platform: Platform = .current) -> [AttachmentAction] {
        var actions: [AttachmentAction] = [.quickLook]
        switch platform {
        case .mac: actions += [.open, .showInFinder, .save]
        case .iOS: actions += [.share, .save]
        }
        if canAddToMap { actions.append(.addToMap) }
        return actions
    }

    /// How to reach a context menu here: a right-click on the Mac, a touch
    /// and hold on iPhone and iPad. Help text that says "right-click" on a
    /// phone sends the operator looking for a mouse.
    static func secondaryClick(platform: Platform = .current) -> String {
        platform == .mac ? "Right-click" : "Touch and hold"
    }

    /// True when the reading pane should draw the attachment as a picture.
    /// Decided by type rather than a list of extensions, so HEIC from an
    /// iPhone counts; the view still falls back to the chip alone if the
    /// bytes do not decode.
    static func isInlineImage(named name: String) -> Bool {
        ImageShrinker.isImage(named: name)
    }
}

/// Temporary copies of received attachments, for Quick Look, Open and Share.
///
/// Attachments live as blobs in the database, and every one of those system
/// services wants a file URL. The copies go under the app's temporary
/// directory, one folder per message, named as the sender named them so the
/// preview's title and a shared file's name are the real ones.
nonisolated enum AttachmentPreviewFiles {

    static let folderName = "AXTerm Attachments"

    /// Where copies for `messageID` go.
    static func directory(for messageID: String,
                          base: URL = FileManager.default.temporaryDirectory) -> URL {
        base.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(ComposeAttachmentIntake.sanitized(messageID), isDirectory: true)
    }

    /// Writes (or reuses) a copy of each attachment and returns their URLs in
    /// the same order. An existing copy with the same bytes is reused, so
    /// reopening a message does not write it again.
    static func write(_ files: [ExportableFile], messageID: String,
                      base: URL = FileManager.default.temporaryDirectory) throws -> [URL] {
        let folder = directory(for: messageID, base: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var used: [String] = []
        var urls: [URL] = []
        for file in files {
            // Two attachments with one name would overwrite each other.
            let name = ComposeAttachmentIntake.uniqueName(
                ComposeAttachmentIntake.sanitized(file.name), existing: used)
            used.append(name)
            let url = folder.appendingPathComponent(name)
            if (try? Data(contentsOf: url)) != file.data {
                try file.data.write(to: url, options: .atomic)
            }
            urls.append(url)
        }
        return urls
    }

    /// Removes copies older than `age`, so the folder does not grow with every
    /// message ever opened. The system clears the temporary directory too, but
    /// on its own schedule.
    static func purge(olderThan age: TimeInterval, now: Date = Date(),
                      base: URL = FileManager.default.temporaryDirectory) {
        let root = base.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > age {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// Where Show in Finder puts a copy: a named folder in Downloads, since a
    /// sandboxed app's temporary directory is not somewhere to send the
    /// Finder. A file already there with the same bytes is reused; one with
    /// different bytes gets a numbered name rather than being overwritten.
    static func downloadsCopy(of file: ExportableFile, in downloads: URL) throws -> URL {
        let folder = downloads.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var name = ComposeAttachmentIntake.sanitized(file.name)
        var taken = existing
        while taken.contains(where: { $0.lowercased() == name.lowercased() }) {
            let url = folder.appendingPathComponent(name)
            if (try? Data(contentsOf: url)) == file.data { return url }
            taken.append(name)
            name = ComposeAttachmentIntake.uniqueName(name, existing: taken)
        }
        let url = folder.appendingPathComponent(name)
        try file.data.write(to: url, options: .atomic)
        return url
    }
}
