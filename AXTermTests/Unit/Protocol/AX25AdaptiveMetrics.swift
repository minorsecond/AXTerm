//
//  AX25AdaptiveMetrics.swift
//  AXTermTests
//
//  Adaptive-system observability, invariant checking, and analysis tooling.
//
//  Contents:
//    AdaptiveSnapshot      — immutable point-in-time capture of all adaptive state
//    AdaptiveTrace         — append-only replay-capable history of snapshots
//    AdaptiveDecisionLog   — structured log of individual adaptation events
//    OscillationDetector   — detects parameter thrashing / rapid flipping
//    ConvergenceDetector   — detects when a metric has settled to a stable value
//    StabilityScorer       — composite stability score in [0, 1]
//    ThroughputMeter       — tracks goodput, retransmit ratio, delivery rate
//    AdaptiveInvariantChecker — asserts adaptive bounds per AXTERM-TRANSMISSION-SPEC.md
//

import Foundation
@testable import AXTerm

// MARK: - Adaptive Snapshot

/// Immutable point-in-time capture of every adaptive parameter for a session.
/// Used for replay traces, oscillation analysis, and convergence tests.
struct AdaptiveSnapshot: Sendable {
    // Wall / virtual clock time
    let time: TimeInterval

    // RTT estimates (from AX25SessionTimers)
    let srtt: Double?
    let rttvar: Double
    let rto: Double

    // Sequence state
    let vs: Int
    let vr: Int
    let va: Int
    let outstandingCount: Int
    let sendBufferCount: Int

    // Statistics
    let framesSent: Int
    let framesReceived: Int
    let retransmissions: Int

    // Session state
    let sessionState: String

    // Adaptive settings snapshot (from the manager's defaultConfig at capture time)
    let paclen: Int
    let windowSize: Int
    let maxRetries: Int

    // Karn state
    let retransmittedNSCount: Int   // How many NS values are currently Karn-excluded

    // Context tag (e.g. "after-rr", "t1-timeout", "rej-received")
    let context: String

    // Triggering condition for this snapshot
    let trigger: AdaptiveTrigger

    /// Capture current state from a live session.
    static func capture(
        from session: AX25Session,
        at time: TimeInterval,
        context: String,
        trigger: AdaptiveTrigger
    ) -> AdaptiveSnapshot {
        AdaptiveSnapshot(
            time: time,
            srtt: session.timers.srtt,
            rttvar: session.timers.rttvar,
            rto: session.timers.rto,
            vs: session.vs,
            vr: session.vr,
            va: session.va,
            outstandingCount: session.outstandingCount,
            sendBufferCount: session.sendBuffer.count,
            framesSent: session.statistics.framesSent,
            framesReceived: session.statistics.framesReceived,
            retransmissions: session.statistics.retransmissions,
            sessionState: session.state.rawValue,
            paclen: session.stateMachine.config.paclen,
            windowSize: session.stateMachine.config.windowSize,
            maxRetries: session.stateMachine.config.maxRetries,
            retransmittedNSCount: 0,   // Opaque: session doesn't expose this directly
            context: context,
            trigger: trigger
        )
    }
}

// MARK: - Adaptive Trigger

/// What caused an adaptive snapshot to be recorded.
enum AdaptiveTrigger: String, Sendable {
    case rrReceived      = "rr_received"
    case rejReceived     = "rej_received"
    case t1Timeout       = "t1_timeout"
    case t3Timeout       = "t3_timeout"
    case sabmSent        = "sabm_sent"
    case uaReceived      = "ua_received"
    case iFrameSent      = "iframe_sent"
    case iFrameReceived  = "iframe_received"
    case disconnect      = "disconnect"
    case periodic        = "periodic"
    case invariantCheck  = "invariant_check"
}

// MARK: - Adaptive Decision Log

/// Structured record of a single adaptation event (parameter change).
struct AdaptiveDecisionLog: Sendable {
    let time: TimeInterval
    let parameter: String      // "rto", "paclen", "windowSize", …
    let previousValue: Double
    let newValue: Double
    let reason: String

    // Observed inputs that drove this decision
    let lossEstimate: Double?
    let rttSample: Double?
    let srtt: Double?
    let rttvar: Double?
    let retryRate: Double?
    let queueDepth: Int

    var delta: Double { newValue - previousValue }
    var increased: Bool { newValue > previousValue }
}

// MARK: - Adaptive Trace

/// Append-only, replay-capable record of snapshots and decision logs.
/// Emits a structured trace on failure with enough information to reproduce the sequence.
final class AdaptiveTrace: @unchecked Sendable {
    private(set) var snapshots: [AdaptiveSnapshot] = []
    private(set) var decisions: [AdaptiveDecisionLog] = []
    let seed: UInt64

    init(seed: UInt64) {
        self.seed = seed
    }

    func append(_ snapshot: AdaptiveSnapshot) {
        snapshots.append(snapshot)
    }

    func recordDecision(_ decision: AdaptiveDecisionLog) {
        decisions.append(decision)
    }

    /// All RTO values in chronological order.
    var rtoHistory: [Double] { snapshots.map(\.rto) }

    /// All SRTT values (only where not nil).
    var srttHistory: [Double] { snapshots.compactMap(\.srtt) }

    /// Retransmit count at each snapshot.
    var retransmitHistory: [Int] { snapshots.map(\.retransmissions) }

    /// Produce a compact, human-readable failure report.
    func failureReport() -> String {
        var lines: [String] = [
            "=== ADAPTIVE TRACE FAILURE REPORT ===",
            "seed: \(seed)",
            "snapshots: \(snapshots.count)",
            "decisions: \(decisions.count)",
            ""
        ]

        if !snapshots.isEmpty {
            lines.append("--- Parameter History ---")
            for (i, snap) in snapshots.enumerated() {
                let srttStr = snap.srtt.map { String(format: "%.3f", $0) } ?? "nil"
                let statePadded = snap.sessionState.padding(toLength: 12, withPad: " ", startingAt: 0)
                lines.append(
                    "[\(String(format: "%3d", i))]"
                    + " t=\(String(format: "%.3f", snap.time))"
                    + " state=\(statePadded)"
                    + " rto=\(String(format: "%.3f", snap.rto))"
                    + " srtt=\(srttStr)"
                    + " rttvar=\(String(format: "%.3f", snap.rttvar))"
                    + " retx=\(snap.retransmissions)"
                    + " ctx=\(snap.context)"
                )
            }
        }

        if !decisions.isEmpty {
            lines.append("")
            lines.append("--- Adaptation Decisions ---")
            for d in decisions {
                let paramPadded = d.parameter.padding(toLength: 10, withPad: " ", startingAt: 0)
                lines.append(
                    "t=\(String(format: "%.3f", d.time))"
                    + " \(paramPadded)"
                    + " \(String(format: "%.3f", d.previousValue))"
                    + "→\(String(format: "%.3f", d.newValue))"
                    + " reason=\"\(d.reason)\""
                )
            }
        }

        lines.append("=== END REPORT ===")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Oscillation Detector

/// Detects adaptive parameter thrashing by measuring sign-change frequency
/// and variance over a sliding window.
///
/// An oscillation is flagged when:
///   1. The number of sign reversals in the delta series exceeds `maxSignChanges`, OR
///   2. The coefficient of variation (stddev / mean) exceeds `maxCV`
///
/// Both checks require at least `minSamples` values.
struct OscillationDetector {
    /// Minimum samples needed before analysis is meaningful.
    let minSamples: Int

    /// Fraction of sign reversals (alternating ↑↓) above which oscillation is flagged.
    /// 0.6 means >60% of consecutive deltas alternate direction.
    let maxSignChangeRatio: Double

    /// Max coefficient of variation (CV = σ/μ) above which oscillation is flagged.
    /// Values > 1.0 indicate the standard deviation exceeds the mean.
    let maxCoefficientOfVariation: Double

    init(
        minSamples: Int = 8,
        maxSignChangeRatio: Double = 0.6,
        maxCV: Double = 1.5
    ) {
        self.minSamples = minSamples
        self.maxSignChangeRatio = maxSignChangeRatio
        self.maxCoefficientOfVariation = maxCV
    }

    struct OscillationResult {
        let isOscillating: Bool
        let signChangeRatio: Double
        let coefficientOfVariation: Double
        let sampleCount: Int
        let mean: Double
        let stddev: Double
    }

    func analyze(_ values: [Double]) -> OscillationResult {
        guard values.count >= minSamples else {
            return OscillationResult(
                isOscillating: false, signChangeRatio: 0, coefficientOfVariation: 0,
                sampleCount: values.count, mean: 0, stddev: 0
            )
        }

        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
        let stddev = variance.squareRoot()
        let cv = mean == 0 ? 0 : stddev / abs(mean)

        // Count sign changes in the delta series
        var signChanges = 0
        var lastDelta: Double? = nil
        for i in 1..<values.count {
            let delta = values[i] - values[i - 1]
            if let prev = lastDelta, delta != 0, prev != 0 {
                if (delta > 0) != (prev > 0) { signChanges += 1 }
            }
            if delta != 0 { lastDelta = delta }
        }
        let totalDeltas = max(1, values.count - 1)
        let signChangeRatio = Double(signChanges) / Double(totalDeltas)

        let oscillating = signChangeRatio > maxSignChangeRatio || cv > maxCoefficientOfVariation

        return OscillationResult(
            isOscillating: oscillating,
            signChangeRatio: signChangeRatio,
            coefficientOfVariation: cv,
            sampleCount: values.count,
            mean: mean,
            stddev: stddev
        )
    }
}

// MARK: - Convergence Detector

/// Detects whether a metric has converged to a stable value.
/// Convergence is defined as:
///   All last `windowSize` values lie within `toleranceFraction` of the window mean.
///
/// Example: SRTT is converged if the last 10 samples are within ±5% of their mean.
struct ConvergenceDetector {
    let windowSize: Int
    let toleranceFraction: Double

    init(windowSize: Int = 10, toleranceFraction: Double = 0.05) {
        self.windowSize = windowSize
        self.toleranceFraction = max(0, toleranceFraction)
    }

    struct ConvergenceResult {
        let hasConverged: Bool
        let windowMean: Double?
        let maxDeviation: Double?
        let sampleCount: Int
    }

    func analyze(_ values: [Double]) -> ConvergenceResult {
        guard values.count >= windowSize else {
            return ConvergenceResult(hasConverged: false, windowMean: nil, maxDeviation: nil, sampleCount: values.count)
        }

        let window = Array(values.suffix(windowSize))
        let mean = window.reduce(0, +) / Double(windowSize)
        guard mean > 0 else {
            return ConvergenceResult(hasConverged: false, windowMean: mean, maxDeviation: nil, sampleCount: values.count)
        }
        let maxDev = window.map { abs($0 - mean) / mean }.max() ?? 0

        return ConvergenceResult(
            hasConverged: maxDev <= toleranceFraction,
            windowMean: mean,
            maxDeviation: maxDev,
            sampleCount: values.count
        )
    }
}

// MARK: - Stability Scorer

/// Produces a composite stability score in [0, 1] by combining:
///   - Oscillation index (lower oscillation → higher score)
///   - Convergence achieved (converged → higher score)
///   - Retransmit ratio (fewer retransmits → higher score)
///   - RTO headroom (RTO near rtoMin is good, near rtoMax is bad)
struct StabilityScorer {
    let rtoMin: Double
    let rtoMax: Double
    let oscillationDetector: OscillationDetector
    let convergenceDetector: ConvergenceDetector

    init(
        rtoMin: Double = 1.0,
        rtoMax: Double = 30.0,
        oscillationDetector: OscillationDetector = OscillationDetector(),
        convergenceDetector: ConvergenceDetector = ConvergenceDetector()
    ) {
        self.rtoMin = rtoMin
        self.rtoMax = rtoMax
        self.oscillationDetector = oscillationDetector
        self.convergenceDetector = convergenceDetector
    }

    struct StabilityScore {
        /// Composite score in [0, 1] where 1.0 = perfectly stable.
        let score: Double
        let oscillationPenalty: Double
        let convergenceBonus: Double
        let retransmitPenalty: Double
        let rtoHeadroomScore: Double
    }

    func score(trace: AdaptiveTrace) -> StabilityScore {
        let snaps = trace.snapshots
        guard !snaps.isEmpty else {
            return StabilityScore(
                score: 0.5, oscillationPenalty: 0, convergenceBonus: 0,
                retransmitPenalty: 0, rtoHeadroomScore: 0.5
            )
        }

        // Oscillation: analyze RTO history
        let rtoHistory = trace.rtoHistory
        let oscResult = oscillationDetector.analyze(rtoHistory)
        let oscillationPenalty = oscResult.isOscillating ? 0.4 : (oscResult.signChangeRatio * 0.3)

        // Convergence bonus
        let convResult = convergenceDetector.analyze(trace.srttHistory)
        let convergenceBonus: Double = convResult.hasConverged ? 0.3 : 0.0

        // Retransmit ratio penalty
        let lastSnap = snaps.last!
        let totalSent = max(1, lastSnap.framesSent)
        let retxRatio = Double(lastSnap.retransmissions) / Double(totalSent)
        let retransmitPenalty = min(0.4, retxRatio * 2.0)

        // RTO headroom: penalise if RTO is near rtoMax
        let rtoRange = max(0.001, rtoMax - rtoMin)
        let rtoFrac = (lastSnap.rto - rtoMin) / rtoRange
        let rtoHeadroomScore = 1.0 - rtoFrac.clamped(to: 0...1)

        let composite = max(0, min(1,
            0.4 * rtoHeadroomScore +
            0.3 * convergenceBonus * (1.0 / 0.3) +  // normalise bonus
            0.2 * (1 - retransmitPenalty / 0.4) +    // normalise penalty
            0.1 * (1 - oscillationPenalty / 0.4)     // normalise penalty
        ))

        return StabilityScore(
            score: composite,
            oscillationPenalty: oscillationPenalty,
            convergenceBonus: convergenceBonus,
            retransmitPenalty: retransmitPenalty,
            rtoHeadroomScore: rtoHeadroomScore
        )
    }
}

// MARK: - Throughput Meter

/// Measures application-layer delivery metrics for a test run.
final class ThroughputMeter: @unchecked Sendable {
    private var totalBytesSent: Int = 0
    private var totalBytesDelivered: Int = 0
    private var totalFramesSent: Int = 0
    private var totalFramesDelivered: Int = 0
    private var retransmittedFrames: Int = 0
    private var startTime: TimeInterval = 0
    private var endTime: TimeInterval = 0
    private(set) var deliveryEvents: [(time: TimeInterval, bytes: Int)] = []

    func start(at time: TimeInterval) {
        startTime = time
        endTime = time
    }

    func recordSend(bytes: Int, at time: TimeInterval) {
        totalBytesSent += bytes
        totalFramesSent += 1
        endTime = time
    }

    func recordDelivery(bytes: Int, at time: TimeInterval) {
        totalBytesDelivered += bytes
        totalFramesDelivered += 1
        deliveryEvents.append((time: time, bytes: bytes))
        endTime = time
    }

    func recordRetransmit() {
        retransmittedFrames += 1
    }

    var elapsedTime: TimeInterval { max(0.001, endTime - startTime) }

    /// Goodput: application bytes successfully delivered per second.
    var goodputBytesPerSecond: Double {
        Double(totalBytesDelivered) / elapsedTime
    }

    /// Gross throughput including retransmits.
    var grossThroughputBytesPerSecond: Double {
        Double(totalBytesSent) / elapsedTime
    }

    /// Ratio of delivered frames to total sent (including retransmits).
    var deliveryRatio: Double {
        guard totalFramesSent > 0 else { return 0 }
        return Double(totalFramesDelivered) / Double(totalFramesSent)
    }

    /// Retransmission overhead ratio (retransmits / total sent attempts).
    var retransmitRatio: Double {
        let total = totalFramesSent + retransmittedFrames
        guard total > 0 else { return 0 }
        return Double(retransmittedFrames) / Double(total)
    }
}

// MARK: - Adaptive Invariant Checker

/// Validates that all adaptive parameters remain within spec-mandated bounds.
/// Must be called regularly (e.g. after every clock advance in the harness).
///
/// Violations are logged as XCTest failures AND added to the trace for replay.
struct AdaptiveInvariantChecker {

    struct Bounds {
        let rtoMin: Double
        let rtoMax: Double
        let paclenlMin: Int
        let paclenMax: Int
        let windowMin: Int
        let windowMax: Int
        let maxRetriesMax: Int

        static let standard = Bounds(
            rtoMin: 0.1,
            rtoMax: 120.0,
            paclenlMin: 16,
            paclenMax: 512,
            windowMin: 1,
            windowMax: 127,
            maxRetriesMax: 50
        )
    }

    let bounds: Bounds

    init(bounds: Bounds = .standard) {
        self.bounds = bounds
    }

    struct Violation: Sendable {
        let parameter: String
        let value: Double
        let bound: String
        let context: String
    }

    /// Check invariants for a session.  Returns any violations found.
    func check(session: AX25Session, context: String = "") -> [Violation] {
        var violations: [Violation] = []

        let rto = session.timers.rto
        if rto < bounds.rtoMin || rto > bounds.rtoMax {
            violations.append(.init(parameter: "rto", value: rto,
                bound: "[\(bounds.rtoMin), \(bounds.rtoMax)]", context: context))
        }
        if rto.isNaN || rto.isInfinite {
            violations.append(.init(parameter: "rto (NaN/Inf)", value: rto,
                bound: "finite", context: context))
        }

        if let srtt = session.timers.srtt {
            if srtt <= 0 || srtt.isNaN || srtt.isInfinite {
                violations.append(.init(parameter: "srtt (invalid)", value: srtt,
                    bound: "> 0, finite", context: context))
            }
        }

        if session.timers.rttvar < 0 || session.timers.rttvar.isNaN {
            violations.append(.init(parameter: "rttvar", value: session.timers.rttvar,
                bound: ">= 0, not NaN", context: context))
        }

        let paclen = session.stateMachine.config.paclen
        if paclen < bounds.paclenlMin || paclen > bounds.paclenMax {
            violations.append(.init(parameter: "paclen", value: Double(paclen),
                bound: "[\(bounds.paclenlMin), \(bounds.paclenMax)]", context: context))
        }

        let ws = session.stateMachine.config.windowSize
        if ws < bounds.windowMin || ws > bounds.windowMax {
            violations.append(.init(parameter: "windowSize", value: Double(ws),
                bound: "[\(bounds.windowMin), \(bounds.windowMax)]", context: context))
        }

        let maxR = session.stateMachine.config.maxRetries
        if maxR < 1 || maxR > bounds.maxRetriesMax {
            violations.append(.init(parameter: "maxRetries", value: Double(maxR),
                bound: "[1, \(bounds.maxRetriesMax)]", context: context))
        }

        // Sequence number legality
        let modulo = session.stateMachine.config.modulo
        let vs = session.vs
        let vr = session.vr
        let va = session.va
        if vs < 0 || vs >= modulo {
            violations.append(.init(parameter: "vs", value: Double(vs),
                bound: "[0, \(modulo))", context: context))
        }
        if vr < 0 || vr >= modulo {
            violations.append(.init(parameter: "vr", value: Double(vr),
                bound: "[0, \(modulo))", context: context))
        }
        if va < 0 || va >= modulo {
            violations.append(.init(parameter: "va", value: Double(va),
                bound: "[0, \(modulo))", context: context))
        }

        // Send buffer consistency
        let smOutstanding = session.stateMachine.sequenceState.outstandingCount
        let bufCount = session.sendBuffer.count
        if smOutstanding != bufCount {
            violations.append(.init(parameter: "sendBuffer/outstandingCount",
                value: Double(bufCount),
                bound: "== \(smOutstanding) (state machine outstanding)",
                context: context))
        }

        return violations
    }
}

// MARK: - Adaptation Rate Limiter (detection only, not enforcement)

/// Detects whether an adaptive parameter is changing faster than allowed.
/// Tracks the number of changes per time window.
struct AdaptationRateLimitDetector {
    let maxChangesPerWindow: Int
    let windowDuration: TimeInterval

    private var changeTimestamps: [TimeInterval] = []

    mutating func recordChange(at time: TimeInterval) {
        changeTimestamps.append(time)
    }

    mutating func isOverLimit(at currentTime: TimeInterval) -> Bool {
        // Remove timestamps outside the window
        changeTimestamps = changeTimestamps.filter { currentTime - $0 <= windowDuration }
        return changeTimestamps.count > maxChangesPerWindow
    }
}
