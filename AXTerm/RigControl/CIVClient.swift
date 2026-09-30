import Foundation

nonisolated enum CIVError: Error, Equatable, Sendable {
    case notOpen
    case timeout(command: UInt8)
    case rejected(command: UInt8)
    case unexpectedResponse(command: UInt8)
    case wrongRadio(found: UInt8, expected: UInt8)
    case transport(String)

    var message: String {
        switch self {
        case .notOpen: return "the CI-V port is not open"
        case .timeout(let c): return String(format: "the radio did not answer command %02X", c)
        case .rejected(let c): return String(format: "the radio rejected command %02X", c)
        case .unexpectedResponse(let c): return String(format: "unexpected reply to command %02X", c)
        case .wrongRadio(let found, let expected):
            return "found \(CIVKnownRadios.describe(found)) on this port, expected \(CIVKnownRadios.describe(expected))"
        case .transport(let detail): return detail
        }
    }
}

/// Talks CI-V to one radio over any `CIVTransport`.
///
/// Requests go out one at a time, because a reply of `OK`/`NG` carries no
/// command byte and can only be matched by order. Each request has a
/// timeout; unsolicited frames (transceive broadcasts, if the radio still
/// sends them) go to `onUnsolicited`; echoes of our own frames are dropped.
nonisolated final class CIVClient: @unchecked Sendable {

    let radioAddress: UInt8
    let controllerAddress: UInt8
    let requestTimeout: TimeInterval
    let transport: CIVTransport

    var onUnsolicited: (@Sendable (CIVFrame) -> Void)?
    var onTransportState: (@Sendable (CIVTransportState) -> Void)?
    /// The port died under us. Separate from `onTransportState`, which the
    /// PTT controller owns: the link needs the same news and there is only
    /// one of that hook.
    var onTransportFailure: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "com.axterm.civ.client")
    private var parser = CIVFrameParser()
    private var pending: [Request] = []
    private var inFlight: Request?

    // Evidence for the one failure this class cannot currently explain: the
    // port opens, every command times out, and the operator is told the radio
    // "has not answered any CI-V command". That sentence is a guess. These
    // counters make it a measurement — silence and a rejected-by-address
    // answer look identical from outside, and they need opposite fixes.
    private var bytesIn = 0
    private var framesIn = 0
    private var framesDropped = 0
    /// Polls that have gone unanswered in a row.
    ///
    /// The second, independent signal that a radio has stopped serving us. On
    /// 2026-09-18 the radio answered no CI-V command for four and a half
    /// hours, 12,624 of them, while every stream stayed punctual with
    /// keepalives and the link reported healthy. One timeout is ordinary; a
    /// run of them is the radio, and nothing was counting the run.
    private var consecutiveTimeouts = 0

    /// How many unanswered polls in a row mean the radio has stopped
    /// answering. At roughly one poll per second a run of eight is about ten
    /// seconds of being ignored, which is far outside anything a busy radio
    /// does and far inside four hours.
    static let unansweredPollLimit = 8

    /// Called when the radio stops answering altogether. Set by the session,
    /// which owns what to do about it.
    var onUnresponsive: ((String) -> Void)?
    private var reportedFirstBytes = false
    private var droppedReports = 0

    private enum Expectation {
        /// A set: `FB` or `FA`.
        case acknowledgement
        /// A read: a frame echoing this command (and subcommand).
        case reply(command: UInt8, subcommand: UInt8?)
    }

    private final class Request {
        let frame: CIVFrame
        let expectation: Expectation
        let continuation: CheckedContinuation<CIVFrame, Error>
        /// A probe asks the whole bus, so it is the one request an address we
        /// were not addressing is allowed to answer.
        let acceptsAnyRadio: Bool
        var timeout: DispatchWorkItem?
        init(frame: CIVFrame, expectation: Expectation, acceptsAnyRadio: Bool = false,
             continuation: CheckedContinuation<CIVFrame, Error>) {
            self.frame = frame
            self.expectation = expectation
            self.acceptsAnyRadio = acceptsAnyRadio
            self.continuation = continuation
        }
    }

    init(transport: CIVTransport, radioAddress: UInt8 = CIVCommand.ic705,
         controllerAddress: UInt8 = CIVFrame.controller, requestTimeout: TimeInterval = 0.5) {
        self.transport = transport
        self.radioAddress = radioAddress
        self.controllerAddress = controllerAddress
        self.requestTimeout = requestTimeout
        transport.onBytes = { [weak self] data in self?.queue.async { self?.received(data) } }
        transport.onStateChange = { [weak self] state in
            self?.queue.async { self?.transportChanged(state) }
        }
    }

    var isOpen: Bool { transport.state == .open }

    func open() { transport.open() }

    func close() {
        transport.close()
        queue.async { self.failAll(CIVError.notOpen) }
    }

    // MARK: - Typed commands

    /// The radio's CI-V address, which must be the one configured.
    func identify() async throws -> UInt8 {
        let reply = try await request(CIVCommand.identify(radio: radioAddress, controller: controllerAddress),
                                      expecting: .reply(command: 0x19, subcommand: 0x00))
        guard let found = reply.data.first else { throw CIVError.unexpectedResponse(command: 0x19) }
        guard found == radioAddress else { throw CIVError.wrongRadio(found: found, expected: radioAddress) }
        return found
    }

    /// Ask every address on the bus who is there, and report whoever answers.
    ///
    /// A CI-V radio answers a frame addressed to `00`, replying from its own
    /// address. That one broadcast separates the two faults that are
    /// indistinguishable from outside once `identify` has timed out: a radio
    /// set to an address this modem is not asking for (it answers, from some
    /// other address) and a CI-V channel that is switched off or not reaching
    /// the radio at all (nothing answers). They need opposite fixes, and
    /// until now the operator was told to go and check both.
    ///
    /// Returns the address that answered, or `nil` on silence.
    func probeAddress() async -> UInt8? {
        let frame = CIVCommand.identify(radio: CIVFrame.broadcast, controller: controllerAddress)
        let reply = try? await request(frame, expecting: .reply(command: 0x19, subcommand: 0x00),
                                       acceptingAnyRadio: true)
        // The header's `from` is the address the bus actually routes on; the
        // payload repeats it, and a radio that disagrees with itself is not
        // worth trusting over the envelope it sent.
        return reply?.from
    }

    func setPTT(_ on: Bool) async throws {
        _ = try await request(CIVCommand.setPTT(on, radio: radioAddress, controller: controllerAddress), expecting: .acknowledgement)
    }

    /// Ask the radio to stop (or start) pouring spectrum-scope waveform data
    /// onto the CI-V stream. On Wi-Fi this flood is what makes CI-V unusable,
    /// so the modem turns it off at connect. The write reaches the radio even
    /// while the parser is swamped, so an ack we may never cleanly read does
    /// not matter — callers treat it as best-effort.
    func setScopeDataOutput(_ on: Bool) async throws {
        _ = try await request(CIVCommand.setScopeDataOutput(on, radio: radioAddress, controller: controllerAddress),
                              expecting: .acknowledgement)
    }

    func readPTT() async throws -> Bool {
        let reply = try await request(CIVCommand.readPTT(radio: radioAddress, controller: controllerAddress),
                                      expecting: .reply(command: 0x1C, subcommand: 0x00))
        return reply.data.first == 0x01
    }

    /// Everything about the receive path the radio will tell us.
    ///
    /// Each read is independent and best-effort: a radio that does not answer
    /// one subcommand should still be judged on the rest, and an audit that
    /// throws away nine good answers because of a tenth helps nobody. What
    /// could not be read keeps its benign default, so the audit never invents
    /// a fault out of a missing reply.
    /// - Parameter toneSquelchFunction: whether this radio's tone squelch
    ///   function is confirmed at `16 5D` (the IC-705). Elsewhere it is not
    ///   asked, and stays off.
    func readReceiveSettings(mode: RigMode, filter: Int, dataMode: Bool,
                             toneSquelchFunction: Bool = false) async -> RigReceiveAudit.Settings {
        // Two unanswered reads in a row and the rest are not asked. With
        // nine reads now, a radio that has stopped answering would otherwise
        // hold the bus for nine timeouts every two minutes, and a keyed
        // transmission waits behind them. A radio lacking one setting answers
        // NG at once, so this never costs an answer from one that is there.
        var unanswered = 0
        func reply(_ frame: CIVFrame, _ command: UInt8, _ sub: UInt8?) async -> CIVFrame? {
            guard unanswered < 2 else { return nil }
            do {
                let answer = try await request(frame, expecting: .reply(command: command, subcommand: sub))
                unanswered = 0
                return answer
            } catch CIVError.timeout {
                unanswered += 1
                return nil
            } catch {
                unanswered = 0
                return nil
            }
        }
        func byte(_ frame: CIVFrame, _ command: UInt8, _ sub: UInt8?) async -> UInt8? {
            await reply(frame, command, sub)?.data.first
        }
        func level(_ frame: CIVFrame, _ command: UInt8, _ sub: UInt8?) async -> Int? {
            guard let d = await reply(frame, command, sub)?.data, let value = CIVBCD.meter(d) else { return nil }
            return Int((Double(value) / 255 * 100).rounded())
        }
        let r = radioAddress, c = controllerAddress
        // BCD, so 0x10 reads as 10 dB rather than 16.
        let attenuator = await byte(CIVCommand.readAttenuator(radio: r, controller: c), 0x11, nil)
        let preamp = await byte(CIVCommand.readPreamp(radio: r, controller: c), 0x16, 0x02)
        let nb = await byte(CIVCommand.readNoiseBlanker(radio: r, controller: c), 0x16, 0x22)
        let nr = await byte(CIVCommand.readNoiseReduction(radio: r, controller: c), 0x16, 0x40)
        let rfGain = await level(CIVCommand.readRFGain(radio: r, controller: c), 0x14, 0x02)
        let squelch = await level(CIVCommand.readSquelchLevel(radio: r, controller: c), 0x14, 0x03)
        let anf = await byte(CIVCommand.readAutoNotch(radio: r, controller: c), 0x16, 0x41)
        let notch = await byte(CIVCommand.readManualNotch(radio: r, controller: c), 0x16, 0x48)
        var tone: UInt8?
        if toneSquelchFunction {
            tone = await byte(CIVCommand.readToneSquelchFunction(radio: r, controller: c), 0x16, 0x5D)
        }
        let anyAnswer = attenuator != nil || preamp != nil || nb != nil
            || nr != nil || rfGain != nil || squelch != nil || anf != nil || notch != nil || tone != nil
        return RigReceiveAudit.Settings(
            attenuatorDB: attenuator.map { Int($0 >> 4) * 10 + Int($0 & 0x0F) } ?? 0,
            preamp: Int(preamp ?? 1),
            noiseBlanker: nb == 0x01,
            noiseReduction: nr == 0x01,
            rfGainPercent: rfGain ?? 100,
            squelchPercent: squelch ?? 0,
            mode: mode, filter: filter, dataMode: dataMode,
            autoNotch: anf == 0x01,
            manualNotch: notch == 0x01,
            // A value outside the guide's list is not a setting this can
            // judge, so it reads as off rather than as a guess.
            toneSquelch: tone.flatMap(RigReceiveAudit.ToneSquelchFunction.init(rawValue:)) ?? .off,
            answered: anyAnswer)
    }

    /// Make one correction the audit asked for, and say what changed.
    ///
    /// Each is a setting whose right value for packet is a fact rather than
    /// a preference (see `RigReceiveAudit.Correction`). The setting is read
    /// first, so the change can be recorded and put back later. The entry is
    /// nil when nothing needed changing, or when the radio would not say what
    /// it held and the change was made blind.
    func applyCorrection(_ correction: RigReceiveAudit.Correction,
                         mode fallbackMode: RigMode) async throws -> RigPrepSnapshot.Entry? {
        let setting = RigPrep.setting(for: correction)
        if let current = await readPrepValue(setting) {
            guard let target = RigPrep.target(for: correction, current: current), target != current else { return nil }
            try await writePrepValue(setting, target)
            return RigPrepSnapshot.Entry(setting: setting, original: current, applied: target)
        }
        // The radio would not report the setting. Make the change the way
        // this always did, without a record: a correction the operator asked
        // for should not fail because a read timed out.
        let r = radioAddress, c = controllerAddress
        let command: CIVFrame
        switch correction {
        case .attenuatorOff:     command = CIVCommand.setAttenuatorOff(radio: r, controller: c)
        case .rfGainFull:        command = CIVCommand.setRFGain(255, radio: r, controller: c)
        case .squelchOpen:       command = CIVCommand.setSquelchLevel(0, radio: r, controller: c)
        case .noiseReductionOff: command = CIVCommand.setNoiseReduction(false, radio: r, controller: c)
        case .noiseBlankerOff:   command = CIVCommand.setNoiseBlanker(false, radio: r, controller: c)
        case .widestFilter:      command = CIVCommand.setMode(fallbackMode, filter: 1, radio: r, controller: c)
        case .autoNotchOff:      command = CIVCommand.setAutoNotch(false, radio: r, controller: c)
        case .manualNotchOff:    command = CIVCommand.setManualNotch(false, radio: r, controller: c)
        case .toneSquelchReceiveOff:
            // Which value keeps the transmit tone depends on what is set now,
            // and that is exactly what the radio would not say.
            throw CIVError.unexpectedResponse(command: 0x16)
        }
        _ = try await request(command, expecting: .acknowledgement)
        return nil
    }

    // MARK: - Settings as raw values (prepare and restore)

    /// What the radio holds for one setting, as raw CI-V data; nil when it
    /// did not answer, refused, or answered with something malformed.
    func readPrepValue(_ setting: RigPrepSetting) async -> [UInt8]? {
        await readPrepValueNoting(setting).value
    }

    /// `readPrepValue`, and whether the radio simply did not answer, which
    /// is different from refusing: a radio that lacks a setting says NG at
    /// once, while one that is not answering costs a full timeout per read.
    private func readPrepValueNoting(_ setting: RigPrepSetting) async -> (value: [UInt8]?, unanswered: Bool) {
        var replies: [CIVFrame] = []
        for frame in setting.readFrames(radio: radioAddress, controller: controllerAddress) {
            do {
                replies.append(try await request(
                    frame, expecting: .reply(command: frame.command, subcommand: frame.subcommand)))
            } catch CIVError.timeout {
                return (nil, true)
            } catch {
                return (nil, false)
            }
        }
        return (setting.decode(replies), false)
    }

    /// Put a raw value on the radio. Every frame must be acknowledged.
    func writePrepValue(_ setting: RigPrepSetting, _ value: [UInt8]) async throws {
        let frames = setting.writeFrames(value, radio: radioAddress, controller: controllerAddress)
        guard !frames.isEmpty else {
            throw CIVError.transport("refused to send a malformed value for \(setting.label)")
        }
        for frame in frames {
            _ = try await request(frame, expecting: .acknowledgement)
        }
    }

    /// Put back what the snapshot says AXTerm changed.
    ///
    /// Reads every setting, plans (`RigPrepRestore.plan`), then writes the
    /// originals in reverse order. Stops where `deadline` passes, so a quit
    /// is never held up by a radio that has stopped answering; anything not
    /// reached is reported as not attempted and stays owed.
    func restore(_ snapshot: RigPrepSnapshot, deadline: Date) async -> RigPrepRestore.Outcome {
        var outcome = RigPrepRestore.Outcome()
        var current: [RigPrepSetting: [UInt8]] = [:]
        var reached = RigPrepSnapshot()
        for entry in snapshot.entries {
            guard Date() < deadline else { break }
            if let value = await readPrepValue(entry.setting) { current[entry.setting] = value }
            reached.record(entry)
        }
        let plan = RigPrepRestore.plan(reached, current: current)
        outcome.changedByOperator = plan.changedByOperator
        outcome.alreadyBack = plan.alreadyBack
        for entry in plan.writes {
            guard Date() < deadline else {
                outcome.notAttempted.append(entry)
                continue
            }
            do {
                try await writePrepValue(entry.setting, entry.original)
                outcome.restored.append(entry)
            } catch {
                outcome.failed.append(entry)
            }
        }
        // Never read before time ran out, so never planned: still owed.
        let planned = Set(reached.settings)
        outcome.notAttempted += snapshot.entries.reversed().filter { !planned.contains($0.setting) }
        return outcome
    }

    /// The radio's audio output level, 0-255, as CI-V reports it.
    func readAFOutputLevel() async throws -> Int {
        let reply = try await request(
            CIVCommand.readMenuItem(.usbAFOutputLevel, radio: radioAddress, controller: controllerAddress),
            expecting: .reply(command: 0x1A, subcommand: 0x05))
        // The reply echoes the item number before the value.
        guard let value = CIVBCD.meter(Array(reply.data.dropFirst(2))) else {
            throw CIVError.unexpectedResponse(command: 0x1A)
        }
        return value
    }

    func setAFOutputLevel(_ value: Int) async throws {
        _ = try await request(
            CIVCommand.setAFOutputLevel(value, radio: radioAddress, controller: controllerAddress),
            expecting: .acknowledgement)
    }

    func readFrequency() async throws -> Int {
        let reply = try await request(CIVCommand.readFrequency(radio: radioAddress, controller: controllerAddress),
                                      expecting: .reply(command: 0x03, subcommand: nil))
        guard let hz = CIVBCD.frequencyHz(reply.data) else { throw CIVError.unexpectedResponse(command: 0x03) }
        return hz
    }

    func setFrequency(_ hz: Int) async throws {
        _ = try await request(CIVCommand.setFrequency(hz: hz, radio: radioAddress, controller: controllerAddress), expecting: .acknowledgement)
    }

    func readMode() async throws -> (mode: RigMode, filter: UInt8) {
        let reply = try await request(CIVCommand.readMode(radio: radioAddress, controller: controllerAddress),
                                      expecting: .reply(command: 0x04, subcommand: nil))
        guard let raw = reply.data.first, let mode = RigMode(rawValue: raw) else { throw CIVError.unexpectedResponse(command: 0x04) }
        return (mode, reply.data.count > 1 ? reply.data[1] : 1)
    }

    func setMode(_ mode: RigMode, filter: UInt8? = nil) async throws {
        _ = try await request(CIVCommand.setMode(mode, filter: filter, radio: radioAddress, controller: controllerAddress),
                              expecting: .acknowledgement)
    }

    func readDataMode() async throws -> Bool {
        let reply = try await request(CIVCommand.readDataMode(radio: radioAddress, controller: controllerAddress),
                                      expecting: .reply(command: 0x1A, subcommand: 0x06))
        return reply.data.first == 0x01
    }

    func setDataMode(_ on: Bool, filter: UInt8 = 1) async throws {
        _ = try await request(CIVCommand.setDataMode(on, filter: filter, radio: radioAddress, controller: controllerAddress),
                              expecting: .acknowledgement)
    }

    /// Turn data mode on, and check the radio took it.
    ///
    /// `setMode` clears the data flag on an Icom, so this has to follow it.
    /// Of everything `configureForPacket` writes, this is the one whose
    /// failure is silent. With `DATA MOD` set to WLAN or USB the radio
    /// modulates from that input **only in data mode**; in plain FM it
    /// modulates from the microphone. So a dropped `1A 06` leaves a radio that
    /// keys on command, unkeys on command, receives perfectly, and puts
    /// nothing on the air — and nothing complains, because receive never
    /// needed the setting. `RigReceiveAudit` carries `dataMode` and has never
    /// had a finding for it for exactly that reason (2026-09-18: an IC-705 on
    /// WLAN keying and unkeying correctly with a silent transmitter).
    ///
    /// One retry before giving up: a single unanswered command on a flaky CI-V
    /// link is worth trying again before telling the operator anything.
    /// A radio that does not answer the readback has told us nothing, and is
    /// not blamed for it: only a radio that answers "off" has actually said
    /// the setting did not take. Otherwise a rig with a flaky read would be
    /// reported as a silent transmitter on every connect.
    func setDataModeChecked(filter: UInt8 = 1) async throws {
        var writeFailure: Error?
        do { try await setDataMode(true, filter: filter) } catch { writeFailure = error }

        switch try? await readDataMode() {
        case .some(true):
            return
        case .none:
            // No evidence either way. Fall back to whether the write itself
            // was acknowledged, which is what this did before it checked.
            if let writeFailure { throw writeFailure }
        case .some(false):
            try await setDataMode(true, filter: filter)
            if (try? await readDataMode()) == false { throw CIVError.rejected(command: 0x1A) }
        }
    }

    func setTransceive(_ on: Bool) async throws {
        _ = try await request(CIVCommand.setTransceive(on, radio: radioAddress, controller: controllerAddress), expecting: .acknowledgement)
    }

    func readSquelchOpen() async throws -> Bool {
        let reply = try await request(CIVCommand.readSquelchStatus(radio: radioAddress, controller: controllerAddress),
                                      expecting: .reply(command: 0x15, subcommand: 0x01))
        return reply.data.first == 0x01
    }

    func readSMeter() async throws -> Int {
        let reply = try await request(CIVCommand.readSMeter(radio: radioAddress, controller: controllerAddress),
                                      expecting: .reply(command: 0x15, subcommand: 0x02))
        guard let value = CIVBCD.meter(reply.data) else { throw CIVError.unexpectedResponse(command: 0x15) }
        return value
    }

    func setMenuItem(_ item: CIVCommand.MenuItem, _ data: [UInt8]) async throws {
        _ = try await request(CIVCommand.setMenuItem(item, data, radio: radioAddress, controller: controllerAddress),
                              expecting: .acknowledgement)
    }

    /// Everything the radio needs to carry packet from this modem, in one
    /// go: the mode with data on, modulation from USB, the AF squelch open
    /// so the modem hears everything, USB SEND off (PTT is a command), CI-V
    /// transceive off (a clean bus), the radio's own TX delays off.
    /// Where the radio takes its DATA-mode modulation from. Over USB the
    /// audio arrives on the USB codec (0x01); over the LAN/RS-BA1 network
    /// link it arrives on the WLAN codec (0x03), and picking the wrong one
    /// keys an unmodulated carrier — a bare CW line on the waterfall —
    /// because the modulator listens to a dead input.
    ///
    /// Values from the IC-705 CI-V Reference Guide, set-mode item 0119
    /// ("MOD Input > DATA MOD"): `00=MIC, 01=USB, 02=MIC, USB, 03=WLAN`.
    ///
    /// `wlan` was 0x02 until 2026-09-17, which is the radio's "MIC, USB" —
    /// so connecting over Wi-Fi told the radio to take modulation from the
    /// microphone and the USB port, neither of which carries the packet
    /// audio arriving over the network. The radio keyed and sent the room.
    /// Exactly the failure the note above describes, caused from here.
    enum DataModSource: UInt8 {
        case mic = 0x00
        case usb = 0x01
        case micAndUSB = 0x02
        case wlan = 0x03
    }

    /// What preparing the radio did: the changes in the operator's words,
    /// the record of each one for putting it back, and the error that
    /// stopped it, if one did. A failure part-way still reports what was
    /// already changed, because those changes are still owed back.
    struct PrepReport: Sendable {
        var changed: [String] = []
        var entries: [RigPrepSnapshot.Entry] = []
        var failure: CIVError?
    }

    /// - Parameter quietTheBus: whether to switch CI-V Transceive off.
    ///   Worth it on a shared serial bus, where the radio's unsolicited
    ///   broadcasts collide with replies. Over the network there is no bus —
    ///   the session is point to point — and the setting is persistent, so
    ///   leaving it off is a change to the operator's radio that outlives
    ///   AXTerm (2026-09-17).
    /// Returns the settings this actually changed, so the operator can be
    /// told rather than having their radio quietly rewritten.
    @discardableResult
    func configureForPacket(_ mode: ModemMode, dataMod: DataModSource = .usb,
                            quietTheBus: Bool = true) async throws -> [String] {
        let report = await prepareForPacket(mode, dataMod: dataMod, quietTheBus: quietTheBus)
        if let failure = report.failure { throw failure }
        return report.changed
    }

    /// `configureForPacket`, recording the original of every setting it
    /// writes, and optionally clearing the receive settings whose right
    /// value for packet is a fact.
    ///
    /// - Parameter clearsReceive: also turn the attenuator, NR, NB and both
    ///   notches off, RF gain full, squelch open, and (where confirmed) the
    ///   receive tone squelch off. Each is read first and written only when
    ///   wrong; one the radio will not report is left alone, because a change
    ///   whose original is unknown is a change that cannot be put back.
    func prepareForPacket(_ mode: ModemMode, dataMod: DataModSource = .usb,
                          quietTheBus: Bool = true, clearsReceive: Bool = false,
                          toneSquelchFunction: Bool = false) async -> PrepReport {
        var report = PrepReport()
        // Cleared the first time a read goes unanswered; see setMenuItemIfNeeded.
        var readable = true
        let r = radioAddress, c = controllerAddress

        // Read before writing. This used to write all ten settings at every
        // connect, which meant reconnecting — after a sleep, a dropped link, a
        // rebuild — silently rewrote the operator's radio each time, including
        // settings that were already right. Somebody who sets a filter or a
        // sideband by hand between overs had it taken back without being told.
        // Now only what is actually wrong is written, and the caller is told
        // what changed.
        let modeReply = try? await request(CIVCommand.readMode(radio: r, controller: c),
                                           expecting: .reply(command: 0x04, subcommand: nil))
        let current: (mode: RigMode, filter: UInt8)? = modeReply.flatMap { reply in
            guard let raw = reply.data.first, let m = RigMode(rawValue: raw) else { return nil }
            return (m, reply.data.count > 1 ? reply.data[1] : 1)
        }
        if current == nil { readable = false }
        // Data mode is read before the mode is set, because setting the mode
        // clears it: read afterwards it says nothing about what the operator
        // had.
        let dataReply = try? await request(CIVCommand.readDataMode(radio: r, controller: c),
                                           expecting: .reply(command: 0x1A, subcommand: 0x06))
        let modeBefore: [UInt8]? = {
            guard let modeReply, let dataReply else { return nil }
            return RigPrepSetting.mode.decode([modeReply, dataReply])
        }()
        let dataWasOn = dataReply?.data.first == 0x01
        let expected = mode.expectedRigMode
        let modeApplied: [UInt8] = [expected.rawValue, 0x01, 0x01, 0x01]
        func noteMode(_ applied: [UInt8]) {
            if let modeBefore, modeBefore != applied {
                report.entries.append(.init(setting: .mode, original: modeBefore, applied: applied))
            }
        }

        do {
            if current?.mode != expected || current?.filter != 1 {
                try await setMode(expected, filter: 1)
                let was = current.map { "\($0.mode.label) to " } ?? ""
                report.changed.append("mode \(was)\(expected.label), widest filter")
            }
            // Not conditional, and deliberately. `setMode` clears the data
            // flag on an Icom, so this has to follow it whether or not the
            // mode changed, and a radio that silently lost data mode is the
            // one failure here that is invisible on receive and fatal on
            // transmit.
            do {
                try await setDataModeChecked(filter: 1)
            } catch {
                // The mode may have moved already; record where it landed so
                // it can still be put back.
                noteMode(await readPrepValue(.mode) ?? [expected.rawValue, 0x01, 0x00, 0x00])
                throw error
            }
            if !dataWasOn { report.changed.append("data mode on") }
            noteMode(modeApplied)

            func menu(_ item: CIVCommand.MenuItem, _ data: [UInt8], _ description: String) async throws -> Bool {
                let result = try await setMenuItemIfNeeded(item, data, readable: &readable)
                guard result.wrote else { return false }
                report.changed.append(description)
                if let original = result.original {
                    report.entries.append(.init(setting: .menuItem(item.rawValue), original: original, applied: data))
                }
                return true
            }
            _ = try await menu(.dataMod, [dataMod.rawValue], "DATA MOD \(dataMod == .wlan ? "WLAN" : "USB")")
            _ = try await menu(.usbAFSquelch, [0x00], "USB AF squelch off")
            _ = try await menu(.usbSend, [0x00], "USB SEND off")
            if quietTheBus, try await menu(.civTransceive, [0x00], "CI-V transceive off") {
                try await setTransceive(false)
            }
            for item in [CIVCommand.MenuItem.txDelayHF, .txDelay50M, .txDelay144M, .txDelay430M] {
                _ = try await menu(item, [0x00], "TX delay off")
            }
        } catch {
            report.failure = (error as? CIVError) ?? .transport(String(describing: error))
            return report
        }

        guard clearsReceive else { return report }
        for correction in RigPrep.receiveClears(toneSquelchFunction: toneSquelchFunction) {
            let setting = RigPrep.setting(for: correction)
            let read = await readPrepValueNoting(setting)
            // A radio that is not answering at all would cost a timeout per
            // setting on every connect; one silence is enough to stop asking.
            if read.unanswered { break }
            guard let now = read.value,
                  let target = RigPrep.target(for: correction, current: now), target != now else { continue }
            do {
                try await writePrepValue(setting, target)
                report.entries.append(.init(setting: setting, original: now, applied: target))
                report.changed.append(RigPrep.describe(setting, from: now, to: target))
            } catch {
                // One refused receive setting is not a reason to fail the
                // connect; the audit will name it.
                TxLog.debug(.modem, "CI-V: could not clear a receive setting",
                            ["setting": setting.label, "error": String(describing: error)])
            }
        }
        return report
    }

    /// Write a menu item only when the radio does not already hold that value.
    ///
    /// Returns whether anything was written, and what the radio held before
    /// when it said. A read that fails tells us nothing, so the write goes
    /// ahead — the setting mattering more than the tidiness, and the
    /// alternative being a radio left misconfigured because one read timed
    /// out. That write has no original to put back.
    private func setMenuItemIfNeeded(_ item: CIVCommand.MenuItem, _ data: [UInt8],
                                     readable: inout Bool) async throws -> (wrote: Bool, original: [UInt8]?) {
        var original: [UInt8]?
        if readable {
            if let value = await readPrepValue(.menuItem(item.rawValue)) {
                if value == data { return (false, value) }
                original = value
            } else {
                // Stop asking. Each unanswered read costs a full CI-V timeout,
                // and ten of them would be five seconds added to every connect
                // on a radio that does not support these reads.
                readable = false
            }
        }
        try await setMenuItem(item, data)
        return (true, original)
    }

    // MARK: - Request/response

    private func request(_ frame: CIVFrame, expecting: Expectation,
                         acceptingAnyRadio: Bool = false) async throws -> CIVFrame {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.transport.state == .open else {
                    continuation.resume(throwing: CIVError.notOpen)
                    return
                }
                self.pending.append(Request(frame: frame, expectation: expecting,
                                            acceptsAnyRadio: acceptingAnyRadio,
                                            continuation: continuation))
                self.advance()
            }
        }
    }

    /// Send the next request if nothing is in flight. Queue-only.
    private func advance() {
        guard inFlight == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        inFlight = request
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.inFlight === request else { return }
            self.inFlight = nil
            // The moment that matters. "PTT failed: timeout" says nothing
            // about whether the radio is mute or merely unheard; these
            // counters separate the two.
            TxLog.warning(.modem, "CI-V: no answer", [
                "command": String(format: "%02X", request.frame.command),
                "sent": request.frame.encoded().map { String(format: "%02x", $0) }.joined(),
                "bytesInSinceOpen": self.bytesIn,
                "framesInSinceOpen": self.framesIn,
                "framesDiscarded": self.framesDropped,
                "after": String(format: "%.2fs", self.requestTimeout)])
            self.consecutiveTimeouts += 1
            if self.consecutiveTimeouts == Self.unansweredPollLimit {
                // Once, on the way past the limit, not on every poll after it.
                //
                // Reported *before* the waiter is resumed. Resuming hands
                // control to whoever was awaiting this request, so a verdict
                // reached afterwards is a verdict that caller can miss: it
                // sees the failure, looks for the reason, and finds nothing
                // yet. Reporting first makes the continuation the edge that
                // publishes it, and the caller cannot observe the one without
                // the other.
                self.onUnresponsive?(
                    "the radio has not answered \(self.consecutiveTimeouts) CI-V commands in a "
                    + "row. Its keepalives are still running, so the session is up and the radio "
                    + "is ignoring it.")
            }
            request.continuation.resume(throwing: CIVError.timeout(command: request.frame.command))
            self.advance()
        }
        request.timeout = timeout
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
        transport.write(request.frame.encoded()) { [weak self] error in
            guard let error else { return }
            self?.queue.async {
                guard let self, self.inFlight === request else { return }
                request.timeout?.cancel()
                self.inFlight = nil
                request.continuation.resume(throwing: CIVError.transport(String(describing: error)))
                self.advance()
            }
        }
    }

    /// Queue-only.
    private func received(_ data: Data) {
        bytesIn += data.count
        if !reportedFirstBytes {
            reportedFirstBytes = true
            TxLog.debug(.modem, "CI-V: first bytes from the radio", [
                "count": data.count,
                "hex": data.prefix(16).map { String(format: "%02x", $0) }.joined()])
        }
        for frame in parser.feed(data) {
            framesIn += 1
            // Any frame the radio addressed to us ends the run, whether or not
            // it is the answer we were waiting for. The question this counter
            // asks is "is the radio answering at all", not "did this poll
            // succeed".
            if frame.from == radioAddress { consecutiveTimeouts = 0 }
            if CIVFilter.isEcho(frame, radio: radioAddress) { continue }
            // While a probe is in flight, any address may answer it — that is
            // the whole point. Our own broadcast coming back with echo-back
            // on is not an answer, so the sender must not be us.
            let answersProbe = (inFlight?.acceptsAnyRadio ?? false)
                && frame.from != controllerAddress
                && frame.to == controllerAddress
            guard answersProbe
                    || (frame.from == radioAddress
                        && CIVFilter.isForUs(frame, controller: controllerAddress)) else {
                framesDropped += 1
                // A radio answering from an address we are not asking for is
                // the likeliest cause of total silence, and it is dropped
                // here without a word. Say it — a few times, not forever.
                if droppedReports < 3 {
                    droppedReports += 1
                    TxLog.debug(.modem, "CI-V: frame discarded", [
                        "from": String(format: "%02X", frame.from),
                        "to": String(format: "%02X", frame.to),
                        "command": String(format: "%02X", frame.command),
                        "weExpectFrom": String(format: "%02X", radioAddress),
                        "weAre": String(format: "%02X", controllerAddress)])
                }
                continue
            }
            if let request = inFlight, frame.to == controllerAddress, matches(frame, request.expectation) {
                request.timeout?.cancel()
                inFlight = nil
                if frame.isNG {
                    request.continuation.resume(throwing: CIVError.rejected(command: request.frame.command))
                } else {
                    request.continuation.resume(returning: frame)
                }
                advance()
            } else {
                onUnsolicited?(frame)
            }
        }
    }

    private func matches(_ frame: CIVFrame, _ expectation: Expectation) -> Bool {
        if frame.isNG { return true }
        switch expectation {
        case .acknowledgement:
            return frame.isOK
        case .reply(let command, let subcommand):
            guard frame.command == command else { return false }
            if let subcommand { return frame.subcommand == subcommand }
            return true
        }
    }

    /// Queue-only.
    private func transportChanged(_ state: CIVTransportState) {
        switch state {
        case .closed: failAll(CIVError.notOpen)
        case .failed(let reason): failAll(CIVError.transport(reason))
        case .opening, .open:
            parser.reset()
            bytesIn = 0; framesIn = 0; framesDropped = 0; consecutiveTimeouts = 0
            reportedFirstBytes = false; droppedReports = 0
        }
        onTransportState?(state)
        if case .failed(let reason) = state { onTransportFailure?(reason) }
    }

    private func failAll(_ error: CIVError) {
        if let request = inFlight {
            request.timeout?.cancel()
            inFlight = nil
            request.continuation.resume(throwing: error)
        }
        for request in pending { request.continuation.resume(throwing: error) }
        pending.removeAll()
    }
}
