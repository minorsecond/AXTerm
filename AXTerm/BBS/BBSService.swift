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

    /// A file on its way to or from the caller, for the operator's view.
    ///
    /// The transcript only says a transfer started and how it ended; forty
    /// minutes of YAPP in between look like nothing is happening. This is
    /// what the live call panel draws its progress bar from.
    nonisolated struct TransferStatus: Equatable, Sendable {
        enum Direction: Equatable, Sendable { case download, upload }
        var direction: Direction
        var caller: String
        /// Nil for an upload until the caller's header names the file.
        var fileName: String?
        var protocolName: String
        var bytesDone: Int
        /// Zero until known, which for an upload is until the header arrives.
        var totalBytes: Int
        var startedAt: Date
    }

    @Published private(set) var messages: [BBSMessage] = []
    @Published private(set) var calls: [BBSCall] = []
    /// The white pages directory, sorted by callsign.
    @Published private(set) var directory: [WhitePagesEntry] = []
    /// Facts recognized in BBS sessions the operator had, waiting to be
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
    /// The transfer running right now, or nil. Set for exactly as long as the
    /// session's bytes belong to a transfer protocol.
    @Published private(set) var transfer: TransferStatus?

    /// Beyond this the oldest lines are dropped: a caller who pastes a book
    /// should not grow the window without bound.
    private static let maxTranscriptLines = 500

    // MARK: - Dependencies

    /// Nil when the database could not be opened. The mailbox then refuses
    /// to run rather than serving callers from memory and losing what they
    /// left when the app quits.
    private let store: BBSMessageStore?
    /// Read by the node, which tells its callers whether the mailbox is on
    /// the air and shows its station text under INFO.
    let settings: BBSSettings
    private let coordinator: SessionCoordinator
    private let sendFrames: ([OutboundFrame]) -> Void
    private let stationCallsign: () -> String
    private let isWinlinkP2PArmed: () -> Bool
    private let winlinkP2PCallsign: () -> String
    /// What this station has heard, for `J`. Injected rather than reached for:
    /// the mailbox has no business holding a packet engine.
    private let heardStations: () -> [BBSShell.HeardStation]
    /// The catalog and the bytes behind it. Nil when there is no database.
    private let library: BBSFileLibrary?
    /// Whether a peer has answered an AXDP capability probe.
    ///
    /// No longer decides the download protocol: every binary download goes
    /// by YAPP (see `sendFile` for why). It only tells the operator, in the
    /// transcript, that the caller runs AXTerm.
    private let peerSupportsAXDP: (String) -> Bool
    /// How long a transfer may go without a byte from the caller before it
    /// is stopped. YAPP's own retries give up after about five minutes; this
    /// ends it sooner and, unlike YAPP, frees the mailbox for the next
    /// command however the protocol got stuck.
    private let transferStallTimeout: TimeInterval
    /// Throughput used for the TIME column and the long-transfer warning.
    ///
    /// Defaults to 90 B/s: 1200 baud is 150 bytes/s of raw channel, and after
    /// AX.25 framing, acks and sharing the frequency with everyone else, the
    /// delivered rate is nearer two thirds of that. An estimate that flatters
    /// itself is worse than none, because a caller plans around it.
    private let linkBytesPerSecond: () -> Double
    /// The license record for a callsign, from the directory AXTerm already
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
    /// Armed by `U`, until the caller's first recognizable protocol frame.
    private var awaitingUpload = false
    private var uploadsThisCall = 0
    /// When this caller was last here, fixed for the duration of the call.
    private var callerLastVisit: Date?

    /// The transfer that owns the session's bytes, if any.
    ///
    /// Everything about one transfer lives in one value with one id, so
    /// ending it is a single assignment, and a callback from a transfer that
    /// has already ended (a cancel's own "canceled" report, say) can be told
    /// apart from the current one and ignored.
    private struct RunningTransfer {
        let id: UUID
        let driver: FileTransferProtocol
        /// Held here because the driver's delegate reference is weak.
        let bridge: BBSTransferBridge
        let direction: TransferStatus.Direction
        /// How the caller is told about it: the file name, or "the upload".
        var what: String
        /// `AREA/name` for the call log, empty for an upload.
        var logName: String
        /// The size the upload's header promised and the policy accepted.
        var acceptedBytes: Int?
        /// Set once an upload has been written to the inbox.
        var stored = false
        /// What the caller is told about a stored upload, said once YAPP is
        /// done. Said at end of file, it reached a caller still waiting for
        /// the acknowledgment of end of transmission, whose YAPP driver read
        /// it as a protocol error (2026-10-01).
        var storedConfirmation: String?
        var framing = YAPPFrameAssembler()
        /// Text the caller typed during the transfer, kept only to spot `A`.
        var typed = Data()
    }
    private var running: RunningTransfer?
    private var lastTransferActivity: Date = .distantPast
    private var watchdog: Task<Void, Never>?
    /// An AXDP message arriving in pieces, collected until it can be read.
    private var axdpBuffer = Data()
    /// Text written while a command is being answered, sent as one batch so
    /// a reply costs one burst of frames rather than one per line.
    private var pendingLines: [String]?

    /// Whether a transfer holds the session. For tests and the UI.
    var isTransferring: Bool { running != nil }

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
         transferStallTimeout: TimeInterval = 180,
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
        self.transferStallTimeout = transferStallTimeout
        self.linkBytesPerSecond = linkBytesPerSecond
        self.licenceRecord = licenceRecord
        self.announce = announce
        self.resolveLicences = resolveLicences
        self.contestedIdentityHolder = contestedIdentityHolder
        self.now = now
        // How the node finds the mailbox to hand callers to, on either
        // platform. A second Mac window builds a second mailbox, and the
        // newest one takes over, as it did when each window wired the node.
        coordinator.nodeMailbox = self
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
        // A goodbye typed into the middle of a YAPP stream would be read as a
        // corrupt block. Cancel first, so the caller's software knows the
        // transfer is over before the text arrives.
        stopTransfer(tellCaller: nil, log: "transfer stopped: mailbox \(reason)")
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

    /// The name of the radio a call came in on, for the callers list — nil
    /// with one radio, when every call came in on it.
    func radioName(for radio: RadioID) -> String? {
        guard let settings = coordinator.appSettings, settings.hasMultipleRadios,
              let profile = settings.radio(radio) else { return nil }
        return profile.name.isEmpty ? RadioProfile.defaultName(for: profile) : profile.name
    }

    private func listener(for radio: RadioID = .primary) -> PersonalBBSListener {
        PersonalBBSListener(
            isArmed: settings.onAir,
            winlinkP2PAddress: isWinlinkP2PArmed() ? winlinkP2PCallsign() : nil,
            myCallsign: answeringCallsign,
            contestedBy: contestedIdentityHolder(),
            currentCaller: live?.callsign,
            servesThisRadio: coordinator.appSettings?.radio(radio)?.mayAnswerMailbox ?? true)
    }

    private func handleInbound(_ session: AX25Session) {
        let decision = listener(for: session.radio).decide(
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
            },
            netRomHandler: { [weak self] session in
                // A neighbor node linked up to carry a NET/ROM circuit: the
                // link is the node's, so the mailbox lets go of it rather
                // than time it out later (smoke run 2026-10-03-1, issue 73).
                self?.append(.note, "\(session.remoteAddress.display) is using this link for NET/ROM; "
                             + "the mailbox stepped aside and left it to the node")
                self?.endCall(unexpected: false)
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

        let callId = (store.flatMap { try? $0.beginCall(callsign: caller, at: at, radio: session.radio) }) ?? -1
        live = LiveCall(callsign: caller, startedAt: at, callId: callId)
        // Read before anything else touches the call log, and held for the
        // call: `FN` must mean "since you were last here", not "since a
        // moment ago".
        callerLastVisit = store.flatMap {
            try? $0.lastVisit(callsign: caller, excluding: callId)
        }

        // Fill what the license already answers before the greeting is
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
        if running != nil {
            feedTransfer(data)
            return
        }

        // An AXTerm caller's own protocol. Recognized wherever it turns up,
        // not only after `U`: a caller who pressed Send in their transfer
        // window without typing `U` first is otherwise left waiting for an
        // acceptance that never comes.
        if !axdpBuffer.isEmpty || (inputBuffer.isEmpty && AXDP.hasMagic(data)) {
            receiveAXDP(data)
            return
        }

        // Armed by `U`. If the first bytes are not a protocol we know, the
        // caller probably typed something instead — fall through and treat it
        // as a command rather than swallowing it.
        if awaitingUpload, startReceiving(data) { return }
        awaitingUpload = false

        receiveText(data)
    }

    private func receiveText(_ data: Data) {
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
        // A line after a transfer began (a caller who typed ahead of their
        // YAPP software, say) is not a command: those bytes belong to the
        // transfer now, and answering them would type into its stream.
        guard var shell, session != nil, running == nil else { return }
        append(.fromCaller, line)

        var output = shell.handle(line: line, mailbox: currentMailbox(), now: now())
        self.shell = shell

        // Where the refusal is already knowable, say it instead of "Ready",
        // rather than telling the caller to start and then that they cannot.
        if output.effects.contains(.beginUpload), let reason = uploadRefusal() {
            output.lines = ["Sorry — \(reason)."]
            output.effects.removeAll { $0 == .beginUpload }
        }

        // What the shell said goes first, so "Sending x" arrives before x
        // does. Everything written while the effects run joins it in one
        // batch, and the batch is flushed early only when a transfer is
        // about to put protocol bytes on the link.
        pendingLines = []
        write(output.lines)
        for effect in output.effects { apply(effect) }
        // A transfer writes its own prompt when it ends, and a caller who has
        // just been told to start an upload is not at a prompt.
        if running == nil, !awaitingUpload, let prompt = output.prompt {
            write([prompt])
        }
        flushLines()

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
            note("left mail for \(message.to): \"\(message.subject)\"")
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
            stopTransfer(tellCaller: nil, log: nil)
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
        guard !lines.isEmpty else { return }
        if pendingLines != nil {
            for line in lines { append(.toCaller, line) }
            pendingLines?.append(contentsOf: lines)
            return
        }
        send(lines, logged: false)
    }

    /// Sends what `process` collected while answering a command.
    private func flushLines() {
        guard let lines = pendingLines else { return }
        pendingLines = nil
        // Already in the transcript: `write` logs a line when it queues it.
        send(lines, logged: true)
    }

    private func send(_ lines: [String], logged: Bool) {
        // Never to a link that is not up: sending on a disconnected session
        // makes the session layer dial the peer, and a mailbox must not call
        // a caller back.
        guard let session, session.state == .connected, !lines.isEmpty else { return }
        if !logged {
            for line in lines { append(.toCaller, line) }
        }

        // CR, not CRLF: the packet convention every terminal on the channel
        // already expects, and half the bytes.
        let text = lines.joined(separator: "\r") + "\r"
        let frames = coordinator.sessionManager.sendData(
            Data(text.utf8),
            to: session.remoteAddress,
            path: session.path,
            radio: session.radio,
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
        // Nothing is sent: the link is gone or going, and a CAN written now
        // would either be lost or, on a disconnected session, make the
        // session layer dial the caller back to deliver it.
        stopTransfer(tellCaller: nil,
                     log: unexpected ? "transfer stopped: link dropped" : nil,
                     notifyPeer: false)
        awaitingUpload = false
        axdpBuffer = Data()
        pendingLines = nil
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

    /// Merges the cached license record for a callsign into the directory.
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
        announce("White pages from \(peer): \(what). Review in BBS → Directory.")
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

    /// A text file as the lines to type down the session, or nil when it
    /// cannot be read.
    ///
    /// The cheapest way to move a file on this link: no negotiation, no
    /// framing, no protocol the caller has to have. Most of what a packet
    /// file area actually holds is text, so this is the common path rather
    /// than the fallback. Shared with NET/ROM circuit callers, whose link
    /// carries lines and nothing else.
    ///
    /// The file goes between a BEGIN line carrying its name and exact byte
    /// count and an END line (`TextDownloadMarkers`). Any terminal shows
    /// them as two more lines of text; an AXTerm caller uses them to save
    /// the file and to check that every line arrived.
    fileprivate func textLines(for file: BBSSharedFile) -> [String]? {
        guard let data = library?.data(for: file) else { return nil }
        return TextDownloadMarkers.markedLines(name: file.name, data: data)
    }

    private func viewFile(_ file: BBSSharedFile) {
        guard let lines = textLines(for: file) else {
            write(["\(file.name) could not be read."])
            return
        }
        write(lines)
        note("read \(file.area)/\(file.name)")
    }

    /// Hands the session to YAPP for the duration of one download.
    ///
    /// YAPP for every caller, AXTerm stations included. AXTerm's own AXDP
    /// sender lives in `SessionCoordinator` and cannot run on a mailbox
    /// session: the mailbox holds the session's delivery claim (it has to, or
    /// the caller's typing would land in the operator's terminal), so the
    /// caller's AXDP acknowledgments would never reach the coordinator, and
    /// its transfer would wait for an acceptance it cannot see. YAPP is a
    /// byte stream the mailbox can own end to end.
    private func sendFile(_ file: BBSSharedFile) {
        guard running == nil else {
            write(["A transfer is already running."])
            return
        }
        guard let data = library?.data(for: file) else {
            write(["\(file.name) could not be read."])
            return
        }
        // The catalog never lists an empty file, but one can be emptied
        // between the scan and the D. YAPP would send its header and then
        // wait forever for a first block that does not exist.
        guard !data.isEmpty else {
            write(["\(file.name) is empty, so there is nothing to send."])
            return
        }

        let caller = live?.callsign ?? ""
        let driver = YAPPProtocol()
        let id = UUID()
        let bridge = makeBridge(id: id)
        driver.delegate = bridge
        running = RunningTransfer(id: id, driver: driver, bridge: bridge,
                                  direction: .download, what: file.name,
                                  logName: "\(file.area)/\(file.name)")
        transfer = TransferStatus(direction: .download, caller: caller,
                                  fileName: file.name, protocolName: "YAPP",
                                  bytesDone: 0, totalBytes: data.count,
                                  startedAt: now())
        append(.note, "sending \(file.name) by YAPP"
               + (peerSupportsAXDP(caller) ? " (the caller runs AXTerm)" : ""))
        startWatchdog()
        // Anything typed after the D, in the same frame, is not a command
        // now; left here it would be glued to the first line after the
        // transfer, and would hide an AXDP message arriving later.
        inputBuffer = Data()

        // The announcement goes out before the first protocol byte does.
        flushLines()
        do {
            try driver.startSending(fileName: file.name, fileData: data)
        } catch {
            clearTransfer()
            write(["\(file.name) could not be sent: \(error.localizedDescription)"])
        }
    }

    private func makeBridge(id: UUID) -> BBSTransferBridge {
        // Weak in the bridge, which the driver can outlive; the inner
        // closures run at once and may hold the service for that long.
        BBSTransferBridge(
            send: { [weak self] bytes in
                guard let self else { return }
                BBSTransferBridge.onMain { self.writeRaw(bytes) }
            },
            finish: { [weak self] ok, error in
                guard let self else { return }
                BBSTransferBridge.onMain { self.finishTransfer(id: id, ok: ok, error: error) }
            },
            confirm: { [weak self] metadata in
                guard let self else { return }
                BBSTransferBridge.onMain { self.decideUpload(id: id, metadata) }
            },
            received: { [weak self] data, metadata in
                guard let self else { return }
                BBSTransferBridge.onMain { self.storeUpload(id: id, data, metadata) }
            },
            progress: { [weak self] bytes in
                guard let self else { return }
                BBSTransferBridge.onMain { self.transferProgressed(id: id, bytes: bytes) }
            })
    }

    /// The protocol reported the end. Ignored unless it is the current
    /// transfer: a transfer the mailbox stopped itself has already been
    /// cleared and explained, and its own "canceled" report is noise.
    private func finishTransfer(id: UUID, ok: Bool, error: String?) {
        guard let run = running, run.id == id else { return }
        clearTransfer()
        guard session != nil else { return }

        switch run.direction {
        case .download:
            if ok {
                write(["\(run.what) sent.", BBSShell.commandPrompt])
                note("downloaded \(run.logName)")
            } else {
                let reason = error ?? "no reason given"
                write(["\(run.what) was not sent: \(reason).", BBSShell.commandPrompt])
                note("download of \(run.logName) stopped: \(reason)")
            }
        case .upload:
            if !ok {
                // A file already stored arrived whole even if the handshake
                // after it did not finish; the caller should know both.
                let reason = error ?? "no reason given"
                write([run.storedConfirmation, "The upload stopped: \(reason).", BBSShell.commandPrompt]
                    .compactMap { $0 })
                note("upload stopped: \(reason)")
            } else if !run.stored {
                write(["The upload ended without a file.", BBSShell.commandPrompt])
            } else {
                write([run.storedConfirmation, BBSShell.commandPrompt].compactMap { $0 })
            }
        }
    }

    private func transferProgressed(id: UUID, bytes: Int) {
        guard let run = running, run.id == id else { return }
        transfer?.bytesDone = bytes
        // The header said how big the file is, and that is what the policy
        // agreed to. A caller who keeps sending past it is not sending that
        // file, and the inbox quota was checked against the smaller number.
        if run.direction == .upload, let accepted = run.acceptedBytes, bytes > accepted {
            stopTransfer(tellCaller: "The upload was larger than its header said, "
                         + "so it was stopped.",
                         log: "upload stopped: larger than its header said")
        }
    }

    /// Bytes a transfer protocol produced, straight onto the session with no
    /// line discipline — the payload is framed by the protocol, not by us.
    private func writeRaw(_ data: Data) {
        // Text queued for this reply goes first, so the stream stays in the
        // order it was written.
        flushLines()
        guard let session, session.state == .connected else { return }
        let frames = coordinator.sessionManager.sendData(
            data,
            to: session.remoteAddress,
            path: session.path,
            radio: session.radio,
            pid: 0xF0,
            displayInfo: "BBS file (\(data.count) bytes)")
        sendFrames(frames)
    }

    /// Caller bytes while a transfer holds the session.
    private func feedTransfer(_ data: Data) {
        guard var run = running else { return }
        lastTransferActivity = now()
        // An upload's blocks carry a checksum only the protocol knows was
        // negotiated, and the protocol reassembles its own stream, so the
        // caller's bytes go to it as they come.
        if run.direction == .upload {
            _ = run.driver.handleIncomingData(data)
            return
        }
        let pieces = run.framing.push(data)
        running?.framing = run.framing

        for piece in pieces {
            // A frame can end the transfer (the last ACK, a CAN); whatever
            // follows it in the same I-frame is not the transfer's business.
            guard let current = running, current.id == run.id else { return }
            run = current
            switch piece {
            case .frame(let frame):
                dispatch(frame, to: run)
            case .text(let text):
                typedDuringTransfer(text)
            }
        }
    }

    /// A reply from the caller during a download. The protocol reads RR,
    /// RF/RT, AF, AT, NAK and CAN from its own stream.
    private func dispatch(_ frame: Data, to run: RunningTransfer) {
        _ = run.driver.handleIncomingData(frame)
    }

    /// A caller whose software does not speak YAPP sees the protocol bytes
    /// as noise and does the natural thing, which is to type `A`. Listening
    /// for it is what gets them back to a prompt without waiting out every
    /// retry.
    private func typedDuringTransfer(_ text: Data) {
        guard var typed = running?.typed else { return }
        typed.append(text)
        if typed.count > 256 { typed = Data(typed.suffix(256)) }
        running?.typed = typed

        let lines = String(decoding: typed, as: UTF8.self)
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .dropLast()  // the part after the last line end is still being typed
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        if lines.contains(where: { $0 == "A" || $0 == "ABORT" }) {
            stopTransfer(tellCaller: "Stopped.", log: "transfer stopped by the caller")
        }
    }

    /// Ends the current transfer from this side: the caller typed `A`, the
    /// sysop pressed Stop, the link went quiet, or the call is ending.
    ///
    /// Cleared before the protocol is told, so the cancel it reports back
    /// finds nothing to finish. The protocol still sends its CAN when
    /// `notifyPeer` is set, because the caller's software is otherwise left
    /// waiting for the next block.
    private func stopTransfer(tellCaller message: String?, log: String?,
                              notifyPeer: Bool = true) {
        guard let run = running else { return }
        clearTransfer()
        if !notifyPeer { run.driver.delegate = nil }
        run.driver.cancel()
        // Nothing more from this driver reaches the link: a receiver in the
        // middle of a block would otherwise ACK it after its own CAN.
        run.driver.delegate = nil
        if let log { note(log) }
        if let message, session != nil {
            write([message, BBSShell.commandPrompt])
        }
    }

    private func clearTransfer() {
        running = nil
        transfer = nil
        stopWatchdog()
    }

    /// The sysop's Stop button.
    func sysopStopTransfer() {
        stopTransfer(tellCaller: "The sysop stopped the transfer.",
                     log: "transfer stopped by the sysop")
    }

    // MARK: - Stalls

    private func startWatchdog() {
        lastTransferActivity = now()
        watchdog?.cancel()
        let timeout = transferStallTimeout
        // Often enough that a stall is caught within a fifth of the limit,
        // rarely enough to cost nothing.
        let interval = min(5, max(0.02, timeout / 5))
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.running != nil else { return }
                if self.now().timeIntervalSince(self.lastTransferActivity) >= timeout {
                    self.transferStalled()
                    return
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func transferStalled() {
        let span: String
        if transferStallTimeout < 60 {
            let seconds = Int(transferStallTimeout.rounded(.up))
            span = "\(seconds) second\(seconds == 1 ? "" : "s")"
        } else {
            let minutes = Int((transferStallTimeout / 60).rounded(.up))
            span = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        stopTransfer(tellCaller: "The transfer stopped: nothing was heard from you for \(span).",
                     log: "transfer stopped: nothing heard for \(span)")
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

    /// Why `U` would be refused before the caller sends anything, or nil.
    /// Asked with a probe file, so only the reasons that do not depend on
    /// the file itself (switched off, no inbox, too many this call) show.
    private func uploadRefusal() -> String? {
        if case .reject(let reason) = uploadPolicy().decide(filename: "probe.bin", size: 1) {
            return reason
        }
        return nil
    }

    private func beginUpload() {
        guard running == nil else {
            write(["A transfer is already running."])
            return
        }
        if let reason = uploadRefusal() {
            write(["Sorry — \(reason)."])
            return
        }
        awaitingUpload = true
    }

    /// Starts a YAPP receive on the caller's own first bytes.
    ///
    /// Only a send-init opens an upload. Anything else after `U` is most
    /// likely the caller typing, and falls through to the command line.
    private func startReceiving(_ data: Data) -> Bool {
        // ENQ 01, YAPP's send init. It may share an I-frame with the header.
        guard data.count >= 2, data[data.startIndex] == YAPPControlChar.enq.rawValue,
              data[data.startIndex + 1] == 0x01 else { return false }

        let driver = YAPPProtocol()
        let id = UUID()
        let bridge = makeBridge(id: id)
        driver.delegate = bridge
        running = RunningTransfer(id: id, driver: driver, bridge: bridge,
                                  direction: .upload, what: "the upload", logName: "")
        transfer = TransferStatus(direction: .upload, caller: live?.callsign ?? "",
                                  fileName: nil, protocolName: "YAPP",
                                  bytesDone: 0, totalBytes: 0, startedAt: now())
        awaitingUpload = false
        append(.note, "receiving an upload by YAPP")
        startWatchdog()
        feedTransfer(data)
        return true
    }

    private func decideUpload(id: UUID, _ metadata: TransferFileMetadata) {
        guard let run = running, run.id == id else { return }
        switch uploadPolicy().decide(filename: metadata.fileName, size: metadata.fileSize) {
        case .accept(let safe):
            running?.acceptedBytes = metadata.fileSize
            running?.what = safe
            transfer?.fileName = safe
            transfer?.totalBytes = metadata.fileSize
            run.driver.acceptTransfer()
        case .reject(let reason):
            // `rejectTransfer` sends YAPP's refusal (NR) but reports no
            // completion, so the mailbox ends the transfer itself.
            clearTransfer()
            run.driver.rejectTransfer(reason: reason)
            write(["Upload refused — \(reason).", BBSShell.commandPrompt])
            note("refused an upload: \(reason)")
        }
    }

    private func storeUpload(id: UUID, _ data: Data, _ metadata: TransferFileMetadata) {
        guard running?.id == id else { return }
        guard let safe = BBSUploadPolicy.sanitize(metadata.fileName),
              let saved = library?.saveUpload(name: safe, data: data) else {
            write(["That file could not be saved."])
            note("an upload could not be saved")
            return
        }
        running?.stored = true
        running?.storedConfirmation = "Received \(saved) (\(BBSFileIndex.size(data.count)))."
        uploadsThisCall += 1
        // Named in the call log because an unattended station accepting files
        // is exactly the thing the operator wants to read about afterwards.
        note("uploaded \(saved)")
    }

    // MARK: - AXDP from an AXTerm caller

    /// Reads an AXDP message the caller's AXTerm sent over the session.
    ///
    /// Two kinds matter. A FILE_META is the caller's transfer window offering
    /// a file: the mailbox takes uploads by YAPP only, so it is declined the
    /// way AXTerm declines any offer, with a NACK the caller's software
    /// understands, and a line saying what to do instead. A CHAT message is
    /// a typed line from a caller with AXDP switched on, and is read as one.
    private func receiveAXDP(_ data: Data) {
        axdpBuffer.append(data)
        while !axdpBuffer.isEmpty {
            guard let (message, consumed) = AXDP.Message.decode(from: axdpBuffer) else {
                // Not readable yet. Past this size it never will be, and the
                // command line gets the session back.
                if axdpBuffer.count > 2048 {
                    axdpBuffer = Data()
                    append(.note, "dropped an AXDP message that could not be read")
                }
                return
            }
            let rest = Data(axdpBuffer.dropFirst(consumed))
            // A remainder that is not another message is the tail of this
            // one still arriving.
            if !rest.isEmpty, !AXDP.hasMagic(rest), axdpBuffer.count <= 2048 { return }
            axdpBuffer = AXDP.hasMagic(rest) ? rest : Data()

            switch message.type {
            case .fileMeta:
                declineAXDPUpload(message)
            case .chat:
                if let payload = message.payload, !payload.isEmpty {
                    receiveText(payload + Data([0x0D]))
                }
            default:
                append(.note, "ignored an AXDP \(message.type) message")
            }
        }
    }

    private func declineAXDPUpload(_ message: AXDP.Message) {
        awaitingUpload = false
        // The same NACK `SessionCoordinator.declineIncomingTransfer` sends,
        // so the caller's transfer ends as "declined" instead of waiting.
        let nack = AXDP.Message(type: .nack, sessionId: message.sessionId, messageId: 1)
        writeRaw(nack.encode())
        let name = message.fileMeta?.filename ?? "that file"
        write(["This mailbox takes uploads by YAPP only, so \(name) was declined.",
               "Type U, then send it again with YAPP as the protocol.",
               BBSShell.commandPrompt])
        note("declined an AXDP upload of \(name)")
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
    private let progressed: @Sendable (Int) -> Void

    init(send: @escaping @Sendable (Data) -> Void,
         finish: @escaping @Sendable (Bool, String?) -> Void,
         confirm: @escaping @Sendable (TransferFileMetadata) -> Void = { _ in },
         received: @escaping @Sendable (Data, TransferFileMetadata) -> Void = { _, _ in },
         progress: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.sendBytes = send
        self.finished = finish
        self.confirmUpload = confirm
        self.receivedFile = received
        self.progressed = progress
    }

    /// Runs `work` on the main actor, synchronously when already there.
    ///
    /// YAPP is driven from the main thread (the mailbox feeds it there and its
    /// retry timer is on the main run loop), so in practice every callback
    /// arrives on it. Running them in place keeps protocol bytes and the text
    /// around them in the order they were produced; a hop through a task
    /// would let a prompt overtake the last block it was meant to follow.
    static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
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

    /// Where an upload is accepted or refused, before a byte is written.
    func transferProtocol(_ transfer: FileTransferProtocol,
                          requestsConfirmation metadata: TransferFileMetadata) {
        confirmUpload(metadata)
    }

    func transferProtocol(_ transfer: FileTransferProtocol,
                          didUpdateProgress progress: Double, bytesSent: Int) {
        progressed(bytesSent)
    }

    func transferProtocol(_ transfer: FileTransferProtocol,
                          stateChanged newState: TransferProtocolState) {}
}

// MARK: - NET/ROM circuit sessions

extension BBSService {

    /// One mailbox caller arriving over a NET/ROM circuit instead of an
    /// AX.25 link. Same shell, same store, same effects — but its own
    /// state, because circuits multiplex where the AX.25 listener serves
    /// one caller at a time.
    ///
    /// The node host hands this session lines and sends back lines
    /// (`NodeMailboxSession`), so text is all it can carry. NET/ROM itself
    /// would carry binary, but no byte stream reaches the mailbox to run a
    /// transfer protocol on. So text files are typed out as on a direct
    /// call, listings work unchanged, and binaries and uploads are refused
    /// by the shell with the callsign to connect to instead.
    // nonisolated class, MainActor methods — see NodeMailboxSession.
    nonisolated final class CircuitSession: NodeMailboxSession {
        private var shell: BBSShell
        private let caller: String
        // weak, not unowned: an unowned stored property in a FAILABLE
        // init corrupts the heap when the guard returns nil (the
        // partially-initialized object's teardown double-releases it) —
        // found the hard way by this class's own tests.
        private weak var service: BBSService?

        @MainActor
        fileprivate init?(service: BBSService, caller: String) {
            guard service.settings.onAir else { return nil }
            self.service = service
            self.caller = caller
            self.shell = BBSShell(
                caller: caller,
                sysop: service.answeringCallsign,
                banner: service.settings.banner,
                publishesHeardList: service.settings.publishHeardList,
                publishesWhitePages: service.settings.publishWhitePages,
                bytesPerSecond: service.linkBytesPerSecond(),
                linesOnlyDirectCall: service.answeringCallsign)
        }

        @MainActor
        func greeting() -> (lines: [String], prompt: String?) {
            guard let service else { return ([], nil) }
            let output = shell.greeting(
                mailbox: service.currentMailbox(), now: Date())
            return (output.lines, output.prompt)
        }

        /// Feeds one line; applies the safe effects through the service.
        @MainActor
        func handle(line: String) -> (lines: [String], prompt: String?, closed: Bool) {
            guard let service else { return ([], nil, true) }
            var output = shell.handle(
                line: line, mailbox: service.currentMailbox(), now: Date())
            var closed = false
            for effect in output.effects {
                switch effect {
                case .store, .kill, .markRead, .learnWhitePages:
                    service.apply(effect)
                case .viewFile(let file):
                    // Text is what this link carries, so a text file is
                    // typed out here exactly as it is on a direct call.
                    if let lines = service.textLines(for: file) {
                        output.lines.append(contentsOf: lines)
                        service.append(.note, "\(caller) read \(file.area)/\(file.name) over NET/ROM")
                    } else {
                        output.lines.append("\(file.name) could not be read.")
                    }
                case .sendFile, .beginUpload:
                    // The shell refuses these itself in lines-only mode; this
                    // is the backstop if that ever changes.
                    output.lines = ["That needs a direct connection to "
                                    + "\(service.answeringCallsign)."]
                case .abortTransfer:
                    // Nothing can be running here; the shell's "Stopped." is true.
                    break
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
