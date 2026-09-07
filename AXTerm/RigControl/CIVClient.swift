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

    private let queue = DispatchQueue(label: "com.axterm.civ.client")
    private var parser = CIVFrameParser()
    private var pending: [Request] = []
    private var inFlight: Request?

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
        var timeout: DispatchWorkItem?
        init(frame: CIVFrame, expectation: Expectation, continuation: CheckedContinuation<CIVFrame, Error>) {
            self.frame = frame
            self.expectation = expectation
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
    /// link the audio arrives on the WLAN codec (0x02), and picking the
    /// wrong one keys an unmodulated carrier — a bare CW line on the
    /// waterfall — because the modulator listens to a dead input.
    enum DataModSource: UInt8 { case usb = 0x01, wlan = 0x02 }

    func configureForPacket(_ mode: ModemMode, dataMod: DataModSource = .usb) async throws {
        switch mode {
        case .afsk1200: try await setMode(.fm, filter: 1)
        case .afsk300: try await setMode(.usb, filter: 1)
        case .g3ruh9600RxIF: try await setMode(.fm, filter: 1)
        }
        try await setDataMode(true, filter: 1)
        try await setMenuItem(.dataMod, [dataMod.rawValue])
        try await setMenuItem(.usbAFSquelch, [0x00])
        try await setMenuItem(.usbSend, [0x00])
        try await setTransceive(false)
        for item in [CIVCommand.MenuItem.txDelayHF, .txDelay50M, .txDelay144M, .txDelay430M] {
            try await setMenuItem(item, [0x00])
        }
    }

    // MARK: - Request/response

    private func request(_ frame: CIVFrame, expecting: Expectation) async throws -> CIVFrame {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.transport.state == .open else {
                    continuation.resume(throwing: CIVError.notOpen)
                    return
                }
                self.pending.append(Request(frame: frame, expectation: expecting, continuation: continuation))
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
        for frame in parser.feed(data) {
            if CIVFilter.isEcho(frame, radio: radioAddress) { continue }
            guard frame.from == radioAddress, CIVFilter.isForUs(frame, controller: controllerAddress) else { continue }
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
        case .opening, .open: parser.reset()
        }
        onTransportState?(state)
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
