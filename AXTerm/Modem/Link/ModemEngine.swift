import Accelerate
import Foundation
import Synchronization

nonisolated enum ModemError: Error, Equatable, Sendable {
    case notRunning
    case queueFull
    case txNotSupportedInMode
    case pttFailed(String)
    case audio(String)
}

/// The modem proper: audio in, frames out; frames in, audio out, with the
/// transmitter keyed around them.
///
/// Three threads meet here and never wait on each other. The audio thread
/// only moves samples through two rings and touches atomics. The DSP
/// thread (or, in tests, the audio thread itself in `inline` scheduling)
/// runs the demodulator, carrier detect, channel access and the transmit
/// state machine, all clocked in input samples rather than wall time, so a
/// test can run a whole transmission in a few synchronous calls. Callers
/// enqueue frames from anywhere under a mutex.
nonisolated final class ModemEngine: ModemAudioSink, @unchecked Sendable {

    enum Scheduling: Sendable { case dedicatedThread, inline }

    let audio: ModemAudioIO
    let ptt: PTTController
    let scheduling: Scheduling

    /// Decoded frame (no FCS) and the slicer that heard it. DSP thread.
    var onFrameDecoded: (@Sendable (Data, Int) -> Void)?
    /// A few times a second. DSP thread.
    var onTelemetry: (@Sendable (ModemTelemetry) -> Void)?
    /// Something went wrong; `fatal` means the modem has stopped.
    var onFault: (@Sendable (String, _ fatal: Bool) -> Void)?

    // Shared with other threads.
    private let configuration: Mutex<SoftModemConfiguration>
    private let pending = Mutex<[Data]>([])
    private let latestTelemetry = Mutex<ModemTelemetry>(ModemTelemetry())
    private let rxRing = SPSCRingBuffer(capacity: 65_536)
    private let txRing = SPSCRingBuffer(capacity: 32_768)
    private let outputConsumed = Atomic<Int64>(0)
    private let txFeeding = Atomic<Bool>(false)
    private let txUnderruns = Atomic<Int64>(0)
    private let rxOverruns = Atomic<Int64>(0)
    private let peakBits = Atomic<UInt32>(0)
    private let running = Atomic<Bool>(false)
    /// 0 waiting for the PTT controller, 1 keyed, 2 refused.
    private let pttConfirmation = Atomic<Int>(0)
    private let wake = DispatchSemaphore(value: 0)
    private let stopped = DispatchSemaphore(value: 0)
    private var thread: Thread?

    // DSP-thread state.
    private enum TXState: Equatable {
        case idle
        case waitingForChannel
        case keying(since: Int64)
        case transmitting(keyedAt: Int64, drainedAt: Int64?)
        case cooldown(until: Int64)
    }
    private var txState: TXState = .idle
    private var active = SoftModemConfiguration()
    private var sampleRate: Double = 48_000
    private var demodulator: AFSKDemodulator?
    private var carrier = DataCarrierDetect(holdSamples: 2400)
    private var access = ChannelAccess(parameters: .init(slotTimeSamples: 4800, persist: 63, maxWaitSamples: 480_000),
                                       rng: SystemRandomNumberGenerator())
    private var encoder: HDLCEncoder?
    private var modulator: AFSKModulator?
    private var rxClock: Int64 = 0
    private var txWrittenTotal: Int64 = 0
    private var framesInTransmission = 0
    private var framesSent: UInt64 = 0
    private var lastDecodeAt: Date?
    private var lastError: String?
    private var lastTelemetryClock: Int64 = 0
    private var startedAt = Date()
    private var scratchIn = [Float](repeating: 0, count: 480)
    private var scratchOut = [Float](repeating: 0, count: 2048)

    init(configuration: SoftModemConfiguration, audio: ModemAudioIO, ptt: PTTController,
         scheduling: Scheduling = .dedicatedThread) {
        self.configuration = Mutex(configuration)
        self.audio = audio
        self.ptt = ptt
        self.scheduling = scheduling
    }

    deinit {
        stop()
    }

    var isRunning: Bool { running.load(ordering: .acquiring) }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        active = configuration.withLock { $0 }
        audio.sink = self
        try audio.start()
        guard let format = audio.format else { throw ModemError.audio("no audio format") }
        sampleRate = format.sampleRate
        rebuildDSP()
        rxClock = 0
        txWrittenTotal = 0
        outputConsumed.store(0, ordering: .releasing)
        txState = .idle
        startedAt = Date()
        running.store(true, ordering: .releasing)
        if scheduling == .dedicatedThread {
            let thread = Thread { [weak self] in self?.runLoop() }
            thread.name = "com.axterm.modem.dsp"
            thread.qualityOfService = .userInteractive
            thread.threadPriority = 0.9
            self.thread = thread
            thread.start()
        }
    }

    func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        if case .transmitting = txState { ptt.setTransmit(false) { _ in } }
        if case .keying = txState { ptt.setTransmit(false) { _ in } }
        txFeeding.store(false, ordering: .releasing)
        audio.stop()
        if scheduling == .dedicatedThread {
            wake.signal()
            _ = stopped.wait(timeout: .now() + .seconds(2))
            thread = nil
        }
        pending.withLock { $0.removeAll() }
        txRing.drain()
    }

    /// Queue a frame (AX.25 bytes, no FCS) for the next transmission.
    func enqueue(_ ax25: Data) throws {
        guard isRunning else { throw ModemError.notRunning }
        let config = configuration.withLock { $0 }
        guard config.mode.isTxCapable else { throw ModemError.txNotSupportedInMode }
        try pending.withLock { queue in
            guard queue.count < config.maxQueuedFrames else { throw ModemError.queueFull }
            queue.append(ax25)
        }
        if scheduling == .dedicatedThread { wake.signal() }
    }

    /// Apply new settings; takes effect at the next block boundary.
    func update(configuration new: SoftModemConfiguration) {
        configuration.withLock { $0 = new }
        if scheduling == .dedicatedThread { wake.signal() }
    }

    func telemetrySnapshot() -> ModemTelemetry {
        latestTelemetry.withLock { $0 }
    }

    // MARK: - ModemAudioSink (real-time thread)

    func audioIO(didCapture samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        guard isRunning else { return }
        let written = rxRing.write(samples)
        if written < samples.count { rxOverruns.add(1, ordering: .relaxed) }
        if let base = samples.baseAddress, samples.count > 0 {
            var peak: Float = 0
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(samples.count))
            peakBits.store(peak.bitPattern, ordering: .relaxed)
        }
        switch scheduling {
        case .inline: iterate()
        case .dedicatedThread: wake.signal()
        }
    }

    func audioIO(render into: UnsafeMutableBufferPointer<Float>) -> Int {
        let n = txRing.read(into: into)
        if n > 0 { outputConsumed.add(Int64(n), ordering: .relaxed) }
        if n < into.count, txFeeding.load(ordering: .relaxed) {
            txUnderruns.add(1, ordering: .relaxed)
        }
        return n
    }

    func audioIO(didReceive event: ModemAudioIOEvent) {
        switch event {
        case .started, .overload:
            break
        case .formatChanged(let format):
            sampleRate = format.sampleRate
            if scheduling == .dedicatedThread { wake.signal() }
        case .deviceLost:
            fail("Audio device lost", fatal: true)
        case .error(let message):
            fail(message, fatal: true)
        }
    }

    // MARK: - DSP thread

    private func runLoop() {
        while isRunning {
            _ = wake.wait(timeout: .now() + .milliseconds(5))
            guard isRunning else { break }
            iterate()
        }
        stopped.signal()
    }

    /// One pass: drain captured audio, decode, run the transmitter, report.
    private func iterate() {
        let config = configuration.withLock { $0 }
        if config != active { applyConfiguration(config) }

        while rxRing.availableToRead >= scratchIn.count {
            let n = scratchIn.withUnsafeMutableBufferPointer { rxRing.read(into: $0) }
            guard n > 0 else { break }
            rxClock += Int64(n)
            receive(scratchIn)
            serviceTransmitter()
        }
        // Whatever is left (a partial block) is processed too when inline,
        // so a test never has samples stuck behind a block boundary.
        if scheduling == .inline, rxRing.availableToRead > 0 {
            let n = scratchIn.withUnsafeMutableBufferPointer { rxRing.read(into: $0) }
            rxClock += Int64(n)
            receive(Array(scratchIn[0..<n]))
            serviceTransmitter()
        }
        if rxRing.availableToRead == 0 { serviceTransmitter() }

        if rxClock - lastTelemetryClock >= Int64(sampleRate / 10) || lastTelemetryClock == 0 {
            lastTelemetryClock = rxClock
            publishTelemetry()
        }
    }

    private var isMuted: Bool {
        switch txState {
        case .idle, .waitingForChannel: return false
        case .keying, .transmitting, .cooldown: return true
        }
    }

    private func receive(_ block: [Float]) {
        guard let demodulator else { return }
        if isMuted { return }
        demodulator.process(block) { [self] event in
            switch event {
            case .frame(let data, let slicer):
                lastDecodeAt = Date()
                onFrameDecoded?(data, slicer)
            case .fcsError:
                break
            }
        }
        _ = carrier.update(activity: demodulator.activity,
                           rmsDBFS: ModemTelemetry.dbfs(demodulator.rxRMS),
                           squelchDBFS: active.rxSquelchDBFS, now: rxClock)
    }

    private func serviceTransmitter() {
        switch txState {
        case .idle:
            let queued = pending.withLock { $0.count }
            guard queued > 0, active.mode.isTxCapable else { return }
            access.requestChannel(now: rxClock)
            txState = .waitingForChannel

        case .waitingForChannel:
            switch access.evaluate(now: rxClock, dcd: carrier.isDetected) {
            case .transmit:
                startKeying()
            case .gaveUp:
                let dropped = pending.withLock { let n = $0.count; $0.removeAll(); return n }
                fail("Channel busy for \(Int(active.maxChannelWaitSeconds)) s; \(dropped) frame(s) dropped", fatal: false)
                txState = .idle
            case .idle, .waiting:
                break
            }

        case .keying(let since):
            switch pttConfirmation.load(ordering: .acquiring) {
            case 1:
                txFeeding.store(true, ordering: .releasing)
                txState = .transmitting(keyedAt: rxClock, drainedAt: nil)
                topUpTransmitRing()
            case 2:
                pending.withLock { $0.removeAll() }
                encoder = nil
                modulator = nil
                txState = .idle
            default:
                if rxClock - since > Int64(2 * sampleRate) {
                    ptt.setTransmit(false) { _ in }
                    pending.withLock { $0.removeAll() }
                    encoder = nil
                    modulator = nil
                    fail("PTT was not confirmed within 2 s; frames dropped", fatal: false)
                    txState = .idle
                }
            }

        case .transmitting(let keyedAt, let drainedAt):
            if rxClock - keyedAt > Int64(active.pttWatchdogSeconds * sampleRate) {
                pending.withLock { $0.removeAll() }
                unkey(reason: "PTT watchdog: transmitter keyed for \(Int(active.pttWatchdogSeconds)) s, forced off")
                return
            }
            absorbPendingFrames()
            topUpTransmitRing()
            guard let modulator, modulator.isExhausted else { return }
            txFeeding.store(false, ordering: .releasing)
            if drainedAt == nil {
                if outputConsumed.load(ordering: .acquiring) >= txWrittenTotal {
                    txState = .transmitting(keyedAt: keyedAt, drainedAt: rxClock)
                }
            } else if let drainedAt, rxClock - drainedAt >= unkeyMarginSamples {
                unkey(reason: nil)
            }

        case .cooldown(let until):
            if rxClock >= until {
                txState = .idle
                demodulator?.reset()
                carrier.reset()
            }
        }
    }

    private var unkeyMarginSamples: Int64 {
        Int64((audio.latency.outputSeconds + ptt.keyUpLatencyHint + 0.02) * sampleRate)
    }

    private func startKeying() {
        var enc = HDLCEncoder(baud: active.mode.baud, txDelayMs: active.txDelayMs, txTailMs: active.txTailMs)
        let frames = pending.withLock { queue -> [Data] in let f = queue; queue.removeAll(); return f }
        for frame in frames { enc.append(frame: frame) }
        framesInTransmission = frames.count
        encoder = enc
        modulator = AFSKModulator(sampleRate: sampleRate, mode: active.mode.parameters,
                                  amplitude: active.txAmplitude, spaceGainDB: active.txSpaceGainDB)
        pttConfirmation.store(0, ordering: .releasing)
        txState = .keying(since: rxClock)
        ptt.setTransmit(true) { [weak self] error in
            guard let self else { return }
            if let error {
                self.lastError = "PTT: \(error)"
                self.pttConfirmation.store(2, ordering: .releasing)
                self.onFault?("PTT failed: \(error)", false)
            } else {
                self.pttConfirmation.store(1, ordering: .releasing)
            }
            if self.scheduling == .dedicatedThread { self.wake.signal() }
        }
    }

    /// Frames queued while we are already on the air ride along, until the
    /// tail has started.
    private func absorbPendingFrames() {
        guard var enc = encoder, !enc.hasStartedTail else { return }
        let more = pending.withLock { queue -> [Data] in let f = queue; queue.removeAll(); return f }
        guard !more.isEmpty else { return }
        for frame in more where enc.append(frame: frame) { framesInTransmission += 1 }
        encoder = enc
    }

    /// Keep about a quarter second of audio queued ahead of the device.
    private func topUpTransmitRing() {
        guard var mod = modulator, var enc = encoder, !mod.isExhausted else { return }
        let lead = Int64(0.3 * sampleRate)
        while !mod.isExhausted,
              txWrittenTotal - outputConsumed.load(ordering: .acquiring) < lead,
              txRing.availableToWrite >= scratchOut.count {
            let n = mod.render(into: &scratchOut, count: scratchOut.count) { enc.nextBit() }
            if n > 0 {
                scratchOut.withUnsafeBufferPointer { ptr in
                    _ = txRing.write(UnsafeBufferPointer(rebasing: ptr[0..<n]))
                }
                txWrittenTotal += Int64(n)
            }
        }
        modulator = mod
        encoder = enc
    }

    private func unkey(reason: String?) {
        txFeeding.store(false, ordering: .releasing)
        txRing.drain()
        ptt.setTransmit(false) { [weak self] error in
            if let error { self?.onFault?("PTT off failed: \(error)", false) }
        }
        if let reason { fail(reason, fatal: false) }
        framesSent += UInt64(framesInTransmission)
        framesInTransmission = 0
        encoder = nil
        modulator = nil
        txState = .cooldown(until: rxClock + Int64(Double(active.rxMuteAfterTxMs) / 1000 * sampleRate))
        demodulator?.reset()
        carrier.reset()
    }

    private func applyConfiguration(_ config: SoftModemConfiguration) {
        let needsDSP = config.mode != active.mode || config.slicerTwistsDB != active.slicerTwistsDB
        active = config
        if needsDSP { rebuildDSP() } else {
            access.parameters = .init(sampleRate: sampleRate, configuration: config)
        }
    }

    private func rebuildDSP() {
        let mode = active.mode.parameters
        demodulator = mode.markHz > 0
            ? AFSKDemodulator(inputSampleRate: sampleRate, mode: mode, slicerTwistsDB: active.slicerTwistsDB)
            : nil
        carrier = DataCarrierDetect(holdSamples: Int(0.05 * sampleRate))
        access = ChannelAccess(parameters: .init(sampleRate: sampleRate, configuration: active),
                               rng: SystemRandomNumberGenerator())
    }

    private func fail(_ message: String, fatal: Bool) {
        lastError = message
        if fatal { running.store(false, ordering: .releasing) }
        onFault?(message, fatal)
    }

    private func publishTelemetry() {
        var t = ModemTelemetry()
        let peak = Float(bitPattern: peakBits.load(ordering: .relaxed))
        t.rxPeakDBFS = ModemTelemetry.dbfs(peak)
        t.rxRMSDBFS = ModemTelemetry.dbfs(demodulator?.rxRMS ?? 0)
        t.rxClipping = peak >= 0.99
        t.dcd = carrier.isDetected
        t.slicerLocked = demodulator?.slicerLocked ?? []
        t.pllJitterBits = demodulator?.pllJitterBits ?? []
        t.framesDecoded = demodulator?.framesDecoded ?? 0
        t.fcsErrors = demodulator?.fcsErrors ?? 0
        t.duplicatesSuppressed = demodulator?.duplicatesSuppressed ?? 0
        t.lastDecodingSlicer = demodulator?.lastDecodingSlicer
        t.framesPerSlicer = demodulator?.framesPerSlicer ?? []
        t.lastDecodeAt = lastDecodeAt
        switch txState {
        case .keying, .transmitting: t.ptt = true
        default: t.ptt = false
        }
        t.waitingForChannel = txState == .waitingForChannel
        t.channelBusy = carrier.isDetected
        t.txQueueDepth = pending.withLock { $0.count } + framesInTransmission
        t.framesSent = framesSent
        t.txUnderruns = UInt64(txUnderruns.load(ordering: .relaxed))
        t.rxOverruns = UInt64(rxOverruns.load(ordering: .relaxed))
        t.audioFormat = audio.format
        t.latency = audio.latency
        t.lastError = lastError
        t.uptime = Date().timeIntervalSince(startedAt)
        latestTelemetry.withLock { $0 = t }
        onTelemetry?(t)
    }
}
