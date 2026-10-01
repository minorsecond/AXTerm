//
//  ReceivedText.swift
//  AXTerm
//
//  Text that arrives as lines in a session and is kept as a file: a
//  mailbox's marked text download, and the terminal's Capture switch.
//
//  A mailbox types a short text file down the session as plain lines
//  (Docs/PacketBBS.md §14, "Getting a file"). Any terminal can read them,
//  but on the caller's side they only scroll past in the transcript. The
//  mailbox now puts one line before the file and one after, carrying the
//  name and the exact byte count, so a caller running AXTerm can rebuild the
//  file and save it like any other received file. Nothing here is a
//  transfer protocol: there is no handshake and nothing is acknowledged.
//  AX.25 already delivers the lines in order, and the count says whether
//  they all arrived.
//

import Foundation

// MARK: - The marker lines

/// The two lines around a typed-out text file, and how the file becomes lines.
///
/// ```
/// --- BEGIN t3k_text.txt (3010 bytes) ---
/// ...the file, one line per CR...
/// --- END t3k_text.txt ---
/// ```
///
/// **The count.** The file is read as UTF-8 (bytes that are not UTF-8 become
/// U+FFFD, as typed-out files always have), and its line endings are
/// normalized: CRLF and a lone CR each become LF. The count is the byte
/// length of that normalized text, including its final LF if it has one.
/// The text is split at each LF; a final LF ends the last line rather than
/// starting an empty one. Each line then goes out followed by one CR, which
/// is what the mailbox has always sent.
///
/// **Rebuilding it.** The receiver takes each line's bytes as they arrived
/// and puts an LF after each. That is exactly the normalized text, or one
/// byte more when the file had no final newline, in which case that last LF
/// is dropped. Any other total means lines went missing.
///
/// **The count governs, not the END line.** A line in the file that reads
/// like an END marker cannot end the file early, because an END line only
/// counts once the count has been reached. So nothing in the file needs
/// escaping, and a caller without AXTerm sees the file exactly as it is.
nonisolated enum TextDownloadMarkers {
    struct Begin: Equatable, Sendable {
        let name: String
        let byteCount: Int
    }

    /// A BEGIN line announcing more than this is not believed. A mailbox
    /// types out only files under 8 KB; the ceiling is generous for other
    /// software and still stops one mistyped line from opening a capture
    /// that never ends.
    static let maxAnnouncedBytes = 16 * 1024 * 1024

    private static let beginPrefix = "--- BEGIN "
    private static let endPrefix = "--- END "
    private static let suffix = " ---"

    static func beginLine(name: String, byteCount: Int) -> String {
        "\(beginPrefix)\(name) (\(byteCount) \(byteCount == 1 ? "byte" : "bytes"))\(suffix)"
    }

    static func endLine(name: String) -> String {
        "\(endPrefix)\(name)\(suffix)"
    }

    /// The name and count from a BEGIN line, or nil when the line is not one.
    /// The count is read from the end of the line, so a name with spaces or
    /// parentheses of its own still parses.
    static func parseBegin(_ line: String) -> Begin? {
        guard line.hasPrefix(beginPrefix), line.hasSuffix(suffix),
              line.count > beginPrefix.count + suffix.count else { return nil }
        let inner = line.dropFirst(beginPrefix.count).dropLast(suffix.count)
        guard inner.hasSuffix(")"),
              let open = inner.range(of: " (", options: .backwards) else { return nil }
        let name = String(inner[inner.startIndex..<open.lowerBound])
        let count = inner[open.upperBound..<inner.index(before: inner.endIndex)]
        let parts = count.split(separator: " ", omittingEmptySubsequences: false)
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              parts.count == 2, parts[1] == "bytes" || parts[1] == "byte",
              !parts[0].isEmpty, parts[0].count <= 10,
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let bytes = Int(parts[0]), bytes <= maxAnnouncedBytes
        else { return nil }
        return Begin(name: name, byteCount: bytes)
    }

    /// The file as the lines the mailbox sends, and the count for its BEGIN line.
    static func body(of data: Data) -> (lines: [String], byteCount: Int) {
        let utf8 = Array(String(decoding: data, as: UTF8.self).utf8)
        var normalized: [UInt8] = []
        normalized.reserveCapacity(utf8.count)
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            if byte == 0x0D {
                normalized.append(0x0A)
                if index + 1 < utf8.count, utf8[index + 1] == 0x0A { index += 1 }
            } else {
                normalized.append(byte)
            }
            index += 1
        }
        guard !normalized.isEmpty else { return ([], 0) }
        var lines = normalized
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if normalized.last == 0x0A { lines.removeLast() }
        return (lines, normalized.count)
    }

    /// BEGIN, the file's lines, END.
    static func markedLines(name: String, data: Data) -> [String] {
        let body = body(of: data)
        return [beginLine(name: name, byteCount: body.byteCount)]
            + body.lines
            + [endLine(name: name)]
    }
}

// MARK: - Splitting received bytes into lines

/// Cuts a session's received bytes into lines, keeping every line.
///
/// The terminal's own line assembly drops empty lines, which is right for a
/// transcript and wrong for a file: a blank line in a text file is part of
/// it. Here a CR ends a line, an LF straight after a CR belongs to it (even
/// when the two arrive in different frames), and a lone LF ends a line too.
/// That is the same rule the mailbox used to split the file.
nonisolated struct ReceivedLineSplitter: Sendable {
    private var partial = Data()
    private var lastWasCR = false

    mutating func push(_ bytes: Data) -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            switch byte {
            case 0x0D:
                lines.append(partial)
                partial = Data()
                lastWasCR = true
            case 0x0A:
                if !lastWasCR {
                    lines.append(partial)
                    partial = Data()
                }
                lastWasCR = false
            default:
                partial.append(byte)
                lastWasCR = false
            }
        }
        return lines
    }

    /// What arrived after the last line ending, if anything. Used when the
    /// link closes, the same moment the transcript shows its partial line.
    mutating func flush() -> Data? {
        lastWasCR = false
        guard !partial.isEmpty else { return nil }
        defer { partial = Data() }
        return partial
    }
}

// MARK: - Receiving a marked download

/// Follows one station's lines, and rebuilds any marked text file in them.
///
/// Idle until a BEGIN line; then every line is part of the file until an
/// END line for the same name arrives at the point where the count has been
/// reached. The receiver reports a result once per BEGIN: complete, or with
/// a problem when lines went missing, more arrived than the count with no
/// END line, or the link closed first.
nonisolated struct TextDownloadReceiver: Sendable {
    struct Result: Equatable, Sendable {
        let name: String
        let announcedBytes: Int
        /// The rebuilt file, or for an incomplete one, what arrived of it.
        let data: Data
        /// Why the file is incomplete; nil when it arrived whole.
        let problem: String?
    }

    private struct Active: Sendable {
        let begin: TextDownloadMarkers.Begin
        let endLine: Data
        var lines: [Data] = []
        /// Bytes so far, counting an LF after every line.
        var collected = 0
        /// Lines and bytes before the most recent END line that came before
        /// the count was reached. If the count is never met, that END line
        /// was most likely the real one and lines were lost before it.
        var beforeEarlyEnd: (lines: Int, bytes: Int)?
    }

    private var active: Active?

    var isReceiving: Bool { active != nil }

    mutating func receive(line: Data) -> Result? {
        guard var current = active else {
            if let text = String(data: line, encoding: .utf8),
               let begin = TextDownloadMarkers.parseBegin(text) {
                active = Active(begin: begin,
                                endLine: Data(TextDownloadMarkers.endLine(name: begin.name).utf8))
            }
            return nil
        }
        let expected = current.begin.byteCount

        if line == current.endLine {
            let lastLineEmpty = current.lines.last?.isEmpty ?? true
            if current.collected == expected {
                active = nil
                return Result(name: current.begin.name, announcedBytes: expected,
                              data: Self.joined(current.lines), problem: nil)
            }
            if current.collected == expected + 1, !lastLineEmpty {
                // The file had no final newline.
                active = nil
                return Result(name: current.begin.name, announcedBytes: expected,
                              data: Self.joined(current.lines).dropLast(), problem: nil)
            }
            if current.collected < expected {
                current.beforeEarlyEnd = (current.lines.count, current.collected)
            }
        }

        if current.collected + line.count + 1 > expected + 1 {
            // Past the count with no END line: this line is not the file's.
            active = nil
            return incomplete(current, reason: { kept in
                current.beforeEarlyEnd != nil
                    ? "The end line came after \(kept) of \(expected) bytes, so part of the file is missing."
                    : "More than the announced \(expected) bytes arrived with no end line."
            })
        }
        current.lines.append(line)
        current.collected += line.count + 1
        active = current
        return nil
    }

    /// The link closed. Reports what had arrived of a file still coming in.
    mutating func linkClosed() -> Result? {
        guard let current = active else { return nil }
        active = nil
        let expected = current.begin.byteCount
        return incomplete(current, reason: { kept in
            "The link closed after \(kept) of \(expected) bytes."
        })
    }

    private func incomplete(_ current: Active, reason: (Int) -> String) -> Result {
        let cut = current.beforeEarlyEnd ?? (current.lines.count, current.collected)
        let kept = Array(current.lines.prefix(cut.lines))
        return Result(name: current.begin.name, announcedBytes: current.begin.byteCount,
                      data: Self.joined(kept), problem: reason(cut.bytes))
    }

    private static func joined(_ lines: [Data]) -> Data {
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(0x0A)
        }
        return data
    }
}

// MARK: - Capture

/// Everything one station sent while the operator's Capture switch was on.
///
/// Lines are kept as they arrived, each followed by LF, so the file reads
/// the same in any editor however the station ended its lines.
nonisolated struct SessionCapture: Sendable {
    let peer: String
    let startedAt: Date
    private(set) var data = Data()
    private(set) var lineCount = 0

    init(peer: String, startedAt: Date) {
        self.peer = peer
        self.startedAt = startedAt
    }

    mutating func append(line: Data) {
        data.append(line)
        data.append(0x0A)
        lineCount += 1
    }

    /// "K0EPI-8 2026-10-01 0603.txt": the station, then the local date and
    /// time the capture began. No colons, which Finder shows as slashes.
    static func fileName(peer: String, startedAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "\(peer) \(formatter.string(from: startedAt)).txt"
    }
}

// MARK: - Handing it over to be saved

/// A finished download or capture, on its way to the AXTerm Transfers folder.
nonisolated struct ReceivedText: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case download(announcedBytes: Int)
        case capture(lines: Int)
    }

    let source: Source
    /// The station it came from, as the terminal names it.
    let peer: String
    /// The file name to save under, before sanitizing.
    let name: String
    let data: Data
    /// Why a download is incomplete; nil when it arrived whole, and always
    /// nil for a capture.
    let problem: String?

    /// "t3k_text (incomplete).txt": the name an incomplete download is saved
    /// under, so it cannot be mistaken for the whole file in Finder or Files.
    static func incompleteName(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) (incomplete)" : "\(base) (incomplete).\(ext)"
    }
}

/// What happened to a `ReceivedText`, in a line for the operator.
nonisolated struct ReceivedTextReport: Equatable, Sendable {
    let notice: String
    let savedURL: URL?
    let transferID: UUID?
}

/// Where finished downloads and captures go: saved, listed in Transfers,
/// and announced. `SessionCoordinator` is the one in the app.
@MainActor
protocol ReceivedTextSink: AnyObject {
    @discardableResult
    func saveReceivedText(_ text: ReceivedText) -> ReceivedTextReport
}

// MARK: - Following every station's lines

/// The terminal's received text, per station: marked downloads and captures.
///
/// Owned by the terminal model, which feeds it every byte it is handed for a
/// session (after AXDP envelopes and other protocol bytes are taken out) and
/// tells it when a link closes. Keyed by the station's callsign, the same
/// key the terminal's own line buffers use, so two stations' lines never mix.
@MainActor
final class ReceivedTextRecorder {
    weak var sink: ReceivedTextSink?
    /// Called whenever a capture starts or stops.
    var onCaptureChange: (() -> Void)?

    private var splitters: [String: ReceivedLineSplitter] = [:]
    private var downloads: [String: TextDownloadReceiver] = [:]
    private var captures: [String: SessionCapture] = [:]
    /// The name each station's text is filed under: during a relay, the far
    /// station rather than the node carrying its bytes.
    private var labels: [String: String] = [:]

    private static func key(_ peer: String) -> String { peer.uppercased() }

    /// Bytes from a station's session, in the order they were delivered.
    func received(_ bytes: Data, key peer: String, label: String) {
        let key = Self.key(peer)
        labels[key] = label
        var splitter = splitters[key] ?? ReceivedLineSplitter()
        let lines = splitter.push(bytes)
        splitters[key] = splitter
        for line in lines { take(line, key: key) }
    }

    /// A chat message that arrived whole (AXDP). It goes to a capture only:
    /// a mailbox types its files as plain lines.
    func receivedMessage(_ text: String, key peer: String, label: String) {
        let key = Self.key(peer)
        labels[key] = label
        guard captures[key] != nil else { return }
        var splitter = ReceivedLineSplitter()
        var lines = splitter.push(Data(text.utf8))
        if let rest = splitter.flush() { lines.append(rest) }
        for line in lines { captures[key]?.append(line: line) }
    }

    /// The station's link closed. A partial last line counts as a line, a
    /// download still coming in is reported incomplete, and a capture is
    /// stopped and saved.
    func linkClosed(key peer: String) {
        let key = Self.key(peer)
        if var splitter = splitters.removeValue(forKey: key), let rest = splitter.flush() {
            take(rest, key: key)
        }
        if var receiver = downloads.removeValue(forKey: key), let result = receiver.linkClosed() {
            deliver(result, key: key)
        }
        if captures[key] != nil { stopCapture(key: key) }
    }

    // MARK: Capture

    func isCapturing(key peer: String) -> Bool { captures[Self.key(peer)] != nil }

    /// The stations being captured, by uppercased callsign.
    var capturingKeys: Set<String> { Set(captures.keys) }

    func startCapture(key peer: String, label: String, at date: Date = Date()) {
        let key = Self.key(peer)
        guard captures[key] == nil else { return }
        labels[key] = label
        captures[key] = SessionCapture(peer: label, startedAt: date)
        onCaptureChange?()
    }

    /// Stops a capture and saves it. Nil when there was none.
    @discardableResult
    func stopCapture(key peer: String) -> ReceivedTextReport? {
        let key = Self.key(peer)
        guard let capture = captures.removeValue(forKey: key) else { return nil }
        onCaptureChange?()
        guard capture.lineCount > 0 else {
            return ReceivedTextReport(
                notice: "Capture of \(capture.peer) stopped. \(capture.peer) sent nothing, "
                    + "so no file was saved.",
                savedURL: nil, transferID: nil)
        }
        let text = ReceivedText(
            source: .capture(lines: capture.lineCount),
            peer: capture.peer,
            name: SessionCapture.fileName(peer: capture.peer, startedAt: capture.startedAt),
            data: capture.data,
            problem: nil)
        return sink?.saveReceivedText(text)
            ?? ReceivedTextReport(notice: "Capture of \(capture.peer) stopped, but there is nowhere to save it.",
                                  savedURL: nil, transferID: nil)
    }

    // MARK: Private

    private func take(_ line: Data, key: String) {
        captures[key]?.append(line: line)
        var receiver = downloads[key] ?? TextDownloadReceiver()
        let result = receiver.receive(line: line)
        downloads[key] = receiver.isReceiving ? receiver : nil
        if let result { deliver(result, key: key) }
    }

    private func deliver(_ result: TextDownloadReceiver.Result, key: String) {
        // A BEGIN followed by nothing at all leaves nothing worth a file.
        guard !result.data.isEmpty || result.problem == nil else {
            TxLog.debug(.session, "Marked text download ended before any of it arrived", [
                "peer": key, "name": result.name
            ])
            return
        }
        sink?.saveReceivedText(ReceivedText(
            source: .download(announcedBytes: result.announcedBytes),
            peer: labels[key] ?? key,
            name: result.name,
            data: result.data,
            problem: result.problem))
    }
}
