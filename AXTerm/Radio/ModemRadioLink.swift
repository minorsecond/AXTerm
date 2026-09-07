#if os(macOS)
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

    /// The radio, as CI-V reports it; empty until read.
    var rigStatus: RigStatus { lock.withLock { _rigStatus } }
    private var _rigStatus = RigStatus()
    /// "IC-705" once identified.
    private(set) var rigModel: String?

    var onRigStatus: (@Sendable (RigStatus) -> Void)?
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

    /// What the "Software" row shows: this modem, its mode.
    var identity: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return "AXTerm Sound Modem \(version) · \(config.mode.rawValue)".replacingOccurrences(of: "  ", with: " ")
    }

    init(config: ModemLinkConfig,
         audio: ModemAudioIO,
         makeTransport: @escaping (String) -> CIVTransport = { SerialCIVTransport(path: $0) },
         scheduling: ModemEngine.Scheduling = .dedicatedThread,
         deliver: @escaping SoftModemLink.Deliver = { work in
             DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
         }) {
        self.config = config
        self.makeTransport = makeTransport
        self.deliver = deliver
        let rigParts = Self.makeRig(config, makeTransport: makeTransport)
        self.civTransport = rigParts.transport
        self.rig = rigParts.client
        self.pttController = rigParts.ptt
        self.modem = SoftModemLink(configuration: config.softModemConfiguration, audio: audio, ptt: rigParts.ptt,
                                   inputName: config.audioInputDeviceName, outputName: config.audioOutputDeviceName,
                                   scheduling: scheduling, deliver: deliver)
        attachRig()
    }

    /// Frames the radio sends unasked — CI-V transceive broadcasts when the
    /// operator tunes — fold into the status; we switch transceive off at
    /// connect, but a radio that ignores that still gets heard.
    private func attachRig() {
        rig?.onUnsolicited = { [weak self] frame in self?.absorbUnsolicited(frame) }
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

    private static func makeRig(_ config: ModemLinkConfig, makeTransport: (String) -> CIVTransport)
    -> (transport: CIVTransport?, client: CIVClient?, ptt: PTTController) {
        guard config.usesRig else { return (nil, nil, NoPTTController()) }
        let transport = makeTransport(config.civSerialPath)
        let client = CIVClient(transport: transport, radioAddress: config.civAddress,
                               controllerAddress: config.civControllerAddress)
        let ptt: PTTController
        switch config.pttMethod {
        case .civ: ptt = CIVPTTController(client: client, maxTransmitSeconds: TimeInterval(config.maxTransmitSeconds))
        case .rts: ptt = SerialLinePTTController(transport: transport, line: .rts, maxTransmitSeconds: TimeInterval(config.maxTransmitSeconds))
        case .dtr: ptt = SerialLinePTTController(transport: transport, line: .dtr, maxTransmitSeconds: TimeInterval(config.maxTransmitSeconds))
        case .none: ptt = NoPTTController()
        }
        return (transport, client, ptt)
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
        let device = config.audioInputDeviceName.isEmpty ? "audio" : config.audioInputDeviceName
        return "\(rigModel ?? "Sound modem") via \(device)"
    }

    var delegate: KISSLinkDelegate? {
        get { _delegate }
        set { _delegate = newValue; modem.delegate = newValue }
    }

    func open() {
        guard state == .disconnected || state == .failed else { return }
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
                if case .failed(let reason) = civTransport.state { throw CIVError.transport(reason) }
                let address = try await rig.identify()
                rigModel = CIVKnownRadios.model(forAddress: address) ?? String(format: "Icom %02X", address)
                try? await rig.setTransceive(false)
                if config.setsRadioModeOnConnect { try await rig.configureForPacket(config.mode) }
                await refreshRigStatus()
                lock.withLock { phase = .modemOpen }
                modem.open()
                startPolling()
            } catch {
                let message = "Radio control failed: \((error as? CIVError)?.message ?? String(describing: error))"
                lock.withLock { phase = .failed(message) }
                civTransport.close()
                deliver { [weak self] in
                    self?._delegate?.linkDidError(message)
                    self?._delegate?.linkDidChangeState(.failed)
                }
            }
        }
    }

    /// The modem stops first (it asks for PTT off), then the radio is told
    /// PTT off once more on the still-open port, and only then does the
    /// port close. A close that raced the unkey would leave the radio
    /// transmitting; this order cannot.
    func close() {
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
            let rigParts = Self.makeRig(new, makeTransport: makeTransport)
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
                              makeTransport: (String) -> CIVTransport = { SerialCIVTransport(path: $0) }) async throws -> String {
        guard config.usesRig else { throw CIVError.transport("no CI-V port chosen") }
        let transport = makeTransport(config.civSerialPath)
        let client = CIVClient(transport: transport, radioAddress: config.civAddress,
                               controllerAddress: config.civControllerAddress)
        client.open()
        defer { client.close() }
        if case .failed(let reason) = transport.state { throw CIVError.transport(reason) }
        let address = try await client.identify()
        try? await client.setTransceive(false)
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
        try await rig.configureForPacket(config.mode)
        await refreshRigStatus()
    }

    // MARK: - Rig status

    private func refreshRigStatus() async {
        guard let rig else { return }
        var status = rigStatus
        if let hz = try? await rig.readFrequency() { status.frequencyHz = hz }
        if let mode = try? await rig.readMode() { status.mode = mode.mode; status.filter = mode.filter }
        if let data = try? await rig.readDataMode() { status.dataMode = data }
        status.ptt = modem.telemetry.ptt
        status.updatedAt = Date()
        lock.withLock { _rigStatus = status }
        onRigStatus?(status)
    }

    /// Every five seconds while the modem is idle; once only when the
    /// operator does not want the frequency followed.
    private func startPolling() {
        pollTask?.cancel()
        guard config.followsRadioFrequency else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if self.modem.telemetry.ptt { continue }
                await self.refreshRigStatus()
            }
        }
    }
}
#endif
