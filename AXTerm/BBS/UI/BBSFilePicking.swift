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
            let outcomes = library.addFiles(urls, to: area)
            return .finished(message: BBSAddFilesSummary.message(for: outcomes, area: area))
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
                    completion: @escaping @MainActor (String?) -> Void) {
        guard !providers.isEmpty else { return }
        let collector = Collector(expected: providers.count) { outcomes in
            completion(BBSAddFilesSummary.message(for: outcomes, area: area))
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
                        collector.add(library.addFiles([url], to: area))
                    }
                }
            } else {
                loadRepresentation(of: provider) { name, data, failure in
                    Task { @MainActor in
                        if let data {
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
        private let finish: @MainActor ([BBSFileLibrary.AddOutcome]) -> Void

        init(expected: Int, finish: @escaping @MainActor ([BBSFileLibrary.AddOutcome]) -> Void) {
            remaining = expected
            self.finish = finish
        }

        func add(_ more: [BBSFileLibrary.AddOutcome]) {
            outcomes += more
            remaining -= 1
            if remaining == 0 { finish(outcomes) }
        }
    }
}
