//
//  BBSFileLibrary.swift
//  AXTerm
//
//  Scanning the folders the operator shares, and reading bytes back out.
//

import Foundation
import Combine

/// The bridge between the operator's disk and the catalogue callers see.
///
/// Everything filesystem-shaped lives here. `BBSShell` has no file access at
/// all and resolves names by lookup in the index this produces, so no command
/// the shell implements can reach a file that was not scanned — traversal is
/// impossible by construction rather than by sanitising caller input.
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
        // The scope has to be *open* while the bookmark is minted. On iOS a
        // URL from the document picker arrives scoped-but-closed, and a
        // bookmark taken outside the scope resolves to a URL that reads
        // nothing — the area would list zero files with no error to explain
        // it. Harmless on macOS, where an open-panel URL is already usable
        // and `startAccessing` simply answers false.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: Self.bookmarkOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            try store?.saveFileArea(
                BBSFileArea(name: name, about: about, bookmark: bookmark))
            rescan()
        } catch {
            lastScanError = "Could not share \(url.lastPathComponent): \(error.localizedDescription)"
        }
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

        for area in areas {
            guard let url = resolve(area) else {
                errors.append("\(area.name): folder is no longer reachable")
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                files.append(contentsOf: try scan(area: area, at: url,
                                                  descriptions: descriptions))
            } catch {
                errors.append("\(area.name): \(error.localizedDescription)")
            }
        }

        index = BBSFileIndex(areas: areas, files: files)
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

    private func resolve(_ area: BBSFileArea) -> URL? {
        guard let bookmark = area.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: Self.resolutionOptions,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        // A stale bookmark still resolves; it just wants rewriting. Serving
        // from it is correct, and re-minting is the operator's next open
        // panel rather than something to do behind their back.
        return url
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

    var hasInbox: Bool { inboxName != nil }

    func setInbox(url: URL?) {
        guard let url else {
            try? store?.setUploadInbox(nil)
            refreshInbox()
            return
        }
        // Same reason as `addArea`: minted inside the scope or not at all.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: Self.bookmarkOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            try store?.setUploadInbox(bookmark)
            refreshInbox()
        } catch {
            lastScanError = "Could not use \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func refreshInbox() {
        guard let url = inboxURL() else {
            inboxName = nil
            inboxBytes = 0
            inboxCount = 0
            return
        }
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
        guard let store, let bookmark = try? store.uploadInbox() else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark,
                        options: Self.resolutionOptions,
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
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

        // The name is already a sanitised leaf, but a write outside the inbox
        // must be impossible even if that ever stops being true.
        guard url.deletingLastPathComponent().standardizedFileURL
                == base.standardizedFileURL else { return nil }
        guard (try? data.write(to: url, options: .withoutOverwriting)) != nil else { return nil }

        refreshInbox()
        return final
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
