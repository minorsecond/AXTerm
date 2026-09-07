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
        didSet { if oldValue != state { onState?(state) } }
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
    private var finishConnect: ((Result<Void, Error>) -> Void)?
    private var serialReorder = SequenceReorderBuffer(holdSeconds: 0.1)
    private var audioReorder = SequenceReorderBuffer(holdSeconds: 0.1)
    private var reorderTimer: DispatchSourceTimer?
    private var recentAudioSizes: [Int] = []
    private var openTask: Task<Void, Error>?

    var isConnected: Bool { state == .connected }
    var roundTrip: Double { control.roundTrip }
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
        for attempt in 0..<Self.loginAttempts {
            try Task.checkCancellation()
            let tokenRequest = (UInt8.random(in: 0...255), UInt8.random(in: 0...255))
            control.sendTracked(IcomLAN.login(local: control.localID, remote: control.remoteID, innerSequence: nextInner(),
                                              tokenRequest: tokenRequest, username: c.username, password: c.password,
                                              program: c.program))
            control.trace("login sent (attempt \(attempt + 1))")
            let loginReply = try await control.expect(timeout: c.timeout, what: "login") { IcomLAN.parseLoginReply($0) != nil }
            let reply = IcomLAN.parseLoginReply(loginReply)!
            control.trace("login accepted=\(reply.accepted) (attempt \(attempt + 1))")
            if reply.accepted { login = reply; break }
            if attempt + 1 < Self.loginAttempts {
                try await Task.sleep(nanoseconds: UInt64(Self.loginRetryDelay * 1_000_000_000))
            }
        }
        guard let login else { throw IcomLANError.badCredentials }
        authID = login.authID

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

    /// Release the token, close the CI-V channel, say goodbye on every
    /// stream. Safe from `deinit`: the teardown is dispatched to the queue,
    /// never run synchronously on it.
    func close() {
        openTask?.cancel()
        openTask = nil
        renewTimer?.cancel(); renewTimer = nil
        reorderTimer?.cancel(); reorderTimer = nil
        let teardown = { [self] in
            if state == .connected || state == .connecting {
                if !authID.isEmpty {
                    control.sendTracked(IcomLAN.token(.release, local: control.localID, remote: control.remoteID,
                                                      innerSequence: nextInner(), authID: authID))
                }
                if serial.remoteID != 0 {
                    serial.sendTracked(IcomLAN.serialOpen(false, sendSequence: nextSerialSequence(),
                                                          local: serial.localID, remote: serial.remoteID))
                }
            }
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

    /// How many times to resend a rejected login before giving up, and how
    /// long to wait between tries. Chosen to outlast the radio's stale-slot
    /// timeout after an unclean disconnect (tens of seconds) without holding
    /// a genuinely-wrong password hostage for too long.
    private static let loginAttempts = 5
    private static let loginRetryDelay: Double = 2.5

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    private func fail(_ why: String) {
        control.trace("session fail: " + why)
        queue.async { [self] in
            guard !isFailed else { return }
            renewTimer?.cancel(); renewTimer = nil
            reorderTimer?.cancel(); reorderTimer = nil
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
            guard isConnected else { return }
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
            case .authFailed where !connectionOpened:
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
                state = .connected
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
