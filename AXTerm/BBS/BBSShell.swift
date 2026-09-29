//
//  BBSShell.swift
//  AXTerm
//
//  The personal mailbox command interpreter, as a pure state machine.
//

import Foundation

/// The command shell a caller talks to once they have connected.
///
/// It performs no I/O. Lines come in, lines and `Effect`s go out, and the
/// driver is responsible for the radio and the database. That is what lets the
/// whole command set — including the visibility rules, which are the part
/// worth being sure about — be tested against string arrays with no TNC and no
/// store, the same way `WinlinkP2PListener` and `StationIdentityMonitor` are.
///
/// The command set follows FBB's personal mailbox: `H I J L R S K N W V B` and
/// their suffixed forms. Nothing here is invented. An operator who has used
/// packet before already knows it, and one who has not can read `H`.
nonisolated struct BBSShell {

    // MARK: - Types

    /// A station this mailbox has heard on the air, for `J`.
    struct HeardStation: Equatable, Sendable {
        var callsign: String
        var lastHeard: Date
    }

    /// Everything the shell is allowed to know about storage: a snapshot the
    /// driver refreshes before each line.
    struct Mailbox: Equatable, Sendable {
        var messages: [BBSMessage]

        /// The id the store will assign next.
        ///
        /// Safe to predict, and only because one radio serves one caller at a
        /// time (the listener refuses a second call as `.busy`). If that ever
        /// stops being true, this has to come back from the store instead.
        var nextID: Int64

        /// The directory, keyed by base callsign.
        var whitePages: [String: WhitePagesEntry]

        /// What this station has heard lately, newest first.
        var heard: [HeardStation]

        /// The operator's own `I` text.
        var stationInfo: String

        /// What is on offer for download.
        var files: BBSFileIndex

        /// When this caller was last here, for `FN`. Nil on a first call.
        var lastVisit: Date?

        init(messages: [BBSMessage] = [],
             nextID: Int64 = 1,
             whitePages: [String: WhitePagesEntry] = [:],
             heard: [HeardStation] = [],
             stationInfo: String = "",
             files: BBSFileIndex = BBSFileIndex(),
             lastVisit: Date? = nil) {
            self.messages = messages
            self.nextID = nextID
            self.whitePages = whitePages
            self.heard = heard
            self.stationInfo = stationInfo
            self.files = files
            self.lastVisit = lastVisit
        }

        func entry(for callsign: String) -> WhitePagesEntry? {
            whitePages[BBSMessage.baseCall(callsign)]
        }
    }

    enum State: Equatable, Sendable {
        case command
        /// `homeBBS` carries the `@BBS` half of `S CALL @ BBS` — a directory
        /// hint about the recipient, never part of the address. This mailbox
        /// does not forward (Docs/PacketBBS.md §1), so the message is filed
        /// under the callsign alone and the hint only teaches white pages.
        case awaitingSubject(to: String, homeBBS: String?)
        case composing(to: String, subject: String, homeBBS: String?, lines: [String])
        /// Walking a first-time caller through the public directory fields.
        /// FBB does this on a first call and it is how a directory actually
        /// fills — asking once, while they are there, beats hoping they
        /// discover four commands.
        case registering(remaining: [WhitePagesEntry.Key])
        case closed
    }

    /// What the driver must do to storage or the link. The shell decides; it
    /// never acts.
    enum Effect: Equatable, Sendable {
        case store(BBSMessage)
        case kill(id: Int64, at: Date)
        case markRead(id: Int64, at: Date)
        /// Type a text file down the session — no transfer protocol at all,
        /// which is both the cheapest option on the air and the one every
        /// terminal can receive.
        case viewFile(BBSSharedFile)
        /// Hand the session to a transfer protocol for this file.
        case sendFile(BBSSharedFile)
        /// Arm the receiver; the transfer protocol carries the filename.
        case beginUpload
        case abortTransfer
        case learnWhitePages(callsign: String,
                             key: WhitePagesEntry.Key,
                             value: String,
                             source: WhitePagesEntry.Source,
                             at: Date)
        case disconnect
    }

    struct Output: Equatable, Sendable {
        var lines: [String]
        /// The prompt to write after `lines`, or nil where the caller is
        /// mid-message or gone. Separate from `lines` so tests can assert on
        /// what was said without stepping over prompts.
        var prompt: String?

        var effects: [Effect]

        init(lines: [String] = [], prompt: String? = BBSShell.commandPrompt,
             effects: [Effect] = []) {
            self.lines = lines
            self.prompt = prompt
            self.effects = effects
        }
    }

    static let commandPrompt = ">"
    static let version = "AXTerm mailbox 1.0"

    // MARK: - Configuration

    /// Who is on the other end, as they addressed us from.
    let caller: String
    /// The operator's callsign — where `S` with no argument leaves mail.
    let sysop: String
    /// Free text the operator types in Settings. Shown on connect, and the
    /// only place this station says anything about when it is on the air:
    /// the operator knows their own hours and can simply state them.
    let banner: String
    let calendar: Calendar

    /// Whether `J` answers. A heard list says what this receiver can hear,
    /// which is a statement about where it is — the operator's call to make.
    let publishesHeardList: Bool
    /// Whether WP answers with the directory. Same disclosure family as
    /// the heard list — names and QTHs of everyone who registered.
    let publishesWhitePages: Bool

    /// Bounds on a single message, because this runs unattended. A caller who
    /// cannot stop typing should cost one session, not the mailbox.
    let maxBodyLines: Int
    let maxBodyBytes: Int
    let maxSubjectLength: Int
    /// How many rows any listing returns before it says what it left out.
    let maxListRows: Int

    /// Measured throughput of this link, for the TIME column. Supplied rather
    /// than assumed: a nominal baud figure is roughly double what a shared
    /// channel actually delivers, and an estimate that flatters itself is
    /// worse than none.
    let bytesPerSecond: Double
    /// Above this, `V` refuses and points at `D`.
    let maxInlineViewBytes: Int
    /// Above this many seconds, `D` asks before holding the channel.
    let longTransferSeconds: Double

    private(set) var state: State = .command
    /// The file id `D` has quoted a time for and is waiting to be asked about
    /// again. Not part of `State` because it does not change what other
    /// commands do — it is a memo, not a mode.
    private(set) var pendingDownload: String?

    init(caller: String,
         sysop: String,
         banner: String = "",
         calendar: Calendar = Calendar(identifier: .gregorian),
         publishesHeardList: Bool = true,
         publishesWhitePages: Bool = true,
         maxBodyLines: Int = 100,
         maxBodyBytes: Int = 8 * 1024,
         maxSubjectLength: Int = 60,
         maxListRows: Int = 40,
         bytesPerSecond: Double = 100,
         maxInlineViewBytes: Int = 8 * 1024,
         longTransferSeconds: Double = 300) {
        self.caller = caller
        self.sysop = sysop
        self.banner = banner
        self.calendar = calendar
        self.publishesHeardList = publishesHeardList
        self.publishesWhitePages = publishesWhitePages
        self.maxBodyLines = maxBodyLines
        self.maxBodyBytes = maxBodyBytes
        self.maxSubjectLength = maxSubjectLength
        self.maxListRows = maxListRows
        self.bytesPerSecond = bytesPerSecond
        self.maxInlineViewBytes = maxInlineViewBytes
        self.longTransferSeconds = longTransferSeconds
    }

    // MARK: - Entry

    /// Written once, when the caller connects.
    ///
    /// Deliberately not an FBB SID (`[FBB-7.011-AB1FHMRX$]` and friends): those
    /// capability letters advertise *forwarding*, and a station that announces
    /// forwarding it does not implement invites other BBSs to schedule against
    /// an address that is only on air when a Mac is awake. The banner says what
    /// this is in words instead.
    mutating func greeting(mailbox: Mailbox, now: Date) -> Output {
        var lines = ["AXTerm personal mailbox — \(sysop.uppercased())"]

        let trimmedBanner = banner.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBanner.isEmpty {
            lines.append(contentsOf: trimmedBanner.components(separatedBy: "\n"))
        }

        // Greet by name when we have been told one. This is most of the point
        // of a directory, and it shows the caller their entry is right.
        if let name = mailbox.entry(for: caller)?.value(.name) {
            lines.append("Hello \(name).")
        }

        let waiting = mailbox.messages.filter {
            $0.killedAt == nil && $0.isAddressed(to: caller) && $0.readAt == nil
        }.count
        switch waiting {
        case 0: lines.append("No new messages for you.")
        case 1: lines.append("1 message for you.")
        default: lines.append("\(waiting) messages for you.")
        }

        // How the directory actually fills up: ask, once, at the only moment
        // the caller is present and it costs them a line each to answer.
        if mailbox.entry(for: caller)?.value(.name) == nil {
            state = .registering(remaining: WhitePagesEntry.Key.registration)
            lines.append("")
            lines.append("I have not met you before. Press Return to skip anything.")
            lines.append(WhitePagesEntry.Key.registration[0].question + ":")
            return Output(lines: lines, prompt: nil)
        }

        lines.append("")
        lines.append(Self.commandSummary)
        return Output(lines: lines)
    }

    // MARK: - Lines

    mutating func handle(line: String, mailbox: Mailbox, now: Date) -> Output {
        switch state {
        case .closed:
            return Output(lines: [], prompt: nil)
        case .awaitingSubject(let to, let homeBBS):
            return takeSubject(line, to: to, homeBBS: homeBBS)
        case .composing(let to, let subject, let homeBBS, let lines):
            return takeBodyLine(line, to: to, subject: subject, homeBBS: homeBBS,
                                soFar: lines, mailbox: mailbox, now: now)
        case .registering(let remaining):
            return takeRegistration(line, remaining: remaining, now: now)
        case .command:
            return runCommand(line, mailbox: mailbox, now: now)
        }
    }

    // MARK: - Commands

    private static let commandSummary =
        "H = help, L = list, R n = read, S CALL = send, W = files, "
        + "D name = download, I CALL = who, B = bye"

    private mutating func runCommand(_ raw: String, mailbox: Mailbox, now: Date) -> Output {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Output() }

        // Split once: several commands take free text (a name, a location)
        // rather than a single token.
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = String(parts[0]).uppercased()
        let rest = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
            : ""
        let argument = rest.isEmpty
            ? nil
            : String(rest.split(separator: " ")[0])

        switch verb {
        case "H", "?", "HELP":
            return Output(lines: help())
        case "V", "VER", "VERSION":
            return Output(lines: [Self.version])
        case "I", "INFO":
            return Output(lines: info(rest, mailbox: mailbox))
        // Cross-dialect courtesy: BPQ operators type MH, Kantronics
        // operators JHEARD — a lifetime habit deserves an answer, not
        // "? MH". Understanding more dialects costs nothing; SPEAKING
        // another node's dialect (banners, prompts) is a different thing
        // entirely and deliberately not done — it would poison the
        // capability fingerprints other stations route by.
        case "J", "HEARD", "MH", "MHEARD", "JHEARD":
            return Output(lines: heardList(mailbox: mailbox))
        case "WP":
            return Output(lines: directory(mailbox: mailbox))
        // `W` is FBB's file directory. `F`/`FILES` kept as aliases because
        // plenty of node software spells it that way and a caller who guesses
        // either should not be told they guessed wrong.
        case "W", "F", "FILES":
            return Output(lines: rest.isEmpty
                          ? fileAreas(mailbox: mailbox)
                          : fileList(area: rest, mailbox: mailbox))
        case "WN", "FN", "NEW":
            return Output(lines: newFiles(mailbox: mailbox))
        case "D", "DOWNLOAD":
            return download(rest, mailbox: mailbox)
        case "U", "UPLOAD":
            return Output(lines: ["Ready — start your upload now."],
                          effects: [.beginUpload])
        case "A", "ABORT":
            pendingDownload = nil
            return Output(lines: ["Stopped."], effects: [.abortTransfer])
        case "L", "LIST":
            return Output(lines: list(mailbox: mailbox, filter: .all))
        case "LM":
            return Output(lines: list(mailbox: mailbox, filter: .mine))
        case "LB":
            return Output(lines: list(mailbox: mailbox, filter: .bulletins))
        case "LL":
            return Output(lines: list(mailbox: mailbox, filter: .all,
                                      lastN: argument.flatMap(Int.init) ?? 10))
        case "R", "READ":
            return read(argument, mailbox: mailbox, now: now)
        case "RM":
            return readMine(mailbox: mailbox, now: now)
        case "S", "SEND", "SP":
            return beginSend(rest.isEmpty ? sysop : rest)
        case "SB":
            return beginSend(BBSMessage.allCall)
        case "K", "KILL":
            return kill(argument, mailbox: mailbox, now: now)
        case "KM":
            return killMine(mailbox: mailbox, now: now)
        case "N":
            return learn(.name, value: rest, now: now)
        case "NH":
            return learn(.homeBBS, value: rest, now: now)
        case "NQ":
            return learn(.qth, value: rest, now: now)
        case "NZ":
            return learn(.zip, value: rest, now: now)
        case "B", "BYE", "Q", "QUIT":
            state = .closed
            return Output(lines: ["73 de \(sysop.uppercased())"],
                          prompt: nil, effects: [.disconnect])
        default:
            return Output(lines: ["? \(verb) — \(Self.commandSummary)"])
        }
    }

    private func help() -> [String] {
        [
            "H          this help",
            "L          list messages you can read",
            "LM / LB    list only your mail / only bulletins",
            "LL n       list the last n",
            "R n        read message n",
            "RM         read all your unread mail",
            "S CALL     send a message to CALL (S alone leaves mail for the sysop)",
            "SB         post a bulletin every caller can read",
            "K n        kill message n (yours only)",
            "KM         kill your mail that you have already read",
            "W          file areas         W <area>  what is in one",
            "WN         what is new since your last call",
            "D <name>   download (text is sent as text — no transfer needed)",
            "U          upload a file to the sysop",
            "A          stop a listing or transfer",
            "I          about this station",
            "I CALL     what the directory knows about CALL",
            "WP         everyone in the directory",
            "J          stations heard here recently",
            "N name     your name            NQ  your town and state",
            "NH bbs     your home BBS        NZ  your postcode",
            "V          version",
            "B          disconnect",
            "",
            "When sending, end the message with /EX on a line by itself."
        ]
    }

    // MARK: - Info and directory

    private func info(_ argument: String, mailbox: Mailbox) -> [String] {
        guard !argument.isEmpty else {
            var lines = ["\(sysop.uppercased()) — \(Self.version)"]
            let trimmed = mailbox.stationInfo.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(contentsOf: trimmed.components(separatedBy: "\n"))
            }
            let live = mailbox.messages.filter { $0.killedAt == nil }.count
            lines.append("\(live) message\(live == 1 ? "" : "s") on file.")
            return lines
        }
        let callsign = BBSMessage.baseCall(argument)
        guard let entry = mailbox.entry(for: callsign) else {
            return ["Nothing on file for \(callsign)."]
        }
        return entry.report()
    }

    private func directory(mailbox: Mailbox) -> [String] {
        guard publishesWhitePages else {
            return ["The directory is not published by this station."]
        }
        let entries = mailbox.whitePages.values
            .filter { !$0.isEmpty }
            .sorted { $0.callsign < $1.callsign }
        guard !entries.isEmpty else {
            return ["The directory is empty. Add yourself with  N Your Name"]
        }

        var lines = ["CALL      NAME             LOCATION"]
        for entry in entries.prefix(maxListRows) {
            lines.append(
                Self.pad(entry.callsign, to: 9) + " "
                + Self.pad(entry.value(.name) ?? "—", to: 16) + " "
                + Self.truncate(entry.value(.qth) ?? "—", to: 24))
        }
        // Never silently truncated: a listing that stops without saying so
        // reads as "that is all there is".
        if entries.count > maxListRows {
            lines.append("… \(entries.count - maxListRows) more not shown.")
        }
        return lines
    }

    private func heardList(mailbox: Mailbox) -> [String] {
        guard publishesHeardList else {
            return ["The heard list is not published by this station."]
        }
        let heard = mailbox.heard.sorted { $0.lastHeard > $1.lastHeard }
        guard !heard.isEmpty else { return ["Nothing heard yet."] }

        var lines = ["CALL      LAST HEARD"]
        for station in heard.prefix(maxListRows) {
            lines.append(Self.pad(station.callsign.uppercased(), to: 9) + " "
                         + shortDate(station.lastHeard) + " " + shortTime(station.lastHeard))
        }
        if heard.count > maxListRows {
            lines.append("… \(heard.count - maxListRows) more not shown.")
        }
        return lines
    }

    // MARK: - Registration

    private mutating func takeRegistration(_ raw: String,
                                           remaining: [WhitePagesEntry.Key],
                                           now: Date) -> Output {
        guard let current = remaining.first else {
            state = .command
            return Output(lines: [Self.commandSummary])
        }
        let answer = raw.trimmingCharacters(in: .whitespaces)

        // `A` leaves the whole thing, as it does everywhere else. A caller who
        // did not want to be interviewed should not have to press Return four
        // times to escape.
        if answer.uppercased() == "A" {
            state = .command
            return Output(lines: ["No problem.", Self.commandSummary])
        }

        var effects: [Effect] = []
        if !answer.isEmpty {
            effects.append(.learnWhitePages(
                callsign: BBSMessage.baseCall(caller),
                key: current, value: answer,
                source: .selfReported, at: now))
        }

        let rest = Array(remaining.dropFirst())
        guard let next = rest.first else {
            state = .command
            return Output(lines: ["Thank you.", "", Self.commandSummary],
                          effects: effects)
        }
        state = .registering(remaining: rest)
        return Output(lines: [next.question + ":"], prompt: nil, effects: effects)
    }

    // MARK: - Learning about the caller

    private func learn(_ key: WhitePagesEntry.Key,
                       value: String,
                       now: Date) -> Output {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return Output(lines: ["Usage: \(key.command) <\(key.label.lowercased())>"])
        }
        // A caller may only describe themselves. Letting `N` take a callsign
        // would make the directory writable by anyone who can key a radio.
        return Output(
            lines: ["\(key.label) noted: \(trimmed)"],
            effects: [.learnWhitePages(callsign: BBSMessage.baseCall(caller),
                                       key: key, value: trimmed,
                                       source: .selfReported, at: now)])
    }

    // MARK: - List

    private enum ListFilter { case all, mine, bulletins }

    private func list(mailbox: Mailbox,
                      filter: ListFilter,
                      lastN: Int? = nil) -> [String] {
        var visible = mailbox.messages
            .filter { $0.isReadable(by: caller) }
            .filter {
                switch filter {
                case .all: true
                case .mine: $0.isAddressed(to: caller)
                case .bulletins: $0.isBulletin
                }
            }
            .sorted { $0.id < $1.id }

        if let lastN, lastN > 0, visible.count > lastN {
            visible = Array(visible.suffix(lastN))
        }

        guard !visible.isEmpty else {
            return [filter == .mine ? "No mail for you." : "No messages."]
        }

        let shown = visible.suffix(maxListRows)
        var lines = ["  #  DATE   FROM     TO     SUBJECT"]
        for message in shown {
            let flag = message.readAt == nil && message.isAddressed(to: caller) ? "*" : " "
            lines.append(
                Self.rightPad(String(message.id), to: 3)
                + flag + " "
                + shortDate(message.receivedAt) + "  "
                + Self.pad(message.from.uppercased(), to: 8) + " "
                + Self.pad(message.to.uppercased(), to: 6) + " "
                + Self.truncate(message.subject, to: 30)
            )
        }
        if visible.count > shown.count {
            lines.append("… \(visible.count - shown.count) older not shown; use LL n.")
        }
        return lines
    }

    private func shortDate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d/%02d", parts.month ?? 0, parts.day ?? 0)
    }

    private func shortTime(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: - Read

    private func read(_ argument: String?, mailbox: Mailbox, now: Date) -> Output {
        guard let argument, let id = Int64(argument) else {
            return Output(lines: ["Usage: R n"])
        }
        // A message that exists but belongs to someone else gets *exactly* the
        // same answer as one that does not exist. Distinguishing them would
        // let a caller enumerate the sysop's private mail by number without
        // ever reading a word of it.
        guard let message = mailbox.messages.first(where: { $0.id == id }),
              message.isReadable(by: caller) else {
            return Output(lines: ["Message \(id) not found."])
        }
        return Output(lines: body(of: message), effects: readEffects(for: message, now: now))
    }

    private func readMine(mailbox: Mailbox, now: Date) -> Output {
        let unread = mailbox.messages
            .filter { $0.isReadable(by: caller) && $0.isAddressed(to: caller) && $0.readAt == nil }
            .sorted { $0.id < $1.id }
        guard !unread.isEmpty else { return Output(lines: ["No unread mail for you."]) }

        // Bounded like every other listing: a caller with forty unread
        // messages should get a session, not a monologue.
        let shown = unread.prefix(maxListRows / 4)
        var lines: [String] = []
        var effects: [Effect] = []
        for message in shown {
            lines.append(contentsOf: body(of: message))
            lines.append("")
            effects.append(contentsOf: readEffects(for: message, now: now))
        }
        if unread.count > shown.count {
            lines.append("\(unread.count - shown.count) more unread; use R n.")
        }
        return Output(lines: lines, effects: effects)
    }

    private func body(of message: BBSMessage) -> [String] {
        var lines = [
            "From: \(message.from.uppercased())  To: \(message.to.uppercased())  \(shortDate(message.receivedAt))",
            "Subj: \(message.subject)",
            ""
        ]
        lines.append(contentsOf: message.body.components(separatedBy: "\n"))
        return lines
    }

    /// Only personal mail carries a read flag; see `BBSMessage.readAt`.
    private func readEffects(for message: BBSMessage, now: Date) -> [Effect] {
        message.readAt == nil && message.isAddressed(to: caller)
            ? [.markRead(id: message.id, at: now)]
            : []
    }

    // MARK: - Kill

    private func kill(_ argument: String?, mailbox: Mailbox, now: Date) -> Output {
        guard let argument, let id = Int64(argument) else {
            return Output(lines: ["Usage: K n"])
        }
        guard let message = mailbox.messages.first(where: { $0.id == id }),
              message.isReadable(by: caller) else {
            return Output(lines: ["Message \(id) not found."])
        }
        guard message.isKillable(by: caller) else {
            return Output(lines: ["Message \(id) is not yours to kill."])
        }
        return Output(lines: ["Message \(id) killed."],
                      effects: [.kill(id: id, at: now)])
    }

    private func killMine(mailbox: Mailbox, now: Date) -> Output {
        // Read mail only. A caller who types KM before reading should not
        // discover they have destroyed something they never saw.
        let done = mailbox.messages
            .filter { $0.killedAt == nil && $0.isAddressed(to: caller) && $0.readAt != nil }
            .sorted { $0.id < $1.id }
        guard !done.isEmpty else {
            return Output(lines: ["Nothing to kill — you have no mail you have already read."])
        }
        return Output(
            lines: ["Killed \(done.count) message\(done.count == 1 ? "" : "s"): "
                    + done.map { String($0.id) }.joined(separator: " ")],
            effects: done.map { .kill(id: $0.id, at: now) })
    }

    // MARK: - Send

    /// Accepts `CALL`, `CALL @ BBS` and `CALL@BBS` — spaces around the `@` are
    /// optional in every mailbox that has ever implemented this, so they are
    /// optional here.
    private mutating func beginSend(_ destination: String) -> Output {
        let cleaned = destination
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        let halves = cleaned.split(separator: "@", maxSplits: 1)
        let to = halves.first.map(String.init) ?? ""
        let homeBBS = halves.count > 1 ? String(halves[1]) : nil

        guard !to.isEmpty else { return Output(lines: ["Usage: S CALL"]) }
        state = .awaitingSubject(to: to, homeBBS: homeBBS)
        let notice = BBSMessage.baseCall(to) == BBSMessage.allCall
            ? ["Bulletin to ALL — every caller can read this."]
            : []
        return Output(lines: notice + ["Subj:"], prompt: nil)
    }

    private mutating func takeSubject(_ raw: String, to: String, homeBBS: String?) -> Output {
        let subject = Self.truncate(
            raw.trimmingCharacters(in: .whitespaces), to: maxSubjectLength)
        state = .composing(to: to, subject: subject.isEmpty ? "(none)" : subject,
                           homeBBS: homeBBS, lines: [])
        return Output(
            lines: ["Enter message, end with /EX on its own line."],
            prompt: nil)
    }

    /// End-of-message markers. `/EX` is the convention every packet mailbox
    /// uses; Ctrl-Z is what terminal software of the era sent for the same
    /// thing, and costs one comparison to honour.
    private static let endOfMessage = "/EX"
    private static let ctrlZ: Character = "\u{1A}"

    private mutating func takeBodyLine(_ raw: String,
                                       to: String,
                                       subject: String,
                                       homeBBS: String?,
                                       soFar: [String],
                                       mailbox: Mailbox,
                                       now: Date) -> Output {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.uppercased() == Self.endOfMessage || raw.contains(Self.ctrlZ) {
            state = .command
            let message = BBSMessage(
                id: mailbox.nextID,
                from: caller.uppercased(),
                to: to,
                subject: subject,
                body: soFar.joined(separator: "\n"),
                receivedAt: now)

            var effects: [Effect] = [.store(message)]
            // `S CALL @ BBS` is where a home BBS comes from on a real network.
            // Recorded as inference, never as testimony: the sender is telling
            // us about somebody else.
            if let homeBBS, !homeBBS.isEmpty {
                effects.append(.learnWhitePages(
                    callsign: BBSMessage.baseCall(to),
                    key: .homeBBS, value: homeBBS,
                    source: .fromMessage, at: now))
            }
            return Output(lines: ["Message \(mailbox.nextID) stored."], effects: effects)
        }

        var lines = soFar
        lines.append(raw)

        // Refused rather than truncated: a caller whose message was silently
        // cut in half has no way to know, and believes it was delivered whole.
        let bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        if lines.count > maxBodyLines || bytes > maxBodyBytes {
            state = .command
            return Output(
                lines: ["Message too long (limit \(maxBodyLines) lines, "
                        + "\(maxBodyBytes / 1024)K) — nothing was stored."])
        }

        state = .composing(to: to, subject: subject, homeBBS: homeBBS, lines: lines)
        return Output(lines: [], prompt: nil)
    }

    // MARK: - Files

    private func fileAreas(mailbox: Mailbox) -> [String] {
        guard !mailbox.files.isEmpty else {
            return ["No files are shared here."]
        }
        var lines = ["AREA      FILES   SIZE  ABOUT"]
        for area in mailbox.files.areas.sorted(by: { $0.name < $1.name }) {
            let contents = mailbox.files.files(in: area.name)
            guard !contents.isEmpty else { continue }
            let bytes = contents.reduce(0) { $0 + $1.byteCount }
            lines.append(
                Self.pad(area.name, to: 9) + " "
                + Self.rightPad(String(contents.count), to: 5) + " "
                + Self.rightPad(BBSFileIndex.size(bytes), to: 6) + "  "
                + Self.truncate(area.about, to: 28))
        }
        lines.append("W <area> lists one. WN shows what is new since your last call.")
        return lines
    }

    /// The column that matters is TIME, not SIZE.
    ///
    /// "146K" sounds small and is twenty-five minutes of a channel somebody
    /// else also wants. A caller deciding what to download is deciding how
    /// long to hold the frequency, so the answer is given in those terms.
    private func fileRows(_ files: [BBSSharedFile], mailbox: Mailbox) -> [String] {
        var lines = ["NAME              SIZE  TIME  ABOUT"]
        for file in files.prefix(maxListRows) {
            lines.append(
                Self.pad(file.name, to: 17) + " "
                + Self.rightPad(BBSFileIndex.size(file.byteCount), to: 5) + " "
                + Self.rightPad(BBSFileIndex.duration(bytes: file.byteCount,
                                                      bytesPerSecond: bytesPerSecond), to: 5) + "  "
                + Self.truncate(file.about, to: 26))
        }
        if files.count > maxListRows {
            lines.append("… \(files.count - maxListRows) more not shown.")
        }
        return lines
    }

    private func fileList(area: String, mailbox: Mailbox) -> [String] {
        let key = BBSFileArea.normalize(area)
        guard mailbox.files.areas.contains(where: { $0.name == key }) else {
            return ["No area called \(key). W lists the areas."]
        }
        let contents = mailbox.files.files(in: key)
        guard !contents.isEmpty else { return ["\(key) is empty."] }
        return fileRows(contents, mailbox: mailbox)
            + ["D <name> fetches one. U uploads to the sysop."]
    }

    /// What changed since this caller was last here.
    ///
    /// The question a regular caller actually has. Sending them the whole
    /// catalogue every visit costs airtime to tell them things they already
    /// know, and the catalogue is the part they stop reading.
    private func newFiles(mailbox: Mailbox) -> [String] {
        guard !mailbox.files.isEmpty else { return ["No files are shared here."] }
        guard let since = mailbox.lastVisit else {
            return ["This is your first call — W lists everything on offer."]
        }
        let fresh = mailbox.files.files
            .filter { $0.modifiedAt > since }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        let stamp = shortDate(since)
        guard !fresh.isEmpty else {
            return ["Nothing new since your last call (\(stamp))."]
        }
        return ["\(fresh.count) new or changed since \(stamp):"]
            + fileRows(fresh, mailbox: mailbox)
    }

    private mutating func download(_ request: String, mailbox: Mailbox) -> Output {
        guard !request.isEmpty else { return Output(lines: ["Usage: D <name>"]) }
        switch mailbox.files.resolve(request) {
        case .notFound:
            pendingDownload = nil
            return Output(lines: ["No file called \(request). W lists what is here."])
        case .ambiguous(let areas):
            pendingDownload = nil
            return Output(lines: ["\(request) is in \(areas.joined(separator: ", ")) "
                                  + "— say which, e.g. D \(areas[0])/\(request)."])
        case .found(let file):
            let seconds = bytesPerSecond > 0 ? Double(file.byteCount) / bytesPerSecond : 0
            let time = BBSFileIndex.duration(bytes: file.byteCount,
                                             bytesPerSecond: bytesPerSecond)

            // Text goes out as text. No protocol to negotiate, nothing the
            // caller needs to have, and fewer bytes on the air than any
            // framing would cost — so one command covers both cases and the
            // caller never has to know which they wanted.
            if file.isText && file.byteCount <= maxInlineViewBytes {
                pendingDownload = nil
                return Output(lines: ["\(file.name) is text — sending it as text (\(time))."],
                              effects: [.viewFile(file)])
            }

            // A long transfer holds the channel against everyone else on it.
            // Asking once costs one line; finding out forty minutes in costs
            // the frequency.
            if seconds > longTransferSeconds && pendingDownload != file.id {
                pendingDownload = file.id
                return Output(lines: [
                    "\(file.name) is \(BBSFileIndex.size(file.byteCount)) — about \(time) "
                    + "of airtime.",
                    "Send  D \(request)  again to go ahead."
                ])
            }
            pendingDownload = nil
            return Output(lines: ["Sending \(file.name) (\(time))."],
                          effects: [.sendFile(file)])
        }
    }

    // MARK: - Formatting

    private static func pad(_ value: String, to width: Int) -> String {
        let clipped = truncate(value, to: width)
        return clipped + String(repeating: " ", count: max(0, width - clipped.count))
    }

    private static func rightPad(_ value: String, to width: Int) -> String {
        String(repeating: " ", count: max(0, width - value.count)) + value
    }

    private static func truncate(_ value: String, to width: Int) -> String {
        value.count <= width ? value : String(value.prefix(width))
    }
}
