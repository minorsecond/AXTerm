import Foundation

/// A `.modem` radio's link: the built-in modem, the radio's CI-V port, and
/// the PTT that joins them.
///
/// Opening goes CI-V first — a wrong radio or a dead port fails before the
/// audio devices are grabbed, so the operator sees one clear error — then
/// audio, then optionally the one-shot radio setup. The wrapper is what
/// `RadioManager` holds, so in-place setting changes have one place to land.
nonisolated final class ModemRadioLink: KISSLink, @unchecked Sendable {

    private(set) var config: ModemLinkConfig
    let modem: SoftModemLink
    private(set) var rig: CIVClient?
    private(set) var pttController: PTTController
    private var civTransport: CIVTransport?
    private let makeTransport: (String) -> CIVTransport
    private let makeSession: (IcomLANSession.Configuration) -> IcomLANSession
    /// The WLAN session, when the radio is reached that way: CI-V and audio
    /// both ride on it.
    private(set) var lanSession: IcomLANSession?
    private let lanAudio: LANModemAudioIO?

    /// The radio, as CI-V reports it; empty until read.
    var rigStatus: RigStatus { lock.withLock { _rigStatus } }
    private var _rigStatus = RigStatus()
    /// "IC-705" once identified.
    private(set) var rigModel: String?

    var onRigStatus: (@Sendable (RigStatus) -> Void)?
    /// A receive setting became wrong while we were running.
    var onReceiveDrift: (@Sendable ([RigReceiveAudit.Finding]) -> Void)?
    /// What the last audit found, so the watch can report changes rather than
    /// the standing state.
    private var lastAudit: [RigReceiveAudit.Finding] = []
    var onTelemetry: (@Sendable (ModemTelemetry) -> Void)? {
        didSet { modem.engine.onTelemetry = onTelemetry }
    }

    private let lock = NSLock()
    private enum Phase: Equatable { case idle, rigOpening, modemOpen, failed(String) }
    private var phase: Phase = .idle
    private var pollTask: Task<Void, Never>?
    /// The last close, still unkeying and shutting the port; the next open
    /// waits for it so the same serial path is not opened twice.
    private var closeTask: Task<Void, Never>?
    private weak var _delegate: KISSLinkDelegate?
    private let deliver: SoftModemLink.Deliver

    // MARK: Auto-reconnect
    // A quit or an Xcode rebuild leaves the IC-705 holding its single client
    // slot for tens of seconds, so the first reopen after a relaunch usually
    // fails — the radio hasn't let go yet. Rather than make the operator mash
    // Reconnect, retry on a bounded backoff that outlasts the slot timeout,
    // stopping on success or an explicit close.
    private var wantsOpen = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private static let maxReconnectAttempts = 8
    private static let baseReconnectDelay: TimeInterval = 3
    private static let maxReconnectDelay: TimeInterval = 30

    /// What the "Software" row shows: this modem, its mode.
    var identity: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return "AXTerm Sound Modem \(version) · \(config.mode.rawValue)".replacingOccurrences(of: "  ", with: " ")
    }

    /// `audio` is the sound device for a USB radio; a Wi-Fi radio brings its
    /// own audio on the session and ignores it. The default serial
    /// transport exists only on the Mac; elsewhere a USB radio has no rig.
    init(config: ModemLinkConfig,
         audio: ModemAudioIO?,
         makeTransport: @escaping (String) -> CIVTransport = ModemRadioLink.defaultSerialTransport,
         makeSession: @escaping (IcomLANSession.Configuration) -> IcomLANSession = { IcomLANSession(configuration: $0) },
         scheduling: ModemEngine.Scheduling = .dedicatedThread,
         deliver: @escaping SoftModemLink.Deliver = { work in
             DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
         }) {
        self.config = config
        self.makeTransport = makeTransport
        self.makeSession = makeSession
        self.deliver = deliver
        let session: IcomLANSession? = config.rigLink == .lan ? makeSession(config.lanConfiguration) : nil
        self.lanSession = session
        let audioIO: ModemAudioIO
        if let session {
            let lan = LANModemAudioIO(session: session)
            self.lanAudio = lan
            audioIO = lan
        } else {
            self.lanAudio = nil
            audioIO = audio ?? SyntheticModemIO()
        }
        let rigParts = Self.makeRig(config, makeTransport: makeTransport, session: session)
        self.civTransport = rigParts.transport
        self.rig = rigParts.client
        self.pttController = rigParts.ptt
        self.modem = SoftModemLink(configuration: config.softModemConfiguration, audio: audioIO, ptt: rigParts.ptt,
                                   inputName: config.rigLink == .lan ? config.lanHost : config.audioInputDeviceName,
                                   outputName: config.rigLink == .lan ? config.lanHost : config.audioOutputDeviceName,
                                   scheduling: scheduling, deliver: deliver)
        attachRig()
    }

    nonisolated static func defaultSerialTransport(_ path: String) -> CIVTransport {
        #if os(macOS)
        return SerialCIVTransport(path: path)
        #else
        return UnavailableCIVTransport(reason: "a USB serial port needs a Mac")
        #endif
    }

    /// Frames the radio sends unasked — CI-V transceive broadcasts when the
    /// operator tunes — fold into the status; we switch transceive off at
    /// connect, but a radio that ignores that still gets heard.
    private func attachRig() {
        rig?.onUnsolicited = { [weak self] frame in self?.absorbUnsolicited(frame) }
        rig?.onTransportFailure = { [weak self] reason in self?.rigDied(reason) }
    }

    /// The radio went away while we were using it.
    ///
    /// Every failure path in `open()` reports itself; this is the one *after*
    /// the link is up, and it had none. From the operator's log of
    /// 2026-09-09: the UDP sockets to the IC-705 died at 11:48:49Z, the
    /// session failed, the CI-V client failed its requests — and the link went
    /// on reporting `.connected` for two hours, with the modem running against
    /// a radio that was no longer listening. Over the WLAN there is no port to
    /// notice going away, so this news is the only news there is.
    private func rigDied(_ reason: String) {
        deliver { [weak self] in
            guard let self else { return }
            // A close in flight is not a failure, and a link already failed
            // must not restart the backoff from a second report.
            guard self.wantsOpen, self.state != .failed else { return }
            let message = "Lost the radio: \(reason)"
            self.pollTask?.cancel()
            self.pollTask = nil
            self.modem.close()
            self.lock.withLock { self.phase = .failed(message) }
            self._delegate?.linkDidError(message)
            self._delegate?.linkDidChangeState(.failed)
            self.scheduleReconnect()
        }
    }

    private func absorbUnsolicited(_ frame: CIVFrame) {
        var status = lock.withLock { _rigStatus }
        switch frame.command {
        case 0x00, 0x03:
            guard let hz = CIVBCD.frequencyHz(frame.data) else { return }
            status.frequencyHz = hz
        case 0x01, 0x04:
            guard let raw = frame.data.first, let mode = RigMode(rawValue: raw) else { return }
            status.mode = mode
            if frame.data.count > 1 { status.filter = frame.data[1] }
        default:
            return
        }
        status.updatedAt = Date()
        lock.withLock { _rigStatus = status }
        onRigStatus?(status)
    }

    private static func makeRig(_ config: ModemLinkConfig, makeTransport: (String) -> CIVTransport, session: IcomLANSession?)
    -> (transport: CIVTransport?, client: CIVClient?, ptt: PTTController) {
        guard config.usesRig else { return (nil, nil, NoPTTController()) }
        let transport: CIVTransport
        if let session { transport = LANCIVTransport(session: session) } else { transport = makeTransport(config.civSerialPath) }
        // The Wi-Fi CI-V stream carries the radio's scope flood and its
        // reorder-buffer latency, so give a reply longer to arrive there
        // than over the direct serial bus.
        let timeout: TimeInterval = session != nil ? 1.2 : 0.5
        let client = CIVClient(transport: transport, radioAddress: config.civAddress,
                               controllerAddress: config.effectiveCIVControllerAddress, requestTimeout: timeout)
        let ptt: PTTController
        // The WLAN has no control lines: keying there is the CI-V command.
        let method: ModemPTTMethod = (session != nil && (config.pttMethod == .rts || config.pttMethod == .dtr)) ? .civ : config.pttMethod
        switch method {
        case .civ: ptt = CIVPTTController(client: client, maxTransmitSeconds: TimeInterval(config.maxTransmitSeconds))
        case .rts: ptt = SerialLinePTTController(transport: transport, line: .rts, maxTransmitSeconds: TimeInterval(config.maxTransmitSeconds))
        case .dtr: ptt = SerialLinePTTController(transport: transport, line: .dtr, maxTransmitSeconds: TimeInterval(config.maxTransmitSeconds))
        case .none: ptt = NoPTTController()
        }
        return (transport, client, ptt)
    }

    /// What to tell the operator when the CI-V port opened but the radio
    /// never answered on it.
    ///
    /// Over the WLAN the login names the radio, so `identify` is best-effort
    /// and every setup command is `try?` — deliberately, because the radio's
    /// scope flood can bury a reply without the link being broken. The cost
    /// is that a genuinely dead control channel looks exactly like a healthy
    /// one until the first transmission, where it surfaces as a bare "PTT
    /// failed: timeout" seconds into an operation the operator has already
    /// committed to. Receive still works without CI-V; keying does not.
    /// - Parameter answeringAddress: who replied to a broadcast asking the
    ///   whole bus, when one was sent. It turns the advice from "check two
    ///   things" into the one thing that is actually wrong.
    /// - Parameter civStreamSilence: how long the WLAN CI-V stream has been
    ///   quiet, when there is one. An attached stream idles continuously, so
    ///   traffic on it while nothing has been read tells the operator the
    ///   radio is there and ignoring CI-V rather than unreachable — the one
    ///   distinction the old wording asked them to guess at.
    /// Quiet shorter than this means the stream is carrying traffic. An
    /// attached CI-V stream idles several times a second, so anything inside
    /// a few seconds is alive and anything beyond it is not.
    static let streamAliveWithin: TimeInterval = 5

    /// - Parameter sourcePortMismatched: the CI-V stream bound a different
    ///   source port from the one its session ID was built from. The radio
    ///   checks the two against each other and refuses the stream without
    ///   saying so, so this produces the same silence as a radio with CI-V
    ///   switched off — and reconnecting is what fixes it, not the menus.
    static func civSilenceComplaint(identified: Bool, statusAnswered: Bool, address: UInt8,
                                    answeringAddress: UInt8? = nil,
                                    civStreamSilence: TimeInterval? = nil,
                                    sourcePortMismatched: Bool = false) -> String? {
        guard !identified, !statusAnswered else { return nil }
        let opening = "The radio is connected but has not answered any CI-V command. "
            + "Receive works; transmit cannot key over CI-V until it does. "
        if sourcePortMismatched {
            // Ours, not the radio's, and no amount of changing its menus
            // will help — so say so before any advice about them.
            return opening
                + "This Mac could not hold the source port the CI-V session was addressed "
                + "from, so the radio is refusing that stream and nothing on the radio needs "
                + "changing. Disconnect and connect again."
        }
        switch answeringAddress {
        case .some(let found) where found != address:
            // The radio is there and talking; we were calling the wrong name.
            return opening + String(format: "A radio answered a broadcast from address %02X, "
                                    + "but this modem is asking for %02X. "
                                    + "Set the modem's CI-V address to %02X.", found, address, found)
        case .some:
            // It answered the broadcast on the very address we use, so the
            // address is right and something else is eating the replies.
            return opening + String(format: "It answered a broadcast from %02X, the address this modem "
                                    + "is already using, so the address is right and the replies are "
                                    + "being lost rather than never sent.", address)
        case .none:
            let nothingAnswered = String(format: "Nothing answered a broadcast to every address "
                                         + "either (this modem is asking for %02X). ", address)
            switch civStreamSilence {
            case .some(let quiet) where quiet <= streamAliveWithin:
                // The radio is keeping the stream alive and still says
                // nothing, so it is reachable and refusing to talk.
                return opening + nothingAnswered
                    + "The CI-V stream itself is alive — the radio is sending on it — so it is "
                    + "reachable and CI-V is switched off at the radio. Turn CI-V Transceive on "
                    + "and check the radio's CI-V address."
            case .some:
                // Nothing at all on the stream: it never attached, which a
                // reconnect too soon after a disconnect will do.
                return opening
                    + "Nothing is arriving on the CI-V stream at all, so it never came up. The "
                    + "radio holds one session for tens of seconds after a disconnect — wait, then "
                    + "connect again."
            case .none:
                return opening + nothingAnswered
                    + "CI-V is switched off at the radio or not reaching it."
            }
        }
    }

    // MARK: - KISSLink

    var state: KISSLinkState {
        let phase = lock.withLock { self.phase }
        switch phase {
        case .idle: return .disconnected
        case .rigOpening: return .connecting
        case .failed: return .failed
        case .modemOpen: return modem.state
        }
    }

    var endpointDescription: String {
        let via: String
        if config.rigLink == .lan {
            via = config.lanHost.isEmpty ? "Wi-Fi" : config.lanHost
        } else {
            via = config.audioInputDeviceName.isEmpty ? "audio" : config.audioInputDeviceName
        }
        return "\(rigModel ?? "Sound modem") via \(via)"
    }

    var delegate: KISSLinkDelegate? {
        get { _delegate }
        set { _delegate = newValue; modem.delegate = newValue }
    }

    func open() {
        guard state == .disconnected || state == .failed else { return }
        wantsOpen = true
        reconnectTask?.cancel()
        reconnectTask = nil
        guard let rig, let civTransport else {
            lock.withLock { phase = .modemOpen }
            modem.open()
            return
        }
        lock.withLock { phase = .rigOpening }
        deliver { [weak self] in self?._delegate?.linkDidChangeState(.connecting) }
        let previousClose = closeTask
        Task { [weak self] in
            guard let self else { return }
            await previousClose?.value
            civTransport.open()
            do {
                var waited = 0
                while civTransport.state == .opening, waited < 600 {
                    try await Task.sleep(for: .milliseconds(25))
                    waited += 1
                }
                if case .failed(let reason) = civTransport.state { throw CIVError.transport(reason) }

                // Over the WLAN the login itself identifies the radio (the
                // connection reply named it), and the IC-705 floods CI-V with
                // scope data that can bury the identify reply. So there,
                // trust the session's name and let identify be best-effort;
                // over USB a wrong radio or dead port must still fail here,
                // before the audio devices are grabbed.
                var identified = false
                if let session = lanSession {
                    rigModel = session.radioName.isEmpty ? "IC-705" : session.radioName
                    // Silence the spectrum-scope flood first. Until it stops,
                    // its FD/FE-laden waveform frames desync the CI-V parser
                    // and swallow the acks every later command waits on — PTT
                    // included. The write lands even mid-flood; give the radio
                    // a moment to go quiet before anything that needs a reply.
                    try? await rig.setScopeDataOutput(false)
                    try? await Task.sleep(for: .milliseconds(300))
                    if (try? await rig.identify()) != nil { identified = true }
                    // else: the bus is busy; the login already proved the radio.
                } else {
                    let address = try await rig.identify()
                    rigModel = CIVKnownRadios.model(forAddress: address) ?? String(format: "Icom %02X", address)
                    identified = true
                }
                // Quieting the bus writes a persistent radio menu item, so
                // it belongs behind the switch that says AXTerm may write
                // them — and never over the network, where there is no
                // shared bus to quiet and the operator needs the setting on.
                // It was unconditional until 2026-09-17, which left the app
                // advising the operator to turn on a setting it switched off
                // at every connect.
                if config.setsRadioModeOnConnect {
                    try? await rig.configureForPacket(
                        config.mode,
                        dataMod: config.rigLink == .lan ? .wlan : .usb,
                        quietTheBus: config.rigLink != .lan)
                }
                let answered = await refreshRigStatus()
                // Over the WLAN identify is allowed to fail, so nothing above
                // this point insists on a reply. If nothing answered either,
                // the control channel is dead and the operator would not find
                // out until the first transmission failed to key. Say it now.
                if Self.civSilenceComplaint(identified: identified, statusAnswered: answered,
                                            address: config.civAddress,
                                            civStreamSilence: lanSession?.civStreamSilence,
                                            sourcePortMismatched: lanSession?.civSourcePortMismatched ?? false) != nil {
                    // Nothing has answered. Before blaming the address, ask
                    // the whole bus who is there: a radio on another address
                    // and a CI-V channel that is not there at all produce
                    // exactly the same silence, and want opposite fixes.
                    let answering = await rig.probeAddress()
                    if let complaint = Self.civSilenceComplaint(identified: identified, statusAnswered: answered,
                                                               address: config.civAddress,
                                                               answeringAddress: answering,
                                                               civStreamSilence: lanSession?.civStreamSilence,
                                                               sourcePortMismatched: lanSession?.civSourcePortMismatched ?? false) {
                        deliver { [weak self] in self?._delegate?.linkDidError(complaint) }
                    }
                }
                // The audio and polling start on the delivery (main) queue,
                // where close() flips `wantsOpen`. A close that raced this
                // open must win: without this guard a close during rig
                // bring-up returned, then this task resurrected the modem —
                // starting a fresh DSP thread and re-keying a radio the
                // operator had just released (the orphan `com.axterm.modem.dsp`
                // thread seen surviving quit).
                deliver { [weak self] in
                    guard let self else { return }
                    guard self.wantsOpen else {
                        self.civTransport?.close()
                        self.rig?.close()
                        self.lock.withLock { self.phase = .idle }
                        return
                    }
                    self.lock.withLock { self.phase = .modemOpen }
                    self.modem.open()
                    self.startPolling()
                    self.reconnectAttempt = 0   // rig up; failures start fresh
                    // Baseline the watch, so the first pass reports what
                    // changed rather than the state we connected to.
                    Task { [weak self] in
                        guard let self else { return }
                        self.lastAudit = await self.auditReceive().findings
                    }
                }
            } catch {
                let message = "Radio control failed: \((error as? CIVError)?.message ?? String(describing: error))"
                lock.withLock { phase = .failed(message) }
                civTransport.close()
                deliver { [weak self] in
                    self?._delegate?.linkDidError(message)
                    self?._delegate?.linkDidChangeState(.failed)
                    self?.scheduleReconnect()
                }
            }
        }
    }

    /// After a failed open, try again on a growing backoff — the radio's held
    /// slot frees within tens of seconds — until it connects, the attempt cap
    /// is hit, or `close()` says to stop. Called on the delivery (main) queue,
    /// which is the only place the reconnect bookkeeping is touched.
    private func scheduleReconnect() {
        guard wantsOpen, reconnectAttempt < Self.maxReconnectAttempts else { return }
        reconnectAttempt += 1
        let backoff = min(Self.baseReconnectDelay * pow(2, Double(reconnectAttempt - 1)),
                          Self.maxReconnectDelay)
        let delay = backoff + Double.random(in: 0...0.5)   // jitter
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.deliver { [weak self] in
                guard let self, self.wantsOpen, self.state == .failed else { return }
                self.open()
            }
        }
    }

    /// The modem stops first (it asks for PTT off), then the radio is told
    /// PTT off once more on the still-open port, and only then does the
    /// port close. A close that raced the unkey would leave the radio
    /// transmitting; this order cannot.
    func close() {
        wantsOpen = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        pollTask?.cancel()
        pollTask = nil
        modem.close()
        lock.withLock { phase = .idle }
        guard let rig else { return }
        let ptt = pttController
        let method = config.pttMethod
        closeTask = Task {
            switch method {
            case .civ:
                if rig.isOpen { try? await rig.setPTT(false) }
            case .rts, .dtr:
                ptt.setTransmit(false) { _ in }
            case .none:
                break
            }
            rig.close()
        }
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        modem.send(data, completion: completion)
    }

    // MARK: - Settings while running

    /// Levels and timing apply in place; anything about the devices, the
    /// mode, the port or the keying rebuilds the link.
    func updateConfig(_ new: ModemLinkConfig) {
        let old = config
        guard new != old else { return }
        config = new
        if new.requiresReopen(from: old) {
            let wasOpen = state == .connected || state == .connecting
            close()
            if new.rigLink == .lan {
                let session = makeSession(new.lanConfiguration)
                lanSession = session
                lanAudio?.session = session
            } else {
                lanSession = nil
            }
            let rigParts = Self.makeRig(new, makeTransport: makeTransport, session: lanSession)
            civTransport = rigParts.transport
            rig = rigParts.client
            pttController = rigParts.ptt
            attachRig()
            modem.replacePTT(rigParts.ptt)
            modem.update(configuration: new.softModemConfiguration)
            if wasOpen { open() }
        } else {
            modem.update(configuration: new.softModemConfiguration)
        }
    }

    /// A steady mark tone through the normal PTT path, for the operator to
    /// set drive level against the radio's ALC.
    func sendTestTone(seconds: Double) throws { try modem.sendTestTone(seconds: seconds) }

    /// Ask the radio on the open CI-V port what it is and where it is.
    /// "IC-705 (A4) · 144.390 MHz FM-D".
    func identifyRadio() async throws -> String {
        guard let rig, rig.isOpen else { throw CIVError.notOpen }
        let address = try await rig.identify()
        rigModel = CIVKnownRadios.model(forAddress: address) ?? String(format: "Icom %02X", address)
        await refreshRigStatus()
        return Self.describe(address: address, status: rigStatus)
    }

    /// The same question on a port nobody has open yet: a throwaway client
    /// that opens, asks and closes. For the form before the radio connects.
    static func identifyRadio(config: ModemLinkConfig,
                              makeTransport: (String) -> CIVTransport = ModemRadioLink.defaultSerialTransport) async throws -> String {
        guard config.usesRig else { throw CIVError.transport("no CI-V port chosen") }
        let transport: CIVTransport = config.rigLink == .lan
            ? LANCIVTransport(session: IcomLANSession(configuration: config.lanConfiguration))
            : makeTransport(config.civSerialPath)
        let client = CIVClient(transport: transport, radioAddress: config.civAddress,
                               controllerAddress: config.effectiveCIVControllerAddress)
        client.open()
        defer { client.close() }
        // The WLAN login takes a moment; the serial port is open at once.
        var waited = 0
        while transport.state == .opening, waited < 400 {
            try await Task.sleep(for: .milliseconds(25))
            waited += 1
        }
        if case .failed(let reason) = transport.state { throw CIVError.transport(reason) }
        let address = try await client.identify()
        // Identifying a radio is a read. It does not get to change its menus.
        if config.rigLink != .lan { try? await client.setTransceive(false) }
        var status = RigStatus()
        if let hz = try? await client.readFrequency() { status.frequencyHz = hz }
        if let mode = try? await client.readMode() { status.mode = mode.mode; status.filter = mode.filter }
        if let data = try? await client.readDataMode() { status.dataMode = data }
        return describe(address: address, status: status)
    }

    private static func describe(address: UInt8, status: RigStatus) -> String {
        var parts = [CIVKnownRadios.describe(address)]
        if let frequency = status.frequencyLabel {
            parts.append(status.modeLabel.map { "\(frequency) \($0)" } ?? frequency)
        }
        return parts.joined(separator: " \u{b7} ")
    }

    /// The one-shot: put the radio in the right mode for this modem.
    func configureRadioForPacket() async throws {
        guard let rig else { throw CIVError.notOpen }
        try await rig.configureForPacket(config.mode, dataMod: config.rigLink == .lan ? .wlan : .usb)
        await refreshRigStatus()
    }

    // MARK: - Rig status

    /// - Returns: whether the radio answered any of the three reads. A
    ///   caller bringing the link up uses that to tell a working CI-V port
    ///   from a silent one, because the reads themselves are best-effort.
    @discardableResult
    private func refreshRigStatus() async -> Bool {
        guard let rig else { return false }
        var status = rigStatus
        var answered = false
        if let hz = try? await rig.readFrequency() { status.frequencyHz = hz; answered = true }
        if let mode = try? await rig.readMode() { status.mode = mode.mode; status.filter = mode.filter; answered = true }
        if let data = try? await rig.readDataMode() { status.dataMode = data; answered = true }
        status.ptt = modem.telemetry.ptt
        status.updatedAt = Date()
        lock.withLock { _rigStatus = status }
        onRigStatus?(status)
        return answered
    }

    /// Ask the radio why it might not be hearing anybody.
    ///
    /// Reads the receive path's settings over CI-V and judges them
    /// (`RigReceiveAudit`). An attenuator left on, RF gain backed off or a
    /// narrow FM filter each cost exactly the margin a distant station needs,
    /// and each is invisible from the Mac until the radio is asked.
    ///
    /// Read-only: nothing here changes a setting. What to do about a finding
    /// is the operator's call, on their radio.
    func auditReceive() async -> RigReceiveAudit.Result {
        guard let rig else {
            return .unavailable("this radio has no CI-V link, so it can only be asked by hand.")
        }
        guard rig.isOpen else {
            return .unavailable("the CI-V link is not open.")
        }
        let status = rigStatus
        // Every read is best-effort, so a radio that answers none of them
        // still returns an empty finding list. That would read as "nothing is
        // wrong", which is the one thing it must not say — so the reads are
        // required to have produced at least one answer.
        let settings = await rig.readReceiveSettings(mode: status.mode ?? .fm,
                                                     filter: Int(status.filter ?? 1),
                                                     dataMode: status.dataMode ?? true)
        guard settings.answered else {
            return .unavailable("the radio did not answer any of them.")
        }
        return .checked(RigReceiveAudit.findings(settings))
    }

    /// Make the corrections the audit asked for, and report what changed.
    ///
    /// Only settings whose right value for packet is a fact: the attenuator,
    /// RF gain, squelch, the noise processing and the FM filter. The mode and
    /// the preamp are named by the audit and deliberately left alone — the
    /// operator may be in USB on purpose, and whether a preamp helps is a
    /// judgement about the band.
    func applyReceiveCorrections(_ findings: [RigReceiveAudit.Finding]) async -> [String] {
        guard let rig, rig.isOpen else { return [] }
        let mode = rigStatus.mode ?? .fm
        var done: [String] = []
        for finding in findings {
            guard let correction = finding.correction else { continue }
            do {
                try await rig.apply(correction, mode: mode)
                done.append(finding.title)
            } catch {
                done.append("\(finding.title) — the radio refused")
            }
        }
        if !done.isEmpty { _ = await refreshRigStatus() }
        return done
    }

    /// What the level loop concluded.
    enum LevelOutcome: Equatable, Sendable {
        /// The peak is inside the window; nothing to do.
        case alreadyRight(peakDBFS: Float)
        case adjusted(from: Int, to: Int, peakDBFS: Float)
        /// The level moved a long way and the audio did not follow, so this is
        /// not the control that feeds the modem.
        case controlDoesNothing
        /// Nothing was being received, so there was nothing to measure.
        case nothingHeard
        case unavailable(String)
    }

    /// Drive the radio's audio output until the modem sees a usable peak.
    ///
    /// The demodulator is level-independent between the rails, so this is not
    /// chasing a number — it is keeping the audio off both of them. It also
    /// checks its own actuator: the IC-705's WLAN audio does not necessarily
    /// follow the same control as its USB audio, and a loop that turns a knob
    /// connected to nothing while reporting success would be worse than not
    /// having one.
    func calibrateReceiveLevel(passes: Int = 6,
                               settle: @Sendable () async -> Void = {
                                   try? await Task.sleep(for: .seconds(3))
                               }) async -> LevelOutcome {
        guard let rig, rig.isOpen else { return .unavailable("The radio's CI-V link is not open.") }
        guard var level = try? await rig.readAFOutputLevel() else {
            return .unavailable("The radio would not report its audio output level.")
        }
        let startedAt = level
        var startPeak: Float?

        for _ in 0..<passes {
            await settle()
            let peak = modem.telemetry.rxPeakDBFS
            guard peak > RigAudioLevel.silenceDBFS else { return .nothingHeard }
            if startPeak == nil { startPeak = peak }
            guard let next = RigAudioLevel.adjust(current: level, peakDBFS: peak) else {
                return level == startedAt ? .alreadyRight(peakDBFS: peak)
                                          : .adjusted(from: startedAt, to: level, peakDBFS: peak)
            }
            guard (try? await rig.setAFOutputLevel(next)) != nil else {
                return .unavailable("The radio refused to set its audio output level.")
            }
            level = next
            if let first = startPeak,
               RigAudioLevel.actuatorIsDead(levelChange: level - startedAt,
                                            peakChangeDB: modem.telemetry.rxPeakDBFS - first) {
                _ = try? await rig.setAFOutputLevel(startedAt)
                return .controlDoesNothing
            }
        }
        return .adjusted(from: startedAt, to: level, peakDBFS: modem.telemetry.rxPeakDBFS)
    }

    /// Every five seconds while the modem is idle; once only when the
    /// operator does not want the frequency followed.
    private func startPolling() {
        pollTask?.cancel()
        guard config.followsRadioFrequency else { return }
        pollTask = Task { [weak self] in
            var sinceAudit = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if self.modem.telemetry.ptt { continue }
                await self.refreshRigStatus()
                // The receive audit is six CI-V reads, so it runs on its own
                // slower beat — often enough to catch a setting changed by
                // hand, rarely enough not to sit on the bus.
                sinceAudit += 1
                if sinceAudit >= 24 {
                    sinceAudit = 0
                    await self.watchForReceiveDrift()
                }
            }
        }
    }

    /// Re-audit, and report only what is newly wrong.
    private func watchForReceiveDrift() async {
        let result = await auditReceive()
        guard case .checked(let now) = result else { return }
        let new = RigReceiveAudit.newFindings(from: lastAudit, to: now)
        lastAudit = now
        guard !new.isEmpty else { return }
        let notice = "The radio changed under us: "
            + new.map { $0.title.lowercased() }.joined(separator: ", ") + "."
        deliver { [weak self] in self?._delegate?.linkDidError(notice) }
        onReceiveDrift?(new)
    }
}

/// A transport for a port this platform cannot open: it fails with the
/// reason, so the radio's status says why instead of hanging.
nonisolated final class UnavailableCIVTransport: CIVTransport, @unchecked Sendable {
    let reason: String
    private(set) var state: CIVTransportState = .closed
    var onBytes: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (CIVTransportState) -> Void)?
    init(reason: String) { self.reason = reason }
    func open() { state = .failed(reason); onStateChange?(state) }
    func close() { state = .closed; onStateChange?(state) }
    func write(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) { completion(CIVTransportError.notOpen) }
    func setModemLines(dtr: Bool?, rts: Bool?) {}
}
