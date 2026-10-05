//
//  ReceiveLevelMonitor.swift
//  AXTerm
//
//  Per-radio receive-level tuning for Mobilinkd TNC4 radios: calibration on
//  request, a short level check every half hour, and the findings the radio
//  page and the TNC menu show. The rules live in the pure types beside this
//  file; this runs them against the live links. See Docs/MobilinkdTNC4.md,
//  "Receive-level calibration" and "Drift watch".
//

import Combine
import Foundation

@MainActor
final class ReceiveLevelMonitor: ObservableObject {

    /// What the monitor needs from the rest of the app, as closures so the
    /// tests can stand in for the links and the beacon.
    struct Dependencies {
        /// The radio's live TNC4 controls, when its link is up and the TNC is
        /// a Mobilinkd.
        var control: (RadioID) -> MobilinkdControlling?
        var profile: (RadioID) -> RadioProfile?
        /// Radios whose link is up.
        var connectedRadios: () -> [RadioID]
        /// The later of the radio's last received and last sent frame.
        var lastActivity: (RadioID) -> Date?
        /// The input gain step the TNC4 is using for this radio.
        var currentGain: (RadioID) -> Int
        var gainRange: (RadioID) -> ClosedRange<Int>
        /// Set the radio's managed input gain (nil hands it back to the TNC4).
        /// The link applies it live and restores the TNC4's own on disconnect.
        var setManagedGain: (RadioID, Int?) -> Void
        /// Send the radio's own beacon through the usual beacon path. Nil
        /// when it went, or why it didn't.
        var sendBeacon: (RadioID) -> String?
        /// A line in the console, attributed to the radio.
        var notify: (String, RadioID) -> Void
        var log: (String, [String: String]) -> Void
        var store: ReceiveLevelStore
        var now: () -> Date = { Date() }
        var random: () -> Double = { Double.random(in: 0..<1) }
    }

    // MARK: Timing

    /// Half an hour between level checks. Each check leaves the TNC4 unable
    /// to decode for about 2 s, so this costs about 0.1% of the time.
    static let watchInterval: TimeInterval = 30 * 60
    /// ±5 minutes, so several radios, or several stations running AXTerm,
    /// don't all go deaf at the same moment.
    static let watchJitter: TimeInterval = 5 * 60
    /// The first check comes two to three minutes after connecting, once the
    /// TNC4 has settled from the connect sequence.
    static let firstWatchDelay: TimeInterval = 2 * 60
    static let sampleSeconds: TimeInterval = 2
    /// No check within 5 s of a frame received or sent: the channel is busy,
    /// or a reply may be on its way.
    static let quietBefore: TimeInterval = 5
    /// How often the watch looks at the radios.
    static let tickInterval: TimeInterval = 30

    /// Calibration listens from 0.3 s to 6 s after our beacon ends. A
    /// fill-in digipeater answers within a second or so, a wide one within
    /// five; the TNC4's own unkey restarts the demodulator, and the stream
    /// must not start before that.
    static let calibrationDelay: TimeInterval = 0.3
    static let calibrationSeconds: TimeInterval = 5.7
    /// The beacon should reach the TNC4 within 10 s of asking for it.
    static let beaconArmTimeout: TimeInterval = 10

    // MARK: State

    enum CalibrationState: Equatable {
        case running(String)
        case finished(CalibrationReport)
    }

    struct CalibrationReport: Equatable {
        let at: Date
        let succeeded: Bool
        let message: String
        let evidence: [String]
        /// The managed gain before, for Undo. `.some(nil)` means the TNC4's own.
        let previousGain: Int??
        let previousBaseline: ReceiveLevelBaseline?

        var help: String { ([message] + evidence).joined(separator: "\n") }
    }

    @Published private(set) var calibrations: [RadioID: CalibrationState] = [:]
    /// Moves on whenever a record changes, so views that read records redraw.
    @Published private(set) var revision = 0
    /// Not published: views read records while drawing, and loading one on
    /// first read must not publish a change mid-draw.
    private var cache: [RadioID: ReceiveLevelRecord] = [:]

    private let deps: Dependencies
    private var nextWatchAt: [RadioID: Date] = [:]
    private var watching: Set<RadioID> = []
    /// Radios taking a sample for the tuning wizard. Published through
    /// `revision`.
    private var listening: Set<RadioID> = []
    private var lastFindingMessage: [RadioID: String] = [:]
    /// No deinit to invalidate it: an isolated deinit on a main-actor class
    /// has crashed the test runner on this toolchain (see SessionCoordinator).
    /// The timer holds the monitor weakly and does nothing once it is gone.
    private var timer: Timer?

    init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// Start the half-hourly watch. Idempotent.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Records

    func record(_ radio: RadioID) -> ReceiveLevelRecord {
        if let cached = cache[radio] { return cached }
        let loaded = deps.store.load(radio)
        cache[radio] = loaded
        return loaded
    }

    private func update(_ radio: RadioID, _ change: (inout ReceiveLevelRecord) -> Void) {
        var r = record(radio)
        change(&r)
        cache[radio] = r
        deps.store.save(r, for: radio)
        revision &+= 1
    }

    func setWatchEnabled(_ on: Bool, for radio: RadioID) {
        update(radio) { $0.watchEnabled = on }
        if !on { nextWatchAt[radio] = nil }
        deps.log("Receive level watch \(on ? "on" : "off")", ["radio": radio.rawValue])
    }

    /// Whether a calibration or level check is running on the radio.
    func isBusy(_ radio: RadioID) -> Bool {
        if case .running = calibrations[radio] { return true }
        return watching.contains(radio) || listening.contains(radio)
    }

    /// When the next calibration beacon may go out, or nil if now.
    func nextCalibrationAllowed(_ radio: RadioID) -> Date? {
        CalibrationBeaconLimit.nextAllowed(after: record(radio).lastCalibrationBeaconAt, now: deps.now())
    }

    func dismissCalibration(_ radio: RadioID) {
        if case .finished = calibrations[radio] { calibrations[radio] = nil }
    }

    // MARK: Calibration

    /// Calibrate an APRS radio: send its beacon once, listen for the
    /// digipeats, and set the input gain from how loud they arrive.
    func calibrate(_ radio: RadioID) {
        guard !isBusy(radio) else { return }
        let now = deps.now()
        guard let profile = deps.profile(radio) else { return }
        guard profile.handlesAPRS else {
            finish(radio, failure: "Calibration sends a beacon, so it only runs on an APRS radio. "
                   + "On a packet channel AXTerm recommends a gain from packets it hears during level checks.")
            return
        }
        guard let control = deps.control(radio) else {
            finish(radio, failure: "Connect the radio first.")
            return
        }
        if let next = nextCalibrationAllowed(radio) {
            let last = record(radio).lastCalibrationBeaconAt ?? now
            finish(radio, failure: "The last calibration beacon went out at \(Self.time(last)). "
                   + "To keep the channel clear, the next can go at \(Self.time(next)).")
            return
        }
        guard control.mobilinkdActivity == .idle else {
            finish(radio, failure: "The TNC4 is busy measuring or sending a tone. Try again when it's done.")
            return
        }

        let gain = deps.currentGain(radio)
        let range = deps.gainRange(radio)
        calibrations[radio] = .running("Sending a beacon\u{2026}")
        deps.log("Receive level calibration started", ["radio": radio.rawValue, "gain": "\(gain)"])

        let request = LevelSampleRequest(
            start: .afterNextTransmission(timing: profile.kissTiming, delay: Self.calibrationDelay,
                                          armTimeout: Self.beaconArmTimeout),
            duration: Self.calibrationSeconds)
        control.sampleInputLevels(request) { result in
            Task { @MainActor in self.calibrationRecorded(radio, gain: gain, range: range, result: result) }
        }
        if let obstacle = deps.sendBeacon(radio) {
            control.cancelInputSampling()
            finish(radio, failure: "The beacon wasn't sent: \(obstacle)")
            return
        }
        update(radio) { $0.lastCalibrationBeaconAt = now }
        calibrations[radio] = .running("Listening for digipeaters\u{2026}")
    }

    private func calibrationRecorded(_ radio: RadioID, gain: Int, range: ClosedRange<Int>,
                                     result: LevelSampleResult) {
        // A failure already reported (the beacon not going) wins.
        guard case .running = calibrations[radio] else { return }
        deps.log("Receive level calibration window ended",
                 ["radio": radio.rawValue, "outcome": "\(result.outcome)",
                  "reports": "\(result.samples.count)", "restarts": "\(result.restarts)"])
        switch result.outcome {
        case .noTransmission:
            finish(radio, failure: "The beacon didn't reach the TNC4 within \(Int(Self.beaconArmTimeout)) s. Nothing was changed.")
            return
        case .unavailable:
            finish(radio, failure: "The TNC4 was busy. Nothing was changed.")
            return
        case .disconnected:
            finish(radio, failure: "The radio disconnected. Nothing was changed.")
            return
        case .cancelled:
            finish(radio, failure: "Canceled. Nothing was changed.")
            return
        case .completed, .interrupted:
            break
        }

        let reading = ReceiveLevelAnalysis.read(result.samples, quietFrom: ReceiveLevelAnalysis.unkeySettleSeconds)
        let now = deps.now()
        switch ReceiveLevelAnalysis.calibrate(reading, gain: gain, range: range) {
        case .noReports:
            finish(radio, failure: "The TNC4 sent no levels. Nothing was changed.")
        case .nothingHeard(let reports):
            let next = Self.time(now.addingTimeInterval(CalibrationBeaconLimit.minimumInterval))
            finish(radio, failure: "No digipeater was heard in the \(Int(Self.calibrationSeconds + Self.calibrationDelay)) s after the beacon, so nothing was changed. "
                   + "Try again after \(next), or check the radio's volume, squelch and antenna.",
                   evidence: ["\(reports) level reports, none with a packet's shape (a carrier, then steady tones)."]
                        + noiseEvidence(reading))
        case .recommend(let rec, let packets, let noise):
            apply(rec, radio: radio, packets: packets, noise: noise, reading: reading, at: now,
                  source: .beacon)
        }
    }

    /// Set the recommended gain, record the baseline, and report.
    private func apply(_ rec: ReceiveGainAdvice.Recommendation, radio: RadioID, packets: Int, noise: Int?,
                       reading: ReceiveLevelAnalysis.Reading?, at now: Date,
                       source: ReceiveLevelBaseline.Source) {
        let profile = deps.profile(radio)
        let previousGain: Int?? = .some(profile?.tnc4.inputGain)
        let previousBaseline = record(radio).baseline
        if profile?.tnc4.inputGain != rec.gain {
            deps.setManagedGain(radio, rec.gain)
        }
        let baseline = ReceiveLevelAnalysis.baseline(rec, packets: packets, noiseVpp: noise, at: now, source: source)
        update(radio) { r in
            r.baseline = baseline
            if let reading {
                r.add(ReceiveLevelAnalysis.packetLevels(reading, at: now, gain: rec.measuredGain))
            }
        }
        let what = source == .beacon
            ? (packets == 1 ? "1 digipeat" : "\(packets) digipeats")
            : (packets == 1 ? "1 packet" : "\(packets) packets")
        let heard = "Heard \(what) at \(ReceiveGainAdvice.percent(rec.measuredFraction))\(rec.measuredClipped ? " (clipped)" : "") "
            + "at \(ReceiveGainAdvice.gainText(rec.measuredGain))."
        let lead: String
        switch rec.action {
        case .keep(let g): lead = "Kept \(ReceiveGainAdvice.gainText(g))."
        case .set(let g), .turnVolumeUp(let g), .turnVolumeDown(let g):
            lead = rec.gain == rec.measuredGain ? "Kept \(ReceiveGainAdvice.gainText(g))." : "Set to \(ReceiveGainAdvice.gainText(g))."
        }
        let message = "\(lead) \(heard) \(ReceiveGainAdvice.advice(rec))"
        var evidence: [String] = []
        if let reading {
            for seg in reading.segments {
                evidence.append(String(format: "Packet at +%.1f s: %@ for %.1f s, after a carrier at %@%@%@.",
                                       seg.start, ReceiveLevelFinding.percent(seg.toneVpp), seg.duration + 0.1,
                                       ReceiveLevelFinding.percent(seg.carrierVpp), seg.clipped ? ", clipped" : "",
                                       seg.onsetClipped ? "; its first 0.1 s clipped and was left out, as the start of the transmission" : ""))
            }
            evidence += noiseEvidence(reading)
            if source == .beacon {
                evidence.append("Packets heard in the 6 s after the beacon are taken as its digipeats. Any packet serves to measure the level.")
            }
        }
        evidence.append("Aim: packets near \(ReceiveGainAdvice.percent(ReceiveGainAdvice.targetFraction)) of full scale, "
                        + "never above \(ReceiveGainAdvice.percent(ReceiveGainAdvice.ceilingFraction)). Each gain step doubles the level.")
        let report = CalibrationReport(at: now, succeeded: true, message: message, evidence: evidence,
                                       previousGain: previousGain, previousBaseline: previousBaseline)
        calibrations[radio] = .finished(report)
        let name = Self.radioName(profile)
        deps.notify("Receive level on \(name): \(message)", radio)
        deps.log("Receive level calibration applied",
                 ["radio": radio.rawValue, "measuredGain": "\(rec.measuredGain)", "gain": "\(rec.gain)",
                  "toneVpp": "\(rec.measuredVpp)", "packets": "\(packets)", "source": source.rawValue])
    }

    private func noiseEvidence(_ reading: ReceiveLevelAnalysis.Reading) -> [String] {
        guard let noise = reading.noiseVpp else { return [] }
        return ["Between packets the input sat at \(ReceiveLevelFinding.percent(noise))."]
    }

    private func finish(_ radio: RadioID, failure message: String, evidence: [String] = []) {
        calibrations[radio] = .finished(CalibrationReport(at: deps.now(), succeeded: false, message: message,
                                                          evidence: evidence, previousGain: nil,
                                                          previousBaseline: nil))
        deps.log("Receive level calibration ended without a change", ["radio": radio.rawValue, "why": message])
    }

    /// Put back the gain and baseline from before the last calibration.
    func undoCalibration(_ radio: RadioID) {
        guard case .finished(let report) = calibrations[radio], report.succeeded,
              let previous = report.previousGain else { return }
        deps.setManagedGain(radio, previous)
        update(radio) { $0.baseline = report.previousBaseline }
        calibrations[radio] = nil
        deps.log("Receive level calibration undone", ["radio": radio.rawValue])
    }

    // MARK: Passive (packet channels)

    /// A recommendation from packets caught during level checks, when enough
    /// have been.
    func passiveAdvice(for radio: RadioID) -> ReceiveLevelAnalysis.Passive? {
        ReceiveLevelAnalysis.passive(record(radio).packetLevels, currentGain: deps.currentGain(radio),
                                     range: deps.gainRange(radio), now: deps.now())
    }

    func applyPassive(_ radio: RadioID) {
        guard !isBusy(radio), let advice = passiveAdvice(for: radio) else { return }
        apply(advice.recommendation, radio: radio, packets: advice.packets, noise: nil, reading: nil,
              at: deps.now(), source: .passive)
    }

    func useGain(_ gain: Int, for radio: RadioID) {
        deps.setManagedGain(radio, gain)
        deps.log("Receive level: gain set from a finding", ["radio": radio.rawValue, "gain": "\(gain)"])
    }

    // MARK: Findings

    /// What looks wrong with the radio's receive level, or nil.
    func finding(for radio: RadioID, now: Date? = nil) -> ReceiveLevelFinding? {
        guard deps.control(radio) != nil, let profile = deps.profile(radio) else { return nil }
        let r = record(radio)
        let name = Self.radioName(profile)
        if let drift = ReceiveLevelDrift.assess(baseline: r.baseline, observations: r.observations,
                                                range: deps.gainRange(radio)) {
            return .level(drift, radioName: name, onAPRS: profile.handlesAPRS)
        }
        if r.baseline == nil, let pinned = ReceiveLevelDrift.assessUncalibrated(observations: r.observations) {
            return .pinned(pinned, radioName: name)
        }
        if profile.handlesAPRS, let missing = r.digipeats.assess(now: now ?? deps.now()) {
            return .digipeats(missing, radioName: name)
        }
        return nil
    }

    // MARK: Digipeat evidence

    /// This radio sent a frame. Counts when it is a UI frame through a
    /// digipeater path on an APRS radio.
    func noteTransmitted(radio: RadioID, isUI: Bool, viaDigipeaters: Bool, at date: Date) {
        // Not while calibrating: the TNC4 isn't decoding then, so the
        // calibration beacon's digipeats are measured, never heard, and would
        // count as a frame nobody repeated.
        guard isUI, viaDigipeaters, !isBusy(radio), deps.profile(radio)?.handlesAPRS == true,
              deps.control(radio) != nil else { return }
        update(radio) { $0.digipeats.noteSent(at: date) }
    }

    /// A copy of one of our own frames came back on this radio, last
    /// repeated by `digipeater`.
    func noteEcho(radio: RadioID, digipeater: String, at date: Date) {
        guard deps.profile(radio)?.handlesAPRS == true else { return }
        var r = record(radio)
        guard r.digipeats.noteEcho(from: digipeater, at: date) else { return }
        cache[radio] = r
        deps.store.save(r, for: radio)
        revision &+= 1
    }

    // MARK: Drift watch

    /// Look at each connected TNC4 radio and take a level check where one
    /// is due. Public for the tests; the timer calls it every 30 s.
    func tick() {
        let now = deps.now()
        let connected = deps.connectedRadios()
        for radio in nextWatchAt.keys where !connected.contains(radio) { nextWatchAt[radio] = nil }
        for radio in connected {
            guard let control = deps.control(radio) else { continue }
            reportFindingChange(radio, now: now)
            guard record(radio).watchEnabled, !isBusy(radio) else { continue }
            guard let due = nextWatchAt[radio] else {
                nextWatchAt[radio] = now.addingTimeInterval(Self.firstWatchDelay + deps.random() * 60)
                continue
            }
            guard now >= due else { continue }
            guard control.mobilinkdActivity == .idle else {
                nextWatchAt[radio] = now.addingTimeInterval(60)
                continue
            }
            if let last = deps.lastActivity(radio), now.timeIntervalSince(last) < Self.quietBefore {
                nextWatchAt[radio] = now.addingTimeInterval(20)
                continue
            }
            let gain = deps.currentGain(radio)
            watching.insert(radio)
            deps.log("Receive level check started", ["radio": radio.rawValue, "gain": "\(gain)"])
            control.sampleInputLevels(.now(for: Self.sampleSeconds)) { result in
                Task { @MainActor in self.watchRecorded(radio, gain: gain, result: result) }
            }
        }
    }

    private func watchRecorded(_ radio: RadioID, gain: Int, result: LevelSampleResult) {
        watching.remove(radio)
        let now = deps.now()
        guard result.outcome == .completed else {
            // Try again soon; a frame going out or a setting changing is
            // ordinary.
            nextWatchAt[radio] = now.addingTimeInterval(5 * 60)
            deps.log("Receive level check ended early", ["radio": radio.rawValue, "outcome": "\(result.outcome)"])
            return
        }
        nextWatchAt[radio] = now.addingTimeInterval(Self.watchInterval + (deps.random() * 2 - 1) * Self.watchJitter)
        recordSample(radio, gain: gain, samples: result.samples, now: now)
    }

    /// Keep what a level sample showed: the observation, any packets in it,
    /// and the calibration's missing noise floor if this sample has it.
    private func recordSample(_ radio: RadioID, gain: Int, samples: [TNC4LevelSample], now: Date) {
        let reading = ReceiveLevelAnalysis.read(samples)
        let obs = ReceiveLevelAnalysis.observation(reading, at: now, gain: gain)
        update(radio) { r in
            r.add(obs)
            r.add(ReceiveLevelAnalysis.packetLevels(reading, at: now, gain: gain))
            if let base = r.baseline, let filled = ReceiveLevelAnalysis.completing(base, with: obs) {
                r.baseline = filled
            }
        }
        deps.log("Receive level check",
                 ["radio": radio.rawValue, "gain": "\(gain)", "reports": "\(reading.reports)",
                  "noiseVpp": reading.noiseVpp.map(String.init) ?? "none",
                  "clipped": String(format: "%.2f", reading.clippedShare),
                  "packets": "\(reading.segments.count)"])
        reportFindingChange(radio, now: now)
    }

    // MARK: Tuning wizard

    /// The longest the wizard listens in one go. The TNC4 decodes nothing
    /// meanwhile, and the session driver caps a recording at 30 s anyway.
    static let maxListenSeconds: TimeInterval = 30

    func isListening(_ radio: RadioID) -> Bool { listening.contains(radio) }

    /// Listen for other stations' packets now, for the tuning wizard's
    /// packet check on a packet channel. Recorded the way a level check is,
    /// so the packets count toward `passiveAdvice`.
    func listen(_ radio: RadioID, seconds: TimeInterval) {
        guard let control = deps.control(radio), control.mobilinkdActivity == .idle,
              !isBusy(radio) else { return }
        let gain = deps.currentGain(radio)
        listening.insert(radio)
        revision &+= 1
        let duration = min(seconds, Self.maxListenSeconds)
        deps.log("Receive level: listening for packets", ["radio": radio.rawValue, "gain": "\(gain)",
                                                          "seconds": "\(Int(duration))"])
        control.sampleInputLevels(.now(for: duration)) { result in
            Task { @MainActor in self.listened(radio, gain: gain, result: result) }
        }
    }

    private func listened(_ radio: RadioID, gain: Int, result: LevelSampleResult) {
        listening.remove(radio)
        defer { revision &+= 1 }
        guard result.outcome == .completed else {
            deps.log("Receive level: listening ended early", ["radio": radio.rawValue, "outcome": "\(result.outcome)"])
            return
        }
        recordSample(radio, gain: gain, samples: result.samples, now: deps.now())
    }

    /// A connected TNC4 radio that has never been tuned: no calibration and
    /// no input gain of its own. The radio page offers the wizard, until the
    /// radio is tuned or the operator says not now.
    func suggestsTuning(_ radio: RadioID) -> Bool {
        guard deps.control(radio) != nil, let profile = deps.profile(radio),
              profile.tnc4.inputGain == nil else { return false }
        let r = record(radio)
        return r.baseline == nil && !r.tuningSuggestionDismissed
    }

    func dismissTuningSuggestion(_ radio: RadioID) {
        update(radio) { $0.tuningSuggestionDismissed = true }
    }

    /// Log a finding when it appears, changes or clears, and put new ones in
    /// the console once.
    private func reportFindingChange(_ radio: RadioID, now: Date) {
        let message = finding(for: radio, now: now)?.message
        guard message != lastFindingMessage[radio] else { return }
        lastFindingMessage[radio] = message
        if let message {
            deps.log("Receive level finding", ["radio": radio.rawValue, "finding": message])
            deps.notify(message, radio)
        } else {
            deps.log("Receive level finding cleared", ["radio": radio.rawValue])
        }
    }

    // MARK: Words

    static func radioName(_ profile: RadioProfile?) -> String {
        guard let profile else { return "this radio" }
        return RadioDetailView.title(for: profile)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
