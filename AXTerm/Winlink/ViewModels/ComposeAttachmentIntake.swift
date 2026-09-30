import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A file on its way into a message: a name and its bytes, already read.
///
/// Read before it reaches the view model so that a file the app loses access
/// to (a drag that ends, a security scope released, a temporary copy the
/// system deletes) cannot fail later, halfway through building a message.
nonisolated struct ComposeIncomingFile: Equatable, Sendable {
    var name: String
    var data: Data
}

/// Getting files into a compose window from drag and drop, the clipboard and
/// the photo library.
///
/// Each source describes what it offers differently. A Finder drag offers a
/// file URL; a drag out of the Files app on an iPad offers the file's own
/// type with a suggested name; a copied screenshot offers PNG bytes and no
/// name at all. The decisions (which representation to ask for, and what to
/// call the result) are made here as plain functions, so they can be tested
/// without a drag session. Loading is the only part that has to touch
/// `NSItemProvider`.
nonisolated enum ComposeAttachmentIntake {

    /// How to read one dragged or pasted item.
    enum Route: Equatable, Sendable {
        /// Ask for a file URL and read the file it points at.
        case fileURL
        /// Ask for a file of this type and read that.
        case file(typeIdentifier: String)
        /// Nothing here is a file. Text belongs in the body, not in an
        /// attachment.
        case unsupported
    }

    /// Chooses how to read an item from the types it offers.
    ///
    /// A file URL wins when present because it carries the real name and the
    /// exact bytes. Otherwise the first data type is used, in the order the
    /// source listed them, which is its own order of fidelity (an iPhone photo
    /// lists HEIC before JPEG). Text and URLs count only when the item also
    /// has a name: a `.txt` dragged from Files is a file to attach, and a
    /// sentence dragged out of Notes is not.
    static func route(for typeIdentifiers: [String], hasSuggestedName: Bool) -> Route {
        if typeIdentifiers.contains(UTType.fileURL.identifier) { return .fileURL }
        for identifier in typeIdentifiers {
            guard let type = UTType(identifier), type.conforms(to: .data) else { continue }
            let isText = type.conforms(to: .text) || type.conforms(to: .url)
            if isText && !hasSuggestedName { continue }
            return .file(typeIdentifier: identifier)
        }
        return .unsupported
    }

    /// The name for an item that arrived as bytes: its suggested name when it
    /// has one, given the type's extension if it has none of its own.
    static func name(suggested: String?, contentType: UTType?, fallbackStem: String) -> String {
        let trimmed = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = trimmed.isEmpty ? fallbackStem : trimmed
        let safeStem = sanitized(stem)
        guard (safeStem as NSString).pathExtension.isEmpty,
              let ext = contentType?.preferredFilenameExtension else { return safeStem }
        return safeStem + "." + ext
    }

    /// The name for the `index`th photo (counting from 1) picked from the
    /// library or taken with the camera, which come with no names.
    static func photoName(index: Int, contentType: UTType?) -> String {
        let ext = contentType?.preferredFilenameExtension ?? "jpg"
        return "Photo \(index).\(ext)"
    }

    /// `name`, or `name` with a number before its extension, whichever is not
    /// already in `existing`. Two attachments with one name leave the
    /// recipient guessing which is which, and some clients save one over the
    /// other.
    static func uniqueName(_ name: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        // "Photo 1.jpg" becomes "Photo 2.jpg", not "Photo 1 2.jpg".
        var number = 2
        if let space = stem.lastIndex(of: " "),
           let trailing = Int(stem[stem.index(after: space)...]) {
            stem = String(stem[..<space])
            number = trailing + 1
        }
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }

    /// Path separators and colons out of a name that came from somewhere
    /// else. B2F carries the name as a header value, and a slash in it would
    /// make the recipient's client write outside its attachments folder.
    static func sanitized(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Attachment" : cleaned
    }

    /// Reads a file the app may only have been lent, releasing the loan
    /// afterwards.
    static func read(_ url: URL) -> ComposeIncomingFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ComposeIncomingFile(name: url.lastPathComponent, data: data)
    }

    /// Reads dragged or pasted items. Returns what it could read and the
    /// names (or descriptions) of what it could not, so the operator hears
    /// about a file that did not make it rather than finding it missing
    /// after the message has gone.
    static func load(_ providers: [NSItemProvider]) async -> (files: [ComposeIncomingFile], failures: [String]) {
        var files: [ComposeIncomingFile] = []
        var failures: [String] = []
        for (offset, provider) in providers.enumerated() {
            let label = provider.suggestedName ?? "item \(offset + 1)"
            switch route(for: provider.registeredTypeIdentifiers,
                         hasSuggestedName: provider.suggestedName != nil) {
            case .unsupported:
                failures.append(label)
            case .fileURL:
                if let file = await loadFileURL(provider) {
                    files.append(file)
                } else {
                    failures.append(label)
                }
            case .file(let identifier):
                if let file = await loadFile(provider, typeIdentifier: identifier,
                                             fallbackStem: offset == 0 ? "Pasted" : "Pasted \(offset + 1)") {
                    files.append(file)
                } else {
                    failures.append(label)
                }
            }
        }
        return (files, failures)
    }

    /// Image types taken from the clipboard when it holds a picture rather
    /// than a file, best first: the formats a screenshot or a copied photo
    /// is likely to carry, with TIFF last because it is the largest.
    static let pastedImageTypes: [UTType] = [.png, .jpeg, .heic, .tiff]

    /// Reads whatever files or images are on the clipboard. Called from a
    /// menu item the operator chose, so on iOS the system's paste prompt is
    /// expected rather than a surprise.
    @MainActor
    static func pasteboardContents() async -> (files: [ComposeIncomingFile], failures: [String]) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            var files: [ComposeIncomingFile] = []
            var failures: [String] = []
            for url in urls {
                if let file = read(url) { files.append(file) } else { failures.append(url.lastPathComponent) }
            }
            return (files, failures)
        }
        for type in pastedImageTypes {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)) {
                return ([ComposeIncomingFile(name: name(suggested: nil, contentType: type, fallbackStem: "Pasted"),
                                             data: data)], [])
            }
        }
        return ([], [])
        #else
        return await load(UIPasteboard.general.itemProviders)
        #endif
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> ComposeIncomingFile? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url.flatMap(read))
            }
        }
    }

    /// The temporary file the provider hands over is deleted when the
    /// callback returns, so it is read inside the callback.
    private static func loadFile(_ provider: NSItemProvider, typeIdentifier: String,
                                 fallbackStem: String) async -> ComposeIncomingFile? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                // A provider's temporary file often has a made-up name; the
                // suggested name is the one the operator saw.
                let name = Self.name(suggested: suggested, contentType: UTType(typeIdentifier),
                                     fallbackStem: fallbackStem)
                continuation.resume(returning: ComposeIncomingFile(name: name, data: data))
            }
        }
    }
}
