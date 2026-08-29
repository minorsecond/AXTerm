//
//  BBSService.swift
//  AXTerm
//
//  Joins an inbound AX.25 session to the mailbox shell and the store.
//

import Foundation
import Combine

/// The mailbox, running.
///
/// `BBSShell` decides what to say and `BBSMessageStore` remembers it; this
/// type owns the parts that touch the world — the claim on the session's
/// bytes, line assembly, the idle timer, and the transcript the operator
/// watches. Keeping them apart is what lets the command set be tested without
/// a radio.
@MainActor
final class BBSService: ObservableObject {

    // MARK: - Observable state

    struct TranscriptLine: Identifiable, Equatable, Sendable {
        enum Direction: Equatable, Sendable { case fromCaller, toCaller, note }
        let id = UUID()
        let direction: Direction
        let text: String
        let at: Date
    }

    struct LiveCall: Equatable, Sendable {
        var callsign: String
        var startedAt: Date
        var callId: Int64
    }

    @Published private(set) var messages: [BBSMessage] = []
    @Published private(set) var calls: [BBSCall] = []
    /// The white pages directory, sorted by callsign.
    @Published private(set) var directory: [WhitePagesEntry] = []
    /// Facts recognised in BBS sessions the operator had, waiting to be
    /// accepted. Offered rather than applied — see `BBSDirectoryHarvester`.
    @Published private(set) var suggestions: [BBSDirectoryHarvester.Candidate] = []
    /// The caller being served right now, if any.
    @Published private(set) var live: LiveCall?
    /// What the current (or most recent) caller saw, both directions.
    @Published private(set) var transcript: [TranscriptLine] = []
    /// Why the last inbound call was not answered. Shown in the UI so a
    /// mailbox that is quiet for a bad reason says which reason.
    @Published private(set) var lastRefusal: String?
    @Published private(set) var storeError: String?

    /// Beyond this the oldest lines are dropped: a caller who pastes a book
    /// should not grow the window without bound.
    private static let maxTranscriptLines = 500

    // MARK: - Dependencies

    /// Nil when the database could not be opened. The mailbox then refuses
    /// to run rather than serving callers from memory and losing what they
    /// left when the app quits.
    private let store: BBSMessageStore?
    private let settings: BBSSettings
    private let coordinator: SessionCoordinator
    private let sendFrames: ([OutboundFrame]) -> Void
    private let stationCallsign: () -> String
    private let isWinlinkP2PArmed: () -> Bool
    private let winlinkP2PCallsign: () -> String
    /// What this station has heard, for `J`. Injected rather than reached for:
    /// the mailbox has no business holding a packet engine.
    private let heardStations: () -> [BBSShell.HeardStation]
    /// The catalogue and the bytes behind it. Nil when there is no database.
    private let library: BBSFileLibrary?
    /// Whether a peer has answered a capability probe, which is what decides
    /// between AXDP and YAPP for a download.
    private let peerSupportsAXDP: (String) -> Bool
    /// Throughput used for the TIME column and the long-transfer warning.
    ///
    /// Defaults to 90 B/s: 1200 baud is 150 bytes/s of raw channel, and after
    /// AX.25 framing, acks and sharing the frequency with everyone else, the
    /// delivered rate is nearer two thirds of that. An estimate that flatters
    /// itself is worse than none, because a caller plans around it.
    private let linkBytesPerSecond: () -> Double
    /// The licence record for a callsign, from the directory AXTerm already
    /// caches. **Cached only** — a mailbox answering a call must not make an
    /// internet request about whoever just called it.
    private let licenceRecord: (String) -> CallsignRecord?
    /// Posts a line to the visible console.
    ///
    /// The operator who just typed the command is watching the terminal, not
    /// the mailbox. `TxLog` was the wrong channel for this — it reaches the
    /// debug log and Sentry, neither of which is on screen.
    private let announce: (String) -> Void
    /// Resolves callsigns against the online directory. Operator-initiated
    /// only — the automatic path stays cache-only, because looking a caller up
    /// the moment they connect tells a third party who is talking to this
    /// station.
    private let resolveLicences: ([String]) async -> Void
    private let contestedIdentityHolder: () -> String?
    private let now: () -> Date

    // MARK: - Live session state

    private var subscriberToken: UUID?
    private var claim: SessionDeliveryClaim?
    private var session: AX25Session?
    private var shell: BBSShell?
    private var inputBuffer = Data()
    private var lastActivity: Date = .distantPast
    private var idleTask: Task<Void, Never>?
    private var activeTransfer: FileTransferProtocol?
    /// Armed by `U`, until the caller's first recognisable protocol frame.
    private var awaitingUpload = false
    private var uploadsThisCall = 0
    private var transferBridge: BBSTransferBridge?
    /// When this caller was last here, fixed for the duration of the call.
    private var callerLastVisit: Date?

    init(store: BBSMessageStore?,
         settings: BBSSettings,
         coordinator: SessionCoordinator,
         sendFrames: @escaping ([OutboundFrame]) -> Void,
         stationCallsign: @escaping () -> String,
         isWinlinkP2PArmed: @escaping () -> Bool,
         winlinkP2PCallsign: @escaping () -> String,
         heardStations: @escaping () -> [BBSShell.HeardStation] = { [] },
         library: BBSFileLibrary? = nil,
         peerSupportsAXDP: @escaping (String) -> Bool = { _ in false },
         linkBytesPerSecond: @escaping () -> Double = { 90 },
         licenceRecord: @escaping (String) -> CallsignRecord? = { _ in nil },
         announce: @escaping (String) -> Void = { _ in },
         resolveLicences: @escaping ([String]) async -> Void = { _ in },
         contestedIdentityHolder: @escaping () -> String? = { nil },
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.settings = settings
        self.coordinator = coordinator
        self.sendFrames = sendFrames
        self.stationCallsign = stationCallsign
        self.isWinlinkP2PArmed = isWinlinkP2PArmed
        self.winlinkP2PCallsign = winlinkP2PCallsign
        self.heardStations = heardStations
        self.library = library
        self.peerSupportsAXDP = peerSupportsAXDP
        self.linkBytesPerSecond = linkBytesPerSecond
        self.licenceRecord = licenceRecord
        self.announce = announce
        self.resolveLicences = resolveLicences
        self.contestedIdentityHolder = contestedIdentityHolder
        self.now = now
    }

    // MARK: - Lifecycle

    /// The key this service registers its address under.
    static let serviceName = "bbs"

    func attach() {
        guard subscriberToken == nil else { return }
        subscriberToken = coordinator.addInboundSessionSubscriber { [weak self] session in
            self?.handleInbound(session)
        }
        syncServiceAddress()
        // A call still marked open belongs to a previous run of the app.
        perform { try $0.closeOrphanedCalls(at: now()) }
        reload()
    }

    func detach() {
        if let subscriberToken { coordinator.removeInboundSessionSubscriber(subscriberToken) }
        subscriberToken = nil
        coordinator.sessionManager.setServiceAddress(nil, for: Self.serviceName)
    }

    /// Tells the session layer which address to accept calls on, if any.
    ///
    /// Without this the mailbox is unreachable on its own SSID: frames not
    /// addressed to a registered address are dropped before they reach the
    /// session layer, so a mailbox callsign nobody accepts is a setting that
    /// silently does nothing.
    ///
    /// Registered only while on air. Registering it always would have AXTerm
    /// answer a SABM and then say nothing, which is worse for the caller than
    /// no answer at all — they cannot tell a connected-to-nothing from a
    /// mailbox that is merely slow.
    func syncServiceAddress() {
        let address = settings.onAir ? answeringCallsign : ""
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        coordinator.sessionManager.setServiceAddress(
            trimmed.isEmpty ? nil : CallsignNormalizer.toAddress(trimmed),
            for: Self.serviceName)
    }

    /// Called when the app is quitting or the machine is going to sleep.
    ///
    /// Vanishing mid-session is the expensive failure: the caller's software
    /// retries into an address that stopped existing, and they have no way to
    /// tell that from a bad path. Saying goodbye costs one frame.
    func shutdown(reason: String = "closing") {
        guard let session else { return }
        write(["", "*** \(reason) — 73"])
        if let disc = coordinator.sessionManager.disconnect(session: session) {
            sendFrames([disc])
        }
        endCall(unexpected: false)
    }

    var isOnAir: Bool { settings.onAir }

    /// False when there is no database to keep messages in.
    var isAvailable: Bool { store != nil }

    /// The throughput figure quoted to callers, exposed so the operator's own
    /// file list shows the same times the caller is told.
    var linkThroughput: Double { linkBytesPerSecond() }

    var answeringCallsign: String {
        settings.effectiveCallsign(stationCallsign: stationCallsign())
    }

    /// The refusal the *next* call would get, or nil when it would be answered.
    /// Drives the status header, so the operator learns why before a caller does.
    func currentRefusal() -> String? {
        let decision = listener().decide(called: answeringCallsign, isInitiator: false)
        return decision.isAnswer ? nil : decision.explanation
    }

    // MARK: - Answering

    private func listener() -> PersonalBBSListener {
        PersonalBBSListener(
            isArmed: settings.onAir,
            winlinkP2PAddress: isWinlinkP2PArmed() ? winlinkP2PCallsign() : nil,
            myCallsign: answeringCallsign,
            contestedBy: contestedIdentityHolder(),
            currentCaller: live?.callsign)
    }

    private func handleInbound(_ session: AX25Session) {
        let decision = listener().decide(
            called: session.localAddress.display,
            isInitiator: session.isInitiator)

        guard decision.isAnswer else {
            // An outbound call of our own is not a refusal worth reporting.
            if decision != .weInitiated {
                lastRefusal = "\(session.remoteAddress.display.uppercased()): \(decision.explanation)"
            }
            return
        }
        answer(session)
    }

    private func answer(_ session: AX25Session) {
        // Answering without somewhere to put what the caller leaves would take
        // their message and drop it on quit, which is worse than not answering.
        guard store != nil else {
            lastRefusal = "\(session.remoteAddress.display.uppercased()): the AXTerm database could not be opened"
            return
        }

        // The claim keeps these bytes away from the terminal and from AXDP
        // reassembly. Failing to get it means something else already owns the
        // conversation, and two readers of one stream is worse than no mailbox.
        guard let claim = coordinator.sessionManager.claimDelivery(
            for: session.key,
            handler: { [weak self] _, data in self?.receive(data) },
            stateHandler: { [weak self] _, _, newState in
                guard newState == .disconnected || newState == .error else { return }
                self?.endCall(unexpected: true)
            }
        ) else {
            lastRefusal = "\(session.remoteAddress.display.uppercased()): another feature owns this session"
            return
        }

        let caller = session.remoteAddress.display.uppercased()
        let at = now()

        self.claim = claim
        self.session = session
        self.inputBuffer = Data()
        self.transcript = []
        self.lastActivity = at
        self.lastRefusal = nil

        var shell = BBSShell(
            caller: caller,
            sysop: answeringCallsign,
            banner: settings.banner,
            publishesHeardList: settings.publishHeardList,
            publishesWhitePages: settings.publishWhitePages,
            bytesPerSecond: linkBytesPerSecond())

        let callId = (store.flatMap { try? $0.beginCall(callsign: caller, at: at) }) ?? -1
        live = LiveCall(callsign: caller, startedAt: at, callId: callId)
        // Read before anything else touches the call log, and held for the
        // call: `FN` must mean "since you were last here", not "since a
        // moment ago".
        callerLastVisit = store.flatMap {
            try? $0.lastVisit(callsign: caller, excluding: callId)
        }

        // Fill what the licence already answers before the greeting is
        // composed, so a first-time caller can be greeted by name rather than
        // asked for one this station could have looked up.
        learnFromLicence(caller: caller, at: at)

        let mailbox = currentMailbox()
        let greeting = shell.greeting(mailbox: mailbox, now: at)
        self.shell = shell
        emit(greeting)
        reload()
        startIdleTimer()
    }

    // MARK: - Inbound bytes

    private func receive(_ data: Data) {
        lastActivity = now()

        // A running transfer owns the byte stream. Feeding these to the line
        // assembler would both corrupt the protocol and scatter binary through
        // the transcript.
        if let activeTransfer {
            activeTransfer.handleIncomingData(data)
            return
        }

        // Armed by `U`. If the first bytes are not a protocol we know, the
        // caller probably typed something instead — fall through and treat it
        // as a command rather than swallowing it.
        if awaitingUpload, startReceiving(data) { return }
        awaitingUpload = false

        inputBuffer.append(data)

        // Callers terminate with CR; some software sends CRLF and a few send
        // bare LF. Splitting on either and dropping empties between them
        // handles all three without a state flag.
        while let index = inputBuffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let lineBytes = inputBuffer[inputBuffer.startIndex..<index]
            inputBuffer.removeSubrange(inputBuffer.startIndex...index)
            let line = String(decoding: lineBytes, as: UTF8.self)
            // A CRLF leaves an empty fragment behind; a caller pressing Return
            // on an empty prompt sends a real empty line. Telling them apart is
            // not worth the state — the shell treats a blank command line as a
            // reprompt, and a blank line inside a message is content the caller
            // typed, which arrives as its own CR either way.
            process(line: line)
        }
    }

    private func process(line: String) {
        guard var shell, session != nil else { return }
        append(.fromCaller, line)

        let output = shell.handle(line: line, mailbox: currentMailbox(), now: now())
        self.shell = shell

        for effect in output.effects { apply(effect) }
        emit(output)
        if output.effects.contains(.disconnect) {
            disconnectCurrent()
        } else {
            reload()
        }
    }

    private func apply(_ effect: BBSShell.Effect) {
        switch effect {
        case .store(let message):
            perform { try $0.store(message) }
            note("left mail for \(message.to) — \"\(message.subject)\"")
        case .kill(let id, let at):
            perform { try $0.kill(id: id, at: at) }
            note("killed \(id)")
        case .markRead(let id, let at):
            perform { try $0.markRead(id: id, at: at) }
            note("read \(id)")
        case .learnWhitePages(let callsign, let key, let value, let source, let at):
            // Only report it in the call log when it actually changed
            // something: a caller re-sending the same name every session
            // should not fill the log with events that are not news.
            var changed = false
            perform {
                changed = try $0.learnWhitePages(
                    callsign: callsign, key: key, value: value, source: source, at: at)
            }
            if changed {
                note(source == .selfReported
                     ? "told us \(key.label.lowercased()): \(value)"
                     : "\(callsign) \(key.label.lowercased()) noted as \(value)")
            }
        case .viewFile(let file):
            viewFile(file)
        case .sendFile(let file):
            sendFile(file)
        case .beginUpload:
            beginUpload()
        case .abortTransfer:
            awaitingUpload = false
            abandonTransfer()
        case .disconnect:
            break
        }
    }

    // MARK: - Outbound

    private func emit(_ output: BBSShell.Output) {
        var lines = output.lines
        if let prompt = output.prompt { lines.append(prompt) }
        write(lines)
    }

    private func write(_ lines: [String]) {
        guard let session, !lines.isEmpty else { return }
        for line in lines { append(.toCaller, line) }

        // CR, not CRLF: the packet convention every terminal on the channel
        // already expects, and half the bytes.
        let text = lines.joined(separator: "\r") + "\r"
        let frames = coordinator.sessionManager.sendData(
            Data(text.utf8),
            to: session.remoteAddress,
            path: session.path,
            channel: session.channel,
            pid: 0xF0,
            displayInfo: "BBS (\(text.utf8.count) bytes)")
        sendFrames(frames)
    }

    // MARK: - Ending

    private func disconnectCurrent() {
        guard let session else { return }
        if let disc = coordinator.sessionManager.disconnect(session: session) {
            sendFrames([disc])
        }
        endCall(unexpected: false)
    }

    private func endCall(unexpected: Bool) {
        abandonTransfer()
        idleTask?.cancel()
        idleTask = nil
        if let claim { coordinator.sessionManager.releaseDelivery(claim) }
        if let live {
            perform { try $0.endCall(id: live.callId, at: now(), unexpected: unexpected) }
        }
        if unexpected { append(.note, "link dropped") }
        claim = nil
        session = nil
        shell = nil
        inputBuffer = Data()
        live = nil
        callerLastVisit = nil
        uploadsThisCall = 0
        reload()
    }

    // MARK: - Idle

    private func startIdleTimer() {
        idleTask?.cancel()
        let timeout = settings.idleTimeout
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                guard let self, self.session != nil else { return }
                guard self.now().timeIntervalSince(self.lastActivity) >= timeout else { continue }
                self.write(["", "*** no activity — disconnecting"])
                self.disconnectCurrent()
                return
            }
        }
    }

    // MARK: - Store plumbing

    private func currentMailbox() -> BBSShell.Mailbox {
        var mailbox = store.flatMap { try? $0.mailbox() } ?? BBSShell.Mailbox()
        mailbox.whitePages = store.flatMap { try? $0.whitePages() } ?? [:]
        mailbox.heard = heardStations()
        mailbox.stationInfo = settings.stationInfo
        mailbox.files = library?.index ?? BBSFileIndex()
        mailbox.lastVisit = callerLastVisit
        return mailbox
    }

    func reload() {
        messages = store.flatMap { try? $0.allMessages() } ?? []
        calls = store.flatMap { try? $0.recentCalls(limit: 200) } ?? []
        directory = (store.flatMap { try? $0.whitePages() } ?? [:])
            .values
            .sorted { $0.callsign < $1.callsign }
    }

    /// Sysop actions from the app's own UI.
    func sysopKill(id: Int64) { perform { try $0.kill(id: id, at: now()) }; reload() }
    func sysopRestore(id: Int64) { perform { try $0.restore(id: id) }; reload() }
    func sysopPurge(id: Int64) { perform { try $0.purge(id: id) }; reload() }
    func sysopMarkRead(id: Int64) { perform { try $0.markRead(id: id, at: now()) }; reload() }

    /// Directory edits from the app. Recorded as self-reported: the operator
    /// is a person stating a fact, the same as a caller typing it.
    func sysopSetDirectoryField(callsign: String, key: WhitePagesEntry.Key, value: String) {
        perform { try $0.setWhitePagesField(callsign: callsign, key: key,
                                            value: value, at: now()) }
        reload()
    }

    func sysopDeleteDirectoryEntry(callsign: String) {
        perform { try $0.deleteWhitePages(callsign: callsign) }
        reload()
    }

    /// Post a message from the sysop — a reply, or a bulletin to `ALL`.
    func sysopPost(to recipient: String, subject: String, body: String) {
        let mailbox = currentMailbox()
        let message = BBSMessage(
            id: mailbox.nextID,
            from: answeringCallsign,
            to: recipient.trimmingCharacters(in: .whitespaces).uppercased(),
            subject: subject,
            body: body,
            receivedAt: now())
        perform { try $0.store(message) }
        reload()
    }

    private func perform(_ work: (BBSMessageStore) throws -> Void) {
        guard let store else { return }
        do { try work(store) } catch { storeError = "\(error)" }
    }

    /// Merges the cached licence record for a callsign into the directory.
    ///
    /// Under the usual rule, so anything the operator was told outranks it and
    /// anything guessed from traffic is improved by it.
    private func learnFromLicence(caller: String, at date: Date) {
        let key = BBSMessage.baseCall(caller)
        guard let record = licenceRecord(key) else { return }
        for (field, value) in WhitePagesEntry.fields(from: record) {
            perform {
                _ = try $0.learnWhitePages(callsign: key, key: field, value: value,
                                           source: .licenceRecord, at: date)
            }
        }
    }

    /// Sysop action: look the directory up and fill what comes back.
    ///
    /// Deliberately separate from the automatic path, and the one place a
    /// network lookup is right: the operator is asking, about callsigns they
    /// chose, at a moment of their choosing. Covers stations nobody has called
    /// from, which is most of the interesting ones.
    func fillDirectoryFromLicences(for callsigns: [String]) async {
        let wanted = callsigns
            .map { BBSMessage.baseCall($0) }
            .filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return }

        await resolveLicences(wanted)

        let at = now()
        for callsign in wanted { learnFromLicence(caller: callsign, at: at) }
        reload()
    }

    // MARK: - Learning from other stations

    /// Feeds a line the operator received from another BBS to the harvester.
    ///
    /// Only lines from a session the operator opened themselves. Nothing here
    /// queries anybody — it reads what already arrived.
    func observeSessionText(_ text: String, from peer: String) {
        let known = Set(directory.map(\.callsign))
        let fresh = BBSDirectoryHarvester.candidates(in: text.components(separatedBy: .newlines))
            .filter { candidate in
                // Don't offer what we already hold with better provenance —
                // the operator should only be asked about news.
                guard let existing = directory.first(where: { $0.callsign == candidate.callsign })
                else { return true }
                guard let field = existing.fields[candidate.key] else { return true }
                return field.source == .observed && field.value != candidate.value
            }
            .filter { candidate in
                // Nor the same suggestion twice.
                !suggestions.contains { $0.id == candidate.id }
            }
        guard !fresh.isEmpty else { return }
        _ = known
        suggestions.append(contentsOf: fresh)
        // Bounded: a long session with a busy BBS should not grow this without
        // limit while the operator is not looking.
        if suggestions.count > 200 {
            suggestions.removeFirst(suggestions.count - 200)
        }
        let what = fresh.count == 1
            ? "\(fresh[0].callsign) \(fresh[0].key.label.lowercased()): \(fresh[0].value)"
            : "\(fresh.count) entries"
        append(.note, "noted \(what) from \(peer)")
        // On screen, where the operator is. A finding surfaced only where they
        // are not is a finding they never see.
        announce("White pages from \(peer) — \(what). Review in BBS → Directory.")
    }

    func acceptSuggestion(_ candidate: BBSDirectoryHarvester.Candidate) {
        perform {
            _ = try $0.learnWhitePages(callsign: candidate.callsign, key: candidate.key,
                                       value: candidate.value, source: .observed, at: now())
        }
        suggestions.removeAll { $0.id == candidate.id }
        reload()
    }

    func acceptAllSuggestions() {
        for candidate in suggestions {
            perform {
                _ = try $0.learnWhitePages(callsign: candidate.callsign, key: candidate.key,
                                           value: candidate.value, source: .observed, at: now())
            }
        }
        suggestions.removeAll()
        reload()
    }

    func dismissSuggestion(_ candidate: BBSDirectoryHarvester.Candidate) {
        suggestions.removeAll { $0.id == candidate.id }
    }

    func dismissAllSuggestions() { suggestions.removeAll() }

    // MARK: - Files

    /// Types a text file down the session.
    ///
    /// The cheapest way to move a file on this link: no negotiation, no
    /// framing, no protocol the caller has to have. Most of what a packet
    /// file area actually holds is text, so this is the common path rather
    /// than the fallback.
    private func viewFile(_ file: BBSSharedFile) {
        guard let data = library?.data(for: file) else {
            write(["\(file.name) could not be read."])
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        write(["--- \(file.name) ---"]
              + text.components(separatedBy: .newlines)
              + ["--- end of \(file.name) ---"])
        note("read \(file.area)/\(file.name)")
    }

    /// Hands the session to a transfer protocol for the duration.
    ///
    /// AXDP when the caller has answered a capability probe — it compresses,
    /// resumes and retransmits selectively, all of which is airtime saved.
    /// YAPP otherwise, because it is what every other packet terminal on the
    /// band actually implements.
    private func sendFile(_ file: BBSSharedFile) {
        guard activeTransfer == nil else {
            write(["A transfer is already running."])
            return
        }
        guard let data = library?.data(for: file) else {
            write(["\(file.name) could not be read."])
            return
        }

        let type: TransferProtocolType =
            peerSupportsAXDP(live?.callsign ?? "") ? .axdp : .yapp
        let driver = TransferProtocolRegistry.shared.createProtocol(type: type)

        let bridge = makeBridge(what: file.name)
        driver.delegate = bridge

        do {
            try driver.startSending(fileName: file.name, fileData: data)
            transferBridge = bridge
            activeTransfer = driver
            append(.note, "sending \(file.name) by \(type.displayName)")
            note("downloaded \(file.area)/\(file.name)")
        } catch {
            write(["\(file.name) could not be sent: \(error.localizedDescription)"])
        }
    }

    private func makeBridge(what: String) -> BBSTransferBridge {
        BBSTransferBridge(
            send: { [weak self] bytes in
                Task { @MainActor [weak self] in self?.writeRaw(bytes) }
            },
            finish: { [weak self] ok, error in
                Task { @MainActor [weak self] in
                    self?.finishTransfer(ok: ok, error: error, what: what)
                }
            },
            confirm: { [weak self] metadata in
                Task { @MainActor [weak self] in self?.decideUpload(metadata) }
            },
            received: { [weak self] data, metadata in
                Task { @MainActor [weak self] in self?.storeUpload(data, metadata) }
            })
    }

    private func finishTransfer(ok: Bool, error: String?, what: String) {
        activeTransfer = nil
        transferBridge = nil
        guard session != nil else { return }
        write(ok
              ? ["\(what) done."]
              : ["\(what) failed: \(error ?? "no reason given")"])
        write([BBSShell.commandPrompt])
    }

    /// Bytes a transfer protocol produced, straight onto the session with no
    /// line discipline — the payload is framed by the protocol, not by us.
    private func writeRaw(_ data: Data) {
        guard let session else { return }
        let frames = coordinator.sessionManager.sendData(
            data,
            to: session.remoteAddress,
            path: session.path,
            channel: session.channel,
            pid: 0xF0,
            displayInfo: "BBS file (\(data.count) bytes)")
        sendFrames(frames)
    }

    /// Abandons a transfer whose session went away, so the next caller is not
    /// refused by a protocol nobody is listening to.
    private func abandonTransfer() {
        activeTransfer?.cancel()
        activeTransfer = nil
        transferBridge = nil
        awaitingUpload = false
    }

    // MARK: - Uploads

    private func uploadPolicy() -> BBSUploadPolicy {
        BBSUploadPolicy(
            isEnabled: settings.acceptUploads,
            hasInbox: library?.hasInbox ?? false,
            maxFileBytes: settings.maxUploadBytes,
            quotaBytes: settings.uploadQuotaBytes,
            usedBytes: library?.inboxBytes ?? 0,
            uploadsThisCall: uploadsThisCall)
    }

    private func beginUpload() {
        guard activeTransfer == nil else {
            write(["A transfer is already running."])
            return
        }
        // Refused up front where the reason is already knowable, rather than
        // after the caller has spent airtime sending a header.
        let policy = uploadPolicy()
        if case .reject(let reason) = policy.decide(filename: "probe.bin", size: 1) {
            write(["Sorry — \(reason)."])
            return
        }
        awaitingUpload = true
    }

    /// Picks the protocol from the caller's own first bytes.
    ///
    /// The mailbox cannot know in advance what the caller's software speaks,
    /// and the registry already recognises each protocol's opening frame.
    private func startReceiving(_ data: Data) -> Bool {
        guard let driver = TransferProtocolRegistry.shared.detectAndCreate(from: data) else {
            return false
        }
        driver.delegate = makeBridge(what: "the upload")
        transferBridge = driver.delegate as? BBSTransferBridge
        activeTransfer = driver
        awaitingUpload = false
        driver.handleIncomingData(data)
        return true
    }

    private func decideUpload(_ metadata: TransferFileMetadata) {
        switch uploadPolicy().decide(filename: metadata.fileName, size: metadata.fileSize) {
        case .accept:
            activeTransfer?.acceptTransfer()
        case .reject(let reason):
            activeTransfer?.rejectTransfer(reason: reason)
            write(["Upload refused — \(reason)."])
            abandonTransfer()
        }
    }

    private func storeUpload(_ data: Data, _ metadata: TransferFileMetadata) {
        guard let safe = BBSUploadPolicy.sanitize(metadata.fileName),
              let saved = library?.saveUpload(name: safe, data: data) else {
            write(["That file could not be saved."])
            return
        }
        uploadsThisCall += 1
        write(["Received \(saved) (\(BBSFileIndex.size(data.count)))."])
        // Named in the call log because an unattended station accepting files
        // is exactly the thing the operator wants to read about afterwards.
        note("uploaded \(saved)")
    }

    // MARK: - Transcript

    private func note(_ text: String) {
        append(.note, text)
        if let live { perform { try $0.appendAction(callId: live.callId, action: text) } }
    }

    private func append(_ direction: TranscriptLine.Direction, _ text: String) {
        transcript.append(TranscriptLine(direction: direction, text: text, at: now()))
        if transcript.count > Self.maxTranscriptLines {
            transcript.removeFirst(transcript.count - Self.maxTranscriptLines)
        }
    }
}

/// Adapts a `FileTransferProtocol`'s callbacks onto the mailbox's main-actor
/// state.
///
/// Holds closures rather than a reference to the service: the protocol
/// implementations are `nonisolated` and would otherwise reach across
/// isolation to touch published state.
nonisolated final class BBSTransferBridge: FileTransferProtocolDelegate {

    private let sendBytes: @Sendable (Data) -> Void
    private let finished: @Sendable (Bool, String?) -> Void
    private let confirmUpload: @Sendable (TransferFileMetadata) -> Void
    private let receivedFile: @Sendable (Data, TransferFileMetadata) -> Void

    init(send: @escaping @Sendable (Data) -> Void,
         finish: @escaping @Sendable (Bool, String?) -> Void,
         confirm: @escaping @Sendable (TransferFileMetadata) -> Void = { _ in },
         received: @escaping @Sendable (Data, TransferFileMetadata) -> Void = { _, _ in }) {
        self.sendBytes = send
        self.finished = finish
        self.confirmUpload = confirm
        self.receivedFile = received
    }

    func transferProtocol(_ transfer: FileTransferProtocol, needsToSend data: Data) {
        sendBytes(data)
    }

    func transferProtocol(_ transfer: FileTransferProtocol,
                          didComplete successfully: Bool, error: String?) {
        finished(successfully, error)
    }

    func transferProtocol(_ transfer: FileTransferProtocol,
                          didReceiveFile data: Data, metadata: TransferFileMetadata) {
        receivedFile(data, metadata)
    }

    /// Where an upload is accepted or refused — before a byte is written.
    func transferProtocol(_ transfer: FileTransferProtocol,
                          requestsConfirmation metadata: TransferFileMetadata) {
        confirmUpload(metadata)
    }

    func transferProtocol(_ transfer: FileTransferProtocol,
                          didUpdateProgress progress: Double, bytesSent: Int) {}
    func transferProtocol(_ transfer: FileTransferProtocol,
                          stateChanged newState: TransferProtocolState) {}
}

// MARK: - NET/ROM circuit sessions

extension BBSService {

    /// One mailbox caller arriving over a NET/ROM circuit instead of an
    /// AX.25 link. Same shell, same store, same effects — but its own
    /// state, because circuits multiplex where the AX.25 listener serves
    /// one caller at a time. File transfer protocols are declined
    /// honestly for now: they own a byte stream, and a circuit caller's
    /// bytes are owned by the node host.
    @MainActor
    final class CircuitSession: NodeMailboxSession {
        private var shell: BBSShell
        private unowned let service: BBSService

        fileprivate init?(service: BBSService, caller: String) {
            guard service.settings.onAir else { return nil }
            self.service = service
            self.shell = BBSShell(
                caller: caller,
                sysop: service.answeringCallsign,
                banner: service.settings.banner,
                publishesHeardList: service.settings.publishHeardList,
                publishesWhitePages: service.settings.publishWhitePages)
        }

        func greeting() -> (lines: [String], prompt: String?) {
            let output = shell.greeting(
                mailbox: service.currentMailbox(), now: Date())
            return (output.lines, output.prompt)
        }

        /// Feeds one line; applies the safe effects through the service.
        func handle(line: String) -> (lines: [String], prompt: String?, closed: Bool) {
            var output = shell.handle(
                line: line, mailbox: service.currentMailbox(), now: Date())
            var closed = false
            for effect in output.effects {
                switch effect {
                case .store, .kill, .markRead, .learnWhitePages:
                    service.apply(effect)
                case .viewFile, .sendFile, .beginUpload, .abortTransfer:
                    output.lines.append(
                        "File transfers are not available over a NET/ROM "
                        + "circuit yet — sorry.")
                case .disconnect:
                    closed = true
                }
            }
            return (output.lines, output.prompt, closed)
        }
    }

    /// Nil when the mailbox is off the air.
    func beginCircuitSession(caller: String) -> CircuitSession? {
        CircuitSession(service: self, caller: caller)
    }
}
