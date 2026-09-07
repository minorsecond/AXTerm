import Foundation

/// The modem's audio over the radio's WLAN: the session's received PCM
/// becomes capture, and every 20 ms the engine is asked for transmit
/// audio, which goes back as PCM. 48 kHz, 16-bit, mono, both ways.
///
/// The session must already be logged in — `ModemRadioLink` opens CI-V
/// first, which is the same login — so `start()` only wires the callbacks
/// and the transmit clock.
/// A minimal thread-safe integer, for the rate measurement.
private final class ManagedAtomic: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.withLock { count += n } }
    var value: Int { lock.withLock { count } }
}

nonisolated final class LANModemAudioIO: ModemAudioIO, @unchecked Sendable {

    /// Swappable while stopped: a settings change rebuilds the session.
    var session: IcomLANSession?
    private(set) var format: ModemAudioFormat?
    var latency: ModemAudioLatency
    weak var sink: ModemAudioSink?

    private let queue = DispatchQueue(label: "com.axterm.modem.lanaudio", qos: .userInteractive)
    private var txTimer: DispatchSourceTimer?
    private var isRunning = false
    private var captureScratch = [Float](repeating: 0, count: 4096)
    private var renderScratch = [Float](repeating: 0, count: 960)
    private var pcmScratch = [UInt8](repeating: 0, count: 1920)
    private var wasFeeding = false
    /// Consecutive 20 ms frames the engine has kept quiet; after a few,
    /// nothing is sent until it speaks again.
    private var quietFrames = 0
    private(set) var packetsReceived = 0
    private(set) var packetsLost = 0

    init(session: IcomLANSession?) {
        self.session = session
        // The radio buffers `txBufferMs` before playing; the network adds
        // some. Inbound the reorder hold is 100 ms.
        let txBuffer = Double(session?.configuration.txBufferMs ?? 300) / 1000
        latency = ModemAudioLatency(inputSeconds: 0.1, outputSeconds: txBuffer + 0.1)
    }

    func start() throws {
        guard !isRunning else { return }
        guard let session, session.isConnected else { throw ModemAudioError.notConnected("the radio's network session is not up") }

        // The radio picks the audio rate (an IC-705 streams 16 kHz over its
        // WLAN, whatever we request), so measure it before the DSP is built:
        // count the samples that arrive over a short window and snap to the
        // nearest rate the radio can use. The DSP filters depend on getting
        // this right, so a wrong guess means nothing decodes.
        let measured = measureSampleRate(session: session, window: 0.7)
        let fmt = ModemAudioFormat(sampleRate: measured, inputChannels: 1, outputChannels: 1)
        format = fmt
        latency.outputSeconds = Double(session.configuration.txBufferMs) / 1000 + 0.1
        isRunning = true
        session.onAudio = { [weak self] pcm in self?.receive(pcm) }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.transmitFrame() }
        t.resume()
        txTimer = t
        sink?.audioIO(didReceive: .started(fmt))
    }

    /// Listen for `window` seconds and count 16-bit mono samples, then snap
    /// to the nearest rate an Icom radio streams. Runs before capture is
    /// wired, so the samples counted here are only for the measurement.
    private func measureSampleRate(session: IcomLANSession, window: Double) -> Double {
        let counter = ManagedAtomic()
        session.onAudio = { pcm in if let pcm { counter.add(pcm.count / 2) } }
        Thread.sleep(forTimeInterval: window)
        session.onAudio = nil
        let perSecond = Double(counter.value) / window
        let candidates: [Double] = [8_000, 16_000, 24_000, 48_000]
        let snapped = candidates.min { abs($0 - perSecond) < abs($1 - perSecond) } ?? 48_000
        // Only trust the snap if we actually heard enough; else assume the
        // radio's requested rate rather than a rate read from silence.
        return perSecond > 2_000 ? snapped : Double(session.configuration.sampleRate)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        txTimer?.cancel(); txTimer = nil
        session?.onAudio = nil
    }

    // MARK: - Receive

    private func receive(_ pcm: Data?) {
        guard isRunning, let sink else { return }
        let bytes: Int
        if let pcm {
            packetsReceived += 1
            bytes = pcm.count
            let n = bytes / 2
            if captureScratch.count < n { captureScratch = [Float](repeating: 0, count: n) }
            pcm.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for i in 0..<n {
                    let v = Int16(bitPattern: UInt16(p[2 * i]) | UInt16(p[2 * i + 1]) << 8)
                    captureScratch[i] = Float(v) / 32768
                }
            }
            captureScratch.withUnsafeBufferPointer { buf in
                sink.audioIO(didCapture: UnsafeBufferPointer(rebasing: buf[0..<n]), hostTime: 0)
            }
        } else {
            // A packet that never came: the same span of silence keeps time.
            packetsLost += 1
            bytes = session?.typicalAudioPacketBytes ?? 960
            let n = bytes / 2
            if captureScratch.count < n { captureScratch = [Float](repeating: 0, count: n) }
            for i in 0..<n { captureScratch[i] = 0 }
            captureScratch.withUnsafeBufferPointer { buf in
                sink.audioIO(didCapture: UnsafeBufferPointer(rebasing: buf[0..<n]), hostTime: 0)
            }
        }
    }

    // MARK: - Transmit

    /// Every 20 ms: pull what the engine has. Silence is sent only briefly
    /// after audio, so an idle modem costs the network nothing.
    private func transmitFrame() {
        guard isRunning, let sink, let session, let format else { return }
        let frames = Int(format.sampleRate * 0.02)
        if renderScratch.count != frames { renderScratch = [Float](repeating: 0, count: frames) }
        if pcmScratch.count != frames * 2 { pcmScratch = [UInt8](repeating: 0, count: frames * 2) }
        let written = renderScratch.withUnsafeMutableBufferPointer { sink.audioIO(render: $0) }
        if written == 0 {
            quietFrames += 1
            guard quietFrames <= 15 else { return }   // 300 ms of trailing silence, then quiet
        } else {
            quietFrames = 0
        }
        for i in 0..<frames {
            let v = i < written ? max(-1, min(1, renderScratch[i])) : 0
            let s = Int16(v * 32767)
            pcmScratch[2 * i] = UInt8(truncatingIfNeeded: s)
            pcmScratch[2 * i + 1] = UInt8(truncatingIfNeeded: s >> 8)
        }
        session.sendAudio(pcm: Data(pcmScratch))
    }
}
