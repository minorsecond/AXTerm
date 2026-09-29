//
//  TxAdaptiveSettings.swift
//  AXTerm
//
//  Adaptive parameter settings with Auto/Manual mode per parameter.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4.1
//
//  Settings UX requirement (from spec):
//  - Mode: Auto / Manual per parameter
//  - If Manual: value picker enabled
//  - If Auto: show "Current" + "Suggested" + "Reason"
//

import Foundation

// MARK: - Adaptive Mode

/// Mode for an adaptive parameter
nonisolated enum AdaptiveMode: String, Sendable, CaseIterable {
    case auto
    case manual
}

// MARK: - Adaptive Setting

/// Generic adaptive setting with Auto/Manual mode
nonisolated struct AdaptiveSetting<T: Comparable & Sendable>: Sendable {
    /// Internal name for persistence
    let name: String

    /// Display name for UI
    let displayName: String

    /// Default value
    let defaultValue: T

    /// Valid range (for numeric types)
    let range: ClosedRange<T>?

    /// Current mode
    var mode: AdaptiveMode = .auto

    /// Manual override value
    var manualValue: T

    /// Current value from adaptive algorithm
    var currentAdaptive: T

    /// Reason for current adaptive value
    var adaptiveReason: String?

    init(name: String, displayName: String, defaultValue: T, range: ClosedRange<T>? = nil) {
        self.name = name
        self.displayName = displayName
        self.defaultValue = defaultValue
        self.range = range
        self.manualValue = defaultValue
        self.currentAdaptive = defaultValue
    }

    /// Effective value based on current mode
    var effectiveValue: T {
        switch mode {
        case .auto:
            return currentAdaptive
        case .manual:
            return clampedManualValue
        }
    }

    /// Manual value clamped to valid range
    var clampedManualValue: T {
        guard let range = range else { return manualValue }
        return min(max(manualValue, range.lowerBound), range.upperBound)
    }

    /// Reason to display (only in auto mode)
    var displayReason: String? {
        guard mode == .auto else { return nil }
        return adaptiveReason
    }
}

// MARK: - Probation & Metrics

/// An in-flight upgrade probe. Every parameter upgrade is provisional until
/// `framesRemaining` clean evidence frames confirm it; a failure during the
/// trial rolls the parameters back and doubles the skepticism.
nonisolated struct AdaptiveProbation: Equatable, Sendable {
    let priorWindow: Int
    let priorPaclen: Int
    var framesRemaining: Int
}

/// User-visible counters describing what the adaptive controller has done and
/// on what evidence — the raw material for "show your work" UI.
nonisolated struct AdaptiveLearningMetrics: Equatable, Sendable {
    /// Every sample seen (evidence-bearing and aggregate).
    var samplesSeen: Int = 0
    /// I-frames delivered cleanly (evidence weight accumulated).
    var evidenceFrames: Int = 0
    /// Retransmissions observed.
    var retransmitsSeen: Int = 0
    /// Parameter upgrades attempted (each opens a probation trial).
    var upgradesAttempted: Int = 0
    /// Upgrades that survived their probation trial.
    var upgradesConfirmed: Int = 0
    /// Upgrades rolled back because the link degraded during the trial.
    var probeRollbacks: Int = 0
    /// Times loss forced parameters down (outside of probation rollbacks).
    var lossDowngrades: Int = 0
}

// MARK: - TX Adaptive Settings

/// All adaptive parameters for transmission
nonisolated struct TxAdaptiveSettings: Sendable {

    // MARK: - Traffic Shaping Parameters (Section 4)

    /// Packet length (bytes)
    var paclen = AdaptiveSetting<Int>(
        name: "paclen",
        displayName: "Packet Length",
        defaultValue: 128,
        range: 32...256
    )

    /// Hop-scaled ceiling on the adaptive paclen ladder (bytes). Every digi
    /// hop multiplies a frame's on-air exposure (2m+1 transmissions per round
    /// trip), compounding the per-byte corruption probability, so routes give
    /// up one ladder rung of maximum paclen per hop — see paclenCeiling(forHops:).
    /// A ceiling on optimism only: loss response below it is untouched.
    var paclenCeiling: Int = 256

    /// Window size (K - outstanding frames)
    var windowSize = AdaptiveSetting<Int>(
        name: "windowSize",
        displayName: "Window Size",
        defaultValue: 2,
        range: 1...7
    )

    /// Maximum retry attempts (N2)
    var maxRetries = AdaptiveSetting<Int>(
        name: "maxRetries",
        displayName: "Max Retries",
        defaultValue: 15,
        range: 1...20
    )

    /// Minimum RTO (seconds)
    /// Digipeated paths often exceed 1s RTT; 3.0s is a safer default start point
    var rtoMin = AdaptiveSetting<Double>(
        name: "rtoMin",
        displayName: "Min RTO",
        defaultValue: 3.0,
        range: 0.5...5.0
    )

    /// Maximum RTO (seconds)
    var rtoMax = AdaptiveSetting<Double>(
        name: "rtoMax",
        displayName: "Max RTO",
        defaultValue: 30.0,
        range: 5.0...60.0
    )

    // MARK: - AXDP Settings (Section 6.x)

    /// AXDP protocol version to use
    var axdpVersion: UInt8 = AXDP.version

    /// Enable AXDP extensions
    var axdpExtensionsEnabled: Bool = true

    /// Auto-negotiate capabilities with peers
    // Default off to avoid sending binary AXDP PINGs to legacy nodes/BBS.
    var autoNegotiateCapabilities: Bool = false

    /// Enable compression for AXDP transfers
    var compressionEnabled: Bool = true

    /// Preferred compression algorithm
    var compressionAlgorithm: AXDPCompression.Algorithm = .lz4

    /// Maximum decompressed payload size
    var maxDecompressedPayload: UInt32 = 4096

    /// Max decompressed clamped to absolute limit
    var clampedMaxDecompressedPayload: UInt32 {
        min(maxDecompressedPayload, AXDPCompression.absoluteMaxDecompressedLen)
    }

    // MARK: - Debug Settings

    /// Show AXDP decode details in transcript
    var showAXDPDecodeDetails: Bool = false
    
    /// Last calculated RTO from adaptive logic
    var currentRto: Double? = nil

    // MARK: - Initialization

    init() {}

    // MARK: - Convenience

    /// Get all adaptive settings as array for iteration
    var allAdaptiveSettings: [Any] {
        [paclen, windowSize, maxRetries, rtoMin, rtoMax]
    }

    // MARK: - Link Controller State (spec Section 4.2)
    //
    // The spec requires EWMA'd metrics and success/fail streaks precisely so
    // parameters do not oscillate on single samples ("This avoids oscillation").
    // The previous implementation rewrote K and paclen from each raw sample,
    // which flapped K 1↔3 within seconds on marginal links (field captures
    // 2026-08-22).

    /// EWMA of per-sample loss rate, worse direction. Nil until the first
    /// sample arrives. This is the link's overall condition — what route
    /// ranking and the operator's readout want.
    var lossRateEWMA: Double? = nil

    /// EWMA of loss on frames **we sent**. Nil until the first sample
    /// arrives, and until then `lossRateEWMA` stands in.
    ///
    /// Separate from `lossRateEWMA` because paclen and K are transmit-side
    /// knobs and only forward loss answers for them. A receive-heavy
    /// session makes the difference stark: on 2026-08-27 AXTerm sent five
    /// I-frames with zero retransmissions while sending 17 REJs against
    /// 109 inbound frames, and the composite loss walked the link down to
    /// paclen 64, K=1 — shrinking our frames to fix damage to theirs.
    var forwardLossEWMA: Double? = nil

    /// EWMA of per-sample ETX. Nil until the first sample arrives.
    var etxEWMA: Double? = nil

    /// Consecutive I-frames delivered without a retransmission.
    var successStreak: Int = 0

    /// Consecutive samples that included at least one retransmission.
    var failStreak: Int = 0

    /// The upgrade currently on trial, if any. One probe at a time.
    var probation: AdaptiveProbation? = nil

    /// Clean frames required before the next upgrade probe. Baseline 10
    /// (spec N=10); doubles each time a probe fails its trial (cap 40) and
    /// resets to baseline when a probe is confirmed.
    var upgradeStreakRequirement: Int = TxAdaptiveSettings.baselineStreakRequirement

    /// What the controller has done, on what evidence — for UI and telemetry.
    var metrics = AdaptiveLearningMetrics()

    /// EWMA smoothing factor (weight of the newest sample).
    private static let ewmaLambda = 0.3

    /// Successes required before probing a parameter upward (spec: N=10).
    private static let baselineStreakRequirement = 10

    /// Skepticism cap after repeated failed probes.
    private static let maxStreakRequirement = 40

    /// Clean evidence frames an upgrade must survive to be confirmed.
    private static let probationTrialFrames = 10

    /// Streak value after an upgrade (spec: "reset to something like 5 so it
    /// doesn't rocket upward").
    private static let streakAfterUpgrade = 5

    /// Paclen steps (spec 4.2: start 128, drop to 64 on loss, raise through
    /// 192 to 256 when stable).
    private static let paclenLadder = [64, 128, 192, 256]

    /// Suggested-K cap in auto mode (spec 4.4: kMax user cap, default 4).
    private static let autoWindowCap = 4

    /// Maximum adaptive paclen for a route with `hops` digipeaters: one
    /// ladder rung down per hop, floored at 128. The 64-byte rung is a LOSS
    /// response and stays reachable on every route — it is never a hop prior.
    static func paclenCeiling(forHops hops: Int) -> Int {
        let topIndex = paclenLadder.count - 1              // 256
        let flooredIndex = max(1, topIndex - max(0, hops)) // never below 128
        return paclenLadder[flooredIndex]
    }

    /// Install the hop-scaled ceiling for this route and clamp any
    /// already-learned paclen above it (e.g. defaults or state inherited
    /// before the route's hop count was known).
    mutating func applyPaclenCeiling(forHops hops: Int) {
        let ceiling = Self.paclenCeiling(forHops: hops)
        paclenCeiling = ceiling
        if paclen.currentAdaptive > ceiling {
            paclen.currentAdaptive = ceiling
            paclen.adaptiveReason = "Capped at \(ceiling) for \(hops)-hop digipeater path"
        }
        if let trial = probation, trial.priorPaclen > ceiling {
            probation = AdaptiveProbation(priorWindow: trial.priorWindow,
                                          priorPaclen: ceiling,
                                          framesRemaining: trial.framesRemaining)
        }
    }

    /// Above this round trip, no upgrade is attempted however clean the samples.
    ///
    /// A healthy 1200-baud VHF path measures 1–3 s; anything past five is a
    /// marginal link that a wider window would only make harder to recover.
    /// Deliberately a ceiling on *upgrades* only — a slow link is not downgraded
    /// on RTT alone, because a slow-but-clean path still carries traffic.
    static let upgradeSrttCeiling: Double = 5.0

    /// Update adaptive values from link quality (spec Sections 4.2 / 4.4 / 7.3).
    ///
    /// - Parameters:
    ///   - lossRate: this SAMPLE's loss fraction in [0, 1], worse direction.
    ///   - forwardLoss: this sample's loss on frames *we sent*. Sizes paclen
    ///     and K, which are transmit-side knobs — reverse loss is real
    ///     evidence about the path but nothing we send can mend it, and
    ///     treating it as a reason to back off spends throughput on a
    ///     problem at the other end. Nil (aggregate sources, older
    ///     callers) falls back to `lossRate`, the previous behaviour.
    ///   - etx: this sample's expected transmissions (≥ 1). Both directions,
    ///     per CLAUDE.md §8 — unchanged, and still what ranks routes.
    ///   - srtt: smoothed RTT if known.
    ///   - newFrames: I-frames newly delivered in this sample (evidence weight).
    ///   - retransmits: retransmissions observed in this sample. Pass nil for
    ///     aggregate sources (network-wide inference) that carry no per-frame
    ///     evidence — those update the EWMAs but never the streaks, per the
    ///     spec's "UI best-effort … don't treat as success/failure" rule.
    ///
    /// Only updates currentAdaptive (suggested value); manual-mode parameters
    /// keep the user's choice via effectiveValue.
    mutating func updateFromLinkQuality(
        lossRate: Double,
        forwardLoss: Double? = nil,
        etx: Double,
        srtt: Double?,
        newFrames: Int = 1,
        retransmits: Int? = nil
    ) {
        // Sanitize: a NaN/Inf sample must not poison the EWMAs.
        guard lossRate.isFinite, etx.isFinite else { return }
        let loss = min(max(lossRate, 0.0), 1.0)
        let sampleEtx = min(max(etx, 1.0), 100.0)
        // An unusable forward figure degrades to the composite, which is
        // what every caller got before this parameter existed.
        let forward = forwardLoss.flatMap { $0.isFinite ? min(max($0, 0.0), 1.0) : nil } ?? loss

        metrics.samplesSeen += 1

        // EWMA update (spec 4.2: "Keep an EWMA of loss_rate …").
        lossRateEWMA = Self.blend(lossRateEWMA, sample: loss)
        forwardLossEWMA = Self.blend(forwardLossEWMA, sample: forward)
        etxEWMA = Self.blend(etxEWMA, sample: sampleEtx)
        let smoothedEtx = etxEWMA ?? sampleEtx
        // What paclen and K are *backed off* from. Upgrades still consult
        // `smoothedLoss`, and so do route ranking and the operator's
        // readout — both directions matter for judging a link, only the
        // forward one for judging our own frames.
        let smoothedLoss = lossRateEWMA ?? loss
        let smoothedForward = forwardLossEWMA ?? forward

        // Streaks (spec 4.2) and the probation trial: only evidence-bearing
        // samples move either. Aggregate sources can neither pass nor fail a
        // probe — no evidence, no verdict.
        var freshFailure = false
        let wasProbing = probation != nil
        if let retransmits {
            metrics.retransmitsSeen += retransmits
            if retransmits > 0 {
                failStreak += 1
                successStreak = 0
                freshFailure = true
            } else if newFrames > 0 {
                metrics.evidenceFrames += newFrames
                successStreak += newFrames
                failStreak = 0
                if var trial = probation {
                    trial.framesRemaining -= newFrames
                    if trial.framesRemaining <= 0 {
                        // The probe survived: the upgrade is confirmed and
                        // skepticism returns to baseline.
                        probation = nil
                        upgradeStreakRequirement = Self.baselineStreakRequirement
                        metrics.upgradesConfirmed += 1
                    } else {
                        probation = trial
                    }
                }
            }
        }

        // Paclen (spec 4.2): degrade immediately, recover only on sustained
        // evidence. Between triggers the value HOLDS — no per-sample rewrite.
        //
        // Sized from FORWARD loss. The composite ETX term that used to sit
        // in this condition is gone rather than converted: for a symmetric
        // link it never fired on its own (ETX > 2 needs ~29% each way,
        // well past the 20% below), so it was load-bearing only for
        // asymmetric ones — precisely the links where it was wrong.
        let paclenBefore = paclen.currentAdaptive
        if smoothedForward >= 0.2 {
            paclen.currentAdaptive = Self.paclenLadder[0]
            paclen.adaptiveReason = "Our frames losing \(Int(smoothedForward * 100))%"
        } else if freshFailure {
            paclen.currentAdaptive = Self.stepDown(paclen.currentAdaptive, ladder: Self.paclenLadder)
            paclen.adaptiveReason = "Retransmission — backing off"
        } else if smoothedForward > 0.1 {
            paclen.currentAdaptive = min(paclen.currentAdaptive, 128)
            paclen.adaptiveReason = "Moderate loss on our frames (\(Int(smoothedForward * 100))%)"
        }

        // Window size K (spec 4.4 Dynamic K, link level): multiplicative
        // decrease on loss. A single good sample never raises K.
        // Also forward-only: collapsing to stop-and-wait halves our own
        // throughput and does nothing about frames arriving damaged.
        let windowBefore = windowSize.currentAdaptive
        if smoothedForward >= 0.2 {
            windowSize.currentAdaptive = 1
            windowSize.adaptiveReason = "Our frames losing \(Int(smoothedForward * 100))% — stop-and-wait"
        } else if freshFailure {
            windowSize.currentAdaptive = max(1, windowSize.currentAdaptive / 2)
            windowSize.adaptiveReason = "Retransmission — halving window"
        }

        if freshFailure {
            if let failed = probation {
                // The upgrade made things worse: roll back to at-or-below the
                // pre-upgrade values and double the skepticism for next time.
                windowSize.currentAdaptive = min(windowSize.currentAdaptive, failed.priorWindow)
                paclen.currentAdaptive = min(paclen.currentAdaptive, failed.priorPaclen)
                windowSize.adaptiveReason = "Upgrade made things worse — rolled back"
                paclen.adaptiveReason = "Upgrade made things worse — rolled back"
                probation = nil
                upgradeStreakRequirement = min(Self.maxStreakRequirement, upgradeStreakRequirement * 2)
                metrics.probeRollbacks += 1
            } else if windowSize.currentAdaptive < windowBefore || paclen.currentAdaptive < paclenBefore {
                metrics.lossDowngrades += 1
            }
        } else if windowSize.currentAdaptive < windowBefore || paclen.currentAdaptive < paclenBefore {
            metrics.lossDowngrades += 1
        }

        // Upgrades (spec 4.2/4.4): only after the required clean streak, only
        // one probe at a time, and never in the same sample a trial ended —
        // a confirmation call must not immediately stack the next probe.
        // A very long round trip is itself evidence of a poor link, whatever the
        // loss figure says. Field capture 2026-08-26, KB5YZB-7 direct: one frame
        // acknowledged with no retransmission read as loss=0.00, etx=1.00 and
        // bought K 1→2 and paclen 64→128 — on a path whose measured SRTT was
        // **12 seconds**, eight times the healthy 1.5 s to DRLNOD on the same
        // radio at the same moment.
        //
        // More frames in flight and larger frames both make that worse: longer
        // to notice a loss, and more of a shared channel held per exchange. So
        // an upgrade needs a round trip that plausibly belongs to a working
        // link, not merely a sample that happened not to fail.
        let srttPermitsUpgrade = (srtt ?? 0) <= Self.upgradeSrttCeiling
        // Note the asymmetry with the downgrades above, which is deliberate:
        // **back off on forward evidence, grow only when both directions
        // look good.** Backing off is an attempt to fix something, and only
        // forward loss is something our frames can fix. Growing is the app
        // choosing to spend more airtime, and a channel that is damaging
        // the other end's frames is not the place to spend it — 13% inbound
        // loss with a clean forward path is a busy or marginal channel, not
        // an invitation to put four frames in flight instead of two.
        if !freshFailure, !wasProbing, successStreak >= upgradeStreakRequirement,
           smoothedLoss <= 0.1, srttPermitsUpgrade {
            let priorWindow = windowSize.currentAdaptive
            let priorPaclen = paclen.currentAdaptive
            var upgraded = false

            let raisedPaclen = min(paclenCeiling, Self.stepUp(priorPaclen, ladder: Self.paclenLadder))
            if raisedPaclen != priorPaclen {
                paclen.currentAdaptive = raisedPaclen
                paclen.adaptiveReason = "Stable link — probing larger frames"
                upgraded = true
            }
            if smoothedEtx <= 1.5, priorWindow < Self.autoWindowCap {
                windowSize.currentAdaptive = priorWindow + 1
                windowSize.adaptiveReason = "Good link quality"
                upgraded = true
            }
            if upgraded {
                probation = AdaptiveProbation(
                    priorWindow: priorWindow,
                    priorPaclen: priorPaclen,
                    framesRemaining: Self.probationTrialFrames
                )
                metrics.upgradesAttempted += 1
            }
            // Consume the streak after any upgrade attempt (spec's anti-rocket).
            successStreak = Self.streakAfterUpgrade
        }

        // RTO from SRTT (per spec Section 7.3)
        if let rtt = srtt, rtt.isFinite, rtt > 0 {
            // RTO = SRTT + 4 * RTTVAR (simplified: use 2x SRTT as rough estimate)
            let suggestedRto = rtt * 2.0
            let clampedRto = max(rtoMin.effectiveValue, min(rtoMax.effectiveValue, suggestedRto))
            rtoMin.adaptiveReason = "Based on measured RTT \(String(format: "%.1f", rtt))s"
            rtoMax.adaptiveReason = "Suggested RTO: \(String(format: "%.1f", clampedRto))s"
            currentRto = clampedRto
        }
        // If SRTT is nil (e.g. pure loss update), preserve the last calculated currentRto.
    }

    private static func blend(_ previous: Double?, sample: Double) -> Double {
        guard let previous else { return sample }
        return previous * (1 - ewmaLambda) + sample * ewmaLambda
    }

    /// Next lower ladder value (or the floor if already at/below it).
    private static func stepDown(_ value: Int, ladder: [Int]) -> Int {
        ladder.last(where: { $0 < value }) ?? ladder[0]
    }

    /// Next higher ladder value (or the cap if already at/above it).
    private static func stepUp(_ value: Int, ladder: [Int]) -> Int {
        ladder.first(where: { $0 > value }) ?? ladder[ladder.count - 1]
    }

    /// Resets only `currentAdaptive` and `adaptiveReason` on all adaptive parameters back to defaults.
    /// Preserves manual mode selections, manual values, AXDP settings, and debug settings.
    /// Called when all sessions disconnect so stale network-learned values don't persist.
    mutating func resetAdaptiveToDefaults() {
        paclen.currentAdaptive = paclen.defaultValue
        paclen.adaptiveReason = nil

        windowSize.currentAdaptive = windowSize.defaultValue
        windowSize.adaptiveReason = nil

        maxRetries.currentAdaptive = maxRetries.defaultValue
        maxRetries.adaptiveReason = nil

        rtoMin.currentAdaptive = rtoMin.defaultValue
        rtoMin.adaptiveReason = nil

        rtoMax.currentAdaptive = rtoMax.defaultValue
        rtoMax.adaptiveReason = nil

        currentRto = nil

        lossRateEWMA = nil
        forwardLossEWMA = nil
        etxEWMA = nil
        successStreak = 0
        failStreak = 0
        probation = nil
        upgradeStreakRequirement = Self.baselineStreakRequirement
        metrics = AdaptiveLearningMetrics()
    }
}
