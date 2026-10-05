//
//  RawTerminalInput.swift
//  AXTerm
//
//  Raw terminal mode for the compose row. See Docs/TerminalInputModes.md.
//

import Combine
import Foundation

/// How the compose row sends what is typed in a connected session.
nonisolated enum TerminalInputMode: String, CaseIterable, Identifiable {
    /// Edit a line, send it with its CR on Return.
    case line
    /// Send keys as they are typed.
    case raw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .line: return "Line"
        case .raw: return "Raw"
        }
    }
}

/// Holds raw mode's buffer and echo for the terminal on screen.
///
/// The terminal view sends what this hands back. The idle timer lives in the
/// view as a task keyed on `flushDeadline`, which restarts with every key.
@MainActor
final class RawTerminalInput: ObservableObject {

    @Published var mode: TerminalInputMode = .line
    @Published private(set) var coalescer = RawKeyCoalescer(maxChunk: AX25Constants.defaultPacketLength)

    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The session's live paclen, the longest chunk raw mode sends.
    var paclen: Int {
        get { coalescer.maxChunk }
        set { coalescer.maxChunk = max(1, newValue) }
    }

    var echoLine: String { coalescer.echoLine }
    var flushDeadline: Date? { coalescer.flushDeadline }

    func input(_ key: RawKeyCoalescer.Key) -> RawKeyCoalescer.Output {
        coalescer.input(key, at: now())
    }

    func flushIfIdle() -> Data? {
        coalescer.flushIfIdle(at: now())
    }

    func flushAll() -> Data? {
        coalescer.flushAll()
    }

    /// Back to Line mode. Returns what was still buffered, for the caller to
    /// send before anything typed in Line mode.
    func leaveRawMode() -> Data? {
        mode = .line
        return coalescer.flushAll()
    }

    /// The far end is gone: nothing buffered can be sent, and the next
    /// session starts on a clean line.
    func sessionEnded() {
        _ = coalescer.flushAll()
        coalescer.resetEcho()
    }

    /// A partial received line as the raw field shows it: control bytes
    /// dropped, a tab as one space.
    nonisolated static func promptText(for data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar in
            if scalar == "\t" { return " " }
            if scalar.value < 0x20 || scalar.value == 0x7F { return nil }
            return scalar
        }))
    }
}
