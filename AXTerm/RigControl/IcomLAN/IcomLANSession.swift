import Foundation

/// A logged-in connection to an Icom radio over its WLAN: the control
/// stream that holds the login and token, the CI-V stream and the audio
/// stream it opens once the radio agrees.
///
/// Order on `open()`: control hello → login → token confirm and renew →
/// wait for the radio's capabilities and the token's acceptance → ask for
/// CI-V and audio at 48 kHz LPCM → hello on both of those → CI-V channel
/// open. The token is renewed every minute; the radio's status packets can
/// end the session (a second client logged in, the radio powered off).
nonisolated final class IcomLANSession: @unchecked Sendable {

    struct Configuration: Equatable, Sendable {
        var host: String
        var controlPort: UInt16 = IcomLAN.controlPort
        var serialPort: UInt16 = IcomLAN.serialPort
        var audioPort: UInt16 = IcomLAN.audioPort
        var username: String
        var password: String
        /// What the login names us as; the radio shows it and echoes it back.
        var program = "AXTerm"
        var sampleRate: UInt16 = 48_000
        var txBufferMs: UInt16 = 300
        var timeout: Double = 3

        init(host: String, username: String, password: String) {
            self.host = host
            self.username = username
            self.password = password
        }
    }

    enum State: Equatable, Sendable {
        case idle, connecting, connected
        case failed(String)
    }

    let configuration: Configuration
    let queue = DispatchQueue(label: "com.axterm.icomlan", qos: .userInitiated)

    /// Any thread.
    var onState: (@Sendable (State) -> Void)?
    /// CI-V bytes from the radio, in order. Queue.
    var onSerialBytes: (@Sendable (Data) -> Void)?
    /// Received PCM (16-bit little-endian mono), in order, nil for a lost
    /// packet. Queue.
    var onAudio: (@Sendable (Data?) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            // Every transition, in the operator's console. The liveness watch
            // bails on anything but `.connected`, so which state it bailed
            // into — and when — is half the diagnosis.
            TxLog.debug(.modem, "IcomLAN state", [
                "from": String(describing: oldValue), "to": String(describing: state)])
            onState?(state)
        }
    }
    /// What the radio called itself in the connection reply, e.g. "IC-705".
    private(set) var radioName: String = ""
    private(set) var deviceName: String = ""

    private let control: IcomLANStream
    private let serial: IcomLANStream
    private let audio: IcomLANStream
    private var authID: [UInt8] = []
    private var replyID: [UInt8]?
    private var tokenAccepted = false
    private var innerSequence: UInt16 = 0
    /// When this session last let go of the radio, for `settleRemaining`.
    private var lastCloseAt: Double = 0
    private var serialSendSequence: UInt16 = 0
    private var audioSendSequence: UInt16 = 1
    private var renewTimer: DispatchSourceTimer?
    private var renewOutstanding = false
    // The control handshake after login is event-driven: these track it and
    // `finishConnect` is resolved once by success or failure.
    private var gotReplyID = false
    private var authOK = false
    private var requestSent = false
    private var connectionOpened = false
    /// True while the login ladder is running. A refusal that arrives as
    /// a status packet belongs to the ladder, not to `handleControl`.
    private var loggingIn = false
    private var finishConnect: ((Result<Void, Error>) -> Void)?
    private var serialReorder = SequenceReorderBuffer(holdSeconds: 0.1)
    private var audioReorder = SequenceReorderBuffer(holdSeconds: 0.1)
    private var reorderTimer: DispatchSourceTimer?
    private var livenessTimer: DispatchSourceTimer?
    /// Whether the last tick was watching, so standing down is reported once
    /// rather than every second.
    private var livenessWasWatching = false
    /// Whether the "nothing judged" state has already been reported for this
    /// watch. It is a bug state, not a periodic one, so it is said once.
    private var livenessReportedUnjudged = false
    /// Ticks since the watch started, so the heartbeat can be periodic. The
    /// count itself is logged: a gap in it is a stalled queue, which reads
    /// nothing like a quiet radio.
    private var livenessTicks = 0
    /// CI-V writes asked for, and writes refused because the session was not
    /// connected. Paired with the stream's own sent/dropped counts, these say
    /// whether our commands are reaching the air at all — the half of "the
    /// radio never answered" that nothing else measures.
    private var civWrites = 0
    private var civWritesRefused = 0
    private var recentAudioSizes: [Int] = []
    private var openTask: Task<Void, Error>?

    var isConnected: Bool { state == .connected }
    var roundTrip: Double { control.roundTrip }

    /// How long the CI-V stream has been quiet, or nil before it opens.
    ///
    /// The liveness watch deliberately never judges this — quiet CI-V is
    /// ordinary, and failing on it would drop a working radio. It is worth
    /// *reporting*, though: an attached stream idles continuously, so a
    /// stream carrying traffic while the CI-V client has read nothing means
    /// the radio is there and ignoring CI-V, and a stream gone quiet means
    /// the stream itself never came up. Those need opposite fixes and
    /// produce the same complaint without this.
    var civStreamSilence: TimeInterval? { serial.silence }

    /// True when the CI-V stream bound a different source port from the one
    /// its session ID was built from. The radio checks the two against each
    /// other and silently refuses the stream when they disagree, which looks
    /// from here exactly like a radio with CI-V switched off.
    var civSourcePortMismatched: Bool { serial.pinnedPortMismatch }
    var audioPacketsLost: Int { audioReorder.lost }

    init(configuration: Configuration) {
        self.configuration = configuration
        queue.setSpecific(key: Self.queueKey, value: ())
        control = IcomLANStream(name: "control", queue: queue)
        serial = IcomLANStream(name: "CI-V", queue: queue)
        audio = IcomLANStream(name: "audio", queue: queue)
        control.onPacket = { [weak self] d in self?.handleControl(d) }
        serial.onPacket = { [weak self] d in self?.handleSerial(d) }
        audio.onPacket = { [weak self] d in self?.handleAudio(d) }
        for stream in [control, serial, audio] {
            stream.onFailure = { [weak self] why in self?.fail("\(stream.name) stream: \(why)") }
        }
    }

    deinit { close() }

    // MARK: - Lifecycle

    /// Connect and log in. Throws with the reason on any failure; the state
    /// says the same.
    func open() async throws {
        guard state != .connected, state != .connecting else { return }
        // The session (and its streams) is reused across reconnects, so clear
        // everything the previous connection left behind before starting a
        // new handshake — otherwise a stale authID, an already-sent flag, or
        // a half-finished token exchange carries over and the reconnect fails.
        authID = []
        replyID = nil
        tokenAccepted = false
        innerSequence = 0
        serialSendSequence = 0
        audioSendSequence = 1
        renewOutstanding = false
        gotReplyID = false
        authOK = false
        requestSent = false
        connectionOpened = false
        loggingIn = false
        finishConnect = nil
        recentAudioSizes = []
        serialReorder.reset()
        audioReorder.reset()

        // Two different situations, two different waits.
        //
        // A session left holding the slot by a PRIOR launch is worth releasing
        // with a targeted disconnect so we take the slot back at once instead
        // of waiting out the login ladder. That only applies to the first
        // connect of this run, when nothing here has closed yet (lastCloseAt
        // is zero).
        //
        // A session WE closed a moment ago in this same run is the opposite
        // case: the radio needs the full settle to let go of CI-V, and coming
        // straight back gets a login that is granted audio with no CI-V — the
        // session connects, every CI-V poll goes unanswered, and it drops and
        // flaps. So after our own close, always wait the settle out; never
        // shortcut it with the reclaim.
        if lastCloseAt == 0,
           IcomLANSlotRelease.reclaim(host: configuration.host) {
            TxLog.debug(.modem, "IcomLAN: released a prior launch's session before reconnecting", [:])
            try await Task.sleep(for: .seconds(IcomLANSlotRelease.settleAfterRelease))
        } else {
            let settle = Self.settleRemaining(now: IcomLANStream.now, lastCloseAt: lastCloseAt)
            if settle > 0 {
                TxLog.debug(.modem, "IcomLAN: letting the radio release the last session",
                            ["waiting": String(format: "%.1fs", settle)])
                try await Task.sleep(for: .seconds(settle))
            }
        }

        state = .connecting
        let task = Task { [self] in try await performOpen() }
        openTask = task
        do {
            try await task.value
        } catch {
            let message = (error as? IcomLANError)?.message ?? String(describing: error)
            fail(message)
            throw error
        }
    }

    private func performOpen() async throws {
        let c = configuration
        control.trace("connecting control to " + c.host)
        try await control.connect(host: c.host, port: c.controlPort, timeout: c.timeout)
        control.trace("control connected")

        // Login. A radio still holding a session from an unclean shutdown
        // (Xcode stop, crash, a lost network) keeps its single client slot
        // for tens of seconds and rejects a fresh login the whole time —
        // and the rejection is byte-for-byte the one it sends for a wrong
        // password, so the two are indistinguishable in the reply. Rather
        // than fail a good password because the slot has not yet timed out,
        // resend the login a few times over several seconds; the slot frees
        // on its own and the next attempt is accepted. This is the same
        // stale-session behaviour every Icom LAN client has to absorb.
        var login: IcomLAN.LoginReply?
        loggingIn = true
        defer { loggingIn = false }
        for attempt in 0..<Self.loginAttempts {
            try Task.checkCancellation()
            let tokenRequest = (UInt8.random(in: 0...255), UInt8.random(in: 0...255))
            control.sendTracked(IcomLAN.login(local: control.localID, remote: control.remoteID, innerSequence: nextInner(),
                                              tokenRequest: tokenRequest, username: c.username, password: c.password,
                                              program: c.program))
            control.trace("login sent (attempt \(attempt + 1))")
            // The radio refuses a held slot in one of two ways: a login reply
            // saying accepted=false, or an asynchronous auth-failed status
            // packet. They mean the same thing, so both have to feed this
            // ladder. Waiting only for the reply meant a status refusal fell
            // through to handleControl, which failed the whole connect on the
            // first attempt — the retry written for exactly this condition
            // never ran, and every relaunch after an unclean exit needed the
            // operator to power-cycle the radio.
            let answer = try await control.expect(timeout: c.timeout, what: "login",
                                                  IcomLAN.isLoginAnswer)
            if let reply = IcomLAN.parseLoginReply(answer) {
                control.trace("login accepted=\(reply.accepted) (attempt \(attempt + 1))")
                if reply.accepted { login = reply; break }
            } else {
                control.trace("login refused by status packet (attempt \(attempt + 1))")
            }
            if attempt + 1 < Self.loginAttempts {
                try await Task.sleep(nanoseconds: UInt64(Self.loginRetryDelay * 1_000_000_000))
            }
        }
        guard let login else { throw IcomLANError.badCredentials }
        authID = login.authID

        // The slot is ours the instant the login is accepted, before the media
        // streams are up. Remember the control stream now, so that if the rest
        // of this connect falls over, or the app is killed before it can say
        // goodbye, the next launch can still release it. The CI-V and audio
        // streams are added once they open (in openMediaStreams).
        IcomLANSlotRelease.remember(host: c.host, streams: slotEndpoints(includeMedia: false))

        // From here the control exchange is event-driven: the radio sends
        // its capabilities, an auth acknowledgement and the connection
        // reply in an order we cannot assume, so `handleControl` drives it
        // and resolves `finishConnect`.
        control.startKeepalive(pingSequence: 2, idlePackets: true)
        control.sendTracked(IcomLAN.token(.confirm, local: control.localID, remote: control.remoteID,
                                          innerSequence: nextInner(), authID: authID))
        control.sendTracked(IcomLAN.token(.renew, local: control.localID, remote: control.remoteID,
                                          innerSequence: nextInner(), authID: authID))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                finishConnect = { result in continuation.resume(with: result) }
                trySendConnectionRequest()   // in case the packets already arrived
            }
            queue.asyncAfter(deadline: .now() + c.timeout * 3) { [self] in
                resolveConnect(.failure(IcomLANError.timeout("connection request")))
            }
        }

        // openMediaStreams (from handleControl) has brought the CI-V and
        // audio sockets up and set the state; nothing more to do here.
    }

    /// The streams of this session, addressed the way the radio sees them, for
    /// the slot-release record. Control is always included; the CI-V and audio
    /// streams only once they have a remote ID and a bound source port, which
    /// `remember` filters for anyway. `includeMedia` is false at login time,
    /// before the media streams exist.
    private func slotEndpoints(includeMedia: Bool) -> [IcomLANSlotRelease.Endpoint] {
        var endpoints: [IcomLANSlotRelease.Endpoint] = []
        if let port = control.boundPort {
            endpoints.append(.init(localID: control.localID, remoteID: control.remoteID,
                                   sourcePort: port, radioPort: configuration.controlPort))
        }
        guard includeMedia else { return endpoints }
        if let port = serial.boundPort {
            endpoints.append(.init(localID: serial.localID, remoteID: serial.remoteID,
                                   sourcePort: port, radioPort: configuration.serialPort))
        }
        if let port = audio.boundPort {
            endpoints.append(.init(localID: audio.localID, remoteID: audio.remoteID,
                                   sourcePort: port, radioPort: configuration.audioPort))
        }
        return endpoints
    }

    /// Release the token, close the CI-V channel, say goodbye on every
    /// stream. Safe from `deinit`: the teardown is dispatched to the queue,
    /// never run synchronously on it.
    func close() {
        openTask?.cancel()
        openTask = nil
        renewTimer?.cancel(); renewTimer = nil
        reorderTimer?.cancel(); reorderTimer = nil
        livenessTimer?.cancel(); livenessTimer = nil
        // A cancelled watch and a watch that never noticed anything produce
        // exactly the same log — nothing. Say which one this was.
        TxLog.debug(.modem, "IcomLAN liveness: watch cancelled by close()",
                    ["state": String(describing: state)])
        let teardown = { [self] in
            // Say goodbye whenever there is something to say goodbye with,
            // whatever state we think we are in.
            //
            // This used to run only from .connected or .connecting, so every
            // failure path — macOS refusing the network, the sockets dying
            // with ENOTCONN, a liveness verdict — went straight to .failed
            // and released nothing. The radio kept the slot and the operator
            // got "closing the app doesn't release the 705", which is exactly
            // what it did (2026-09-17).
            //
            // A release the radio has already acted on is ignored. A release
            // never sent costs the operator their radio until the slot times
            // out on its own, so the asymmetry only points one way.
            if !authID.isEmpty, control.remoteID != 0 {
                // Refresh what we know of this session before we let go, so the
                // reclaim on the next launch measures its window from when we
                // actually leave, not from when the session first came up, and
                // covers every stream. The goodbyes below are unacknowledged
                // UDP that may not land; the record is what guarantees the slot
                // gets freed regardless.
                IcomLANSlotRelease.remember(host: configuration.host,
                                            streams: slotEndpoints(includeMedia: true))
                control.sendTracked(IcomLAN.token(.release, local: control.localID, remote: control.remoteID,
                                                  innerSequence: nextInner(), authID: authID))
            }
            if serial.remoteID != 0 {
                serial.sendTracked(IcomLAN.serialOpen(false, sendSequence: nextSerialSequence(),
                                                      local: serial.localID, remote: serial.remoteID))
            }
            // A slot is taken the moment the radio accepts a login, not when
            // the whole connection succeeds. Keying only on connectionOpened
            // was too narrow and cost an afternoon: an attempt that logged in
            // and then lost the network left the radio holding the slot, the
            // retry went straight in with no settle, and the radio granted
            // audio without CI-V — receive and carrier detect worked while
            // every CI-V command went unanswered and PTT timed out.
            //
            // Still not armed by an attempt that got nowhere. A socket macOS
            // refused, or a radio that never answered the first control
            // packet, took nothing and owes nothing, which is what stopped a
            // fresh launch sitting there for fifteen seconds (2026-09-17).
            if connectionOpened || authID.isEmpty == false { lastCloseAt = IcomLANStream.now }
            audio.disconnect()
            serial.disconnect()
            control.disconnect()
            serialReorder.reset()
            audioReorder.reset()
            if state != .idle, !isFailed { state = .idle }
        }
        // Flush the disconnect synchronously when we can, so the radio's
        // single client slot is released before the process moves on; a
        // callback already on the queue must not deadlock, so hop then.
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            teardown()
        } else {
            queue.sync(execute: teardown)
        }
    }

    private static let queueKey = DispatchSpecificKey<Void>()

    /// How long to leave the radio alone after letting go of it, before
    /// logging in again.
    ///
    /// The radio keeps one session. `close()` sends the token release and
    /// tears the sockets down in the same breath, so the release is not
    /// acknowledged and the radio can still be holding the old session when
    /// the next login arrives. It then answers the login, carries audio, and
    /// never attaches CI-V — a session that looks connected here and reads
    /// as disconnected on the radio, with transmit dead (2026-09-17).
    ///
    /// Fifteen seconds, from the operator's log of 2026-09-17. A reconnect
    /// 15s after a close answered CI-V on the first command; two reconnects
    /// about 5s after a close did not — one recovered on its own six seconds
    /// into the session, the other lost the radio entirely and failed with
    /// "the radio did not answer (control I-am-here)". Five was a guess and
    /// it was too small; the login retry path below budgets 12.5s against
    /// the same timeout, which is the same order.
    ///
    /// It only ever delays a reconnect, never a first connect, and only by
    /// what is left of the period.
    static let settleAfterClose: TimeInterval = 15

    /// What is left of the settle period, or zero when the radio has been
    /// left alone long enough — or was never connected in this session.
    ///
    /// Clamped at both ends. `CFAbsoluteTimeGetCurrent` is wall clock and can
    /// step backwards, and an elapsed time of −100s would otherwise ask the
    /// operator to wait 105 seconds to reconnect.
    static func settleRemaining(now: Double, lastCloseAt: Double,
                                settle: TimeInterval = settleAfterClose) -> TimeInterval {
        guard lastCloseAt > 0 else { return 0 }
        return min(settle, max(0, settle - (now - lastCloseAt)))
    }

    /// How many times to resend a rejected login before giving up, and how
    /// long to wait between tries. Chosen to outlast the radio's stale-slot
    /// timeout after an unclean disconnect (tens of seconds) without holding
    /// a genuinely-wrong password hostage for too long.
    private static let loginAttempts = 5
    private static let loginRetryDelay: Double = 2.5

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    /// Fails the session on evidence gathered outside it.
    ///
    /// The CI-V client sees something no stream can: polls going unanswered
    /// while every stream stays punctual. It has no business tearing the
    /// session down itself, so it reports and this decides.
    func failFromOutside(_ why: String) {
        queue.async { [weak self] in
            guard let self, self.isConnected else { return }
            TxLog.warning(.modem, "IcomLAN failing from CI-V evidence", ["why": why])
            self.fail(why)
        }
    }

    private func fail(_ why: String) {
        control.trace("session fail: " + why)
        TxLog.warning(.modem, "IcomLAN session failed", ["why": why, "state": String(describing: state)])
        queue.async { [self] in
            guard !isFailed else { return }
            renewTimer?.cancel(); renewTimer = nil
            reorderTimer?.cancel(); reorderTimer = nil
            livenessTimer?.cancel(); livenessTimer = nil
            // Release the token before dropping the socket, exactly as a
            // clean close does. Without this the radio keeps our session in
            // its single client slot until the token times out (tens of
            // seconds), so the next retry, a quick relaunch, or a Test
            // connection collides with our own ghost and the radio reports
            // it as "another client connected."
            if !authID.isEmpty {
                control.sendTracked(IcomLAN.token(.release, local: control.localID, remote: control.remoteID,
                                                  innerSequence: nextInner(), authID: authID))
            }
            audio.disconnect(); serial.disconnect(); control.disconnect()
            state = .failed(why)
        }
    }

    // MARK: - Sending

    /// CI-V bytes to the radio. Frames longer than the radio's 80-byte
    /// limit are split; CI-V frames never are that long.
    func sendSerial(_ bytes: Data) {
        queue.async { [self] in
            guard isConnected else {
                civWritesRefused += 1
                return
            }
            civWrites += 1
            var rest = bytes
            while !rest.isEmpty {
                let chunk = rest.prefix(80)
                rest = rest.dropFirst(chunk.count)
                serial.sendTracked(IcomLAN.serialData(Data(chunk), sendSequence: nextSerialSequence(),
                                                      local: serial.localID, remote: serial.remoteID))
            }
        }
    }

    /// Transmit audio: 16-bit little-endian mono at the negotiated rate,
    /// 20 ms at a time (1920 bytes at 48 kHz), split the way the radio likes.
    func sendAudio(pcm: Data) {
        queue.async { [self] in
            guard isConnected else { return }
            var rest = pcm
            var sizes = IcomLAN.audioChunkSizes
            while !rest.isEmpty {
                let size = sizes.isEmpty ? 1364 : sizes.removeFirst()
                let chunk = rest.prefix(size)
                rest = rest.dropFirst(chunk.count)
                audio.sendTracked(IcomLAN.audioData(Data(chunk), sendSequence: audioSendSequence &- 1,
                                                    local: audio.localID, remote: audio.remoteID))
                audioSendSequence &+= 1
            }
        }
    }

    // MARK: - Inbound

    private func handleControl(_ d: Data) {
        if let caps = IcomLAN.parseCapabilities(d) {
            replyID = caps.replyID
            gotReplyID = true
            if !caps.radioName.isEmpty { radioName = caps.radioName }
            tokenAccepted = true   // legacy flag, kept for any readers
            trySendConnectionRequest()
            return
        }
        if let action = IcomLAN.parseTokenReply(d) {
            // Any token acknowledgement means the auth took.
            if action == .renew || action == .confirm { authOK = true; renewOutstanding = false }
            trySendConnectionRequest()
            return
        }
        if let reply = IcomLAN.parseConnectionReply(d) {
            control.trace("connection reply accepted=" + String(reply.accepted) + " dev=" + reply.deviceName)
            guard !connectionOpened else { return }
            // The radio emits a 0x90 with accepted=false as its *initial*
            // connection status ("no audio/CI-V session active yet"), part
            // of its normal reply to the token — BEFORE we have sent our
            // connection request. That is not a refusal of anything; only a
            // 0x90 that arrives after we actually sent the request answers
            // it. Treating the pre-request status as a refusal made the
            // session fail on a perfectly good handshake and only then send
            // the real request into a socket that was already tearing down.
            guard requestSent else {
                control.trace("ignoring pre-request 0x90 status (accepted=\(reply.accepted))")
                return
            }
            if reply.accepted {
                deviceName = reply.deviceName
                if !reply.authID.isEmpty { authID = reply.authID }
                connectionOpened = true
                openMediaStreams()
            } else {
                control.trace("connection request refused: " + d.map { String(format: "%02x", $0) }.joined())
                resolveConnect(.failure(IcomLANError.rejected("the radio refused the audio and CI-V request (is another client connected?)")))
            }
            return
        }
        if let status = IcomLAN.parseStatus(d) {
            control.trace("status packet -> " + String(describing: status))
            // Before the connection opens, an auth-failed status is fatal;
            // afterwards the radio still emits periodic status and only a
            // clean radio-disconnect ends the session.
            switch status {
            case .authFailed where !connectionOpened && !loggingIn:
                resolveConnect(.failure(IcomLANError.rejected("the radio refused the login (another client may be connected)")))
            case .radioDisconnected:
                if connectionOpened { fail(IcomLANError.radioDisconnected.message) }
                else { resolveConnect(.failure(IcomLANError.radioDisconnected)) }
            default:
                break
            }
        }
    }

    /// Send the CI-V/audio request once the radio has told us who it is and
    /// acknowledged the auth. Guarded so it fires exactly once.
    private func trySendConnectionRequest() {
        guard !requestSent, gotReplyID, authOK else { return }
        requestSent = true
        let c = configuration
        var request = IcomLAN.ConnectionRequest(radioName: radioName.isEmpty ? "IC-705" : radioName, username: c.username)
        request.sampleRate = c.sampleRate
        request.serialPort = c.serialPort
        request.audioPort = c.audioPort
        request.txBufferMs = c.txBufferMs
        let packet = IcomLAN.connectionRequest(request, local: control.localID, remote: control.remoteID,
                                               innerSequence: nextInner(), authID: authID, replyID: replyID ?? [])
        control.trace("sending connection request: " + packet.map { String(format: "%02x", $0) }.joined())
        control.sendTracked(packet)
    }

    /// Open the CI-V and audio sockets once the radio has agreed, then
    /// declare the session connected.
    private func openMediaStreams() {
        let c = configuration
        Task { [self] in
            do {
                try await serial.connect(host: c.host, port: c.serialPort, timeout: c.timeout)
                serial.startKeepalive(pingSequence: 1, idlePackets: true)
                serial.sendTracked(IcomLAN.serialOpen(true, sendSequence: nextSerialSequence(),
                                                      local: serial.localID, remote: serial.remoteID))
                try await audio.connect(host: c.host, port: c.audioPort, timeout: c.timeout)
                audio.startKeepalive(pingSequence: 1, idlePackets: false)
                startRenewals()
                startReorderTicks()
                startLivenessWatch()
                state = .connected
                // Now that all three streams are up, remember every one so the
                // next launch can release the CI-V and audio streams too, not
                // just control — a stale CI-V stream is what leaves a fresh
                // session with audio and no answers.
                IcomLANSlotRelease.remember(host: c.host, streams: slotEndpoints(includeMedia: true))
                resolveConnect(.success(()))
            } catch {
                resolveConnect(.failure(error))
            }
        }
    }

    private func resolveConnect(_ result: Result<Void, Error>) {
        guard let finish = finishConnect else { return }
        finishConnect = nil
        finish(result)
    }

    private func handleSerial(_ d: Data) {
        guard let h = IcomLAN.Header.parse(d) else { return }
        // Idle packets carry sequence numbers too; they keep the order intact.
        guard IcomLAN.isIdle(d) || IcomLAN.serialPayload(d) != nil else { return }
        serialReorder.add(sequence: h.sequence, data: d, now: IcomLANStream.now, release: { [self] _, packet in
            if let packet, let payload = IcomLAN.serialPayload(packet) { onSerialBytes?(payload) }
        }, requestRetransmit: { [self] missing in
            requestRetransmit(missing, on: serial)
        })
    }

    private func handleAudio(_ d: Data) {
        guard let h = IcomLAN.Header.parse(d), let payload = IcomLAN.audioPayload(d) else { return }
        recentAudioSizes.append(payload.count)
        if recentAudioSizes.count > 8 { recentAudioSizes.removeFirst() }
        audioReorder.add(sequence: h.sequence, data: payload, now: IcomLANStream.now, release: { [self] _, pcm in
            onAudio?(pcm)
        }, requestRetransmit: { [self] missing in
            requestRetransmit(missing, on: audio)
        })
    }

    /// Bytes per lost audio packet, from what has been arriving.
    var typicalAudioPacketBytes: Int {
        guard !recentAudioSizes.isEmpty else { return 960 }
        return recentAudioSizes.reduce(0, +) / recentAudioSizes.count
    }

    private func requestRetransmit(_ missing: [UInt16], on stream: IcomLANStream) {
        guard !missing.isEmpty else { return }
        if missing.count == 1 {
            let p = IcomLAN.retransmitRequest(sequence: missing[0], local: stream.localID, remote: stream.remoteID)
            stream.send(p); stream.send(p)
        } else {
            let p = IcomLAN.retransmitRequest(ranges: [(missing.first!, missing.last!)], local: stream.localID, remote: stream.remoteID)
            stream.send(p); stream.send(p)
        }
    }

    private func startReorderTicks() {
        reorderTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.02, repeating: 0.02)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = IcomLANStream.now
            self.serialReorder.tick(now: now) { _, packet in
                if let packet, let payload = IcomLAN.serialPayload(packet) { self.onSerialBytes?(payload) }
            }
            self.audioReorder.tick(now: now) { _, pcm in self.onAudio?(pcm) }
        }
        t.resume()
        reorderTimer = t
    }

    /// Fail the session when the radio goes quiet.
    ///
    /// The token renewal below is a liveness check of a sort, but a slow one:
    /// it can take two minutes to conclude, and it only ever watched the
    /// control stream's *answers*. This watches all three streams' inbound
    /// traffic, which over UDP is the only evidence the radio is still there
    /// at all — see `IcomLANLiveness`.
    /// One line per second is noise; one line never is unfalsifiable. log12
    /// (2026-09-10) had ten minutes of dead audio and no verdict, and no way
    /// to tell whether the watch ran, bailed, or was never started. Every
    /// thirty ticks is ~120 lines an hour and settles that question outright.
    private static let livenessHeartbeatTicks = 30

    /// Liveness goes out as `.modem`, deliberately: that is the category
    /// carrying `[MODEM]` in the console log the operator exports, so these
    /// lines land in the same stream, on the same clock, as the last traffic
    /// before a drop. Console output needs Wire debug enabled — same as the
    /// `[MODEM]` lines themselves.
    private func livenessLog(_ message: String, _ data: [String: Any] = [:]) {
        var payload = data
        payload["tick"] = livenessTicks
        payload["state"] = String(describing: state)
        TxLog.debug(.modem, "IcomLAN liveness: " + message, payload)
    }

    private func startLivenessWatch() {
        livenessTimer?.cancel()
        livenessWasWatching = false
        livenessReportedUnjudged = false
        livenessTicks = 0
        TxLog.debug(.modem, "IcomLAN liveness: watch started", [
            "limit": IcomLANLiveness.silenceLimit, "interval": 1.0])
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Say when the watch stands down, because its silence looks
            // exactly like a healthy link. log12 (2026-09-10) holds ten
            // minutes of dead audio, no verdict, and no way to tell whether
            // the watchdog ran, bailed here, or never started — which cost a
            // diagnosis. Traced on the transition, not once a second.
            self.livenessTicks += 1
            if !self.isConnected {
                if self.livenessWasWatching {
                    self.livenessWasWatching = false
                    self.livenessReportedUnjudged = false
                    self.livenessLog("standing down — session is no longer connected")
                }
                return
            }
            self.livenessWasWatching = true
            // Control and audio only. Both carry traffic continuously once
            // connected — the radio pings us on control several times a
            // second, and audio is a packet every few milliseconds (measured
            // at over a hundred in ten seconds by `IcomLANLiveTests`). The
            // serial stream is deliberately left out: CI-V flows only when
            // somebody has something to say, so quiet there is ordinary and
            // failing on it would drop a working radio.
            //
            // The quieter of the two decides. Audio stopping while control
            // still pings is a radio we have gone deaf to, which is the
            // symptom the operator reported, not a healthy link.
            let silences = [self.control.silence, self.audio.silence].compactMap { $0 }
            guard let longest = silences.max() else {
                if !self.livenessReportedUnjudged {
                    self.livenessReportedUnjudged = true
                    self.livenessLog("no stream reports a silence — nothing can be judged")
                }
                return
            }
            // CI-V is reported but never judged — quiet there is ordinary,
            // and failing on it would drop a working radio. It is here
            // because a dead CI-V stream and a radio ignoring CI-V produce
            // the same complaint ("has not answered any CI-V command") and
            // need opposite fixes.
            let detail: [String: Any] = [
                "quiet": String(format: "%.1fs", longest),
                "control": String(format: "%.1fs", self.control.silence ?? -1),
                "audio": String(format: "%.1fs", self.audio.silence ?? -1),
                "civ": String(format: "%.1fs", self.serial.silence ?? -1),
                "civAsked": self.civWrites,
                "civRefused": self.civWritesRefused,
                "civSent": self.serial.sentPackets,
                "civDropped": self.serial.droppedSends,
                "audioPayload": String(format: "%.1fs", self.audio.payloadSilence ?? -1)]
            // Half the limit is the interesting part: quiet enough to record,
            // not yet a verdict. A log that jumps straight from healthy to
            // failed says nothing about how it got there.
            if longest >= IcomLANLiveness.silenceLimit / 2 {
                self.livenessLog("approaching the limit", detail)
            } else if self.livenessTicks % Self.livenessHeartbeatTicks == 0 {
                // Proof the timer is running. Its absence is the single most
                // useful thing this log can say.
                self.livenessLog("healthy", detail)
            }
            if let why = IcomLANLiveness.complaint(silentFor: longest) {
                self.livenessLog("FAILING the link", detail)
                self.fail(why)
                return
            }
            // A stream can be punctual and empty. The radio keeps pinging
            // every stream on its own schedule after it has stopped serving
            // them, so silence alone missed a four-and-a-half-hour outage
            // (2026-09-18); audio carrying nothing but keepalives is the part
            // that was decidable and unmeasured.
            if let quietAudio = self.audio.payloadSilence,
               let why = IcomLANLiveness.payloadComplaint(silentFor: quietAudio) {
                self.livenessLog("FAILING the link — audio carries only keepalives", detail)
                self.fail(why)
            }
        }
        t.resume()
        livenessTimer = t
    }

    private func startRenewals() {
        renewTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            if self.renewOutstanding {
                // Two minutes without an answer: the token is gone.
                self.fail("the radio stopped answering the token renewal")
                return
            }
            self.renewOutstanding = true
            self.control.sendTracked(IcomLAN.token(.renew, local: self.control.localID, remote: self.control.remoteID,
                                                   innerSequence: self.nextInner(), authID: self.authID))
        }
        t.resume()
        renewTimer = t
    }

    private func nextInner() -> UInt16 { defer { innerSequence &+= 1 }; return innerSequence }
    private func nextSerialSequence() -> UInt16 { defer { serialSendSequence &+= 1 }; return serialSendSequence }
}
