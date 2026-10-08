import Foundation

/// File names in what a station sends, so a tap can fill in the download
/// command (park rehearsal 2026-10-08, finding 28). Typing `D` and a name
/// like Photo-20261008-052732.jpg on a phone is slow, and one wrong
/// character costs another exchange on the air.
///
/// Hosts list files in their own formats: AXTerm's NAME / SIZE / TIME table,
/// DOS-style `README.TXT  1234` from older BBSes and nodes. What they share
/// is a name with an extension, so that is what counts: a run of name
/// characters, a dot, and an extension of one to five letters and digits
/// starting with a letter. Names with no extension, or with spaces in them,
/// are left for the operator to type.
nonisolated enum FileNameScanner {
    /// Extensions that make a web address, not a file.
    private static let webEndings: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "io", "us", "uk", "ca", "de", "info", "biz"
    ]

    private static let shape = /[A-Za-z0-9_][A-Za-z0-9_\-+~.]*\.[A-Za-z][A-Za-z0-9]{0,4}/

    static func names(in text: String) -> [(range: Range<String.Index>, name: String)] {
        var hits: [(range: Range<String.Index>, name: String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            if let range = fileName(in: text, token: start..<index) {
                hits.append((range, String(text[range])))
            }
        }
        return hits
    }

    /// The token with its surrounding punctuation trimmed, when what is left
    /// is a file name.
    private static func fileName(in text: String, token: Range<String.Index>) -> Range<String.Index>? {
        let word = text[token]
        // An address, a URL or a path is not a name to download.
        guard !word.contains("@"), !word.contains("/"), !word.contains(":") else { return nil }
        var lower = token.lowerBound
        var upper = token.upperBound
        while lower < upper, "(\"'[<{".contains(text[lower]) {
            lower = text.index(after: lower)
        }
        while lower < upper, ".,;:)!?\"']>}".contains(text[text.index(before: upper)]) {
            upper = text.index(before: upper)
        }
        let candidate = text[lower..<upper]
        guard candidate.wholeMatch(of: shape) != nil,
              let dot = candidate.lastIndex(of: ".") else { return nil }
        // Two characters before the dot at least: "e.g" and "i.e" are not files.
        guard candidate.distance(from: candidate.startIndex, to: dot) >= 2 else { return nil }
        let ending = candidate[candidate.index(after: dot)...].lowercased()
        guard !webEndings.contains(ending) else { return nil }
        return lower..<upper
    }
}

/// The link a file name carries in the Session view. It never leaves the
/// app: `ConsoleView` catches it and fills in the download command.
nonisolated enum ConsoleFileLink {
    static let scheme = "axterm-file"

    static func url(for name: String) -> URL? {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: "\(scheme):\(encoded)")
    }

    /// The file name a link carries, or nil if this is somebody else's URL.
    static func name(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let raw = url.absoluteString.dropFirst(scheme.count + 1)
        return raw.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The command that downloads a file from a station.
///
/// AXTerm's mailbox and most BBSes take `D <name>`; other hosts want
/// `DOWNLOAD`, `GET` or `R`. Rather than guess per brand of host, AXTerm
/// keeps the word the operator last used to fetch a file from that station.
nonisolated enum DownloadCommand {
    static let defaultVerb = "D"

    /// Commands that take a file name and are not downloads.
    private static let notDownloads: Set<String> = ["U", "UP", "UPLOAD", "K", "KILL", "DEL", "DELETE", "RM"]

    /// The command word, when `typed` is one word and a file name.
    static func verb(learnedFrom typed: String) -> String? {
        let words = typed.split(whereSeparator: \.isWhitespace)
        guard words.count == 2 else { return nil }
        let verb = words[0].uppercased()
        guard (1...10).contains(verb.count), verb.allSatisfy(\.isLetter), !notDownloads.contains(verb)
        else { return nil }
        let name = String(words[1])
        guard let hit = FileNameScanner.names(in: name).first, hit.name == name else { return nil }
        return verb
    }

    static func line(verb: String, name: String) -> String {
        "\(verb) \(name)"
    }
}

/// The download word used with each station, kept across launches.
@MainActor
final class DownloadCommandMemory {
    static let shared = DownloadCommandMemory()
    private static let key = "downloadCommandVerbs"

    private let defaults: UserDefaults
    private var verbs: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        verbs = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// Notes the word if `typed`, sent to `station`, was a download.
    func learn(typed: String, to station: String) {
        guard let verb = DownloadCommand.verb(learnedFrom: typed) else { return }
        let key = Self.normalize(station)
        guard !key.isEmpty, verbs[key] != verb else { return }
        verbs[key] = verb
        defaults.set(verbs, forKey: Self.key)
    }

    func command(for name: String, station: String) -> String {
        DownloadCommand.line(verb: verbs[Self.normalize(station)] ?? DownloadCommand.defaultVerb, name: name)
    }

    private static func normalize(_ station: String) -> String {
        station.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
