//
//  OwnerConsole.swift
//  AXTerm
//
//  The owner's way in at the station's prompts, the mailbox's and the
//  node's (Docs/RemoteAccessPlan.md): sign-in by code or key, the check each
//  owner command carries, ST, and the control commands.
//

import CryptoKit
import Foundation

/// One link's owner state and the commands that use it. A prompt passes
/// each line through `route` and offers each command word to `command`;
/// what is not the owner's business it handles itself. The node hands its
/// console to the mailbox when the caller types BBS and takes it back on
/// the way out, so a sign-in and the device's counter carry across.
nonisolated struct OwnerConsole {
    enum Effect: Equatable, Sendable {
        /// The operator tried to sign in, rightly or not: logged either way.
        case signIn(accepted: Bool)
        /// Run one of the operator's control commands with its argument.
        case runControl(OwnerControlCommand, argument: String)
    }

    struct Reply: Equatable {
        var lines: [String]
        var effects: [Effect] = []
    }

    /// What a prompt does with a line.
    enum Route: Equatable {
        /// Handle this line; `checked` when it came with a right check.
        case line(String, checked: Bool)
        /// The console has answered it (a wrong check).
        case reply(Reply)
    }

    /// The caller, and the address they called (the node's alias, say):
    /// both are in a key sign-in's session key, as the device derives it.
    let caller: String
    let station: String
    /// The station's own callsign, whose operator may sign in: the same as
    /// `station` except where the caller dialed an alias.
    let ownerCallsign: String
    /// Checks an owner's one-time code (`OwnerCode.Checker`); nil unless
    /// owner commands are on and the caller is the operator's callsign.
    /// Without it, and without `ownerKeys`, OWNER and ST are unknown.
    var checkOwnerCode: ((String, Date) -> OwnerCode.Verdict)?
    /// The devices that may sign in with a key (`OwnerKey`); nil unless
    /// owner commands are on, the caller is the operator's callsign and a
    /// device is paired.
    var ownerKeys: [OwnerKey.PairedDevice]?
    /// The operator's control commands (`OwnerControlCommand`).
    var controls: [OwnerControlCommand] = []
    /// The radios the radio commands may name (`ControlRadio`).
    var radios: [ControlRadio] = []

    private let makeOneTimeKey: () -> P256.KeyAgreement.PrivateKey
    /// The one-time key of the challenge outstanding, until a sign-in uses
    /// it up or it runs out (`OwnerKey.challengeLifetime`).
    private var challenge: (key: P256.KeyAgreement.PrivateKey, issued: Date)?
    /// The session key of a key sign-in, and the counter the next owner
    /// command's check covers.
    private var session: (key: SymmetricKey, counter: UInt64)?
    private var wrongChecks = 0
    /// Signed in with a right code or key, until the link ends.
    private(set) var isOwner = false
    /// Signed in with a key: from then on each owner command must carry its
    /// own check, so anyone putting frames into the link under the
    /// operator's callsign cannot use the sign-in.
    private(set) var byKey = false

    init(caller: String, station: String, ownerCallsign: String? = nil,
         checkOwnerCode: ((String, Date) -> OwnerCode.Verdict)? = nil,
         ownerKeys: [OwnerKey.PairedDevice]? = nil,
         makeOneTimeKey: @escaping () -> P256.KeyAgreement.PrivateKey = { P256.KeyAgreement.PrivateKey() }) {
        self.caller = caller
        self.station = station
        self.ownerCallsign = ownerCallsign ?? station
        self.checkOwnerCode = checkOwnerCode
        self.ownerKeys = ownerKeys
        self.makeOneTimeKey = makeOneTimeKey
    }

    /// OWNER and ST exist for this caller.
    var offers: Bool { checkOwnerCode != nil || ownerKeys != nil }

    /// The words that are owner commands for this caller.
    var verbs: [String] { ["ST"] + controls.map { $0.name.uppercased() } }

    /// Before a prompt reads a line. At a command line, a line with a check
    /// is the command it carries, or a wrong check. Elsewhere (a message
    /// being written, whose first word happened to be an owner command) a
    /// right check comes off, keeping the counter in step with the
    /// device's, and anything else is text.
    mutating func route(_ line: String, atCommandLine: Bool) -> Route {
        guard byKey, line.hasPrefix("!") else { return .line(line, checked: false) }
        if let command = acceptCheck(line) { return .line(command, checked: true) }
        guard atCommandLine else { return .line(line, checked: false) }
        return .reply(wrongCheck())
    }

    /// The answer to an owner command, or nil when `verb` is not one here.
    /// `status` is what ST shows.
    mutating func command(_ verb: String, _ rest: String, checked: Bool, status: [String], now: Date) -> Reply? {
        guard offers else { return nil }
        let control = controls.first { $0.name.uppercased() == verb }
        guard verb == "OWNER" || verb == "ST" || control != nil else { return nil }
        if verb == "OWNER" { return signIn(rest, now: now) }
        if byKey, !checked {
            return Reply(lines: ["Owner commands from a paired device carry a check; AXTerm adds it for you."])
        }
        guard isOwner else { return Reply(lines: [Self.signInFirst]) }
        if verb == "ST" { return Reply(lines: status.isEmpty ? ["Nothing to report."] : status) }
        return run(control!, rest)
    }

    /// The owner's part of a prompt's help, empty when there is none.
    var helpLines: [String] {
        guard offers else { return [] }
        let radioCommands = controls.contains { if case .radio = $0.action { return true }; return false }
        return [
            "",
            "OWNER code sign in as the owner with your authenticator code",
            "ST         the station's state (owner)"
        ] + controls.map { command in
            var word = command.name.uppercased()
            if case .radio(let quantity) = command.action { word += quantity.canSet ? " r [W]" : " r" }
            return String((word.padding(toLength: max(11, word.count + 2), withPad: " ", startingAt: 0)
                           + command.help).prefix(79))
        } + (radios.isEmpty || !radioCommands ? [] : ["Radios: " + radios.map(\.name).joined(separator: ", ")])
    }

    private static let signInFirst = "Sign in first: OWNER and the six-digit code from your authenticator app."

    // MARK: - Signing in

    private mutating func signIn(_ rest: String, now: Date) -> Reply {
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        let word = parts.first?.uppercased()
        if word == "KEY" {
            guard ownerKeys != nil else {
                return Reply(lines: ["No device is paired with this station. Pair one in its owner settings at home."])
            }
            let oneTime = makeOneTimeKey()
            challenge = (oneTime, now)
            return Reply(lines: [OwnerKey.challengePrefix + OwnerKey.encode(oneTime.publicKey)])
        }
        if word == "MAC", let ownerKeys {
            return keySignIn(parts.count > 1 ? parts[1] : "", paired: ownerKeys, now: now)
        }
        guard let checkOwnerCode, let code = parts.first else {
            return Reply(lines: [checkOwnerCode == nil
                ? "OWNER KEY starts a sign-in from a paired AXTerm."
                : "OWNER takes the six-digit code from your authenticator app."])
        }
        switch checkOwnerCode(code, now) {
        case .accepted:
            isOwner = true
            return Reply(lines: ["Signed in as the owner until you disconnect. ST shows the station."],
                         effects: [.signIn(accepted: true)])
        case .wrong:
            return Reply(lines: ["That code is not right."], effects: [.signIn(accepted: false)])
        case .used:
            return Reply(lines: ["That code was already used. Wait for the next one."],
                         effects: [.signIn(accepted: false)])
        case .lockedOut:
            return Reply(lines: ["Too many wrong codes. Codes are refused for now; a paired device's key still works."],
                         effects: [.signIn(accepted: false)])
        }
    }

    /// `OWNER MAC <check>`: the device's answer to the challenge, made with
    /// the session key only a paired device can derive.
    private mutating func keySignIn(_ given: String, paired: [OwnerKey.PairedDevice], now: Date) -> Reply {
        guard let outstanding = challenge else {
            return Reply(lines: ["Ask for a challenge first: OWNER KEY."])
        }
        challenge = nil
        guard now.timeIntervalSince(outstanding.issued) <= OwnerKey.challengeLifetime else {
            return Reply(lines: ["That challenge has run out. Ask for a new one: OWNER KEY."])
        }
        let answer = given.trimmingCharacters(in: .whitespaces)
        for device in paired {
            guard let key = OwnerKey.sessionKey(mine: outstanding.key, theirs: device.publicKey,
                                                station: station, caller: caller),
                  OwnerKey.matches(answer, OwnerKey.check(key: key, counter: 0, command: "",
                                                          length: OwnerKey.signInCheckBytes)) else { continue }
            session = (key, 1)
            wrongChecks = 0
            isOwner = true
            byKey = true
            return Reply(lines: ["Signed in as the owner until you disconnect. Owner commands carry a check.",
                                 OwnerKey.ownerCommandsPrefix + verbs.joined(separator: " ")],
                         effects: [.signIn(accepted: true)])
        }
        return Reply(lines: ["That sign-in is not from a paired device."], effects: [.signIn(accepted: false)])
    }

    /// The line without its check when the check is right for the next
    /// counter, which it then moves on; nil otherwise.
    private mutating func acceptCheck(_ line: String) -> String? {
        guard line.hasPrefix("!"), var current = session else { return nil }
        let pieces = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let command = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : ""
        guard let given = pieces.first,
              OwnerKey.matches(given, OwnerKey.check(key: current.key, counter: current.counter, command: command,
                                                     length: OwnerKey.commandCheckBytes)) else { return nil }
        current.counter += 1
        session = current
        return command
    }

    /// A wrong check is logged, and the third ends the sign-in.
    private mutating func wrongCheck() -> Reply {
        wrongChecks += 1
        guard wrongChecks >= OwnerKey.wrongChecksAllowed else {
            return Reply(lines: ["That check is not right."], effects: [.signIn(accepted: false)])
        }
        session = nil
        byKey = false
        isOwner = false
        return Reply(lines: [OwnerKey.signedOutLine], effects: [.signIn(accepted: false)])
    }

    // MARK: - Control commands

    private func run(_ command: OwnerControlCommand, _ argument: String) -> Reply {
        let word = command.name.uppercased()
        if case .radio(let quantity) = command.action {
            return radioControl(word, quantity, argument)
        }
        if command.changesTransmission, !byKey {
            return Reply(lines: ["\(word) changes how the station transmits: sign in with a paired AXTerm's key."])
        }
        switch command.argument.accept(argument) {
        case .success(let accepted):
            return Reply(lines: [], effects: [.runControl(command, argument: accepted)])
        case .failure(let refusal):
            let fits: String
            switch refusal {
            case .unexpected: fits = "nothing after it"
            case .notANumber:
                if case .number(let min, let max) = command.argument {
                    fits = "a number from \(OwnerControlCommand.ArgumentRule.format(min)) to "
                        + "\(OwnerControlCommand.ArgumentRule.format(max))"
                } else { fits = "a number" }
            case .outOfRange(let min, let max): fits = "a number from \(min) to \(max)"
            case .notAChoice(let choices): fits = "one of " + choices.joined(separator: ", ")
            }
            return Reply(lines: ["\(word) takes \(fits)."])
        }
    }

    /// `PWR 705` reads; `PWR 705 5` sets power, inside that radio's range.
    /// The runner gets a plain rigctl command for the radio named.
    private func radioControl(_ word: String, _ quantity: OwnerControlCommand.RadioQuantity,
                              _ text: String) -> Reply {
        guard let example = radios.first?.name else {
            return Reply(lines: ["No radios are set up for control commands."])
        }
        let parts = text.split(separator: " ").map(String.init)
        guard let asked = parts.first else {
            return Reply(lines: ["\(word) takes a radio, such as \(word) \(example)"
                                 + (quantity.canSet ? ", or \(word) \(example) 5 to set it." : ".")])
        }
        guard let radio = radios.first(where: { $0.name.caseInsensitiveCompare(asked) == .orderedSame }) else {
            return Reply(lines: ["\(word): no radio called \(asked). Radios: "
                                 + radios.map(\.name).joined(separator: ", ") + "."])
        }
        let named = "\(word) \(radio.name)"
        let isPower = quantity == .power
        guard parts.count > 1 else {
            let read = OwnerControlCommand(name: named, help: "", argument: .none,
                                           action: .rigctl(host: radio.host, port: radio.port,
                                                           set: quantity.readLine, read: nil),
                                           changesTransmission: false,
                                           scale: isPower ? radio.fullPowerWatts : 1, unit: isPower ? "W" : "")
            return Reply(lines: [], effects: [.runControl(read, argument: "")])
        }
        guard quantity.canSet else { return Reply(lines: ["\(word) only reads: \(named)."]) }
        guard radio.allowsChanges else {
            return Reply(lines: ["\(word): the \(radio.name) is set to read only from the road."])
        }
        var typed = parts[1]
        if typed.lowercased().hasSuffix("w") { typed.removeLast() }
        let range = OwnerControlCommand.ArgumentRule.number(min: radio.minWatts, max: radio.maxWatts)
        guard parts.count == 2, case .success(let watts) = range.accept(typed) else {
            return Reply(lines: ["\(word): the \(radio.name) takes "
                                 + "\(OwnerControlCommand.ArgumentRule.format(radio.minWatts)) to "
                                 + "\(OwnerControlCommand.ArgumentRule.format(radio.maxWatts)) W."])
        }
        guard byKey else {
            return Reply(lines: ["\(named) \(watts) changes how the station transmits: "
                                 + "sign in with a paired AXTerm's key."])
        }
        let set = OwnerControlCommand(name: named, help: "", argument: range,
                                      action: .rigctl(host: radio.host, port: radio.port,
                                                      set: "L RFPOWER {arg}", read: quantity.readLine),
                                      changesTransmission: true, scale: radio.fullPowerWatts, unit: "W",
                                      steps: radio.powerSteps)
        return Reply(lines: [], effects: [.runControl(set, argument: watts)])
    }
}
