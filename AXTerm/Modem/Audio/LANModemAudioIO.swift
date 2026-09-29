import Accelerate
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
    /// Capture and render run on different queues, so each has its own
    /// 16-bit staging buffer.
    private var captureInt16 = [Int16](repeating: 0, count: 4096)
    private var renderScratch = [Float](repeating: 0, count: 960)
    private var renderInt16 = [Int16](repeating: 0, count: 960)
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
            if captureInt16.count < n { captureInt16 = [Int16](repeating: 0, count: n) }
            // One copy and two vector ops. The byte-at-a-time loop this
            // replaces ran three bounds-checked reads per sample, sixteen
            // thousand times a second, on the packet-receive queue. Native
            // byte order is little-endian on every platform this runs on,
            // which is the order the radio sends.
            captureInt16.withUnsafeMutableBytes { raw in _ = pcm.copyBytes(to: raw) }
            captureInt16.withUnsafeBufferPointer { i16 in
                captureScratch.withUnsafeMutableBufferPointer { f in
                    vDSP_vflt16(i16.baseAddress!, 1, f.baseAddress!, 1, vDSP_Length(n))
                    var scale: Float = 1.0 / 32768   // exact, so identical to the division
                    vDSP_vsmul(f.baseAddress!, 1, &scale, f.baseAddress!, 1, vDSP_Length(n))
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
            captureScratch.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(n)) }
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
        let written = renderScratch.withUnsafeMutableBufferPointer { sink.audioIO(render: $0) }
        if written == 0 {
            quietFrames += 1
            guard quietFrames <= 15 else { return }   // 300 ms of trailing silence, then quiet
        } else {
            quietFrames = 0
        }
        session.sendAudio(pcm: Self.encodePCM(&renderScratch, written: written, staging: &renderInt16))
    }

    /// Float samples to the little-endian 16-bit PCM the radio expects.
    ///
    /// Extracted from `transmitFrame` so it can be tested against the
    /// byte-at-a-time loop it replaced. This is the last step before audio
    /// leaves for the radio, and a fault here is silent in the worst way: the
    /// transmitter keys, the carrier goes up, and nothing modulates it.
    ///
    /// Zero past what was rendered, clip, scale, truncate toward zero — the
    /// same arithmetic as `Int16(v * 32767)` on a clipped v, as vector ops
    /// rather than three array writes per sample.
    static func encodePCM(_ samples: inout [Float], written: Int, staging: inout [Int16]) -> Data {
        let frames = samples.count
        if staging.count != frames { staging = [Int16](repeating: 0, count: frames) }
        guard frames > 0 else { return Data() }
        samples.withUnsafeMutableBufferPointer { f in
            let p = f.baseAddress!
            if written < frames { vDSP_vclr(p + written, 1, vDSP_Length(frames - written)) }
            var low: Float = -1, high: Float = 1, scale: Float = 32767
            vDSP_vclip(p, 1, &low, &high, p, 1, vDSP_Length(frames))
            vDSP_vsmul(p, 1, &scale, p, 1, vDSP_Length(frames))
            staging.withUnsafeMutableBufferPointer { i16 in
                vDSP_vfix16(p, 1, i16.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        return staging.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
