import Accelerate
import Foundation

/// The modem's audio over the radio's WLAN: the session's received PCM
/// becomes capture, and every 20 ms the engine is asked for transmit
/// audio, which goes back as PCM. 48 kHz, 16-bit, mono, both ways.
///
/// The session must already be logged in — `ModemRadioLink` opens CI-V
/// first, which is the same login — so `start()` only wires the callbacks
/// and the transmit clock.
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
    /// Decided at `start()`, from whether the session reached Warbler.
    private(set) var transmitTail: ModemTransmitTail = .radio
    /// Which transmit frames go out; see `TrailingSilenceGate`.
    private var silenceGate = TrailingSilenceGate(tail: .radio)
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
        transmitTail = Self.transmitTail(for: session)
        silenceGate = TrailingSilenceGate(tail: transmitTail)
        TxLog.debug(.modem, "LAN transmit tail", [
            "policy": transmitTail.rawValue,
            "farEnd": session.viaWarbler ? "Warbler (capabilities carry 02:57:42:4C:45:52)" : "radio",
            "trailingSilenceMs": silenceGate.limit * 20,
            "reason": transmitTail.reason])
        isRunning = true
        session.onAudio = { [weak self] pcm in self?.receive(pcm) }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.transmitFrame() }
        t.resume()
        txTimer = t
        sink?.audioIO(didReceive: .started(fmt))
    }

    /// The tail policy for a logged-in session.
    static func transmitTail(for session: IcomLANSession) -> ModemTransmitTail {
        .forIcomLAN(viaWarbler: session.viaWarbler)
    }

    /// Listen for `window` seconds and count 16-bit mono samples, then snap
    /// to the nearest rate an Icom radio streams. Runs before capture is
    /// wired, so the samples counted here are only for the measurement.
    private func measureSampleRate(session: IcomLANSession, window: Double) -> Double {
        let lock = NSLock()
        var arrivals: [Arrival] = []
        session.onAudio = { pcm in
            guard let pcm else { return }
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock { arrivals.append(Arrival(at: now, samples: pcm.count / 2)) }
        }
        Thread.sleep(forTimeInterval: window)
        session.onAudio = nil
        let heard = lock.withLock { arrivals }
        return Self.estimateRate(heard, configured: Double(session.configuration.sampleRate))
    }

    /// One audio packet heard while measuring: when, and how many samples.
    struct Arrival: Equatable, Sendable { let at: Double; let samples: Int }

    /// The radio's rate from the packets that arrived: samples over the span
    /// they arrived in, snapped to a rate an Icom radio streams. Counting
    /// over the whole window read audio that began part-way through as a
    /// slower rate (48 kHz arriving for 0.15 s of 0.7 s snapped to 8 kHz),
    /// and the decoder built for it heard nothing (2026-10-10). Too few
    /// packets, or too short a span, to measure: the configured rate.
    static func estimateRate(_ arrivals: [Arrival], configured: Double) -> Double {
        guard arrivals.count >= 6, let first = arrivals.first, let last = arrivals.last else { return configured }
        let span = last.at - first.at
        guard span >= 0.08 else { return configured }
        // The first packet's samples arrived before the span began.
        let samples = arrivals.dropFirst().reduce(0) { $0 + $1.samples }
        let perSecond = Double(samples) / span
        let candidates: [Double] = [8_000, 16_000, 24_000, 48_000]
        return candidates.min { abs($0 - perSecond) < abs($1 - perSecond) } ?? configured
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

    /// Every 20 ms: pull what the engine has. Silence goes out only inside a
    /// transmission and, for a direct radio, briefly after it, so an idle
    /// modem costs the network nothing.
    private func transmitFrame() {
        guard isRunning, let sink, let session, let format else { return }
        let frames = Int(format.sampleRate * 0.02)
        if renderScratch.count != frames { renderScratch = [Float](repeating: 0, count: frames) }
        let written = renderScratch.withUnsafeMutableBufferPointer { sink.audioIO(render: $0) }
        guard silenceGate.shouldSend(written: written, moreToCome: sink.transmitAudioPending) else { return }
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
