import Foundation
import Combine

typealias AdaptiveSessionID = String

nonisolated struct AdaptiveETXSample: Sendable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let etx: Double

    init(timestamp: Date, etx: Double) {
        self.id = UUID()
        self.timestamp = timestamp
        self.etx = etx
    }
}

nonisolated struct AdaptiveRingBuffer<Element: Sendable>: Sendable {
    let capacity: Int
    private(set) var storage: [Element]

    init(capacity: Int, storage: [Element] = []) {
        self.capacity = max(1, capacity)
        self.storage = Array(storage.suffix(max(1, capacity)))
    }

    var elements: [Element] { storage }
    var isEmpty: Bool { storage.isEmpty }
    var last: Element? { storage.last }

    mutating func append(_ element: Element) {
        storage.append(element)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    mutating func removeAll(where shouldRemove: (Element) -> Bool) {
        storage.removeAll(where: shouldRemove)
    }

    mutating func replaceLast(with element: Element) {
        guard !storage.isEmpty else {
            append(element)
            return
        }
        storage[storage.count - 1] = element
    }
}

/// What an open session is sending with right now, and why (spec §7.8.1).
///
/// The route's controller suggests K and paclen; the session runs them only
/// within its ceilings, merged with any other session to the same station,
/// and a larger K waits for the frames in flight to be acknowledged. So the
/// figure the status bar shows during a session comes from here.
nonisolated struct AdaptiveLiveLink: Sendable, Equatable {
    /// The K the session sends with now.
    let k: Int
    /// The paclen data is cut at now.
    let p: Int
    /// The most K may grow to on this link.
    let windowCeiling: Int
    /// The most paclen may grow to on this link.
    let paclenCeiling: Int
    /// A larger K waiting for the frames in flight to be acknowledged.
    let pendingK: Int?
    /// Where the session's starting values came from.
    let startSource: LinkStartSource
    /// The controller's reason for its latest change.
    let reason: String?

    /// Tooltip text: why the values are what they are (CLAUDE.md §11).
    var explanation: String {
        var lines = ["This session is sending with K\(k) P\(p)."]
        lines.append("Window: \(k) frames in flight at most. This link allows up to \(windowCeiling).")
        lines.append("Packet length: \(p) bytes. This link allows up to \(paclenCeiling).")
        if let pendingK {
            lines.append("A raise to K\(pendingK) is waiting until the frames in flight are acknowledged.")
        }
        lines.append(startSourceSentence)
        if let reason, !reason.isEmpty {
            lines.append("Last change: \(reason).")
        }
        lines.append("A run of clean frames earns one step, kept only if the next 10 frames are clean too. "
                     + "A retransmission halves the window and shortens packets at once. "
                     + "The ceilings are K=4 and 256 bytes direct, less per digipeater, "
                     + "and never more than the other station offered.")
        return lines.joined(separator: "\n")
    }

    private var startSourceSentence: String {
        switch startSource {
        case .configured:
            return "Started from your settings: nothing was confirmed for this station on this path in the last 24 hours."
        case .confirmed(let date):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Started from the values this link confirmed at \(formatter.string(from: date))."
        case .recentEvidence:
            return "Started from this route's own results in the last 30 minutes."
        case .channel:
            return "Started from this radio's figure: nothing was known about this route yet."
        case .merged:
            return "Another session to this station is open, so both use the smaller of their values."
        }
    }
}

nonisolated struct AdaptiveParams: Sendable, Equatable {
    /// The open session's live values, when one is up on this route. The
    /// status bar shows these rather than the controller's suggestion.
    var live: AdaptiveLiveLink? = nil
    /// K as the status bar shows it: the session's live K when a session is
    /// up, otherwise the route's learned value.
    var displayK: Int { live?.k ?? k }
    /// Paclen as the status bar shows it, in the same sense.
    var displayP: Int { live?.p ?? p }
    let k: Int
    let p: Int
    let n2: Int
    let rtoMin: Double
    let rtoMax: Double
    let currentRto: Double?
    let lossRate: Double?
    let etx: Double?
    let srtt: Double?
    let qualityLabel: String
    let updatedAt: Date
    let destination: String?
    let pathSignature: String?
    /// Which channel this figure is about. Nil for the operator's baseline,
    /// which belongs to no radio.
    let radio: RadioID?

    // Learning state — what the controller decides on and what it has done,
    // so the UI can show its work rather than bare verdicts.
    /// EWMA loss the controller's thresholds actually compare against.
    let smoothedLoss: Double?
    /// EWMA ETX ditto.
    let smoothedEtx: Double?
    /// Clean frames toward the next upgrade probe.
    let successStreak: Int
    /// Clean frames REQUIRED for the next probe (rises after failed probes).
    let upgradeStreakRequirement: Int
    /// Frames left in the current upgrade's probation trial; nil = no trial.
    let probationFramesRemaining: Int?
    /// Counters: samples, evidence, upgrades attempted/confirmed/rolled back.
    let metrics: AdaptiveLearningMetrics

    /// Derive the display record from the controller plus the raw sample that
    /// triggered the update.
    init(
        settings: TxAdaptiveSettings,
        lossRate: Double?,
        etx: Double?,
        srtt: Double?,
        updatedAt: Date,
        destination: String?,
        pathSignature: String?,
        radio: RadioID? = nil
    ) {
        self.k = settings.windowSize.effectiveValue
        self.p = settings.paclen.effectiveValue
        self.n2 = settings.maxRetries.effectiveValue
        self.rtoMin = settings.rtoMin.effectiveValue
        self.rtoMax = settings.rtoMax.effectiveValue
        self.currentRto = settings.currentRto
        self.lossRate = lossRate
        self.etx = etx
        self.srtt = srtt
        self.qualityLabel = settings.windowSize.displayReason ?? settings.paclen.displayReason ?? "Adaptive"
        self.updatedAt = updatedAt
        self.destination = destination
        self.pathSignature = pathSignature
        self.radio = radio
        self.smoothedLoss = settings.lossRateEWMA
        self.smoothedEtx = settings.etxEWMA
        self.successStreak = settings.successStreak
        self.upgradeStreakRequirement = settings.upgradeStreakRequirement
        self.probationFramesRemaining = settings.probation?.framesRemaining
        self.metrics = settings.metrics
    }
}

extension AdaptiveParams {
    /// One-line, plain-language account of what the controller is doing right
    /// now — trial in progress, streak building, or waiting for evidence.
    var learningNarrative: String {
        if let remaining = probationFramesRemaining {
            return "Upgrade on trial: \(remaining) clean frame\(remaining == 1 ? "" : "s") to confirm (any retransmit rolls it back)"
        }
        if successStreak > 0 {
            return "\(successStreak) of \(upgradeStreakRequirement) clean frames toward the next upgrade"
        }
        if metrics.samplesSeen == 0 {
            return "Waiting for evidence: no connected-mode traffic to learn from yet"
        }
        return qualityLabel
    }

    /// One-line count of the controller's actions, for the popover footer.
    var activitySummary: String {
        var parts: [String] = []
        if metrics.upgradesAttempted > 0 {
            let confirmed = metrics.upgradesConfirmed
            parts.append("\(metrics.upgradesAttempted) upgrade\(metrics.upgradesAttempted == 1 ? "" : "s") (\(confirmed) confirmed)")
        }
        if metrics.probeRollbacks > 0 {
            parts.append("\(metrics.probeRollbacks) rolled back")
        }
        if metrics.lossDowngrades > 0 {
            parts.append("\(metrics.lossDowngrades) loss downgrade\(metrics.lossDowngrades == 1 ? "" : "s")")
        }
        guard !parts.isEmpty else {
            return metrics.samplesSeen == 0
                ? "No activity yet"
                : "No parameter changes over \(metrics.evidenceFrames) observed frame\(metrics.evidenceFrames == 1 ? "" : "s")"
        }
        return parts.joined(separator: " · ")
    }
}

final class AdaptiveStatusStore: ObservableObject {
    @Published var globalAdaptive: AdaptiveParams?
    @Published var sessionAdaptiveByID: [AdaptiveSessionID: AdaptiveParams] = [:]
    @Published var selectedSessionID: AdaptiveSessionID?
    /// Which channel to show when the operator has not selected a session.
    ///
    /// `globalAdaptive` is the operator's baseline — the configured settings,
    /// which belong to no radio and never see a link sample. Showing it as the
    /// live figure meant the toolbar read "All channels" with no ETX, no loss
    /// and "no qualifying link samples yet" while both radios were learning
    /// and saying so in the log. The default is a real channel, named.
    @Published var defaultChannelID: AdaptiveSessionID?
    @Published var globalETXHistory = AdaptiveRingBuffer<AdaptiveETXSample>(capacity: 900)
    @Published var sessionETXHistoryByID: [AdaptiveSessionID: AdaptiveRingBuffer<AdaptiveETXSample>] = [:]

    /// Live values of open sessions, by the same ID as their route's figure.
    /// Kept apart so a route update (which rebuilds the figure from the
    /// controller) does not drop them.
    private var liveLinkByID: [AdaptiveSessionID: AdaptiveLiveLink] = [:]

    /// One hour of network history: samples land at most every 30 s, and the
    /// events that move channel ETX (a net, a mail forward, propagation) run
    /// tens of minutes — a shorter window shows an event's tail with no
    /// baseline before it. Matches the dashboard's 1h timeframe.
    private let globalWindow: TimeInterval = 60 * 60
    /// Per-session samples arrive per-frame; sessions are short-lived and the
    /// controller has already digested anything older than this.
    private let sessionWindow: TimeInterval = 10 * 60
    private let minSampleSpacing: TimeInterval = 2

    /// Explicit nonisolated deinit to avoid Swift concurrency runtime bug
    /// where isolated deallocating deinit triggers task-local scope corruption.
    nonisolated deinit {}

    /// The scope the UI is showing: the operator's selection if it has a
    /// figure, else the default channel, else nothing (the baseline).
    var effectiveScopeID: AdaptiveSessionID? {
        if let selectedSessionID, sessionAdaptiveByID[selectedSessionID] != nil {
            return selectedSessionID
        }
        if let defaultChannelID, sessionAdaptiveByID[defaultChannelID] != nil {
            return defaultChannelID
        }
        return nil
    }

    var effectiveAdaptive: AdaptiveParams? {
        if let id = effectiveScopeID, let scoped = sessionAdaptiveByID[id] {
            return scoped
        }
        return globalAdaptive
    }

    /// Radios carrying APRS and nothing else, which the tuner cannot learn
    /// from.
    ///
    /// Kept so the popover can name them. A radio with no adaptive figure is
    /// otherwise indistinguishable from one that is broken, and an APRS radio
    /// will never have a figure however long the operator waits for one.
    @Published var radiosCarryingOnlyAPRS: [RadioID] = []

    func setRadiosCarryingOnlyAPRS(_ radios: [RadioID]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setRadiosCarryingOnlyAPRS(radios) }
            return
        }
        guard radiosCarryingOnlyAPRS != radios else { return }
        radiosCarryingOnlyAPRS = radios
    }

    func setDefaultChannel(id: AdaptiveSessionID?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setDefaultChannel(id: id) }
            return
        }
        guard defaultChannelID != id else { return }
        defaultChannelID = id
    }

    /// The timespan the ETX chart covers for the current scope — surfaced in
    /// the UI so the chart says what it shows.
    var effectiveETXWindow: TimeInterval {
        if let id = effectiveScopeID, sessionETXHistoryByID[id] != nil {
            return sessionWindow
        }
        return globalWindow
    }

    var effectiveETXHistory: [AdaptiveETXSample] {
        if let id = effectiveScopeID, let history = sessionETXHistoryByID[id] {
            return trimToWindow(history.elements, window: sessionWindow)
        }
        return trimToWindow(globalETXHistory.elements, window: globalWindow)
    }

    func setSelectedSession(id: AdaptiveSessionID?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setSelectedSession(id: id) }
            return
        }
        selectedSessionID = id
    }

    func updateGlobal(settings: TxAdaptiveSettings, lossRate: Double?, etx: Double?, srtt: Double?, updatedAt: Date = Date()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateGlobal(settings: settings, lossRate: lossRate, etx: etx, srtt: srtt, updatedAt: updatedAt)
            }
            return
        }
        globalAdaptive = AdaptiveParams(
            settings: settings,
            lossRate: lossRate, etx: etx, srtt: srtt,
            updatedAt: updatedAt,
            destination: nil, pathSignature: nil
        )
        if let etx {
            appendSample(
                AdaptiveETXSample(timestamp: updatedAt, etx: etx),
                into: &globalETXHistory,
                window: globalWindow
            )
        }
    }

    func refreshGlobalSettings(_ settings: TxAdaptiveSettings, updatedAt: Date = Date()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshGlobalSettings(settings, updatedAt: updatedAt)
            }
            return
        }
        globalAdaptive = AdaptiveParams(
            settings: settings,
            lossRate: globalAdaptive?.lossRate, etx: globalAdaptive?.etx, srtt: globalAdaptive?.srtt,
            updatedAt: updatedAt,
            destination: nil, pathSignature: nil
        )
    }

    func updateSession(
        id: AdaptiveSessionID,
        destination: String,
        pathSignature: String,
        radio: RadioID? = nil,
        settings: TxAdaptiveSettings,
        lossRate: Double?,
        etx: Double?,
        srtt: Double?,
        updatedAt: Date = Date()
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateSession(
                    id: id,
                    destination: destination,
                    pathSignature: pathSignature,
                    radio: radio,
                    settings: settings,
                    lossRate: lossRate,
                    etx: etx,
                    srtt: srtt,
                    updatedAt: updatedAt
                )
            }
            return
        }
        var params = AdaptiveParams(
            settings: settings,
            lossRate: lossRate, etx: etx, srtt: srtt,
            updatedAt: updatedAt,
            destination: destination, pathSignature: pathSignature, radio: radio
        )
        params.live = liveLinkByID[id]
        sessionAdaptiveByID[id] = params

        if let etx {
            var history = sessionETXHistoryByID[id] ?? AdaptiveRingBuffer<AdaptiveETXSample>(capacity: 400)
            appendSample(
                AdaptiveETXSample(timestamp: updatedAt, etx: etx),
                into: &history,
                window: sessionWindow
            )
            sessionETXHistoryByID[id] = history
        }
    }

    /// Records an open session's live K and paclen against its route's
    /// figure, or clears them (nil) when the session ends.
    func updateLive(id: AdaptiveSessionID, live: AdaptiveLiveLink?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateLive(id: id, live: live) }
            return
        }
        guard liveLinkByID[id] != live else { return }
        liveLinkByID[id] = live
        if var params = sessionAdaptiveByID[id] {
            params.live = live
            sessionAdaptiveByID[id] = params
        }
    }

    func removeSession(id: AdaptiveSessionID) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.removeSession(id: id) }
            return
        }
        sessionAdaptiveByID.removeValue(forKey: id)
        sessionETXHistoryByID.removeValue(forKey: id)
        liveLinkByID.removeValue(forKey: id)
        if selectedSessionID == id {
            selectedSessionID = nil
        }
    }

    private func appendSample(_ sample: AdaptiveETXSample, into history: inout AdaptiveRingBuffer<AdaptiveETXSample>, window: TimeInterval) {
        let cutoff = sample.timestamp.addingTimeInterval(-window)
        history.removeAll { $0.timestamp < cutoff }

        if let last = history.last, sample.timestamp.timeIntervalSince(last.timestamp) < minSampleSpacing {
            history.replaceLast(with: sample)
            return
        }
        history.append(sample)
    }

    private func trimToWindow(_ samples: [AdaptiveETXSample], window: TimeInterval) -> [AdaptiveETXSample] {
        guard let latest = samples.last else { return [] }
        let cutoff = latest.timestamp.addingTimeInterval(-window)
        return samples.filter { $0.timestamp >= cutoff }
    }
}
