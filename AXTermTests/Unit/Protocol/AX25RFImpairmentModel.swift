//
//  AX25RFImpairmentModel.swift
//  AXTermTests
//
//  Deterministic RF impairment simulation for adaptive AX.25 testing.
//
//  All impairment generators:
//    - accept a seeded SplitMix64 RNG for reproducible behaviour
//    - are composable (CompositeImpairmentModel)
//    - support time-based phase switching (ImpairmentTimeline)
//    - emit FrameDisposition, not side-effects
//
//  Impairment models implemented:
//    PerfectChannelModel       — no loss, fixed latency
//    UniformLossModel          — independent loss at fixed probability
//    AsymmetricLossModel       — different forward / reverse loss rates
//    BurstLossModel            — Markov 2-state good/bad channel (Gilbert-Elliott simplified)
//    GilbertElliottModel       — 4-parameter Gilbert-Elliott with per-state BER
//    LatencyJitterModel        — adds deterministic jitter to a base model
//    DuplicationModel          — delivers each frame a second time with some probability
//    AlternatingChannelModel   — good for T_good seconds, bad for T_bad seconds, repeating
//    ImpairmentTimeline        — ordered sequence of (deadline, model) phases
//    CompositeImpairmentModel  — applies several models in pipeline order
//

import Foundation
@testable import AXTerm

// MARK: - Seeded RNG (reuses SplitMix64 algorithm already present in AX25Fuzzer)

/// Lightweight seeded pseudo-random number generator.
/// Uses the SplitMix64 algorithm — high quality, fast, period = 2^64.
/// All adaptive test impairment models take an `inout RFRng` parameter so
/// the caller owns the RNG state and replay is trivial: save the seed.
struct RFRng: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64 = 42) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z &>> 27)) &* 0x94d049bb133111eb
        return z ^ (z &>> 31)
    }

    /// Uniform double in [0, 1).
    mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Returns true with the given probability.
    mutating func chance(_ p: Double) -> Bool {
        p > 0 && (p >= 1.0 || nextDouble() < p)
    }

    /// Uniform double in [lo, hi].
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + nextDouble() * (hi - lo)
    }
}

// MARK: - Frame Disposition

/// What the impairment model decides to do with a single in-flight frame.
enum FrameDisposition: Equatable {
    /// Deliver normally after `delay` seconds of propagation.
    case deliver(delay: TimeInterval)

    /// Frame is lost — the sender will see a timeout.
    case drop

    /// Frame is delivered twice: first copy at `firstDelay`, second at `secondDelay`.
    /// Models radio duplication (adjacent repeaters, multipath echo).
    case duplicate(firstDelay: TimeInterval, secondDelay: TimeInterval)
}

// MARK: - Impairment Direction

/// Which half of the link an impairment applies to.
enum ImpairmentDirection {
    case forward    // local → remote
    case reverse    // remote → local (ACK path)
    case both
}

// MARK: - Impairment Model Protocol

/// A model that decides, given a frame and current virtual time, what should happen to it.
protocol RFImpairmentModel {
    /// Evaluate disposition for one frame.
    /// - Parameters:
    ///   - type: AX.25 frame type: "i", "s", or "u"
    ///   - direction: Which direction on the link this frame is travelling.
    ///   - time: Current virtual clock time (seconds).
    ///   - rng: Caller-owned RNG for deterministic randomness.
    /// - Returns: What to do with the frame.
    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition
}

// MARK: - Perfect Channel

/// Lossless channel with a fixed propagation delay.
struct PerfectChannelModel: RFImpairmentModel {
    /// One-way propagation time (seconds).
    var latency: TimeInterval

    init(latency: TimeInterval = 0.1) {
        self.latency = max(0, latency)
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        .deliver(delay: latency)
    }
}

// MARK: - Uniform Loss

/// Each frame is independently dropped with probability `lossProbability`.
/// Models a white-noise RF channel with memoryless loss.
struct UniformLossModel: RFImpairmentModel {
    /// Base one-way propagation latency.
    var latency: TimeInterval

    /// Probability of dropping any given frame (0 = perfect, 1 = full blockage).
    var lossProbability: Double

    init(latency: TimeInterval = 0.1, lossProbability: Double) {
        self.latency = max(0, latency)
        self.lossProbability = lossProbability.clamped(to: 0...1)
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        rng.chance(lossProbability) ? .drop : .deliver(delay: latency)
    }
}

// MARK: - Asymmetric Loss

/// Different loss rates on the forward and reverse (ACK) paths.
/// Models classic packet radio where the downlink path is noisier than the uplink,
/// or vice versa, causing the sender to see disproportionate ACK loss.
struct AsymmetricLossModel: RFImpairmentModel {
    var latency: TimeInterval
    /// Loss probability for frames going forward (local → remote).
    var forwardLoss: Double
    /// Loss probability for frames going reverse (remote → local / ACK path).
    var reverseLoss: Double

    init(latency: TimeInterval = 0.1, forwardLoss: Double, reverseLoss: Double) {
        self.latency = max(0, latency)
        self.forwardLoss = forwardLoss.clamped(to: 0...1)
        self.reverseLoss = reverseLoss.clamped(to: 0...1)
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        let p = direction == .reverse ? reverseLoss : forwardLoss
        return rng.chance(p) ? .drop : .deliver(delay: latency)
    }
}

// MARK: - Burst Loss (Markov 2-State / Gilbert model)

/// Two-state Markov channel:
///   Good state → each frame lost with probability `goodLoss` (typically ~0)
///   Bad  state → each frame lost with probability `badLoss`  (typically ~0.9)
/// Transitions:
///   Good → Bad with probability `goodToBad` per frame
///   Bad  → Good with probability `badToGood` per frame
///
/// This models RF fading/shadowing, temporary interference, and channel bursts.
/// All transitions are driven by the caller's RNG.
struct BurstLossModel: RFImpairmentModel {
    var latency: TimeInterval

    // Per-frame transition probabilities
    var goodToBadProbability: Double
    var badToGoodProbability: Double

    // Per-frame loss probabilities in each state
    var goodStateLoss: Double
    var badStateLoss: Double

    // Current Markov state (mutable across frames)
    private(set) var isInBadState: Bool

    init(
        latency: TimeInterval = 0.1,
        goodToBad: Double = 0.05,
        badToGood: Double = 0.3,
        goodLoss: Double = 0.01,
        badLoss: Double = 0.9,
        startInBadState: Bool = false
    ) {
        self.latency = max(0, latency)
        self.goodToBadProbability = goodToBad.clamped(to: 0...1)
        self.badToGoodProbability = badToGood.clamped(to: 0...1)
        self.goodStateLoss = goodLoss.clamped(to: 0...1)
        self.badStateLoss = badLoss.clamped(to: 0...1)
        self.isInBadState = startInBadState
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        // State transition
        if isInBadState {
            if rng.chance(badToGoodProbability) { isInBadState = false }
        } else {
            if rng.chance(goodToBadProbability) { isInBadState = true }
        }

        let lossProbability = isInBadState ? badStateLoss : goodStateLoss
        return rng.chance(lossProbability) ? .drop : .deliver(delay: latency)
    }
}

// MARK: - Gilbert-Elliott (4-parameter extended)

/// Full Gilbert-Elliott model with:
///   - 2 states (Good, Bad)
///   - Independent transition probabilities p (G→B) and q (B→G)
///   - Per-state BER (bit error rate, used here as frame loss proxy)
///   - Optional latency spike in bad state
///
/// Closely matches the model used in RFC 4588 and most wireless channel simulations.
struct GilbertElliottModel: RFImpairmentModel {
    var baseLatency: TimeInterval
    var badStateLatencyBonus: TimeInterval   // Extra delay when in bad state

    var pGoodToBad: Double                   // p
    var qBadToGood: Double                   // q
    var goodStateBER: Double                 // h (error rate in good state)
    var badStateBER: Double                  // k (error rate in bad state)

    private(set) var inBadState: Bool

    init(
        baseLatency: TimeInterval = 0.1,
        badStateLatencyBonus: TimeInterval = 0.3,
        pGoodToBad: Double = 0.1,
        qBadToGood: Double = 0.4,
        goodBER: Double = 0.01,
        badBER: Double = 0.8,
        startBad: Bool = false
    ) {
        self.baseLatency = max(0, baseLatency)
        self.badStateLatencyBonus = max(0, badStateLatencyBonus)
        self.pGoodToBad = pGoodToBad.clamped(to: 0...1)
        self.qBadToGood = qBadToGood.clamped(to: 0...1)
        self.goodStateBER = goodBER.clamped(to: 0...1)
        self.badStateBER = badBER.clamped(to: 0...1)
        self.inBadState = startBad
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        // State transition first (per-frame)
        if inBadState {
            if rng.chance(qBadToGood) { inBadState = false }
        } else {
            if rng.chance(pGoodToBad) { inBadState = true }
        }

        let ber = inBadState ? badStateBER : goodStateBER
        if rng.chance(ber) {
            return .drop
        }
        let delay = inBadState ? baseLatency + badStateLatencyBonus : baseLatency
        return .deliver(delay: delay)
    }
}

// MARK: - Latency Jitter Wrapper

/// Wraps another model and adds random latency jitter to all `deliver` dispositions.
/// `deliver(delay: d)` becomes `deliver(delay: d + uniform(-jitter, +jitter))`.
/// Models oscillating propagation delay common in HF and digipeated VHF links.
struct LatencyJitterModel: RFImpairmentModel {
    var inner: any RFImpairmentModel
    /// Maximum one-sided jitter (seconds). Actual jitter is uniform in [-maxJitter, +maxJitter].
    var maxJitter: TimeInterval
    /// Minimum delivery delay after jitter is applied (floor prevents negative latency).
    var minimumDelay: TimeInterval

    init(
        wrapping inner: any RFImpairmentModel,
        maxJitter: TimeInterval = 0.05,
        minimumDelay: TimeInterval = 0.005
    ) {
        self.inner = inner
        self.maxJitter = max(0, maxJitter)
        self.minimumDelay = max(0, minimumDelay)
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        let base = inner.disposition(type: type, direction: direction, time: time, rng: &rng)
        switch base {
        case .deliver(let delay):
            let jitter = rng.uniform(-maxJitter, maxJitter)
            return .deliver(delay: max(minimumDelay, delay + jitter))
        case .drop:
            return .drop
        case .duplicate(let first, let second):
            let j1 = rng.uniform(-maxJitter, maxJitter)
            let j2 = rng.uniform(-maxJitter, maxJitter)
            return .duplicate(
                firstDelay: max(minimumDelay, first + j1),
                secondDelay: max(minimumDelay, second + j2)
            )
        }
    }
}

// MARK: - Duplication Model

/// Independently duplicates delivered frames with probability `duplicateProbability`.
/// The duplicate arrives `duplicateDelay` seconds after the original.
/// Models digipeater double-fire, multipath reflections, or AGWPE duplicate injection.
struct DuplicationModel: RFImpairmentModel {
    var inner: any RFImpairmentModel
    var duplicateProbability: Double
    var duplicateDelay: TimeInterval

    init(
        wrapping inner: any RFImpairmentModel,
        duplicateProbability: Double = 0.15,
        duplicateDelay: TimeInterval = 0.05
    ) {
        self.inner = inner
        self.duplicateProbability = duplicateProbability.clamped(to: 0...1)
        self.duplicateDelay = max(0.001, duplicateDelay)
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        let base = inner.disposition(type: type, direction: direction, time: time, rng: &rng)
        switch base {
        case .deliver(let delay):
            if rng.chance(duplicateProbability) {
                return .duplicate(firstDelay: delay, secondDelay: delay + duplicateDelay)
            }
            return .deliver(delay: delay)
        default:
            return base
        }
    }
}

// MARK: - Alternating Channel

/// Alternates between a "good" and a "bad" model in fixed time slots.
/// `good` model runs for `goodDuration` seconds, then `bad` for `badDuration`, repeating.
/// Models periodic interference (TDMA bleed, microwave link cycles, ionospheric fading).
struct AlternatingChannelModel: RFImpairmentModel {
    var goodModel: any RFImpairmentModel
    var badModel: any RFImpairmentModel
    var goodDuration: TimeInterval
    var badDuration: TimeInterval
    var epochStart: TimeInterval    // Virtual time when the first good phase began

    init(
        good: any RFImpairmentModel,
        bad: any RFImpairmentModel,
        goodDuration: TimeInterval = 5.0,
        badDuration: TimeInterval = 2.0,
        epochStart: TimeInterval = 0.0
    ) {
        self.goodModel = good
        self.badModel = bad
        self.goodDuration = max(0.001, goodDuration)
        self.badDuration  = max(0.001, badDuration)
        self.epochStart   = epochStart
    }

    var cycleDuration: TimeInterval { goodDuration + badDuration }

    func isInGoodPhase(at time: TimeInterval) -> Bool {
        let t = (time - epochStart).truncatingRemainder(dividingBy: cycleDuration)
        return t < goodDuration
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        if isInGoodPhase(at: time) {
            return goodModel.disposition(type: type, direction: direction, time: time, rng: &rng)
        } else {
            return badModel.disposition(type: type, direction: direction, time: time, rng: &rng)
        }
    }
}

// MARK: - Impairment Timeline

/// A sequence of timed phases, each with its own impairment model.
/// Phases are evaluated in order; the last phase whose `startTime <= currentTime` is active.
///
/// Usage:
///   var timeline = ImpairmentTimeline(defaultModel: PerfectChannelModel())
///   timeline.add(at: 5.0, model: UniformLossModel(lossProbability: 0.3))  // degrade at t=5
///   timeline.add(at: 15.0, model: PerfectChannelModel())                  // recover at t=15
struct ImpairmentTimeline: RFImpairmentModel {
    private struct Phase {
        let startTime: TimeInterval
        var model: any RFImpairmentModel
    }

    private var phases: [Phase] = []
    private var defaultModel: any RFImpairmentModel

    init(defaultModel: any RFImpairmentModel = PerfectChannelModel()) {
        self.defaultModel = defaultModel
    }

    /// Add a new phase that begins at `startTime`.
    mutating func add(at startTime: TimeInterval, model: any RFImpairmentModel) {
        phases.append(Phase(startTime: startTime, model: model))
        phases.sort { $0.startTime < $1.startTime }
    }

    private func activePhaseIndex(at time: TimeInterval) -> Int? {
        // Last phase whose startTime <= time
        var active: Int? = nil
        for (i, phase) in phases.enumerated() {
            if phase.startTime <= time { active = i } else { break }
        }
        return active
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        if let idx = activePhaseIndex(at: time) {
            return phases[idx].model.disposition(type: type, direction: direction, time: time, rng: &rng)
        }
        return defaultModel.disposition(type: type, direction: direction, time: time, rng: &rng)
    }
}

// MARK: - Composite (Pipeline) Model

/// Applies an ordered list of impairment models in series.
/// The first model that returns `.drop` wins. If all return `.deliver`, the LAST model's
/// delay is used (pipeline semantics: impairments accumulate, last wins on timing).
/// If any model returns `.duplicate`, the first duplication decision wins.
///
/// This allows layering: e.g. UniformLoss → LatencyJitter → DuplicationModel.
struct CompositeImpairmentModel: RFImpairmentModel {
    var stages: [any RFImpairmentModel]

    init(_ stages: [any RFImpairmentModel] = []) {
        self.stages = stages
    }

    mutating func add(_ model: any RFImpairmentModel) {
        stages.append(model)
    }

    mutating func disposition(
        type: String,
        direction: ImpairmentDirection,
        time: TimeInterval,
        rng: inout RFRng
    ) -> FrameDisposition {
        var finalDisposition: FrameDisposition = .deliver(delay: 0)

        for i in stages.indices {
            let d = stages[i].disposition(type: type, direction: direction, time: time, rng: &rng)
            switch d {
            case .drop:
                return .drop   // First drop wins
            case .duplicate:
                return d       // First duplication wins
            case .deliver(let delay):
                // Accumulate to get latest timing
                finalDisposition = .deliver(delay: delay)
            }
        }
        return finalDisposition
    }
}

// MARK: - Convenience Factories

extension PerfectChannelModel {
    static let default_ = PerfectChannelModel(latency: 0.1)
}

extension UniformLossModel {
    /// Typical VHF AX.25 link under moderate QRM.
    static func vhfModerate(latency: TimeInterval = 0.1) -> UniformLossModel {
        UniformLossModel(latency: latency, lossProbability: 0.08)
    }
    /// Severe HF link.
    static func hfSevere(latency: TimeInterval = 0.5) -> UniformLossModel {
        UniformLossModel(latency: latency, lossProbability: 0.35)
    }
}

extension BurstLossModel {
    /// Short, recoverable fading burst (models QRM from a nearby transmitter).
    static func shortBurst(latency: TimeInterval = 0.1) -> BurstLossModel {
        BurstLossModel(
            latency: latency,
            goodToBad: 0.05,
            badToGood: 0.5,
            goodLoss: 0.0,
            badLoss: 1.0
        )
    }
    /// Long, deep fade (e.g. shadow margin exhausted during mobile operation).
    static func deepFade(latency: TimeInterval = 0.15) -> BurstLossModel {
        BurstLossModel(
            latency: latency,
            goodToBad: 0.03,
            badToGood: 0.1,
            goodLoss: 0.02,
            badLoss: 0.95
        )
    }
}

// MARK: - Helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
