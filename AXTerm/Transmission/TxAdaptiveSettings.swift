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

    /// EWMA of per-sample loss rate. Nil until the first sample arrives.
    var lossRateEWMA: Double? = nil

    /// EWMA of per-sample ETX. Nil until the first sample arrives.
    var etxEWMA: Double? = nil

    /// Consecutive I-frames delivered without a retransmission.
    var successStreak: Int = 0

    /// Consecutive samples that included at least one retransmission.
    var failStreak: Int = 0

    /// EWMA smoothing factor (weight of the newest sample).
    private static let ewmaLambda = 0.3

    /// Successes required before probing a parameter upward (spec: N=10).
    private static let successesForUpgrade = 10

    /// Streak value after an upgrade (spec: "reset to something like 5 so it
    /// doesn't rocket upward").
    private static let streakAfterUpgrade = 5

    /// Paclen steps (spec 4.2: start 128, drop to 64 on loss, raise through
    /// 192 to 256 when stable).
    private static let paclenLadder = [64, 128, 192, 256]

    /// Suggested-K cap in auto mode (spec 4.4: kMax user cap, default 4).
    private static let autoWindowCap = 4

    /// Update adaptive values from link quality (spec Sections 4.2 / 4.4 / 7.3).
    ///
    /// - Parameters:
    ///   - lossRate: this SAMPLE's loss fraction in [0, 1].
    ///   - etx: this sample's expected transmissions (≥ 1).
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
        etx: Double,
        srtt: Double?,
        newFrames: Int = 1,
        retransmits: Int? = nil
    ) {
        // Sanitize: a NaN/Inf sample must not poison the EWMAs.
        guard lossRate.isFinite, etx.isFinite else { return }
        let loss = min(max(lossRate, 0.0), 1.0)
        let sampleEtx = min(max(etx, 1.0), 100.0)

        // EWMA update (spec 4.2: "Keep an EWMA of loss_rate …").
        lossRateEWMA = Self.blend(lossRateEWMA, sample: loss)
        etxEWMA = Self.blend(etxEWMA, sample: sampleEtx)
        let smoothedLoss = lossRateEWMA ?? loss
        let smoothedEtx = etxEWMA ?? sampleEtx

        // Streaks (spec 4.2): only evidence-bearing samples move them.
        var freshFailure = false
        if let retransmits {
            if retransmits > 0 {
                failStreak += 1
                successStreak = 0
                freshFailure = true
            } else if newFrames > 0 {
                successStreak += newFrames
                failStreak = 0
            }
        }

        // Paclen (spec 4.2): degrade immediately, recover only on sustained
        // evidence. Between triggers the value HOLDS — no per-sample rewrite.
        if smoothedLoss >= 0.2 || smoothedEtx > 2.0 {
            paclen.currentAdaptive = Self.paclenLadder[0]
            paclen.adaptiveReason = "Loss \(Int(smoothedLoss * 100))%, ETX \(String(format: "%.1f", smoothedEtx))"
        } else if freshFailure {
            paclen.currentAdaptive = Self.stepDown(paclen.currentAdaptive, ladder: Self.paclenLadder)
            paclen.adaptiveReason = "Retransmission — backing off"
        } else if smoothedLoss > 0.1 {
            paclen.currentAdaptive = min(paclen.currentAdaptive, 128)
            paclen.adaptiveReason = "Moderate loss (\(Int(smoothedLoss * 100))%)"
        } else if successStreak >= Self.successesForUpgrade {
            let raised = Self.stepUp(paclen.currentAdaptive, ladder: Self.paclenLadder)
            if raised != paclen.currentAdaptive {
                paclen.currentAdaptive = raised
                paclen.adaptiveReason = "Stable link — probing larger frames"
            }
        }

        // Window size K (spec 4.4 Dynamic K, link level): multiplicative
        // decrease on loss, additive increase only after a sustained clean
        // streak. A single good sample never raises K (the old behavior
        // flapped K on every threshold crossing).
        if smoothedLoss >= 0.2 {
            windowSize.currentAdaptive = 1
            windowSize.adaptiveReason = "High loss - stop-and-wait"
        } else if freshFailure {
            windowSize.currentAdaptive = max(1, windowSize.currentAdaptive / 2)
            windowSize.adaptiveReason = "Retransmission — halving window"
        } else if successStreak >= Self.successesForUpgrade, smoothedEtx <= 1.5 {
            if windowSize.currentAdaptive < Self.autoWindowCap {
                windowSize.currentAdaptive += 1
                windowSize.adaptiveReason = "Good link quality"
            }
        }

        // Consume the streak after any upgrade attempt (spec's anti-rocket).
        if successStreak >= Self.successesForUpgrade {
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
        etxEWMA = nil
        successStreak = 0
        failStreak = 0
    }
}
