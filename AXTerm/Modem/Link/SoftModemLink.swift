import Foundation

/// The built-in modem as a `KISSLink`.
///
/// It speaks KISS on both faces so the link layer above needs no new
/// protocol: the engine's KISS-framed AX.25 is unwrapped in `send`, and
/// decoded frames go up KISS-framed on the configured port. KISS command
/// frames (TXDELAY, P, SlotTime, TXtail, FullDuplex) adjust the modem live,
/// as they would a TNC.
nonisolated final class SoftModemLink: KISSLink, @unchecked Sendable {

    /// How work reaches the main actor; tests inject a synchronous one.
    typealias Deliver = @Sendable (@escaping @MainActor () -> Void) -> Void

    let engine: ModemEngine
    private(set) var endpointDescription: String
    weak var delegate: KISSLinkDelegate?

    private let lock = NSLock()
    private var _state: KISSLinkState = .disconnected
    private var configuration: SoftModemConfiguration
    private var parser = KISSFrameParser()
    private let deliver: Deliver

    var state: KISSLinkState { lock.withLock { _state } }
    var telemetry: ModemTelemetry { engine.telemetrySnapshot() }
    var currentConfiguration: SoftModemConfiguration { lock.withLock { configuration } }

    init(configuration: SoftModemConfiguration,
         audio: ModemAudioIO,
         ptt: PTTController,
         inputName: String = "", outputName: String = "",
         scheduling: ModemEngine.Scheduling = .dedicatedThread,
         deliver: @escaping Deliver = { work in
             DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
         }) {
        self.configuration = configuration
        self.engine = ModemEngine(configuration: configuration, audio: audio, ptt: ptt, scheduling: scheduling)
        self.deliver = deliver
        let inName = inputName.isEmpty ? "audio in" : inputName
        let outName = outputName.isEmpty ? "audio out" : outputName
        self.endpointDescription = "softmodem \(configuration.mode.rawValue) in:\(inName) out:\(outName)"

        engine.onFrameDecoded = { [weak self] frame, _ in
            guard let self else { return }
            let port = self.lock.withLock { self.configuration.kissPort }
            let kiss = KISS.encodeFrame(payload: frame, port: port)
            self.deliver { [weak self] in self?.delegate?.linkDidReceive(kiss) }
        }
        engine.onFault = { [weak self] message, fatal in
            guard let self else { return }
            if fatal { self.setState(.failed) }
            self.deliver { [weak self] in self?.delegate?.linkDidError(message) }
        }
    }

    // MARK: - KISSLink

    func open() {
        guard state == .disconnected || state == .failed else { return }
        setState(.connecting)
        do {
            try engine.start()
            setState(.connected)
            KISSLinkLog.opened(endpointDescription)
        } catch {
            setState(.failed)
            let message = "Sound modem could not start: \(describe(error))"
            KISSLinkLog.error(endpointDescription, message: message)
            deliver { [weak self] in self?.delegate?.linkDidError(message) }
        }
    }

    func close() {
        engine.stop()
        lock.withLock { parser.reset() }
        setState(.disconnected)
        KISSLinkLog.closed(endpointDescription, reason: "closed")
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard state == .connected else {
            completion(ModemError.notRunning)
            return
        }
        // The shared parser discards KISS command frames (a TNC's tuning
        // knobs); here they are the modem's own, so pick them off first.
        var dataFrames = Data()
        for chunk in data.split(separator: KISS.FEND, omittingEmptySubsequences: true) {
            let command = chunk[chunk.startIndex] & 0x0F
            if (0x01...0x05).contains(command), chunk.count >= 2 {
                let value = KISS.unescape(Data(chunk.dropFirst())).first ?? 0
                var updated = lock.withLock { configuration }
                if updated.apply(kissCommand: command, value: value) {
                    lock.withLock { configuration = updated }
                    engine.update(configuration: updated)
                }
            } else {
                dataFrames.append(KISS.FEND)
                dataFrames.append(contentsOf: chunk)
                dataFrames.append(KISS.FEND)
            }
        }
        let frames = lock.withLock { parser.feedFrames(dataFrames) }
        for frame in frames {
            switch frame.output {
            case .ax25(let payload):
                do {
                    try engine.enqueue(payload)
                } catch {
                    completion(error)
                    return
                }
            case .unknown, .mobilinkdTelemetry:
                break
            }
        }
        completion(nil)
    }

    /// A new keying method, for a closed link.
    func replacePTT(_ new: PTTController) { engine.replacePTT(new) }

    /// Key up with a steady tone, for setting the radio's drive level.
    func sendTestTone(seconds: Double) throws { try engine.requestTestTone(seconds: seconds) }

    /// Settings changed under a running link: levels and timing apply in
    /// place; the engine rebuilds its DSP if the mode did.
    func update(configuration new: SoftModemConfiguration) {
        lock.withLock { configuration = new }
        engine.update(configuration: new)
    }

    // MARK: - Internals

    private func setState(_ new: KISSLinkState) {
        let old: KISSLinkState = lock.withLock {
            let previous = _state
            _state = new
            return previous
        }
        guard old != new else { return }
        KISSLinkLog.stateChange(endpointDescription, from: old, to: new)
        deliver { [weak self] in self?.delegate?.linkDidChangeState(new) }
    }

    private func describe(_ error: Error) -> String {
        if let audio = error as? ModemAudioError {
            switch audio {
            case .deviceNotFound(let uid): return "audio device not found (\(uid))"
            case .permissionDenied: return "microphone access denied — allow AXTerm under System Settings › Privacy & Security › Microphone"
            case .unsupportedFormat(let detail): return "unsupported audio format: \(detail)"
            case .system(let code, let stage): return "CoreAudio error \(code) while \(stage)"
            }
        }
        return String(describing: error)
    }
}
