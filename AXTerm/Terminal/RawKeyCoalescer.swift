//
//  RawKeyCoalescer.swift
//  AXTerm
//
//  Raw terminal mode's keys-to-bytes model. See Docs/TerminalInputModes.md.
//

import Foundation

/// Turns keys typed in raw mode into the chunks a connected session sends,
/// and keeps the echo of the line being typed.
///
/// It has no clock or timer of its own: the caller passes the time of each
/// key and asks `flushIfIdle(at:)` when `flushDeadline` comes round, which
/// keeps every rule here testable without waiting.
nonisolated struct RawKeyCoalescer: Equatable {

    enum Key: Equatable {
        /// Typed or pasted text. LF and CR LF become one CR.
        case text(String)
        case returnKey
        case backspace
        case tab
        case escape
        /// A C0 control byte, 0x00 to 0x1F, from Ctrl and a key.
        case control(UInt8)
    }

    struct Output: Equatable {
        /// Chunks to send now, in order. None is longer than `maxChunk`.
        var chunks: [Data] = []
        /// Echo lines ended by a CR in this input, in order.
        var committedLines: [String] = []
    }

    /// How long typing must stop before a partial buffer is sent. TNC-2's
    /// transparent mode sends on `PACTIME AFTER 10`, 10 × 100 ms.
    static let idleSend: TimeInterval = 1.0

    /// The longest chunk sent: the session's paclen.
    var maxChunk: Int

    /// Bytes typed and not yet sent.
    private(set) var pending = Data()
    /// The line typed since the last CR, as the operator sees it.
    private(set) var echoLine = ""
    /// When the buffer goes out if nothing else is typed; nil when empty.
    private(set) var flushDeadline: Date?

    init(maxChunk: Int) {
        self.maxChunk = max(1, maxChunk)
    }

    // MARK: Input

    mutating func input(_ key: Key, at now: Date) -> Output {
        var out = Output()
        for atom in Self.atoms(for: key) {
            add(atom, to: &out)
        }
        flushDeadline = pending.isEmpty ? nil : now.addingTimeInterval(Self.idleSend)
        return out
    }

    /// The buffer, if typing has been quiet for `idleSend`.
    mutating func flushIfIdle(at now: Date) -> Data? {
        guard let deadline = flushDeadline, now >= deadline else { return nil }
        return flushAll()
    }

    /// Everything still buffered, sent now: leaving raw mode, or the session
    /// ending.
    mutating func flushAll() -> Data? {
        flushDeadline = nil
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    /// Starts a fresh echo line without sending anything, for a new session.
    mutating func resetEcho() {
        echoLine = ""
    }

    // MARK: Key map

    /// The bytes a key sends.
    static func bytes(for key: Key) -> Data {
        atoms(for: key).reduce(into: Data()) { $0.append(contentsOf: $1.bytes) }
    }

    /// The control byte for Ctrl and a key: @, A to Z (either case), and
    /// [ \ ] ^ _, the keys that have one on a terminal.
    static func controlByte(for character: Character) -> UInt8? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              scalar.isASCII else { return nil }
        let value = UInt8(scalar.value)
        switch value {
        case 0x40...0x5F: return value - 0x40       // @ A–Z [ \ ] ^ _
        case 0x61...0x7A: return value - 0x60       // a–z
        default: return nil
        }
    }

    /// How a sent chunk reads in the console: CR as ↵, BS as ⌫, HT as ⇥,
    /// other control bytes in caret form.
    static func consoleText(for data: Data) -> String {
        var text = ""
        var run = Data()
        func flushRun() {
            guard !run.isEmpty else { return }
            text += String(decoding: run, as: UTF8.self)
            run.removeAll()
        }
        for byte in data {
            switch byte {
            case 0x0D: flushRun(); text += "↵"
            case 0x08: flushRun(); text += "⌫"
            case 0x09: flushRun(); text += "⇥"
            case 0x00..<0x20: flushRun(); text += "^" + String(UnicodeScalar(byte + 0x40))
            case 0x7F: flushRun(); text += "^?"
            default: run.append(byte)
            }
        }
        flushRun()
        return text
    }

    // MARK: Internals

    /// One key's worth of bytes and what it does to the buffer and echo.
    private enum Atom: Equatable {
        case printable(Character)
        case carriageReturn
        case backspace
        case tab
        case control(UInt8)

        var bytes: [UInt8] {
            switch self {
            case .printable(let c): return Array(String(c).utf8)
            case .carriageReturn: return [0x0D]
            case .backspace: return [0x08]
            case .tab: return [0x09]
            case .control(let b): return [b]
            }
        }
    }

    private static func atoms(for key: Key) -> [Atom] {
        switch key {
        case .returnKey: return [.carriageReturn]
        case .backspace: return [.backspace]
        case .tab: return [.tab]
        case .escape: return [.control(0x1B)]
        case .control(let byte): return [atom(forControl: byte & 0x1F)]
        case .text(let string):
            // Swift reads CR LF as one Character, so each line ending is one
            // atom however the paste spelled it.
            return string.map { character in
                if character == "\r\n" || character == "\n" || character == "\r" {
                    return .carriageReturn
                }
                if let scalar = character.unicodeScalars.first,
                   character.unicodeScalars.count == 1,
                   scalar.value < 0x20 || scalar.value == 0x7F {
                    return atom(forControl: UInt8(scalar.value))
                }
                return .printable(character)
            }
        }
    }

    private static func atom(forControl byte: UInt8) -> Atom {
        switch byte {
        case 0x0D: return .carriageReturn
        case 0x08: return .backspace
        case 0x09: return .tab
        default: return .control(byte)
        }
    }

    private mutating func add(_ atom: Atom, to out: inout Output) {
        for byte in atom.bytes {
            pending.append(byte)
            if pending.count >= maxChunk {
                out.chunks.append(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }

        switch atom {
        case .printable(let character):
            echoLine.append(character)
        case .tab:
            echoLine.append(" ")
        case .backspace:
            if !echoLine.isEmpty { echoLine.removeLast() }
        case .carriageReturn:
            out.committedLines.append(echoLine)
            echoLine = ""
            sendPending(into: &out)
        case .control:
            // Ctrl-C, Ctrl-Z and Esc mean "act on this now".
            sendPending(into: &out)
        }
    }

    private mutating func sendPending(into out: inout Output) {
        guard !pending.isEmpty else { return }
        out.chunks.append(pending)
        pending.removeAll(keepingCapacity: true)
    }
}
