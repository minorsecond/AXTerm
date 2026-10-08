//
//  BBSFilePicking.swift
//  AXTerm
//
//  What a Files-screen picker is for, and getting dropped files into an area.
//

import Foundation
import UniformTypeIdentifiers

/// What the one file importer on a Files screen is choosing.
///
/// Two `.fileImporter` modifiers on one view behave like two sheets: only
/// one of them ever presents, and the other button silently does nothing.
/// The Mac pane had exactly that, with the upload-inbox picker shadowing
/// "Share a Folder". So each screen holds one importer, and what the pick is
/// for is this value, which also decides what the importer accepts.
nonisolated enum BBSFilePickPurpose: Equatable, Identifiable, Sendable {
    /// A new folder to share; the name sheet follows.
    case shareFolder
    /// Where uploads land.
    case uploadInbox
    /// A folder chosen again for an area whose folder went missing.
    case relocate(area: String)
    /// Files to copy into an area.
    case addFiles(area: String)

    var id: String {
        switch self {
        case .shareFolder: "share"
        case .uploadInbox: "inbox"
        case .relocate(let area): "relocate-\(area)"
        case .addFiles(let area): "add-\(area)"
        }
    }

    var contentTypes: [UTType] {
        switch self {
        case .shareFolder, .uploadInbox, .relocate: [.folder]
        case .addFiles: [.item]
        }
    }

    var allowsMultipleSelection: Bool {
        if case .addFiles = self { return true }
        return false
    }
}

/// What the one importer on a Files screen is doing: open or not, and what
/// the open pick is for.
///
/// SwiftUI closes a file importer by setting its `isPresented` binding to
/// false before it calls the completion handler. Keeping the purpose in the
/// same state that binding clears meant the handler found nothing to act on,
/// and on 2026-10-01 "Share a Folder" closed the panel and shared nothing,
/// silently. Closing the panel here only closes it; the purpose stays until
/// the completion handler takes it with `finish()`.
nonisolated struct BBSFilePicker: Equatable, Sendable {
    private(set) var isPresented = false
    private(set) var purpose: BBSFilePickPurpose?

    mutating func begin(_ purpose: BBSFilePickPurpose) {
        self.purpose = purpose
        isPresented = true
    }

    /// The importer's binding setter: the panel went away.
    mutating func panelClosed() {
        isPresented = false
    }

    /// What the pick was for, handed out once, whether or not the panel
    /// already closed.
    mutating func finish() -> BBSFilePickPurpose? {
        isPresented = false
        defer { purpose = nil }
        return purpose
    }

    var contentTypes: [UTType] { purpose?.contentTypes ?? [.folder] }
    var allowsMultipleSelection: Bool { purpose?.allowsMultipleSelection ?? false }
}

/// What the view does next after a pick.
nonisolated enum BBSFilePickResult: Equatable, Sendable {
    /// Ask for the new area's name before sharing it.
    case nameNewArea(URL)
    /// Done; tell the operator this, if anything.
    case finished(message: String?)
    /// The other files are in (and `message` says so); these photos wait
    /// for the operator to choose their size.
    case sizePhotos([BBSPendingPhoto], message: String?)
}

/// A photo on its way into an area, held until the operator picks its size.
nonisolated struct BBSPendingPhoto: Identifiable, Equatable, Sendable {
    let id = UUID()
    let name: String
    let data: Data
    let area: String
}

/// Photos added to an area are sized before callers can list them
/// (operator, 2026-10-07, downloading from the BBS at a park). A phone photo
/// is megabytes, which is hours of a shared channel; the operator picks the
/// size from the same preview Send File uses.
nonisolated enum BBSPhotoIntake {
    /// An image bigger than the Small size is worth asking about. A smaller
    /// one has nothing to gain and goes straight in.
    static func wantsSizing(name: String, byteCount: Int) -> Bool {
        ImageShrinker.isImage(named: name) && byteCount > (PhotoSendSize.small.byteBudget ?? 0)
    }

    /// Splits picked files into photos to size (read now, while the picker's
    /// access lasts) and everything else.
    static func split(_ urls: [URL], area: String) -> (photos: [BBSPendingPhoto], others: [URL]) {
        var photos: [BBSPendingPhoto] = []
        var others: [URL] = []
        for url in urls {
            if let photo = pending(at: url, area: area) {
                photos.append(photo)
            } else {
                others.append(url)
            }
        }
        return (photos, others)
    }

    /// The photo at `url` when it wants sizing, read into memory.
    static func pending(at url: URL, area: String) -> BBSPendingPhoto? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard wantsSizing(name: url.lastPathComponent, byteCount: size),
              let data = try? Data(contentsOf: url), ImageShrinker.isImage(data) else { return nil }
        return BBSPendingPhoto(name: url.lastPathComponent, data: data, area: area)
    }

    /// Photos picked from the photo library for an area (operator,
    /// 2026-10-08). They arrive as bytes with no name, so each is named for
    /// when it was picked (`PickedPhotos.name`). Then the same rule as from
    /// Files: one bigger than Small waits for its size, a smaller one goes
    /// straight in, and one whose bytes did not load is said so.
    @MainActor
    static func addFromLibrary(_ photos: [(data: Data?, contentType: UTType?)], to area: String,
                               library: BBSFileLibrary, at date: Date = Date(),
                               timeZone: TimeZone = .current)
        -> (waiting: [BBSPendingPhoto], outcomes: [BBSFileLibrary.AddOutcome]) {
        var waiting: [BBSPendingPhoto] = []
        var outcomes: [BBSFileLibrary.AddOutcome] = []
        for (index, photo) in photos.enumerated() {
            let name = PickedPhotos.name(index: index, of: photos.count, contentType: photo.contentType,
                                         at: date, timeZone: timeZone)
            guard let data = photo.data else {
                outcomes.append(.refused(name: name, reason: "it could not be read"))
                continue
            }
            if wantsSizing(name: name, byteCount: data.count), ImageShrinker.isImage(data) {
                waiting.append(BBSPendingPhoto(name: name, data: data, area: area))
            } else {
                outcomes.append(library.addFile(named: name, data: data, to: area))
            }
        }
        return (waiting, outcomes)
    }

    /// Puts the photo in its area as the operator chose it.
    @MainActor
    static func add(_ photo: BBSPendingPhoto, as prepared: PhotoSendChoice.Prepared,
                    library: BBSFileLibrary) -> BBSFileLibrary.AddOutcome {
        library.addFile(named: prepared.name, data: prepared.data, to: photo.area)
    }
}

@MainActor
enum BBSFilePick {
    /// Carries out a pick. The same routing for the Mac pane and the iOS
    /// screens, so a purpose cannot do one thing on one platform and another
    /// on the other.
    static func apply(_ purpose: BBSFilePickPurpose, urls: [URL],
                      library: BBSFileLibrary) -> BBSFilePickResult {
        switch purpose {
        case .shareFolder:
            guard let url = urls.first else { return .finished(message: nil) }
            return .nameNewArea(url)
        case .uploadInbox:
            guard let url = urls.first else { return .finished(message: nil) }
            library.setInbox(url: url)
            return .finished(message: nil)
        case .relocate(let area):
            guard let url = urls.first else { return .finished(message: nil) }
            library.relocateArea(name: area, url: url)
            return .finished(message: nil)
        case .addFiles(let area):
            let (photos, others) = BBSPhotoIntake.split(urls, area: area)
            let outcomes = others.isEmpty ? [] : library.addFiles(others, to: area)
            let message = BBSAddFilesSummary.message(for: outcomes, area: area)
            return photos.isEmpty ? .finished(message: message) : .sizePhotos(photos, message: message)
        }
    }
}

/// Files dropped on an area, from Finder, the Files app or another app.
///
/// A file URL is taken where the drag offers one (Finder does); otherwise
/// the file's own representation is copied out of the provider, which is
/// what an iPad drag from Files or Photos offers. Either way the bytes go
/// through `BBSFileLibrary`, which decides the name and refuses what it
/// would never serve.
enum BBSFileDrop {
    static let acceptedTypes: [UTType] = [.fileURL, .item]

    /// Loads every provider and reports all the outcomes together, once.
    @MainActor
    static func add(_ providers: [NSItemProvider], to area: String,
                    library: BBSFileLibrary,
                    completion: @escaping @MainActor (String?, [BBSPendingPhoto]) -> Void) {
        guard !providers.isEmpty else { return }
        let collector = Collector(expected: providers.count) { outcomes, photos in
            completion(BBSAddFilesSummary.message(for: outcomes, area: area), photos)
        }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let suggested = provider.suggestedName ?? "A file"
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    Task { @MainActor in
                        guard let url else {
                            collector.add([.refused(name: suggested,
                                                    reason: "it could not be read")])
                            return
                        }
                        if let photo = BBSPhotoIntake.pending(at: url, area: area) {
                            collector.hold(photo)
                        } else {
                            collector.add(library.addFiles([url], to: area))
                        }
                    }
                }
            } else {
                loadRepresentation(of: provider) { name, data, failure in
                    Task { @MainActor in
                        if let data, BBSPhotoIntake.wantsSizing(name: name, byteCount: data.count),
                           ImageShrinker.isImage(data) {
                            collector.hold(BBSPendingPhoto(name: name, data: data, area: area))
                        } else if let data {
                            collector.add([library.addFile(named: name, data: data, to: area)])
                        } else {
                            collector.add([.refused(name: name, reason: failure ?? "it could not be read")])
                        }
                    }
                }
            }
        }
    }

    /// Copies a dropped file's bytes out of the temporary file the provider
    /// lends, which is deleted when the callback returns.
    private static func loadRepresentation(
        of provider: NSItemProvider,
        done: @escaping @Sendable (String, Data?, String?) -> Void
    ) {
        let fallbackName = provider.suggestedName ?? "Dropped file"
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
            guard let url else {
                done(fallbackName, nil, "it could not be read")
                return
            }
            let name = url.lastPathComponent.isEmpty ? fallbackName : url.lastPathComponent
            // Checked before reading, so a large drop is refused without
            // being loaded into memory first.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= BBSFileLibrary.defaultMaxFileBytes else {
                done(name, nil, "it is over the "
                     + "\(BBSFileIndex.size(BBSFileLibrary.defaultMaxFileBytes)) limit, "
                     + "so callers would never see it")
                return
            }
            done(name, try? Data(contentsOf: url), nil)
        }
    }

    /// Gathers outcomes from providers that load in any order.
    @MainActor
    private final class Collector {
        private var remaining: Int
        private var outcomes: [BBSFileLibrary.AddOutcome] = []
        private var photos: [BBSPendingPhoto] = []
        private let finish: @MainActor ([BBSFileLibrary.AddOutcome], [BBSPendingPhoto]) -> Void

        init(expected: Int,
             finish: @escaping @MainActor ([BBSFileLibrary.AddOutcome], [BBSPendingPhoto]) -> Void) {
            remaining = expected
            self.finish = finish
        }

        func add(_ more: [BBSFileLibrary.AddOutcome]) {
            outcomes += more
            settle()
        }

        /// A photo that waits for its size instead of going in now.
        func hold(_ photo: BBSPendingPhoto) {
            photos.append(photo)
            settle()
        }

        private func settle() {
            remaining -= 1
            if remaining == 0 { finish(outcomes, photos) }
        }
    }
}
