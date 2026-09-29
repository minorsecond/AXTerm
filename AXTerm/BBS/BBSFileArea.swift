//
//  BBSFileArea.swift
//  AXTerm
//
//  What a caller can download, and what it will cost them in airtime.
//

import Foundation

/// A folder the operator has chosen to share, under a short name callers type.
nonisolated struct BBSFileArea: Equatable, Sendable, Identifiable {
    /// Short, typed at the prompt: `F OPS`. Uppercased and space-free.
    var name: String
    /// One line, shown beside the area in `F`.
    var about: String
    /// Security-scoped bookmark for the folder. The app is sandboxed, so a
    /// path alone stops working at the next launch — see `BBSFileLibrary`.
    var bookmark: Data?

    var id: String { name }

    init(name: String, about: String = "", bookmark: Data? = nil) {
        self.name = BBSFileArea.normalize(name)
        self.about = about
        self.bookmark = bookmark
    }

    /// Area names are typed on a radio link by someone who cannot see the
    /// screen they are typing into. Case and spaces are not worth honouring.
    static func normalize(_ name: String) -> String {
        name.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

/// One shareable file, as the index sees it.
///
/// Deliberately holds **no path**. Resolution happens by lookup in the index
/// (`BBSFileIndex.resolve`), never by joining a caller's input onto a
/// directory — which is what makes traversal impossible by construction
/// rather than by sanitising.
nonisolated struct BBSSharedFile: Equatable, Sendable, Identifiable {
    var area: String
    /// Basename as it appears on disk, and as callers type it.
    var name: String
    var byteCount: Int
    var modifiedAt: Date
    /// The operator's one-line description. A filename alone tells a caller
    /// nothing, and on a link this slow they cannot afford to download one to
    /// find out what it is.
    var about: String

    var id: String { "\(area)/\(name)" }

    /// Whether `V` can type it out instead of running a transfer protocol.
    var isText: Bool { BBSSharedFile.textExtensions.contains(fileExtension) }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    /// Types worth reading inline. Conservative on purpose: typing a binary
    /// down a terminal session wastes airtime and can wedge the caller's
    /// software.
    static let textExtensions: Set<String> = [
        "txt", "md", "csv", "tsv", "log", "asc", "cfg", "ini", "conf",
        "json", "xml", "yml", "yaml", "sql", "nfo", "list"
    ]
}

/// The catalogue, and every question a caller can ask of it.
///
/// Built by scanning; the shell only ever reads it. That split is what keeps
/// the safety property checkable: the shell has no filesystem access at all,
/// so no command it implements can reach outside what was scanned.
nonisolated struct BBSFileIndex: Equatable, Sendable {

    var areas: [BBSFileArea]
    var files: [BBSSharedFile]

    init(areas: [BBSFileArea] = [], files: [BBSSharedFile] = []) {
        self.areas = areas
        self.files = files
    }

    var isEmpty: Bool { files.isEmpty }

    func files(in area: String) -> [BBSSharedFile] {
        let key = BBSFileArea.normalize(area)
        return files.filter { $0.area == key }.sorted { $0.name < $1.name }
    }

    /// Resolves what a caller typed to exactly one file, or explains why not.
    ///
    /// Accepts `NAME` and `AREA/NAME`. Matching is case-insensitive because
    /// the caller is typing blind on a radio link.
    enum Resolution: Equatable, Sendable {
        case found(BBSSharedFile)
        case notFound
        /// The same name exists in more than one area, so the caller must say
        /// which. Listing the areas is the whole point of the answer.
        case ambiguous(areas: [String])
    }

    func resolve(_ request: String) -> Resolution {
        let trimmed = request.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .notFound }

        // `AREA/NAME` narrows to one area first. Note this is a *lookup key*,
        // not a path: "../../etc/passwd" simply matches nothing.
        let parts = trimmed.split(separator: "/", maxSplits: 1)
        let candidates: [BBSSharedFile]
        let wanted: String
        if parts.count == 2 {
            let area = BBSFileArea.normalize(String(parts[0]))
            wanted = String(parts[1]).lowercased()
            candidates = files.filter { $0.area == area }
        } else {
            wanted = trimmed.lowercased()
            candidates = files
        }

        let matches = candidates.filter { $0.name.lowercased() == wanted }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default:
            return .ambiguous(areas: matches.map(\.area).sorted())
        }
    }

    // MARK: - Rendering

    /// Sizes in K and M, never bytes.
    ///
    /// A caller reading `146432` has to do arithmetic to learn anything; the
    /// column also costs airtime on every row it appears in.
    static func size(_ bytes: Int) -> String {
        switch bytes {
        case ..<1_024: return "\(max(bytes, 0))B"
        case ..<1_024_000:
            return "\(Int((Double(bytes) / 1024.0).rounded()))K"
        default:
            let megabytes = Double(bytes) / (1024.0 * 1024.0)
            return megabytes < 10
                ? String(format: "%.1fM", megabytes)
                : "\(Int(megabytes.rounded()))M"
        }
    }

    /// How long this will take on the air, which is the number that actually
    /// decides whether a caller wants the file.
    ///
    /// Bytes are not a useful unit on a link this slow: 146 KB sounds small
    /// and is twenty-five minutes of somebody else's channel.
    static func duration(bytes: Int, bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "?" }
        let seconds = Double(bytes) / bytesPerSecond
        switch seconds {
        case ..<60: return "<1m"
        case ..<3_600: return "\(Int((seconds / 60).rounded(.up)))m"
        case ..<86_400:
            let hours = Int(seconds / 3_600)
            let minutes = Int((seconds - Double(hours) * 3_600) / 60)
            return minutes == 0 ? "\(hours)h" : "\(hours)h\(minutes)m"
        default: return ">1d"
        }
    }
}
