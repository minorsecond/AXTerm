//
//  BBSFileLibrary.swift
//  AXTerm
//
//  Scanning the folders the operator shares, and reading bytes back out.
//

import Foundation
import Combine

/// The bridge between the operator's disk and the catalog callers see.
///
/// Everything filesystem-shaped lives here. `BBSShell` has no file access at
/// all and resolves names by lookup in the index this produces, so no command
/// the shell implements can reach a file that was not scanned — traversal is
/// impossible by construction rather than by sanitizing caller input.
@MainActor
final class BBSFileLibrary: ObservableObject {

    /// Skipped rather than shared. Anything larger is hours of airtime and
    /// almost certainly a mistake; the operator can raise it if they mean it.
    nonisolated static let defaultMaxFileBytes = 5 * 1024 * 1024

    /// Security scope is spelled differently per platform: macOS asks for it
    /// explicitly, iOS grants it implicitly to a document-picked URL.
    #if os(macOS)
    nonisolated static let bookmarkOptions: URL.BookmarkCreationOptions = .withSecurityScope
    nonisolated static let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    nonisolated static let bookmarkOptions: URL.BookmarkCreationOptions = []
    nonisolated static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    @Published private(set) var index = BBSFileIndex()
    @Published private(set) var lastScanError: String?
    /// Areas whose folder could not be found at the last scan: moved to a
    /// drive that is not mounted, deleted, or renamed past what the bookmark
    /// can follow. Listed so the Files screen can offer to choose each one
    /// again instead of only printing an error.
    @Published private(set) var unreachableAreas: Set<String> = []

    private let store: BBSMessageStore?
    private let maxFileBytes: Int

    init(store: BBSMessageStore?, maxFileBytes: Int = BBSFileLibrary.defaultMaxFileBytes) {
        self.store = store
        self.maxFileBytes = maxFileBytes
    }

    // MARK: - Areas

    /// Shares a folder the operator picked in an open panel.
    ///
    /// The app is sandboxed, so the URL alone is worthless after a relaunch —
    /// a security-scoped bookmark is what survives, and without one the file
    /// area works until the operator quits and then quietly serves nothing.
    func addArea(name: String, about: String, url: URL) {
        do {
            let bookmark = try Self.mintBookmark(for: url)
            try store?.saveFileArea(
                BBSFileArea(name: name, about: about, bookmark: bookmark))
            rescan()
        } catch {
            lastScanError = "Could not share \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Points an existing area at a folder chosen again, keeping its name and
    /// description, and the descriptions of the files in it.
    func relocateArea(name: String, url: URL) {
        let key = BBSFileArea.normalize(name)
        let about = ((try? store?.fileAreas()) ?? [])
            .first { $0.name == key }?.about ?? ""
        addArea(name: key, about: about, url: url)
    }

    /// A bookmark for a folder the operator picked.
    ///
    /// The scope has to be *open* while the bookmark is minted. On iOS a URL
    /// from the document picker arrives scoped-but-closed, and a bookmark
    /// taken outside the scope resolves to a URL that reads nothing: the area
    /// would list zero files with no error to explain it. Harmless on macOS,
    /// where an open-panel URL is already usable and `startAccessing` simply
    /// answers false.
    nonisolated static func mintBookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: bookmarkOptions,
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
    }

    /// Resolves a bookmark and, when the system calls it stale (the folder
    /// was moved or renamed and the bookmark followed it), returns a fresh
    /// one to store in its place.
    ///
    /// A stale bookmark works today but may not survive the next move, and
    /// re-minting it is cheap and needs nothing from the operator. Left
    /// alone, it goes on resolving until one day it does not, and the area
    /// quietly serves nothing.
    nonisolated static func resolveBookmark(_ bookmark: Data) -> (url: URL, refreshed: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: resolutionOptions,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale ? try? mintBookmark(for: url) : nil)
    }

    func removeArea(name: String) {
        try? store?.deleteFileArea(name: name)
        rescan()
    }

    func setDescription(area: String, name: String, about: String) {
        try? store?.setFileDescription(area: area, name: name, about: about)
        rescan()
    }

    // MARK: - Scanning

    func rescan() {
        guard let store else {
            index = BBSFileIndex()
            return
        }
        let areas = (try? store.fileAreas()) ?? []
        let descriptions = (try? store.fileDescriptions()) ?? [:]

        var files: [BBSSharedFile] = []
        var errors: [String] = []
        var unreachable: Set<String> = []
        var current: [BBSFileArea] = []

        for var area in areas {
            let url = resolve(&area)
            // Held with the fresh bookmark if one was minted, so reading a
            // file later does not find the stale one and mint again.
            current.append(area)
            guard let url else {
                errors.append("\(area.name): folder is no longer reachable")
                unreachable.insert(area.name)
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // A bookmark can resolve to where the folder used to be. An
            // empty listing there would read as a folder the operator
            // emptied, so it is reported as the missing folder it is.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                errors.append("\(area.name): folder is no longer reachable")
                unreachable.insert(area.name)
                continue
            }

            do {
                files.append(contentsOf: try scan(area: area, at: url,
                                                  descriptions: descriptions))
            } catch {
                errors.append("\(area.name): \(error.localizedDescription)")
            }
        }

        index = BBSFileIndex(areas: current, files: files)
        unreachableAreas = unreachable
        lastScanError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        refreshInbox()
    }

    /// One level deep, files only.
    ///
    /// A file area is conventionally flat, and staying flat keeps the caller's
    /// `D <name>` unambiguous without teaching them a path syntax over a link
    /// where they cannot see what they are typing.
    private func scan(area: BBSFileArea,
                      at url: URL,
                      descriptions: [String: String]) throws -> [BBSSharedFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])

        return entries.compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { return nil }
            // Symlinks are not followed: a link inside a shared folder is a
            // way to serve something the operator never chose to share.
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.isHidden != true else { return nil }
            let size = values.fileSize ?? 0
            guard size > 0, size <= maxFileBytes else { return nil }

            let name = entry.lastPathComponent
            return BBSSharedFile(
                area: area.name,
                name: name,
                byteCount: size,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                about: descriptions["\(area.name)/\(name)"] ?? "")
        }
        .sorted { $0.name < $1.name }
    }

    /// Resolves an area's folder, storing a fresh bookmark in place of a
    /// stale one and updating `area` to match.
    private func resolve(_ area: inout BBSFileArea) -> URL? {
        guard let bookmark = area.bookmark,
              let (url, refreshed) = Self.resolveBookmark(bookmark) else { return nil }
        if let refreshed {
            area.bookmark = refreshed
            try? store?.saveFileArea(area)
        }
        return url
    }

    private func resolve(_ area: BBSFileArea) -> URL? {
        var copy = area
        return resolve(&copy)
    }

    // MARK: - Uploads

    /// Where files from callers land.
    ///
    /// Deliberately **not** one of the shared areas. A caller who could write
    /// into an area would be publishing to every other caller the moment the
    /// transfer finished — using the operator's station to distribute
    /// something nobody looked at. Uploads sit here until the operator moves
    /// them, and nothing serves them in the meantime.
    @Published private(set) var inboxName: String?
    @Published private(set) var inboxBytes = 0
    @Published private(set) var inboxCount = 0
    /// An inbox was chosen but its folder cannot be found. Uploads are
    /// refused until it is chosen again, and the Files screen says so rather
    /// than showing the "choose a folder" it shows before one ever was.
    @Published private(set) var inboxUnreachable = false

    var hasInbox: Bool { inboxName != nil }

    func setInbox(url: URL?) {
        guard let url else {
            try? store?.setUploadInbox(nil)
            refreshInbox()
            return
        }
        do {
            try store?.setUploadInbox(try Self.mintBookmark(for: url))
            refreshInbox()
        } catch {
            lastScanError = "Could not use \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func refreshInbox() {
        guard let url = inboxURL() else {
            let chosen = ((try? store?.uploadInbox()) ?? nil) != nil
            inboxName = nil
            inboxBytes = 0
            inboxCount = 0
            inboxUnreachable = chosen
            return
        }
        inboxUnreachable = false
        inboxName = url.lastPathComponent

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        var bytes = 0
        var count = 0
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            bytes += values.fileSize ?? 0
            count += 1
        }
        inboxBytes = bytes
        inboxCount = count
    }

    private func inboxURL() -> URL? {
        // `try?` on a throwing function returning `Data?` flattens to `Data?`,
        // so one unwrap covers both the throw and the empty case.
        guard let store, let bookmark = try? store.uploadInbox(),
              let (url, refreshed) = Self.resolveBookmark(bookmark) else { return nil }
        if let refreshed { try? store.setUploadInbox(refreshed) }
        // As for an area: a bookmark that resolves to where the folder used
        // to be is not an inbox, and writing there would recreate nothing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    /// Writes an accepted upload, never over something already there.
    ///
    /// - Parameter name: already through `BBSUploadPolicy.sanitize`.
    /// - Returns: the name it ended up with, or nil if it could not be written.
    func saveUpload(name: String, data: Data) -> String? {
        guard let base = inboxURL() else { return nil }
        let scoped = base.startAccessingSecurityScopedResource()
        defer { if scoped { base.stopAccessingSecurityScopedResource() } }

        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []))
        let final = BBSUploadPolicy.uniqueName(name, taken: existing)
        let url = base.appendingPathComponent(final)

        // The name is already a sanitized leaf, but a write outside the inbox
        // must be impossible even if that ever stops being true.
        guard url.deletingLastPathComponent().standardizedFileURL
                == base.standardizedFileURL else { return nil }
        guard (try? data.write(to: url, options: .withoutOverwriting)) != nil else { return nil }

        refreshInbox()
        return final
    }

    // MARK: - Adding files

    /// What became of one file the operator asked to share.
    enum AddOutcome: Equatable, Sendable {
        case added(name: String)
        /// A file of that name was already in the folder, and nothing is
        /// ever replaced: callers may have fetched the old one by name.
        case renamed(from: String, to: String)
        case refused(name: String, reason: String)
    }

    /// Copies files into an area's folder, from a picker or a drop.
    ///
    /// Copied, never moved: the originals are the operator's and stay where
    /// they were. This is the one place the app writes into a shared folder,
    /// and only on the operator's own say-so.
    func addFiles(_ urls: [URL], to areaName: String) -> [AddOutcome] {
        let outcomes = urls.map { url -> AddOutcome in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                return .refused(name: name, reason: "folders are not shared, only the files in them")
            }
            return place(name, size: values?.fileSize ?? 0, in: areaName) { destination in
                try FileManager.default.copyItem(at: url, to: destination)
            }
        }
        rescan()
        return outcomes
    }

    /// Writes bytes into an area's folder under a name that came with them,
    /// for drops that deliver data rather than a file URL.
    func addFile(named name: String, data: Data, to areaName: String) -> AddOutcome {
        let outcome = place(name, size: data.count, in: areaName) { destination in
            try data.write(to: destination, options: .withoutOverwriting)
        }
        rescan()
        return outcome
    }

    /// The name as a file in a shared folder, or nil when it cannot be one.
    ///
    /// A drop can carry a name its source chose, so this refuses anything
    /// that is not a plain leaf: a path, `.` or `..`, a hidden name (which
    /// the scan would skip anyway, so it would be shared and never offered),
    /// or control characters. Otherwise the operator's own name is kept:
    /// unlike an upload's, it was not chosen by a stranger.
    nonisolated static func acceptableSharedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.hasPrefix("."),
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains(":"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    private func place(_ name: String, size: Int, in areaName: String,
                       write: (URL) throws -> Void) -> AddOutcome {
        guard let leaf = Self.acceptableSharedName(name) else {
            return .refused(name: name, reason: "that name cannot be used for a shared file")
        }
        // The same rules the scan applies, said now instead of the file
        // silently never appearing.
        guard size > 0 else {
            return .refused(name: leaf, reason: "it is empty")
        }
        guard size <= maxFileBytes else {
            return .refused(name: leaf, reason: "it is over the \(BBSFileIndex.size(maxFileBytes)) "
                            + "limit, so callers would never see it")
        }
        let key = BBSFileArea.normalize(areaName)
        guard let area = ((try? store?.fileAreas()) ?? []).first(where: { $0.name == key }),
              let base = resolve(area) else {
            return .refused(name: leaf, reason: "the \(key) folder cannot be reached")
        }
        let scoped = base.startAccessingSecurityScopedResource()
        defer { if scoped { base.stopAccessingSecurityScopedResource() } }

        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
        let final = BBSUploadPolicy.uniqueName(leaf, taken: taken)
        let destination = base.appendingPathComponent(final)
        // The name is a checked leaf, but a write outside the folder must be
        // impossible even if that ever stops being true.
        guard destination.deletingLastPathComponent().standardizedFileURL
                == base.standardizedFileURL else {
            return .refused(name: leaf, reason: "that name cannot be used for a shared file")
        }
        do {
            try write(destination)
        } catch {
            return .refused(name: leaf, reason: error.localizedDescription)
        }
        return final == leaf ? .added(name: final) : .renamed(from: leaf, to: final)
    }

    // MARK: - Reading

    /// Bytes for a file the index produced.
    ///
    /// Takes a `BBSSharedFile` rather than a name on purpose: the caller's
    /// input has already been resolved against the index by the time anything
    /// reaches the filesystem.
    func data(for file: BBSSharedFile) -> Data? {
        guard let area = index.areas.first(where: { $0.name == file.area }),
              let base = resolve(area) else { return nil }
        let scoped = base.startAccessingSecurityScopedResource()
        defer { if scoped { base.stopAccessingSecurityScopedResource() } }

        let url = base.appendingPathComponent(file.name)
        // Belt and braces: the index only ever holds basenames, but a path
        // that escapes the shared folder must never be readable even if one
        // somehow got in.
        guard url.deletingLastPathComponent().standardizedFileURL
                == base.standardizedFileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}
