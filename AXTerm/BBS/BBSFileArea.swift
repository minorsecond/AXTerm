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
    /// Whether trusted callers may upload straight into this area (home
    /// retest finding 11). Off unless the operator switches it on: anything
    /// in an area is served under the operator's callsign.
    var acceptsTrustedUploads = false

    var id: String { name }

    init(name: String, about: String = "", bookmark: Data? = nil, acceptsTrustedUploads: Bool = false) {
        self.name = BBSFileArea.normalize(name)
        self.about = about
        self.bookmark = bookmark
        self.acceptsTrustedUploads = acceptsTrustedUploads
    }

    /// Area names are typed on a radio link by someone who cannot see the
    /// screen they are typing into. Case and spaces are not worth honoring.
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
/// rather than by sanitizing.
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

/// The catalog, and every question a caller can ask of it.
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
        /// No name matches exactly, and the request starts more than one:
        /// the caller types more of the one they want.
        case several(names: [String])
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

        // An exact name first; otherwise the start of one, so a caller can
        // fetch a long name without typing all of it (park rehearsal
        // 2026-10-08).
        var matches = candidates.filter { $0.name.lowercased() == wanted }
        if matches.isEmpty {
            matches = candidates.filter { $0.name.lowercased().hasPrefix(wanted) }
            let names = Set(matches.map(\.name))
            if names.count > 1 { return .several(names: names.sorted()) }
        }
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

nonisolated struct BBSArrivingUpload: Equatable, Sendable {
    var name: String
    var from: String
    var bytesDone: Int
    var totalBytes: Int
}

/// A file in the upload inbox (`BBSFileLibrary.uploads`).
nonisolated struct BBSUpload: Equatable, Sendable, Identifiable {
    /// Its name in the inbox.
    var name: String
    var byteCount: Int
    /// When the mailbox took it, or for a file put in the folder some other
    /// way, the file's own date.
    var receivedAt: Date
    /// The caller who sent it; nil for a file that did not come from one.
    var from: String?
    var id: String { name }

    /// The Files sidebar tag for the uploads list. Area names are normalized
    /// to letters, digits and dashes, so this can never be one.
    static let listTag = "\u{1}uploads"
}

/// Who may upload straight into an area that allows it (home retest
/// finding 11).
nonisolated enum BBSTrust {
    /// The operator's own callsign at any SSID, or a listed callsign. A
    /// listed callsign without an SSID covers every SSID of it; with one,
    /// only that station.
    static func isTrusted(_ caller: String, station: String, list: [String]) -> Bool {
        let call = caller.uppercased().trimmingCharacters(in: .whitespaces)
        let base = Self.base(call)
        if !base.isEmpty, base == Self.base(station.uppercased()) { return true }
        return list.contains { entry in
            let listed = entry.uppercased().trimmingCharacters(in: .whitespaces)
            return listed.contains("-") ? listed == call : listed == base
        }
    }

    /// A list entry from what the operator typed: a callsign of letters
    /// and digits, with an SSID from 0 to 15 or none. Nil for anything else.
    static func entry(from text: String) -> String? {
        let call = text.trimmingCharacters(in: .whitespaces).uppercased()
        let parts = call.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let base = parts.first,
              (3...6).contains(base.count), base.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              base.contains(where: \.isNumber) else { return nil }
        if parts.count == 2 {
            guard let ssid = Int(parts[1]), (0...15).contains(ssid) else { return nil }
        }
        return call
    }

    /// "K0EPI (you), W0ARP": who may upload into an area that allows it.
    static func summary(station: String, list: [String]) -> String {
        let you = base(station.uppercased())
        return ([you.isEmpty ? "Your own callsign" : you + " (you)"] + list).joined(separator: ", ")
    }

    private static func base(_ callsign: String) -> String {
        String(callsign.split(separator: "-").first ?? "")
    }
}

/// Where an upload goes when the caller named an area with `U PARK`: into
/// the area for a trusted caller and an area that takes their uploads, the
/// inbox for everyone else, who is told so (home retest finding 11).
nonisolated struct BBSUploadTarget: Equatable, Sendable {
    /// The area it goes into, or nil for the inbox.
    let area: String?
    /// What the caller is told before "Ready", or nil when they named no area.
    let note: String?

    static func resolve(area: String?, caller: String, station: String, trusted: [String],
                        areas: [BBSFileArea]) -> BBSUploadTarget {
        guard let area else { return BBSUploadTarget(area: nil, note: nil) }
        guard let named = areas.first(where: { $0.name == area }) else {
            return BBSUploadTarget(area: nil, note: "There is no area called \(area). Uploads go to the sysop's inbox.")
        }
        // Not trusted and switched off read the same: a caller has no need
        // to learn which it was.
        guard named.acceptsTrustedUploads, BBSTrust.isTrusted(caller, station: station, list: trusted) else {
            return BBSUploadTarget(area: nil, note: "Uploads go to the sysop's inbox, not into \(area).")
        }
        return BBSUploadTarget(area: area, note: "Your upload goes straight into \(area).")
    }
}
