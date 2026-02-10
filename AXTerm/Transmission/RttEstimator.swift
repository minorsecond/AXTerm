//
//  RttEstimator.swift
//  AXTerm
//
//  Adaptive RTO estimation using Jacobson/Karels algorithm.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 11.3
//

import Foundation

/// Estimates smoothed RTT and calculates adaptive RTO.
///
/// Implements the Jacobson/Karels algorithm (RFC 6298 style):
/// - RTTVAR = (1 - β) × RTTVAR + β × |SRTT - RTT_sample|
/// - SRTT = (1 - α) × SRTT + α × RTT_sample
/// - RTO = SRTT + 4 × RTTVAR
///
/// This provides adaptive timeouts that respond to network conditions
/// without being overly sensitive to individual outliers.
nonisolated struct RttEstimator {
    /// Smoothed RTT estimate (nil until first sample)
    var srtt: Double? = nil

    /// RTT variance estimate
    var rttvar: Double = 0.0

    /// Smoothing factor for SRTT (1/8 per RFC 6298)
    let alpha: Double = 1.0 / 8.0

    /// Smoothing factor for RTTVAR (1/4 per RFC 6298)
    let beta: Double = 1.0 / 4.0

    /// Default RTO before any samples (seconds)
    let defaultRto: Double = 3.0

    /// Update estimates with a new RTT sample.
    /// - Parameter sample: Measured RTT in seconds
    mutating func update(sample: Double) {
        if let s = srtt {
            // Update existing estimates
            rttvar = (1 - beta) * rttvar + beta * abs(s - sample)
            srtt = (1 - alpha) * s + alpha * sample
        } else {
            // First sample: initialize
            srtt = sample
            rttvar = sample / 2
        }

        // Log RTT update
        if let newSrtt = srtt {
            TxLog.rttUpdate(
                peer: "estimator",
                srtt: newSrtt,
                rttvar: rttvar,
                rto: rto()
            )
        }
    }

    /// Calculate the recommended RTO (retransmission timeout).
    /// - Parameters:
    ///   - min: Minimum RTO (default 1.0s per RFC 6298)
    ///   - max: Maximum RTO (default 30.0s, configurable for packet radio)
    /// - Returns: Calculated RTO in seconds, clamped to [min, max]
    func rto(min: Double = 1.0, max: Double = 30.0) -> Double {
        guard let s = srtt else {
            return defaultRto
        }
        let computed = s + 4 * rttvar
        return Swift.max(min, Swift.min(max, computed))
    }

    /// Reset estimator to initial state.
    mutating func reset() {
        srtt = nil
        rttvar = 0.0
    }
}

// MARK: - Link RTT Tracker

/// Tracks RTT and delivery statistics for a link (destination + path).
nonisolated struct LinkRttTracker {
    /// Link identifier
    let linkKey: String

    /// RTT estimator
    var rttEstimator: RttEstimator = RttEstimator()

    /// Success count for current streak
    var successStreak: Int = 0

    /// Failure count for current streak
    var failStreak: Int = 0

    /// Total successful deliveries
    var totalSuccess: Int = 0

    /// Total failed deliveries
    var totalFail: Int = 0

    /// Loss rate EWMA (0.0 - 1.0)
    var lossRate: Double = 0.0

    /// Retry rate EWMA
    var retryRate: Double = 0.0

    /// EWMA smoothing factor
    let ewmaAlpha: Double = 0.125

    init(linkKey: String) {
        self.linkKey = linkKey
    }

    /// Record a successful delivery (acked without retransmit).
    /// - Parameter rtt: Measured round-trip time
    mutating func recordSuccess(rtt: Double) {
        rttEstimator.update(sample: rtt)
        successStreak += 1
        failStreak = 0
        totalSuccess += 1

        // Update loss rate EWMA
        lossRate = (1 - ewmaAlpha) * lossRate + ewmaAlpha * 0.0
    }

    /// Record a failed delivery (timeout/retransmit needed).
    mutating func recordFailure() {
        failStreak += 1
        successStreak = 0
        totalFail += 1

        // Update loss rate EWMA
        lossRate = (1 - ewmaAlpha) * lossRate + ewmaAlpha * 1.0
    }

    /// Record a retry (not necessarily final failure).
    mutating func recordRetry() {
        retryRate = (1 - ewmaAlpha) * retryRate + ewmaAlpha * 1.0
        // Reset success streak on any retry
        successStreak = 0
    }

    /// Get recommended RTO for this link.
    var recommendedRto: Double {
        rttEstimator.rto()
    }

    /// Whether link quality allows increasing parameters (stable).
    var isStable: Bool {
        successStreak >= 10 && lossRate < 0.1
    }

    /// Whether link quality suggests decreasing parameters (degraded).
    var isDegraded: Bool {
        failStreak >= 1 || lossRate > 0.2
    }
}

// MARK: - Link Quality Metrics for Adaptive Tuning

/// Suggested adaptive parameters based on link quality.
nonisolated struct AdaptiveParameters {
    /// Suggested packet length (bytes)
    let paclen: Int

    /// Suggested window size (K)
    let windowSize: Int

    /// Reason for suggestions (for UI display)
    let reason: String
}

extension LinkRttTracker {
    /// Calculate suggested adaptive parameters based on link quality.
    /// - Parameters:
    ///   - basePaclen: User's preferred paclen
    ///   - baseWindow: User's preferred window size
    /// - Returns: Adjusted parameters with explanation
    func adaptiveParameters(basePaclen: Int = 128, baseWindow: Int = 2) -> AdaptiveParameters {
        var paclen = basePaclen
        var windowSize = baseWindow
        var reasons: [String] = []

        // Adjust based on loss rate
        if lossRate > 0.2 {
            paclen = min(paclen, 64)
            windowSize = 1
            reasons.append("Loss rate \(Int(lossRate * 100))%")
        } else if lossRate > 0.1 {
            paclen = min(paclen, 128)
            windowSize = min(windowSize, 2)
            reasons.append("Moderate loss")
        }

        // Adjust based on ETX (estimated from loss rate)
        let etx = 1.0 / max(0.05, (1 - lossRate) * (1 - lossRate))
        if etx > 2.0 {
            paclen = min(paclen, 64)
            reasons.append("ETX \(String(format: "%.1f", etx))")
        }

        // Increase if stable
        if isStable && reasons.isEmpty {
            paclen = min(basePaclen + 64, 256)
            windowSize = min(baseWindow + 1, 4)
            reasons.append("Stable link")
        }

        let reason = reasons.isEmpty ? "Default" : reasons.joined(separator: ", ")
        return AdaptiveParameters(paclen: paclen, windowSize: windowSize, reason: reason)
    }
}

// MARK: - AIMD Congestion Window

/// AIMD (Additive Increase Multiplicative Decrease) congestion window.
///
/// Implements TCP-like congestion control for AX.25 connected mode:
/// - Slow start: exponential growth until loss or threshold
/// - Congestion avoidance: linear growth after slow start
/// - On loss: halve the window (multiplicative decrease)
nonisolated struct AIMDWindow: Sendable {
    /// Current congestion window (fractional)
    private(set) var cwnd: Double

    /// Slow start threshold
    private(set) var ssthresh: Double

    /// Maximum window size
    let maxWindow: Double

    /// Minimum window size
    let minWindow: Double = 1.0

    /// Additive increase factor (increase per RTT)
    let aiIncrement: Double = 1.0

    /// Multiplicative decrease factor
    let mdFactor: Double = 0.5

    /// Whether currently in slow start phase
    var isSlowStart: Bool {
        cwnd < ssthresh
    }

    /// Effective window as integer (floored)
    var effectiveWindow: Int {
        max(1, Int(cwnd))
    }

    init(initialWindow: Double = 1.0, maxWindow: Double = 8.0, ssthresh: Double? = nil) {
        self.cwnd = max(1.0, initialWindow)
        self.maxWindow = max(1.0, maxWindow)
        self.ssthresh = ssthresh ?? maxWindow / 2
    }

    /// Called when an ACK is received (successful delivery).
    mutating func onAck() {
        let oldCwnd = cwnd
        if isSlowStart {
            // Slow start: increase by 1 per ACK (exponential growth)
            cwnd = min(cwnd + 1.0, maxWindow)
            TxLog.congestionWindowChange(peer: "aimd", cwnd: effectiveWindow, reason: "ACK (slow start)")
        } else {
            // Congestion avoidance: increase by 1/cwnd per ACK (linear growth)
            cwnd = min(cwnd + aiIncrement / cwnd, maxWindow)
            if Int(oldCwnd) != effectiveWindow {
                TxLog.congestionWindowChange(peer: "aimd", cwnd: effectiveWindow, reason: "ACK (congestion avoidance)")
            }
        }
    }

    /// Called when a loss is detected (timeout or NACK).
    mutating func onLoss() {
        // Set new ssthresh to half current window
        ssthresh = max(minWindow, cwnd * mdFactor)

        // Multiplicative decrease
        cwnd = max(minWindow, cwnd * mdFactor)

        TxLog.congestionWindowChange(peer: "aimd", cwnd: effectiveWindow, reason: "LOSS (MD to \(String(format: "%.1f", cwnd)))")
    }

    /// Reset to initial state.
    mutating func reset() {
        cwnd = minWindow
        ssthresh = maxWindow / 2
    }
}

// MARK: - Paclen Adapter

/// Adapts packet length based on link performance.
///
/// Per spec Section 4.2:
/// - Start conservative (e.g., 128 bytes)
/// - Decrease on failure/retry
/// - Increase after N consecutive successes
nonisolated struct PaclenAdapter: Sendable {
    /// Current recommended paclen
    private(set) var currentPaclen: Int

    /// User's base/preferred paclen
    let basePaclen: Int

    /// Minimum allowed paclen
    let minPaclen: Int

    /// Maximum allowed paclen
    let maxPaclen: Int

    /// Consecutive successes required to increase
    let stabilityThreshold: Int = 10

    /// Current success streak
    private var successStreak: Int = 0

    init(basePaclen: Int = 128, minPaclen: Int = 32, maxPaclen: Int = 256) {
        self.basePaclen = basePaclen
        self.currentPaclen = basePaclen
        self.minPaclen = max(16, minPaclen)
        self.maxPaclen = max(minPaclen, maxPaclen)
    }

    /// Record a successful delivery (no retransmit needed).
    mutating func recordSuccess() {
        successStreak += 1

        // Increase paclen after stability threshold
        if successStreak >= stabilityThreshold {
            // Increase by 32 bytes, clamped
            currentPaclen = min(currentPaclen + 32, maxPaclen)
            // Reset streak but keep partial credit
            successStreak = stabilityThreshold / 2
        }
    }

    /// Record a failure (timeout/retransmit).
    mutating func recordFailure() {
        successStreak = 0

        // Decrease paclen by half the distance to min
        let decrease = (currentPaclen - minPaclen) / 2
        currentPaclen = max(minPaclen, currentPaclen - max(16, decrease))
    }

    /// Record a retry (partial failure).
    mutating func recordRetry() {
        successStreak = 0

        // Smaller decrease than full failure
        currentPaclen = max(minPaclen, currentPaclen - 16)
    }

    /// Reset to base paclen.
    mutating func reset() {
        currentPaclen = basePaclen
        successStreak = 0
    }
}
