//
//  MobilinkdSessionDriver.swift
//  AXTerm
//
//  The Mobilinkd side of a link, shared by the Bluetooth LE and serial
//  transports: prove the TNC4 can be heard, read what it holds, apply the
//  radio's settings, put them back on the way out, and the live controls the
//  settings page uses. The transport supplies the bytes and the timing.
//

import Foundation

/// Runs entirely on the owning link's queue, except the two lock-protected
/// properties other threads read (`isMobilinkd`, `activity`).
nonisolated final class MobilinkdSessionDriver: @unchecked Sendable {

    struct Hooks {
        /// The link's queue. Timers fire here.
        let queue: DispatchQueue
        /// Write bytes to the TNC, whatever the link's reported state.
        let write: (Data) -> Void
        /// Write frames one after another with a short gap, then call back.
        let writeSequence: ([Data], @escaping () -> Void) -> Void
        let isConnected: () -> Bool
        let log: (String) -> Void
        /// The TNC4 has answered and been set up; report the link connected.
        let ready: () -> Void
        /// The TNC4 took the probe and said nothing back. The transport
        /// decides what to do (Bluetooth LE reconnects).
        let silent: () -> Void
        /// The settings the radio's profile manages.
        let wanted: () -> MobilinkdSettings
        /// The clock sample times are read from. Tests may replace it.
        var now: () -> Date = { Date() }
    }

    private enum Phase { case idle, probing, readingLevels, applying, restoring }

    static let probeTimeout: TimeInterval = 3
    static let levelReadTimeout: TimeInterval = 2
    /// How long to keep the link up after the restore frames.
    static let restoreSettleSeconds: TimeInterval = 1.2

    private let hooks: Hooks
    private let lock = NSLock()
    private var _isMobilinkd = false
    private var _activity: MobilinkdActivity = .idle

    private var phase: Phase = .idle
    private var sessionTimer: DispatchSourceTimer?
    private var activityTimer: DispatchSourceTimer?
    private var parser = KISSFrameParser()
    private var levelReport = MobilinkdDeviceState()
    /// What the TNC4 held before this link changed anything.
    private(set) var levelsFound: MobilinkdSettings?
    /// The fields this link set, and what it set them to.
    private(set) var levelsApplied: MobilinkdSettings?

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    deinit {
        sessionTimer?.cancel()
        activityTimer?.cancel()
        samplingTimer?.cancel()
        samplingWatch?.cancel()
    }

    /// The link's TNC is a Mobilinkd. Set by the transport.
    var isMobilinkd: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isMobilinkd }
        set { lock.lock(); _isMobilinkd = newValue; lock.unlock() }
    }

    var activity: MobilinkdActivity {
        lock.lock()
        defer { lock.unlock() }
        return _activity
    }

    // MARK: Connecting

    /// Start once the link can carry bytes and the KISS timing is out.
    ///
    /// About one BLE connection in four to a TNC4 comes up with notifications
    /// reported as enabled and then never delivers a byte (2026-09-29), so
    /// nothing is trusted until the TNC4 answers a firmware-version query.
    func begin() {
        phase = .probing
        startSessionTimer(after: Self.probeTimeout) { [weak self] in
            guard let self, self.phase == .probing else { return }
            self.phase = .idle
            self.hooks.silent()
        }
        hooks.write(MobilinkdSession.probe)
    }

    private func probeAnswered(_ reply: Data) {
        cancelSessionTimer()
        hooks.log("TNC4 answered, firmware \(MobilinkdTNC.parseFirmwareVersion(reply) ?? "?")")
        // Always find out what the TNC4 holds, even when the profile manages
        // nothing yet: a setting changed later (the level assistant, a slider)
        // must be restorable, and reading then would stop a measurement.
        startLevelRead()
    }

    private func startLevelRead() {
        phase = .readingLevels
        levelReport = MobilinkdDeviceState()
        startSessionTimer(after: Self.levelReadTimeout) { [weak self] in self?.levelReadTimedOut() }
        hooks.writeSequence(MobilinkdSession.readRequests) {}
    }

    private func levelsRead(_ current: MobilinkdSettings) {
        cancelSessionTimer()
        // Keep the first reading: after a drop and reconnect the TNC4 still
        // holds what this link set, not what the owner had.
        if levelsFound == nil { levelsFound = current }
        let found = levelsFound ?? current
        let wanted = hooks.wanted()
        // Fields this link set before but the profile no longer manages go
        // back to what the TNC4 had; the rest go to the profile's values.
        let released = found.restricted(to: levelsApplied ?? MobilinkdSettings()).subtracting(wanted)
        let target = released.merging(wanted)
        levelsApplied = wanted.isEmpty ? nil : wanted
        hooks.log("TNC4 held \(current); setting \(target)")
        sendSessionFrames(MobilinkdSession.connectFrames(wanted: target, found: current)) { [weak self] in
            guard let self, !self.hooks.isConnected() else { return }
            self.hooks.ready()
        }
    }

    /// Without knowing what the TNC4 held, changing it would leave it changed
    /// for good, so change nothing and carry on with its own settings.
    private func levelReadTimedOut() {
        hooks.log("TNC4 did not report its settings; leaving them as they are")
        sendSessionFrames(MobilinkdSession.connectFrames(wanted: nil, found: nil)) { [weak self] in
            guard let self, !self.hooks.isConnected() else { return }
            self.hooks.ready()
        }
    }

    private func sendSessionFrames(_ frames: [Data], then completion: (() -> Void)? = nil) {
        guard !frames.isEmpty else { completion?(); return }
        phase = .applying
        hooks.writeSequence(frames) { [weak self] in
            guard let self else { return }
            if self.phase == .applying { self.phase = .idle }
            completion?()
        }
    }

    // MARK: Inbound

    /// Watch a copy of the inbound stream for replies the session is waiting
    /// on. The transport still delivers everything to its delegate.
    func observe(_ data: Data) {
        let recording = sampling?.streaming == true
        guard phase == .probing || phase == .readingLevels || recording else {
            parser.reset()
            return
        }
        for frame in parser.feedFrames(data) {
            guard case .mobilinkdTelemetry(let hardware) = frame.output else { continue }
            if recording, phase == .idle {
                if case .inputLevel(let level) = MobilinkdReply.parse(hardware) { recordLevel(level) }
                continue
            }
            switch phase {
            case .probing where MobilinkdSession.isProbeReply(hardware):
                probeAnswered(hardware)
            case .readingLevels:
                if let reply = MobilinkdReply.parse(hardware) { levelReport.apply(reply) }
                if let levels = MobilinkdSettings(reportedBy: levelReport) { levelsRead(levels) }
            default:
                break
            }
        }
    }

    // MARK: Live changes

    /// The profile's settings changed while the link is up.
    func wantedChanged(from old: MobilinkdSettings) {
        let wanted = hooks.wanted()
        guard isMobilinkd, old != wanted else { return }
        // A recording taken across a settings change measures two things at
        // once. End it (with its RESET) before sending the change.
        if sampling != nil { finishSampling(.interrupted) }
        guard let found = levelsFound else {
            startLevelRead()
            return
        }
        // Fields the profile stopped managing go back to what the TNC4 had;
        // the rest go to the profile's values.
        let current = found.merging(levelsApplied)
        let released = found.restricted(to: levelsApplied ?? MobilinkdSettings()).subtracting(wanted)
        var frames = MobilinkdSettings.frames(toReach: released.merging(wanted), from: current)
        if activity == .measuring {
            // An input gain or twist change restarts the level stream by
            // itself; the usual RESET would end the measurement instead.
            frames.removeAll { $0 == Data(MobilinkdTNC.reset()) }
        }
        sendSessionFrames(frames)
        levelsApplied = wanted.isEmpty ? nil : wanted
    }

    // MARK: Closing

    /// What to send before the link goes down: unkey a test tone, end a
    /// measurement, and put back every setting this link changed. Empty when
    /// there is nothing to do.
    func closingFrames() -> [Data] {
        var frames = MobilinkdSession.restoreFrames(applied: levelsApplied, found: levelsFound)
        let reset = Data(MobilinkdTNC.reset())
        switch activity {
        case .sendingTone:
            // Unkey first: a TNC4 left sending a tone keeps the radio keyed.
            frames.insert(Data(MobilinkdTNC.stopTX()), at: 0)
            if frames.last != reset { frames.append(reset) }
        case .measuring:
            if frames.last != reset { frames.append(reset) }
        case .sampling:
            if sampling?.streaming == true, frames.last != reset { frames.append(reset) }
        case .idle:
            break
        }
        // The RESET, if one is needed, goes out with the frames above.
        if sampling != nil { finishSampling(.disconnected, sendReset: false) }
        endActivity()
        cancelSessionTimer()
        guard isMobilinkd, !frames.isEmpty, phase != .restoring else { return [] }
        phase = .restoring
        return frames
    }

    /// One connection ended. What the TNC4 held (`levelsFound`) survives, so
    /// a link that drops and reconnects can still put it back at the end.
    func connectionEnded() {
        cancelSessionTimer()
        // Nothing can be written now. A new connection restarts the
        // demodulator, and its connect sequence ends with RESET anyway.
        if sampling != nil { finishSampling(.disconnected, sendReset: false) }
        endActivity()
        phase = .idle
        parser.reset()
        levelReport = MobilinkdDeviceState()
        isMobilinkd = false
    }

    /// The link closed on purpose; there is nothing left to put back.
    func linkClosed() {
        connectionEnded()
        levelsFound = nil
        levelsApplied = nil
    }

    // MARK: Controls

    func refreshStatus() {
        guard isMobilinkd, activity == .idle else { return }
        hooks.writeSequence(MobilinkdSession.statusRequests) {}
    }

    func startMeasuring() {
        guard isMobilinkd, activity == .idle else { return }
        beginActivity(.measuring, for: MobilinkdTNC.maxMeasuringSeconds) { [weak self] in self?.stopMeasuring() }
        hooks.write(Data(MobilinkdTNC.streamInputLevel()))
    }

    func stopMeasuring() {
        guard activity == .measuring else { return }
        endActivity()
        hooks.write(Data(MobilinkdTNC.reset()))
    }

    func startTone(_ tone: MobilinkdTestTone, for seconds: TimeInterval) {
        guard isMobilinkd else { return }
        if sampling != nil { finishSampling(.interrupted) }
        // A measurement streams on the same audio task; end it first.
        let preface: [UInt8] = activity == .measuring ? MobilinkdTNC.reset() : []
        beginActivity(.sendingTone(tone), for: max(1, seconds)) { [weak self] in self?.stopTone() }
        hooks.write(Data(preface + tone.frame))
    }

    func stopTone() {
        guard case .sendingTone = activity else { return }
        endActivity()
        hooks.write(Data(MobilinkdTNC.stopTX() + MobilinkdTNC.reset()))
    }

    func save() {
        guard isMobilinkd else { return }
        hooks.write(Data(MobilinkdTNC.saveEEPROM()))
        // What the TNC4 starts with is now what this link set, so closing has
        // nothing to put back.
        if let found = levelsFound { levelsFound = found.merging(levelsApplied) }
    }

    // MARK: Timed recordings

    /// A recording in progress: waiting for a transmission, waiting for it to
    /// end, or streaming.
    private struct Sampling {
        let request: LevelSampleRequest
        let completion: @Sendable (LevelSampleResult) -> Void
        /// When the TNC4 should be done sending, once a frame has gone out.
        var transmitEnds: Date?
        var streaming = false
        var reference: Date?
        var streamAskedAt: Date?
        var lastReportAt: Date?
        var endsAt: Date?
        var samples: [TNC4LevelSample] = []
        var restarts = 0
    }

    private var sampling: Sampling?
    private var samplingTimer: DispatchSourceTimer?
    private var samplingWatch: DispatchSourceTimer?

    /// A stream that has sent nothing for this long has stopped. The TNC4
    /// reports ten times a second, so 0.7 s is seven missed reports.
    static let streamGapSeconds: TimeInterval = 0.7
    /// Ask again at most this often. A transmission ending mid-recording
    /// (CSMA holding ours longer than estimated) stops the stream once;
    /// twice is already odd.
    static let maxStreamRestarts = 2
    /// Longest a recording may stream, whatever it was asked for.
    static let maxSamplingSeconds: TimeInterval = 30

    func sampleLevels(_ request: LevelSampleRequest,
                      completion: @escaping @Sendable (LevelSampleResult) -> Void) {
        guard isMobilinkd, activity == .idle, phase == .idle, sampling == nil else {
            completion(.unavailable())
            return
        }
        lock.lock()
        _activity = .sampling
        lock.unlock()
        sampling = Sampling(request: request, completion: completion)
        switch request.start {
        case .now:
            hooks.log("Level sample: \(String(format: "%.1f", request.duration)) s, starting now")
            startStream(reference: hooks.now())
        case .afterNextTransmission(_, _, let armTimeout):
            hooks.log("Level sample: waiting for the next transmission")
            scheduleSampling(after: armTimeout) { [weak self] in
                guard let self, let s = self.sampling, s.transmitEnds == nil else { return }
                self.hooks.log("Level sample: nothing was sent within \(Int(armTimeout)) s")
                self.finishSampling(.noTransmission)
            }
        }
    }

    func cancelSampling() {
        guard sampling != nil else { return }
        finishSampling(.cancelled)
    }

    /// The link is about to write `data` to the TNC. A data frame is the
    /// transmission a recording waits for, or one that spoils a recording
    /// already streaming.
    func willSend(_ data: Data) {
        guard var s = sampling else { return }
        let lengths = TNC4Airtime.dataFrameLengths(in: data)
        guard !lengths.isEmpty else { return }
        if s.streaming {
            // Stop the stream before the frame reaches the TNC4, so its
            // demodulator is running again for CSMA. Keying up would end the
            // stream anyway.
            hooks.log("Level sample: a frame went out mid-recording; stopping")
            finishSampling(.interrupted)
            return
        }
        guard case .afterNextTransmission(let timing, let delay, _) = s.request.start else { return }
        let now = hooks.now()
        // Frames queued back to back go out in one transmission, with one
        // preamble.
        var airtime = 0.0
        for (index, bytes) in lengths.enumerated() {
            airtime += TNC4Airtime.transmitSeconds(frameBytes: bytes, timing: timing)
            if index > 0 || s.transmitEnds != nil {
                airtime -= Double(max(0, timing.txDelayMs)) / 1000
            }
        }
        let start = max(s.transmitEnds ?? now.addingTimeInterval(TNC4Airtime.linkLatency), now)
        let ends = start.addingTimeInterval(airtime)
        s.transmitEnds = ends
        sampling = s
        let untilEnd = ends.timeIntervalSince(now)
        hooks.log("Level sample: transmission ends in about \(String(format: "%.2f", untilEnd)) s; "
                  + "streaming from \(String(format: "%.1f", delay)) s after that")
        scheduleSampling(after: max(0, untilEnd + delay)) { [weak self] in
            guard let self, self.sampling?.streaming == false else { return }
            self.startStream(reference: ends)
        }
    }

    private func startStream(reference: Date) {
        guard var s = sampling else { return }
        let now = hooks.now()
        let duration = min(s.request.duration, Self.maxSamplingSeconds)
        s.streaming = true
        s.reference = reference
        s.streamAskedAt = now
        s.endsAt = now.addingTimeInterval(duration)
        sampling = s
        parser.reset()
        hooks.write(Data(MobilinkdTNC.streamInputLevel()))
        scheduleSampling(after: duration) { [weak self] in self?.finishSampling(.completed) }
        startSamplingWatch()
    }

    private func recordLevel(_ level: MobilinkdInputLevel) {
        guard var s = sampling, s.streaming, let reference = s.reference else { return }
        let now = hooks.now()
        s.samples.append(TNC4LevelSample(t: now.timeIntervalSince(reference), level: level))
        s.lastReportAt = now
        sampling = s
    }

    /// Ask for the stream again if it has gone quiet with time left: the
    /// TNC4 ends a stream whenever it keys up or unkeys.
    private func checkStream() {
        guard var s = sampling, s.streaming, let endsAt = s.endsAt else { return }
        let now = hooks.now()
        let last = s.lastReportAt ?? s.streamAskedAt ?? now
        guard now.timeIntervalSince(last) >= Self.streamGapSeconds,
              endsAt.timeIntervalSince(now) > 1.0,
              s.restarts < Self.maxStreamRestarts else { return }
        s.restarts += 1
        s.streamAskedAt = now
        s.lastReportAt = nil
        sampling = s
        hooks.log("Level sample: the stream stopped; asking again (\(s.restarts))")
        hooks.write(Data(MobilinkdTNC.streamInputLevel()))
    }

    /// End the recording, hand back what it got, and put the TNC4 back to
    /// decoding. Every way out of a recording comes through here.
    private func finishSampling(_ outcome: LevelSampleResult.Outcome, sendReset: Bool = true) {
        guard let s = sampling else { return }
        sampling = nil
        samplingTimer?.cancel()
        samplingTimer = nil
        samplingWatch?.cancel()
        samplingWatch = nil
        if s.streaming, sendReset {
            hooks.write(Data(MobilinkdTNC.reset()))
        }
        endActivity()
        hooks.log("Level sample ended (\(outcome)): \(s.samples.count) reports, \(s.restarts) restarts")
        s.completion(LevelSampleResult(outcome: outcome, samples: s.samples, restarts: s.restarts))
    }

    private func scheduleSampling(after seconds: TimeInterval, _ handler: @escaping () -> Void) {
        samplingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: hooks.queue)
        timer.schedule(deadline: .now() + max(0, seconds))
        timer.setEventHandler(handler: handler)
        samplingTimer = timer
        timer.resume()
    }

    private func startSamplingWatch() {
        samplingWatch?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: hooks.queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in self?.checkStream() }
        samplingWatch = timer
        timer.resume()
    }

    // MARK: Timers

    private func beginActivity(_ activity: MobilinkdActivity, for seconds: TimeInterval,
                               onTimeout: @escaping () -> Void) {
        activityTimer?.cancel()
        lock.lock()
        _activity = activity
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: hooks.queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: onTimeout)
        activityTimer = timer
        timer.resume()
    }

    private func endActivity() {
        activityTimer?.cancel()
        activityTimer = nil
        lock.lock()
        _activity = .idle
        lock.unlock()
    }

    private func startSessionTimer(after seconds: TimeInterval, _ handler: @escaping () -> Void) {
        cancelSessionTimer()
        let timer = DispatchSource.makeTimerSource(queue: hooks.queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: handler)
        sessionTimer = timer
        timer.resume()
    }

    private func cancelSessionTimer() {
        sessionTimer?.cancel()
        sessionTimer = nil
    }
}
