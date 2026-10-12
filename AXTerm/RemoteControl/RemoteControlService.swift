//
//  RemoteControlService.swift
//  AXTerm
//
//  The station's remote control, which the mailbox and the node both use
//  (Docs/RemoteAccessPlan.md): one code checker and lockout, the control
//  commands' runner, one fail-safe per link, and one log.
//

import Combine
import Foundation

@MainActor
final class RemoteControlService: ObservableObject {

    /// What decides whether a link may change the station: 97.213 wants a
    /// direct control link, on a frequency 97.201 allows.
    struct LinkFacts: Equatable, Sendable {
        /// The radio the link is on; nil when there is none to name.
        var radio: RadioID?
        /// Through a digipeater.
        var digipeated: Bool
        /// Through a NET/ROM circuit or another node.
        var relayed: Bool
    }

    /// One line of the remote-control log.
    struct Event: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var at: Date
        var caller: String
        /// Where it came in: the mailbox or the node.
        var door: String
        var text: String
    }

    static let logKey = "remoteControlLog"
    /// The log keeps this many lines.
    static let logLimit = 200

    let settings: BBSSettings
    private let defaults: UserDefaults

    var ownerSecret: () -> Data? = { OwnerCodeSecretStore().read() }
    var runner = OwnerControlRunner()
    /// The frequency a radio is on, for the control link rule.
    var linkFrequencyHz: (RadioID) -> Int? = { _ in nil }
    /// How long the operator may be silent before the fail-safe puts the
    /// changes back: under the 3 minutes 97.213(b) allows, with room for the
    /// restore itself.
    var silenceLimit: Duration = .seconds(150)
    var now: () -> Date = Date.init

    @Published private(set) var log: [Event]

    /// One checker for every door, so a used code stays used and a lockout
    /// holds wherever the caller tries next.
    private var checker: OwnerCode.Checker?

    /// What one link's commands changed, and how to reach its caller.
    private struct Pending {
        var restores: [(name: String, plan: OwnerControlRestore)] = []
        var watchdog: Task<Void, Never>?
        var write: ([String]) -> Void
        var note: ((String) -> Void)?
        var caller: String
        var door: String
    }

    private var pending: [String: Pending] = [:]
    /// Links with a command run on them that have not ended.
    private var activeLinks: Set<String> = []

    init(settings: BBSSettings, defaults: UserDefaults = AppEnvironment.defaults) {
        self.settings = settings
        self.defaults = defaults
        self.log = defaults.data(forKey: Self.logKey)
            .flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
    }

    // MARK: - Signing in

    /// How this caller's OWNER code is checked at `station`, or nil when
    /// they cannot be the owner: owner commands off, no secret made, or
    /// another callsign.
    func codeCheck(for caller: String, station: String) -> ((String, Date) -> OwnerCode.Verdict)? {
        guard settings.ownerCommandsEnabled, BBSShell.isOwnerCallsign(caller, station: station),
              ownerSecret() != nil else { return nil }
        return { [weak self] code, at in self?.check(code, at: at) ?? .wrong }
    }

    /// The devices this caller may sign in with by key, or nil when they
    /// cannot be the owner or none is paired.
    func keys(for caller: String, station: String) -> [OwnerKey.PairedDevice]? {
        guard settings.ownerCommandsEnabled, BBSShell.isOwnerCallsign(caller, station: station),
              !settings.ownerDevices.isEmpty else { return nil }
        return settings.ownerDevices
    }

    /// A link's console brought up to the settings as they are now, so a
    /// change made at home during a call applies to it.
    func refresh(_ console: inout OwnerConsole) {
        console.checkOwnerCode = codeCheck(for: console.caller, station: console.ownerCallsign)
        console.ownerKeys = keys(for: console.caller, station: console.ownerCallsign)
        console.controls = settings.ownerControlCommands
        console.radios = settings.controlRadios
    }

    private func check(_ code: String, at date: Date) -> OwnerCode.Verdict {
        guard let secret = ownerSecret() else { return .wrong }
        if checker?.secret != secret { checker = OwnerCode.Checker(secret: secret) }
        return checker!.check(code, at: date)
    }

    // MARK: - Running commands

    /// Runs a control command for a link, writes what it says and then the
    /// prompt, and keeps what it changed for the fail-safe. One that changes
    /// how the station transmits runs only over a direct link on a frequency
    /// 97.201 allows.
    func run(_ command: OwnerControlCommand, argument: String, link: String, facts: LinkFacts,
             caller: String, door: String, write: @escaping ([String]) -> Void, prompt: String?,
             note: ((String) -> Void)? = nil) {
        let word = command.name.uppercased()
        let promptLines = prompt.map { [$0] } ?? []
        if command.changesTransmission, let reason = refusal(facts) {
            say("refused \(word): \(reason)", caller: caller, door: door, note: note)
            write(["\(word): \(reason)"] + promptLines)
            return
        }
        activeLinks.insert(link)
        say("ran " + (argument.isEmpty ? word : "\(word) \(argument)"), caller: caller, door: door, note: note)
        let runner = self.runner
        Task { @MainActor [weak self] in
            let result = await runner.run(command, argument: argument)
            guard let self else { return }
            guard self.activeLinks.contains(link) else {
                // The link went while it ran: nothing is left to say it to,
                // and nothing to keep a change for.
                if let restore = result.restore {
                    self.say(await runner.restore(restore), caller: caller, door: door, note: note)
                }
                return
            }
            if let restore = result.restore {
                var entry = self.pending[link]
                    ?? Pending(write: write, note: note, caller: caller, door: door)
                entry.write = write
                entry.note = note
                entry.restores.append((word, restore))
                self.pending[link] = entry
                self.armWatchdog(link)
            }
            write(result.lines + promptLines)
        }
    }

    /// Heard from the operator on this link: it is working.
    func heard(_ link: String) {
        guard pending[link]?.restores.isEmpty == false else { return }
        armWatchdog(link)
    }

    /// The link ended. A failed link is the control link failing, so what
    /// its commands changed is put back; one ended on purpose keeps it.
    func linkEnded(_ link: String, failed: Bool) {
        activeLinks.remove(link)
        if failed {
            putBack(link, sayingTo: false)
        } else {
            pending[link]?.watchdog?.cancel()
            pending[link] = nil
        }
    }

    /// Adds a line to the log.
    func record(_ text: String, caller: String, door: String) {
        log.append(Event(at: now(), caller: caller, door: door, text: text))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        defaults.set(try? JSONEncoder().encode(log), forKey: Self.logKey)
    }

    private func refusal(_ facts: LinkFacts) -> String? {
        if facts.relayed { return "it needs a direct link, not one through a NET/ROM circuit." }
        return TelecommandLink.refusal(frequencyHz: facts.radio.flatMap(linkFrequencyHz), digipeated: facts.digipeated)
    }

    private func say(_ text: String, caller: String, door: String, note: ((String) -> Void)?) {
        record(text, caller: caller, door: door)
        note?(text)
    }

    private func armWatchdog(_ link: String) {
        pending[link]?.watchdog?.cancel()
        let limit = silenceLimit
        pending[link]?.watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.putBack(link, sayingTo: true)
        }
    }

    /// The fail-safe: everything the link's commands changed, newest first,
    /// each step logged.
    private func putBack(_ link: String, sayingTo callerToo: Bool) {
        guard let entry = pending.removeValue(forKey: link) else { return }
        entry.watchdog?.cancel()
        guard !entry.restores.isEmpty else { return }
        say(callerToo ? "fail-safe: nothing heard from the operator" : "fail-safe: the link failed",
            caller: entry.caller, door: entry.door, note: entry.note)
        if callerToo {
            let names = entry.restores.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            entry.write(["Nothing heard from you: put back \(names.joined(separator: ", "))."])
        }
        let runner = self.runner
        Task { @MainActor [weak self] in
            for restore in entry.restores.reversed() {
                let what = await runner.restore(restore.plan)
                self?.say(what, caller: entry.caller, door: entry.door, note: entry.note)
            }
        }
    }
}
