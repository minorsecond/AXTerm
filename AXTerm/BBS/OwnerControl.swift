//
//  OwnerControl.swift
//  AXTerm
//
//  Control commands the operator defines at home, run from the road as
//  owner commands (Docs/RemoteAccessPlan.md, "Owner control commands").
//

import Foundation
import Network

/// One control command: the word typed, a help line, a rule for its
/// argument, and what it does. A Hamlib rigctl command reaches any radio
/// behind rigctld (Warbler serves the IC-705 on localhost:4533); a script in
/// AXTerm's Application Scripts folder reaches anything else. A command that
/// changes how the station transmits must say how to put the change back,
/// because 97.213(b) asks for the station to stop within 3 minutes when the
/// control link fails.
nonisolated struct OwnerControlCommand: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var help: String
    var argument: ArgumentRule
    var action: Action
    var changesTransmission: Bool
    /// What a typed number is divided by on its way to rigctl, and a number
    /// read back multiplied by: 10 turns the IC-705's watts into Hamlib's
    /// fraction of full power. 1 leaves numbers alone.
    var scale: Double = 1
    /// Shown after a scaled number, such as W.
    var unit = ""
    /// How many steps the radio keeps a scaled value in (255 for an Icom's
    /// power), so a typed number lands on the nearest one; 0 when unknown.
    var steps = 0

    /// What the argument may be. Nothing else reaches rigctl or a script.
    enum ArgumentRule: Codable, Equatable, Sendable {
        case none
        case number(min: Double, max: Double)
        case choice([String])

        enum Refusal: Error, Equatable {
            case unexpected
            case notANumber
            case outOfRange(String, String)
            case notAChoice([String])
        }

        /// The argument as it goes to the action, or why it cannot.
        func accept(_ text: String) -> Result<String, Refusal> {
            let typed = text.trimmingCharacters(in: .whitespaces)
            switch self {
            case .none:
                return typed.isEmpty ? .success("") : .failure(.unexpected)
            case .number(let min, let max):
                guard Self.isPlainNumber(typed), let value = Double(typed) else { return .failure(.notANumber) }
                guard value >= min, value <= max else {
                    return .failure(.outOfRange(Self.format(min), Self.format(max)))
                }
                return .success(typed)
            case .choice(let choices):
                guard let match = choices.first(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) else {
                    return .failure(.notAChoice(choices))
                }
                return .success(match)
            }
        }

        /// Digits with at most one point and an optional leading minus.
        private static func isPlainNumber(_ text: String) -> Bool {
            var body = Substring(text)
            if body.first == "-" { body = body.dropFirst() }
            guard !body.isEmpty, body.filter({ $0 == "." }).count <= 1 else { return false }
            return body.allSatisfy { $0 == "." || ($0.isASCII && $0.isNumber) } && body != "."
        }

        static func format(_ value: Double) -> String {
            value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        }
    }

    enum Action: Codable, Equatable, Sendable {
        /// A Hamlib NET rigctl line, `{arg}` standing for the argument. With
        /// `read`, the value is read first, so the fail-safe can put it back
        /// with `set`.
        case rigctl(host: String, port: Int, set: String, read: String?)
        /// A script in AXTerm's Application Scripts folder, given the
        /// argument. `restore`, another script there, is what the fail-safe
        /// runs.
        case script(name: String, restore: String?)
        /// One quantity of whichever radio is named after the word
        /// (`ControlRadio`): `PWR 705` reads it, `PWR 705 5` sets power.
        case radio(RadioQuantity)
    }

    /// What a radio command reads, and for power sets, by Hamlib rigctl.
    enum RadioQuantity: String, Codable, CaseIterable, Sendable {
        case frequency, mode, power, signal, voltage

        var readLine: String {
            switch self {
            case .frequency: "f"
            case .mode: "m"
            case .power: "l RFPOWER"
            case .signal: "l STRENGTH"
            case .voltage: "l VD_METER"
            }
        }

        var canSet: Bool { self == .power }
    }

    /// A typed number divided by the scale, for rigctl. With `steps`, the
    /// nearest step to it, sent a quarter step up: rigctld truncates
    /// (Hamlib does, and so does Warbler), and a quarter step lands on the
    /// same step whether the far end truncates or rounds.
    static func scaled(_ text: String, by scale: Double, steps: Int = 0) -> String {
        guard scale != 1 || steps > 0, let value = Double(text) else { return text }
        let fraction = value / scale
        guard steps > 0 else { return String(format: "%g", fraction) }
        let step = min(max((fraction * Double(steps)).rounded(), 0), Double(steps))
        if step == Double(steps) { return "1" }
        return String(format: "%.6f", (step + 0.25) / Double(steps))
    }

    static func fill(_ template: String, with argument: String) -> String {
        template.replacingOccurrences(of: "{arg}", with: argument)
    }

    /// Why this definition cannot be saved, or nil.
    func problem(among others: [OwnerControlCommand]) -> String? {
        let word = name.uppercased()
        guard (1...8).contains(word.count), word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return "A name is 1 to 8 letters and digits."
        }
        if BBSShell.builtInVerbs.contains(word) { return "\(word) is one of the mailbox's own commands." }
        if others.contains(where: { $0.id != id && $0.name.uppercased() == word }) {
            return "There is already a command called \(word)."
        }
        switch action {
        case .rigctl(_, _, let set, let read):
            if (set + (read ?? "")).contains(where: \.isNewline) { return "A rigctl command is one line." }
            if [set, read ?? ""].contains(where: Self.keysTheTransmitter) {
                return "AXTerm does not key the transmitter from a control command."
            }
            if changesTransmission, read == nil { return Self.needsWayBack }
        case .script(let script, let restore):
            for file in [script] + (restore.map { [$0] } ?? []) where !Self.isPlainFileName(file) {
                return "A script is a file name in AXTerm's scripts folder."
            }
            if changesTransmission, restore == nil { return Self.needsWayBack }
        case .radio:
            break
        }
        return nil
    }

    private static let needsWayBack = "It changes how the station transmits, so it needs a way to put that back."

    /// rigctl's `T` and `set_ptt`: nothing could promise to let go again.
    private static func keysTheTransmitter(_ line: String) -> Bool {
        guard var word = line.split(separator: " ").first.map(String.init) else { return false }
        if word.hasPrefix("\\") { word.removeFirst() }
        return word == "T" || word.lowercased() == "set_ptt"
    }

    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && !name.contains(where: \.isNewline)
    }
}

/// What the fail-safe runs to put a transmitting change back.
nonisolated enum OwnerControlRestore: Equatable, Sendable {
    case rigctl(host: String, port: Int, line: String)
    case script(name: String)
}

nonisolated struct OwnerControlResult: Equatable, Sendable {
    var lines: [String]
    /// Set when the command changed how the station transmits.
    var restore: OwnerControlRestore?
}

/// One line to a Hamlib NET rigctl server, and its reply lines.
nonisolated protocol RigctlTransport: Sendable {
    func exchange(host: String, port: Int, line: String) async throws -> [String]
}

/// A script in AXTerm's Application Scripts folder, and what it printed.
nonisolated protocol ScriptRunning: Sendable {
    func run(script: String, arguments: [String]) async throws -> [String]
}

/// Runs control commands and their restores.
nonisolated struct OwnerControlRunner: Sendable {
    /// Lines of output the caller is sent, at most.
    static let maxLines = 8

    let rigctl: RigctlTransport
    let scripts: ScriptRunning

    init(rigctl: RigctlTransport = RigctlTCPTransport(), scripts: ScriptRunning = ApplicationScriptRunner()) {
        self.rigctl = rigctl
        self.scripts = scripts
    }

    func run(_ command: OwnerControlCommand, argument: String) async -> OwnerControlResult {
        let word = command.name.uppercased()
        switch command.action {
        case .rigctl(let host, let port, let set, let read):
            do {
                var restore: OwnerControlRestore?
                if command.changesTransmission, let read {
                    let current = try await rigctl.exchange(host: host, port: port,
                                                            line: OwnerControlCommand.fill(read, with: ""))
                    guard let value = current.first, !value.hasPrefix("RPRT") else {
                        return OwnerControlResult(lines: ["\(word): could not read what it is now, so nothing was changed."])
                    }
                    restore = .rigctl(host: host, port: port, line: OwnerControlCommand.fill(set, with: value))
                }
                let sent = OwnerControlCommand.scaled(argument, by: command.scale, steps: command.steps)
                let reply = try await rigctl.exchange(host: host, port: port,
                                                      line: OwnerControlCommand.fill(set, with: sent))
                if let report = reply.first(where: { $0.hasPrefix("RPRT") }) {
                    guard report == "RPRT 0" else {
                        return OwnerControlResult(lines: ["\(word): the radio said \(report)."])
                    }
                    let done = argument.isEmpty || command.unit.isEmpty
                        ? "\(word): done." : "\(word): done, \(argument) \(command.unit)."
                    return OwnerControlResult(lines: [done], restore: restore)
                }
                return OwnerControlResult(lines: Self.shorten(Self.inUnits(reply, command), for: word), restore: restore)
            } catch {
                return OwnerControlResult(lines: ["\(word): cannot reach \(host):\(port)."])
            }
        case .radio:
            // The mailbox turns a radio command into a rigctl one for the
            // radio named; one that gets here named none.
            return OwnerControlResult(lines: ["\(word): name a radio."])
        case .script(let name, let restoreScript):
            do {
                let output = try await scripts.run(script: name, arguments: argument.isEmpty ? [] : [argument])
                return OwnerControlResult(lines: Self.shorten(output, for: word),
                                          restore: command.changesTransmission ? restoreScript.map { .script(name: $0) } : nil)
            } catch {
                return OwnerControlResult(lines: ["\(word): the script did not run (\(name))."])
            }
        }
    }

    /// Puts a change back; what happened, for the call log.
    func restore(_ plan: OwnerControlRestore) async -> String {
        switch plan {
        case .rigctl(let host, let port, let line):
            let reply = try? await rigctl.exchange(host: host, port: port, line: line)
            return reply?.contains("RPRT 0") == true ? "put back: \(line)" : "could not put back: \(line)"
        case .script(let name):
            let ran = (try? await scripts.run(script: name, arguments: [])) != nil
            return ran ? "put back: ran \(name)" : "could not put back: \(name) did not run"
        }
    }

    /// A number read back, multiplied by the command's scale and shown with
    /// its unit; anything else as it came.
    static func inUnits(_ reply: [String], _ command: OwnerControlCommand) -> [String] {
        guard command.scale != 1, let first = reply.first, let value = Double(first) else { return reply }
        let shown = String(format: "%.1f", value * command.scale)
        return [command.unit.isEmpty ? shown : "\(shown) \(command.unit)"] + reply.dropFirst()
    }

    /// The first line named, every line under 80 characters, and no more
    /// than `maxLines` of them.
    static func shorten(_ output: [String], for word: String) -> [String] {
        let kept = output.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !kept.isEmpty else { return ["\(word): done."] }
        var lines = kept.prefix(maxLines).enumerated().map { index, line in
            String((index == 0 ? "\(word): \(line)" : line).prefix(79))
        }
        if kept.count > maxLines { lines.append("(\(kept.count - maxLines) more lines)") }
        return lines
    }
}

/// Hamlib NET rigctl over TCP. A set is answered `RPRT n`; a get with bare
/// values and no end mark, so the reply ends at `RPRT` or when the line goes
/// quiet.
nonisolated struct RigctlTCPTransport: RigctlTransport {
    var quietGap: Duration = .milliseconds(300)
    var timeout: Duration = .seconds(3)

    func exchange(host: String, port: Int, line: String) async throws -> [String] {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw URLError(.badURL) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        defer { connection.cancel() }
        try await Self.ready(connection, within: timeout)
        try await Self.send(Data((line + "\n").utf8), on: connection)
        var received = Data()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let chunk = try await Self.receive(on: connection, within: received.isEmpty ? timeout : quietGap)
            guard let chunk, !chunk.isEmpty else { break }
            received.append(chunk)
            let text = String(decoding: received, as: UTF8.self)
            if text.split(separator: "\n").contains(where: { $0.hasPrefix("RPRT") }), text.hasSuffix("\n") { break }
        }
        return String(decoding: received, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func ready(_ connection: NWConnection, within limit: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error): if once.claim() { continuation.resume(throwing: error) }
                case .cancelled: if once.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds(limit)) {
                if once.claim() { continuation.resume(throwing: URLError(.timedOut)) }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// The next bytes, or nil when nothing came within the limit. A receive
    /// still waiting when the limit passes is left to the connection's
    /// cancel, which the caller does on the way out; whichever comes first
    /// answers, once.
    private static func receive(on connection: NWConnection, within limit: Duration) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            let once = OnceFlag()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                guard once.claim() else { return }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? (isComplete ? Data() : nil)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds(limit)) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// A flag that can be claimed once, from any thread.
nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Scripts in AXTerm's Application Scripts folder, the one place a
/// sandboxed Mac app may run the operator's own scripts from. iPhone and
/// iPad have no such folder.
nonisolated struct ApplicationScriptRunner: ScriptRunning {
    enum Failure: Error { case unavailable }

    #if os(macOS)
    static func folder() throws -> URL {
        try FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
    }
    #endif

    func run(script: String, arguments: [String]) async throws -> [String] {
        #if os(macOS)
        let task = try NSUserUnixTask(url: try Self.folder().appendingPathComponent(script))
        let pipe = Pipe()
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        task.standardOutput = pipe.fileHandleForWriting
        try await task.execute(withArguments: arguments)
        try? pipe.fileHandleForWriting.close()
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return String(decoding: collected.data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        #else
        throw Failure.unavailable
        #endif
    }
}

/// Bytes gathered from a pipe on whatever thread it reports.
nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) {
        lock.lock()
        bytes.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

/// Where a command that changes how the station transmits may come from.
/// 97.213 allows control over a radio link that is an auxiliary station,
/// and 97.201 puts auxiliary stations on 2 m and up, outside a few segments.
/// A digipeated link is other stations relaying, not the control link.
nonisolated enum TelecommandLink {
    /// The segments 97.201(b) keeps auxiliary stations out of, in MHz.
    static let excludedMHz: [ClosedRange<Double>] = [
        144.0...144.5, 145.8...146.0, 219.0...220.0, 222.0...222.15, 431.0...433.0, 435.0...438.0
    ]

    /// Why a transmitting command may not run over this link, or nil.
    static func refusal(frequencyHz: Int?, digipeated: Bool) -> String? {
        if digipeated { return "it needs a direct link, not one through a digipeater." }
        guard let hz = frequencyHz else { return "AXTerm cannot tell which frequency this link is on." }
        let mhz = Double(hz) / 1_000_000
        if mhz < 144 || excludedMHz.contains(where: { $0.contains(mhz) }) {
            return "this link is on \(String(format: "%.3f", mhz)) MHz, where 97.201 does not allow a control link."
        }
        return nil
    }
}

/// The settings form for a control command, as typed. `build` turns it into
/// a command or says what to fix.
nonisolated struct OwnerControlDraft: Equatable, Sendable {
    enum ArgumentKind: String, CaseIterable, Sendable { case none, number, choice }
    enum ActionKind: String, CaseIterable, Sendable { case rigctl, script, radio }

    struct Problem: Error, Equatable {
        let text: String
    }

    var id = UUID()
    var name = ""
    var help = ""
    var argumentKind = ArgumentKind.none
    var minText = ""
    var maxText = ""
    var choicesText = ""
    var actionKind = ActionKind.rigctl
    /// Warbler serves the IC-705's rigctld here.
    var host = "localhost"
    var portText = "4533"
    var setText = ""
    var readText = ""
    var scriptName = ""
    var restoreName = ""
    var changesTransmission = false
    var scaleText = "1"
    var unit = ""
    var quantity = OwnerControlCommand.RadioQuantity.power

    init() {}

    init(_ command: OwnerControlCommand) {
        id = command.id
        name = command.name
        help = command.help
        changesTransmission = command.changesTransmission
        scaleText = OwnerControlCommand.ArgumentRule.format(command.scale)
        unit = command.unit
        switch command.argument {
        case .none: argumentKind = .none
        case .number(let min, let max):
            argumentKind = .number
            minText = OwnerControlCommand.ArgumentRule.format(min)
            maxText = OwnerControlCommand.ArgumentRule.format(max)
        case .choice(let choices):
            argumentKind = .choice
            choicesText = choices.joined(separator: " ")
        }
        switch command.action {
        case .rigctl(let host, let port, let set, let read):
            actionKind = .rigctl
            self.host = host
            portText = String(port)
            setText = set
            readText = read ?? ""
        case .script(let script, let restore):
            actionKind = .script
            scriptName = script
            restoreName = restore ?? ""
        case .radio(let quantity):
            actionKind = .radio
            self.quantity = quantity
        }
    }

    func build(among others: [OwnerControlCommand]) -> Result<OwnerControlCommand, Problem> {
        let argument: OwnerControlCommand.ArgumentRule
        switch argumentKind {
        case .none:
            argument = .none
        case .number:
            guard let min = Double(minText.trimmingCharacters(in: .whitespaces)),
                  let max = Double(maxText.trimmingCharacters(in: .whitespaces)), min < max else {
                return .failure(Problem(text: "The lowest and highest are numbers, lowest first."))
            }
            argument = .number(min: min, max: max)
        case .choice:
            let choices = choicesText.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.uppercased() }
            guard !choices.isEmpty else { return .failure(Problem(text: "List at least one choice.")) }
            argument = .choice(choices)
        }
        let action: OwnerControlCommand.Action
        switch actionKind {
        case .rigctl:
            guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
                return .failure(Problem(text: "The port is a number from 1 to 65535."))
            }
            let host = host.trimmingCharacters(in: .whitespaces)
            let set = setText.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return .failure(Problem(text: "Say which computer runs rigctld.")) }
            guard !set.isEmpty else { return .failure(Problem(text: "Say what to send to rigctld.")) }
            let read = readText.trimmingCharacters(in: .whitespaces)
            action = .rigctl(host: host, port: port, set: set, read: read.isEmpty ? nil : read)
        case .script:
            let script = scriptName.trimmingCharacters(in: .whitespaces)
            guard !script.isEmpty else { return .failure(Problem(text: "Name the script to run.")) }
            let restore = restoreName.trimmingCharacters(in: .whitespaces)
            action = .script(name: script, restore: restore.isEmpty ? nil : restore)
        case .radio:
            action = .radio(quantity)
        }
        guard let scale = Double(scaleText.trimmingCharacters(in: .whitespaces)), scale > 0 else {
            return .failure(Problem(text: "The scale is a number above 0."))
        }
        let command = OwnerControlCommand(id: id, name: name.trimmingCharacters(in: .whitespaces).uppercased(),
                                          help: help.trimmingCharacters(in: .whitespaces),
                                          argument: actionKind == .radio ? .none : argument, action: action,
                                          changesTransmission: actionKind == .radio ? quantity.canSet
                                                                                    : changesTransmission,
                                          scale: scale, unit: unit.trimmingCharacters(in: .whitespaces))
        if let problem = command.problem(among: others) { return .failure(Problem(text: problem)) }
        return .success(command)
    }
}

extension OwnerControlCommand {
    /// A ready-made set for the IC-705 behind Warbler (rigctld on
    /// localhost:4533), with the FT-710 (4532) read only. The 705 carries the
    /// operator's own link, so the set reads it and turns its power up or
    /// down, and never changes its frequency or mode, which would cut the
    /// link the command came in on. The FT-710 runs the station's HF link
    /// unattended, so it is only read.
    static var warblerIC705Preset: [OwnerControlCommand] {
        func read(_ name: String, _ help: String, _ line: String, port: Int = 4533) -> OwnerControlCommand {
            OwnerControlCommand(name: name, help: help, argument: .none,
                                action: .rigctl(host: "localhost", port: port, set: line, read: nil),
                                changesTransmission: false)
        }
        return [
            read("QRG", "the 705's frequency in Hz", "f"),
            read("MODE", "the 705's mode and filter width", "m"),
            OwnerControlCommand(name: "PWR", help: "the 705's power in watts", argument: .none,
                                action: .rigctl(host: "localhost", port: 4533, set: "l RFPOWER", read: nil),
                                changesTransmission: false, scale: 10, unit: "W"),
            OwnerControlCommand(name: "SETPWR", help: "set the 705's power in watts, 0.5 to 10",
                                argument: .number(min: 0.5, max: 10),
                                action: .rigctl(host: "localhost", port: 4533, set: "L RFPOWER {arg}",
                                                read: "l RFPOWER"),
                                changesTransmission: true, scale: 10, unit: "W"),
            read("SIG", "signal on the 705's frequency, dB over S9", "l STRENGTH"),
            read("VOLTS", "the 705's supply voltage", "l VD_METER"),
            read("HFQRG", "the FT-710's frequency in Hz", "f", port: 4532)
        ]
    }

    /// SETPWR and PWR as the first preset had them, taking and showing
    /// Hamlib's fraction of full power.
    static let legacyIC705Power: [OwnerControlCommand] = [
        OwnerControlCommand(name: "SETPWR", help: "set the 705's power, 0.1 to 1 (1 W to 10 W)",
                            argument: .number(min: 0.1, max: 1),
                            action: .rigctl(host: "localhost", port: 4533, set: "L RFPOWER {arg}", read: "l RFPOWER"),
                            changesTransmission: true),
        OwnerControlCommand(name: "PWR", help: "the 705's power, 1 = 10 W", argument: .none,
                            action: .rigctl(host: "localhost", port: 4533, set: "l RFPOWER", read: nil),
                            changesTransmission: false)
    ]

    /// Stored commands with the first preset's SETPWR and PWR moved to watts.
    /// One the operator changed is left as it is.
    static func upgradingPreset(_ stored: [OwnerControlCommand]) -> [OwnerControlCommand] {
        let current = warblerIC705Preset
        return stored.map { command in
            var anonymous = command
            guard let legacy = legacyIC705Power.first(where: { anonymous.id = $0.id; return anonymous == $0 }),
                  var replacement = current.first(where: { $0.name == legacy.name }) else { return command }
            replacement.id = command.id
            return replacement
        }
    }

    /// `preset` added to `existing`, skipping names already in use.
    static func adding(_ preset: [OwnerControlCommand], to existing: [OwnerControlCommand]) -> [OwnerControlCommand] {
        let taken = Set(existing.map { $0.name.uppercased() })
        return existing + preset.filter { !taken.contains($0.name.uppercased()) }
    }
}

extension OwnerControlCommand {
    private enum CodingKeys: String, CodingKey {
        case id, name, help, argument, action, changesTransmission, scale, unit, steps
    }

    /// Commands saved before scales existed have none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        help = try container.decode(String.self, forKey: .help)
        argument = try container.decode(ArgumentRule.self, forKey: .argument)
        action = try container.decode(Action.self, forKey: .action)
        changesTransmission = try container.decode(Bool.self, forKey: .changesTransmission)
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
        steps = try container.decodeIfPresent(Int.self, forKey: .steps) ?? 0
    }
}

/// A radio the control commands can reach, named once: `705`, `710`. Power
/// is in watts, inside the radio's own range, so an impossible setting such
/// as 75 W on the IC-705 never reaches it.
nonisolated struct ControlRadio: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    /// What follows the word: PWR 705.
    var name: String
    var host: String
    var port: Int
    /// Hamlib's full power (RFPOWER 1.0), in watts.
    var fullPowerWatts: Double
    var minWatts: Double
    var maxWatts: Double
    /// Off keeps the radio to reading from the road.
    var allowsChanges = true
    /// How many steps the radio keeps power in: 255 on the IC-705, 100 on
    /// the FT-710. 0 sends the plain fraction.
    var powerSteps = 0

    /// The IC-705 and the FT-710 behind Warbler.
    static var warblerPreset: [ControlRadio] {
        [
            ControlRadio(name: "705", host: "localhost", port: 4533, fullPowerWatts: 10, minWatts: 0.5, maxWatts: 10,
                         powerSteps: 255),
            ControlRadio(name: "710", host: "localhost", port: 4532, fullPowerWatts: 100, minWatts: 5, maxWatts: 100,
                         powerSteps: 100)
        ]
    }

    /// Why this radio cannot be saved, or nil.
    func problem(among others: [ControlRadio]) -> String? {
        let word = name.trimmingCharacters(in: .whitespaces)
        guard (1...8).contains(word.count), word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return "A radio's name is 1 to 8 letters and digits, such as 705."
        }
        if others.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(word) == .orderedSame }) {
            return "There is already a radio called \(word)."
        }
        guard (1...65535).contains(port), !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Give the computer and port of its rigctld."
        }
        guard fullPowerWatts > 0, minWatts > 0, minWatts < maxWatts, maxWatts <= fullPowerWatts else {
            return "The lowest power is above 0 and below the highest, and the highest is at most full power."
        }
        return nil
    }
}

extension OwnerControlCommand {
    /// One word per quantity, for whichever radio is named after it.
    static var radioPreset: [OwnerControlCommand] {
        func radio(_ name: String, _ help: String, _ quantity: RadioQuantity) -> OwnerControlCommand {
            OwnerControlCommand(name: name, help: help, argument: .none, action: .radio(quantity),
                                changesTransmission: quantity.canSet)
        }
        return [
            radio("QRG", "a radio's frequency in Hz", .frequency),
            radio("MODE", "a radio's mode and filter width", .mode),
            radio("PWR", "a radio's power in watts; with W, set it", .power),
            radio("SIG", "signal on a radio's frequency, dB over S9", .signal),
            radio("VOLTS", "a radio's supply voltage", .voltage)
        ]
    }

    /// The first, one-radio sets (QRG, SETPWR, HFQRG and the rest, each
    /// fixed to one radio) give way to the radio set, with both of Warbler's
    /// radios named. Commands the operator changed or added stay.
    static func movingToRadios(_ commands: [OwnerControlCommand],
                               radios: [ControlRadio]) -> (commands: [OwnerControlCommand], radios: [ControlRadio]) {
        let oneRadioSets = warblerIC705Preset + legacyIC705Power
        func isOneRadioSet(_ command: OwnerControlCommand) -> Bool {
            oneRadioSets.contains { var plain = command; plain.id = $0.id; return plain == $0 }
        }
        guard commands.contains(where: isOneRadioSet) else { return (commands, radios) }
        let kept = commands.filter { !isOneRadioSet($0) }
        return (adding(radioPreset, to: kept), radios.isEmpty ? ControlRadio.warblerPreset : radios)
    }
}

extension ControlRadio {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, fullPowerWatts, minWatts, maxWatts, allowsChanges, powerSteps
    }

    /// Radios saved before power steps existed have none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        fullPowerWatts = try container.decode(Double.self, forKey: .fullPowerWatts)
        minWatts = try container.decode(Double.self, forKey: .minWatts)
        maxWatts = try container.decode(Double.self, forKey: .maxWatts)
        allowsChanges = try container.decodeIfPresent(Bool.self, forKey: .allowsChanges) ?? true
        powerSteps = try container.decodeIfPresent(Int.self, forKey: .powerSteps) ?? 0
    }
}
