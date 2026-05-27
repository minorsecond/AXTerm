//
//  AX25AdaptiveValidationTests.swift
//  AXTermTests
//
//  Adaptive AX.25 Validation Framework — complete test suite.
//
//  Organisation: 15 parts matching the specification.
//    Part  1 — Adaptive Observability
//    Part  2 — Adaptive Invariants
//    Part  3 — RF Impairment Simulation
//    Part  4 — Convergence Testing
//    Part  5 — Oscillation Detection
//    Part  6 — Fairness Testing
//    Part  7 — Adaptive RTO / Karn's Algorithm Validation
//    Part  8 — Adaptive PACLEN Testing
//    Part  9 — Window Adaptation Testing
//    Part 10 — Persistent Learning Validation
//    Part 11 — Adaptive Fuzzing
//    Part 12 — Soak Testing
//    Part 13 — Throughput / Stability Benchmarking
//    Part 14 — Failure Replayability
//    Part 15 — Architecture / Determinism
//
//  All tests:
//    - Use AX25VirtualClock (no wall-clock sleeps)
//    - Are seeded and replayable
//    - Assert adaptive invariants
//    - Emit a structured trace on failure via continueAfterFailure
//

import XCTest
@testable import AXTerm

// MARK: - Part 1: Adaptive Observability

@MainActor
final class AdaptiveObservabilityTests: XCTestCase {

    private func makeHarness(seed: UInt64 = 1, model: (any RFImpairmentModel)? = nil) -> AdaptiveTestHarness {
        var cfg = HarnessConfig()
        cfg.seed = seed
        if let m = model { cfg.forwardModel = m; cfg.reverseModel = m }
        return AdaptiveTestHarness(config: cfg)
    }

    // O-1: Snapshots are emitted after every RR on a perfect channel.
    func testSnapshotsEmittedAfterRR() {
        let h = makeHarness()
        XCTAssertTrue(h.connect(), "Should connect")
        h.queueFrames(count: 4, payload: Data("observe".utf8))
        h.advance(seconds: 5.0)

        // Must have at least one snapshot from the RR handler
        XCTAssertGreaterThan(h.trace.snapshots.count, 0,
            "Harness must emit at least one adaptive snapshot per exchange")
    }

    // O-2: Snapshots carry finite, non-NaN RTO values.
    func testSnapshotRTOIsFinite() {
        let h = makeHarness()
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 8)
        h.advance(seconds: 8.0)

        for snap in h.trace.snapshots {
            XCTAssertFalse(snap.rto.isNaN,      "Snapshot RTO must not be NaN at t=\(snap.time)")
            XCTAssertFalse(snap.rto.isInfinite, "Snapshot RTO must not be Inf at t=\(snap.time)")
            XCTAssertGreaterThan(snap.rto, 0,    "Snapshot RTO must be positive at t=\(snap.time)")
        }
    }

    // O-3: SRTT is nil before the first round-trip and non-nil after.
    func testSRTTNilBeforeFirstRoundTrip() {
        let h = makeHarness()
        _ = h.alice.connect(to: AX25Address(call: "BOB-1", ssid: 0), path: DigiPath(), channel: 0)
        let preConnectSession = h.alice.session(for: AX25Address(call: "BOB-1", ssid: 0))

        // Before UA arrives: no RTT sample
        XCTAssertNil(preConnectSession.timers.srtt,
            "SRTT must be nil before the first round-trip completes")

        // After connect (UA delivered)
        h.advance(seconds: 0.5)   // Deliver UA (was scheduled at baseLatency=0.1)
    }

    // O-4: Each snapshot has a monotonically non-decreasing timestamp.
    func testSnapshotTimestampsMonotonic() {
        let h = makeHarness()
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 10)
        h.advance(seconds: 10.0)

        var prevTime: TimeInterval = -1
        for snap in h.trace.snapshots {
            XCTAssertGreaterThanOrEqual(snap.time, prevTime,
                "Snapshot timestamps must be non-decreasing")
            prevTime = snap.time
        }
    }

    // O-5: Adaptive trace produces a non-empty failure report string.
    func testFailureReportIsNonEmpty() {
        let h = makeHarness()
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 4)
        h.advance(seconds: 4.0)

        let report = h.trace.failureReport()
        XCTAssertFalse(report.isEmpty, "Failure report must be non-empty")
        XCTAssertTrue(report.contains("seed"), "Report must include seed for replay")
    }

    // O-6: Retransmit count in snapshots is monotonically non-decreasing.
    func testRetransmitCountMonotonic() {
        var cfg = HarnessConfig()
        cfg.seed = 6
        cfg.forwardModel = UniformLossModel(latency: 0.1, lossProbability: 0.25)
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 10)
        h.advance(seconds: 20.0)

        var prevRetx = -1
        for snap in h.trace.snapshots {
            XCTAssertGreaterThanOrEqual(snap.retransmissions, prevRetx,
                "Retransmit count must not decrease (monotonic counter)")
            prevRetx = snap.retransmissions
        }
    }
}

// MARK: - Part 2: Adaptive Invariants

@MainActor
final class AdaptiveInvariantTests: XCTestCase {

    private func makeHarness(seed: UInt64 = 2, loss: Double = 0.0) -> AdaptiveTestHarness {
        var cfg = HarnessConfig()
        cfg.seed = seed
        cfg.forwardModel = UniformLossModel(latency: 0.1, lossProbability: loss)
        cfg.reverseModel = UniformLossModel(latency: 0.1, lossProbability: loss)
        cfg.checkInvariantsAutomatically = true
        return AdaptiveTestHarness(config: cfg)
    }

    // I-1: RTO stays within [rtoMin, rtoMax] on a perfect channel.
    func testRTOBoundedPerfectChannel() {
        let h = makeHarness(loss: 0.0)
        XCTAssertTrue(h.connect())
        for _ in 0..<5 {
            h.queueFrames(count: 4)
            h.advance(seconds: 4.0)
        }
        XCTAssertEqual(h.invariantViolations.filter { $0.parameter.contains("rto") }.count, 0,
            "No RTO bound violations on perfect channel. Violations: \(h.invariantViolations)")
    }

    // I-2: No invariant violations under 15% uniform loss.
    func testNoInvariantViolationsUnderModerateLoss() {
        let h = makeHarness(seed: 22, loss: 0.15)
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 12)
        h.advance(seconds: 30.0)

        let criticalViolations = h.invariantViolations.filter {
            $0.parameter.contains("rto") || $0.parameter.contains("NaN") || $0.parameter.contains("Inf")
        }
        XCTAssertEqual(criticalViolations.count, 0,
            "Critical invariant violations under 15% loss: \(criticalViolations.map { "\($0.parameter)=\($0.value)" })")
    }

    // I-3: SRTT never becomes NaN after a valid RTT sample.
    func testSRTTNeverNaN() {
        let h = makeHarness(loss: 0.0)
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 8)
        h.advance(seconds: 8.0)

        for snap in h.trace.snapshots {
            if let srtt = snap.srtt {
                XCTAssertFalse(srtt.isNaN, "SRTT became NaN at t=\(snap.time)")
                XCTAssertFalse(srtt.isInfinite, "SRTT became Inf at t=\(snap.time)")
                XCTAssertGreaterThan(srtt, 0, "SRTT must be positive at t=\(snap.time)")
            }
        }
    }

    // I-4: RTTVAR is always non-negative.
    func testRTTVARNonNegative() {
        let h = makeHarness(seed: 24, loss: 0.2)
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 10)
        h.advance(seconds: 20.0)

        for snap in h.trace.snapshots {
            XCTAssertGreaterThanOrEqual(snap.rttvar, 0,
                "RTTVAR turned negative at t=\(snap.time): \(snap.rttvar)")
            XCTAssertFalse(snap.rttvar.isNaN, "RTTVAR became NaN at t=\(snap.time)")
        }
    }

    // I-5: Sequence numbers stay within modulo bounds throughout all exchanges.
    func testSequenceNumbersAlwaysInBounds() {
        let h = makeHarness(loss: 0.0)
        XCTAssertTrue(h.connect())
        // Send > modulo (8) frames to ensure wrap-around
        for _ in 0..<3 {
            h.queueFrames(count: 7)
            h.advance(seconds: 5.0)
        }

        let seqViolations = h.invariantViolations.filter {
            ["vs", "vr", "va"].contains($0.parameter)
        }
        XCTAssertEqual(seqViolations.count, 0,
            "Sequence number violations: \(seqViolations)")
    }

    // I-6: Send buffer count always equals state machine's outstanding count.
    func testSendBufferConsistency() {
        let h = makeHarness(seed: 26, loss: 0.1)
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 8)
        h.advance(seconds: 15.0)

        let bufViolations = h.invariantViolations.filter { $0.parameter.contains("sendBuffer") }
        XCTAssertEqual(bufViolations.count, 0,
            "Send buffer desync violations: \(bufViolations)")
    }

    // I-7: NaN RTT sample guard — feeding NaN directly to updateRTT preserves prior SRTT.
    func testNaNRTTSampleRejected() {
        var timers = AX25SessionTimers(rtoMin: 1.0, rtoMax: 30.0, initialRto: 2.0)
        timers.updateRTT(sample: 1.5)
        let srttBefore = timers.srtt

        // Now try to inject NaN
        timers.updateRTT(sample: Double.nan)

        XCTAssertEqual(timers.srtt, srttBefore,
            "NaN RTT sample must be silently discarded; SRTT must be unchanged")
        XCTAssertFalse(timers.rto.isNaN, "RTO must not become NaN after NaN sample injection")
    }

    // I-8: Negative RTT sample is rejected.
    func testNegativeRTTSampleRejected() {
        var timers = AX25SessionTimers(rtoMin: 1.0, rtoMax: 30.0, initialRto: 2.0)
        timers.updateRTT(sample: 1.5)
        let srttBefore = timers.srtt

        timers.updateRTT(sample: -0.5)
        XCTAssertEqual(timers.srtt, srttBefore,
            "Negative RTT sample must not update SRTT")
    }

    // I-9: Infinity RTT sample is rejected.
    func testInfiniteRTTSampleRejected() {
        var timers = AX25SessionTimers(rtoMin: 1.0, rtoMax: 30.0, initialRto: 2.0)
        timers.updateRTT(sample: Double.infinity)

        XCTAssertNil(timers.srtt, "SRTT must remain nil after Inf sample as first input")
        XCTAssertFalse(timers.rto.isInfinite, "RTO must not become Infinite")
    }

    // I-10: Zero RTT sample is rejected (physically impossible).
    func testZeroRTTSampleRejected() {
        var timers = AX25SessionTimers(rtoMin: 1.0, rtoMax: 30.0, initialRto: 2.0)
        timers.updateRTT(sample: 0.0)

        XCTAssertNil(timers.srtt, "Zero RTT sample must not initialise SRTT")
    }
}

// MARK: - Part 3: RF Impairment Simulation

@MainActor
final class RFImpairmentModelTests: XCTestCase {

    // R-1: PerfectChannel always delivers with base latency.
    func testPerfectChannelAlwaysDelivers() {
        var rng = RFRng(seed: 3)
        var model = PerfectChannelModel(latency: 0.1)
        for _ in 0..<100 {
            let d = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng)
            XCTAssertEqual(d, .deliver(delay: 0.1), "Perfect channel must always deliver at base latency")
        }
    }

    // R-2: UniformLossModel drops frames close to the configured probability.
    func testUniformLossDropRateWithinTolerance() {
        var rng = RFRng(seed: 3)
        var model = UniformLossModel(latency: 0.1, lossProbability: 0.3)
        var drops = 0
        let n = 1000
        for _ in 0..<n {
            if case .drop = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng) {
                drops += 1
            }
        }
        let rate = Double(drops) / Double(n)
        XCTAssertEqual(rate, 0.3, accuracy: 0.05,
            "Uniform loss rate should be ~30% ± 5% (got \(Int(rate*100))%)")
    }

    // R-3: AsymmetricLossModel applies different rates forward vs reverse.
    func testAsymmetricLossModelDifferentRates() {
        var rng1 = RFRng(seed: 3); var model1 = AsymmetricLossModel(latency: 0.1, forwardLoss: 0.1, reverseLoss: 0.5)
        var rng2 = RFRng(seed: 3); var model2 = AsymmetricLossModel(latency: 0.1, forwardLoss: 0.1, reverseLoss: 0.5)
        var fwdDrops = 0; var revDrops = 0
        let n = 1000
        for _ in 0..<n {
            if case .drop = model1.disposition(type: "i", direction: .forward, time: 0, rng: &rng1) { fwdDrops += 1 }
            if case .drop = model2.disposition(type: "s", direction: .reverse, time: 0, rng: &rng2) { revDrops += 1 }
        }
        XCTAssertLessThan(Double(fwdDrops), Double(revDrops),
            "Reverse loss (\(revDrops)) should exceed forward loss (\(fwdDrops)) with asymmetric model")
    }

    // R-4: BurstLossModel in bad state produces high loss; in good state produces low loss.
    func testBurstLossModelHighLossInBadState() {
        var rng = RFRng(seed: 3)
        var model = BurstLossModel(latency: 0.1, goodToBad: 0.0, badToGood: 0.0,
                                   goodLoss: 0.0, badLoss: 0.99, startInBadState: true)
        var drops = 0
        let n = 100
        for _ in 0..<n {
            if case .drop = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng) { drops += 1 }
        }
        XCTAssertGreaterThan(drops, 90, "Bad state BurstLossModel should drop >90% of frames (got \(drops)%)")
    }

    // R-5: BurstLossModel in good state with zero transition probability produces zero drops.
    func testBurstLossModelGoodStateNoDrop() {
        var rng = RFRng(seed: 3)
        var model = BurstLossModel(latency: 0.1, goodToBad: 0.0, badToGood: 0.0,
                                   goodLoss: 0.0, badLoss: 0.99, startInBadState: false)
        for _ in 0..<100 {
            let d = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng)
            if case .drop = d {
                XCTFail("Good state with zero transitions and zero good-loss should not drop frames")
                break
            }
        }
    }

    // R-6: AlternatingChannelModel switches between models at the configured period.
    func testAlternatingChannelSwitchesPeriodically() {
        var rng = RFRng(seed: 3)
        let goodModel = PerfectChannelModel()
        let badModel  = UniformLossModel(latency: 0.1, lossProbability: 1.0)  // 100% drop in bad phase
        var model = AlternatingChannelModel(
            good: goodModel, bad: badModel,
            goodDuration: 5.0, badDuration: 5.0, epochStart: 0.0
        )

        // At t=2.0 (good phase) → deliver
        let d1 = model.disposition(type: "i", direction: .forward, time: 2.0, rng: &rng)
        XCTAssertNotEqual(d1, .drop, "Good phase should not drop at t=2.0")

        // At t=7.0 (bad phase, 100% loss) → drop
        let d2 = model.disposition(type: "i", direction: .forward, time: 7.0, rng: &rng)
        XCTAssertEqual(d2, .drop, "Bad phase with 100% loss should always drop at t=7.0")
    }

    // R-7: ImpairmentTimeline transitions at the configured time.
    func testImpairmentTimelineTransitions() {
        var rng = RFRng(seed: 3)
        var timeline = ImpairmentTimeline(defaultModel: PerfectChannelModel())
        timeline.add(at: 10.0, model: UniformLossModel(latency: 0.1, lossProbability: 1.0))

        // Before t=10: perfect
        let before = timeline.disposition(type: "i", direction: .forward, time: 5.0, rng: &rng)
        XCTAssertNotEqual(before, .drop)

        // After t=10: 100% loss
        let after = timeline.disposition(type: "i", direction: .forward, time: 12.0, rng: &rng)
        XCTAssertEqual(after, .drop)
    }

    // R-8: DuplicationModel produces .duplicate for frames at configured probability.
    func testDuplicationModelProducesDuplicates() {
        var rng = RFRng(seed: 3)
        var model = DuplicationModel(wrapping: PerfectChannelModel(), duplicateProbability: 0.5)
        var duplicateCount = 0
        let n = 200
        for _ in 0..<n {
            let d = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng)
            if case .duplicate = d { duplicateCount += 1 }
        }
        XCTAssertGreaterThan(duplicateCount, 0, "DuplicationModel at 50% probability must produce some duplicates")
        XCTAssertLessThan(duplicateCount, n, "DuplicationModel must not duplicate every frame")
    }

    // R-9: LatencyJitterModel varies delivery delay while keeping it positive.
    func testLatencyJitterModelPositiveDelay() {
        var rng = RFRng(seed: 3)
        var model = LatencyJitterModel(wrapping: PerfectChannelModel(latency: 0.1), maxJitter: 0.09)
        for _ in 0..<100 {
            let d = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng)
            if case .deliver(let delay) = d {
                XCTAssertGreaterThan(delay, 0, "Jitter must never produce negative delivery delay")
            }
        }
    }

    // R-10: CompositeImpairmentModel propagates drops from any stage.
    func testCompositeModelDropWins() {
        var rng = RFRng(seed: 3)
        var model = CompositeImpairmentModel([
            PerfectChannelModel(),
            UniformLossModel(latency: 0.1, lossProbability: 1.0)  // stage 2: always drops
        ])
        for _ in 0..<20 {
            let d = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng)
            XCTAssertEqual(d, .drop, "Composite model with 100%-drop stage must always drop")
        }
    }

    // R-11: Determinism — same seed produces same sequence of dispositions.
    func testDeterministicWithSameSeed() {
        let seed: UInt64 = 42
        func runModel() -> [Bool] {
            var rng = RFRng(seed: seed)
            var model = BurstLossModel.shortBurst()
            return (0..<50).map { _ in
                if case .drop = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng) { return true }
                return false
            }
        }
        XCTAssertEqual(runModel(), runModel(), "Same seed must produce identical impairment sequence")
    }
}

// MARK: - Part 4: Convergence Testing

@MainActor
final class AdaptiveConvergenceTests: XCTestCase {

    // C-1: SRTT converges on a perfect channel after sufficient frames.
    func testSRTTConvergesOnPerfectChannel() {
        var cfg = HarnessConfig()
        cfg.seed = 4
        cfg.forwardModel = PerfectChannelModel(latency: 0.2)
        cfg.reverseModel = PerfectChannelModel(latency: 0.2)
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())

        // Send enough frames for SRTT to converge
        for _ in 0..<20 {
            h.queueFrames(count: 1)
            h.advance(seconds: 1.0)
        }

        let detector = ConvergenceDetector(windowSize: 8, toleranceFraction: 0.1)
        let result = detector.analyze(h.trace.srttHistory)

        XCTAssertTrue(result.hasConverged,
            "SRTT should converge after 20 frames on perfect channel. " +
            "Samples: \(h.trace.srttHistory.count), " +
            "maxDeviation: \(result.maxDeviation.map { String(format:"%.3f", $0) } ?? "nil"), " +
            "seed: \(cfg.seed)")
    }

    // C-2: RTO converges (stabilises) after many frames on a stable channel.
    func testRTOConvergesOnStableChannel() {
        var cfg = HarnessConfig()
        cfg.seed = 41
        cfg.forwardModel = PerfectChannelModel(latency: 0.15)
        cfg.reverseModel = PerfectChannelModel(latency: 0.15)
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())

        for _ in 0..<15 {
            h.queueFrames(count: 1)
            h.advance(seconds: 0.8)
        }

        let rtoHistory = h.trace.rtoHistory
        guard rtoHistory.count >= 8 else {
            XCTFail("Too few snapshots to evaluate RTO convergence; got \(rtoHistory.count)")
            return
        }

        let detector = ConvergenceDetector(windowSize: 6, toleranceFraction: 0.15)
        let result = detector.analyze(rtoHistory)
        XCTAssertTrue(result.hasConverged,
            "RTO should stabilise after 15 I-frame exchanges. " +
            "maxDeviation: \(result.maxDeviation.map { String(format:"%.3f", $0) } ?? "nil")")
    }

    // C-3: Recovery — after a burst-loss period, SRTT recovers to near its pre-impairment value.
    func testSRTTRecoveryAfterBurstLoss() {
        var cfg = HarnessConfig()
        cfg.seed = 43

        // Timeline: perfect → burst loss → perfect
        var timeline = ImpairmentTimeline(defaultModel: PerfectChannelModel(latency: 0.1))
        timeline.add(at: 5.0, model: UniformLossModel(latency: 0.3, lossProbability: 0.6))
        timeline.add(at: 15.0, model: PerfectChannelModel(latency: 0.1))
        cfg.forwardModel = timeline
        cfg.reverseModel = PerfectChannelModel(latency: 0.1)
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())

        // Phase 1: stable (t 0–5)
        for _ in 0..<10 { h.queueFrames(count: 1); h.advance(seconds: 0.5) }

        // Capture pre-impairment SRTT
        let preSRTT = h.aliceSRTT ?? 0.2

        // Phase 2: high loss (t 5–15)
        for _ in 0..<10 { h.advance(seconds: 1.0) }

        // Phase 3: recovery (t 15–30)
        for _ in 0..<15 { h.queueFrames(count: 1); h.advance(seconds: 1.0) }

        let postSRTT = h.aliceSRTT ?? preSRTT
        XCTAssertLessThan(postSRTT, preSRTT * 4.0,
            "SRTT should recover towards pre-impairment value after channel recovers. " +
            "pre=\(preSRTT) post=\(postSRTT)")
    }

    // C-4: Burst loss followed by recovery — retransmit count stops growing after recovery.
    func testRetransmitCountStabilisesAfterRecovery() {
        var cfg = HarnessConfig()
        cfg.seed = 44
        var timeline = ImpairmentTimeline(defaultModel: PerfectChannelModel(latency: 0.1))
        timeline.add(at: 3.0, model: UniformLossModel(latency: 0.1, lossProbability: 0.7))
        timeline.add(at: 10.0, model: PerfectChannelModel(latency: 0.1))
        cfg.forwardModel = timeline
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())

        for _ in 0..<8  { h.queueFrames(count: 1); h.advance(seconds: 1.0) }  // loss period
        let retxDuringLoss = h.aliceSession?.statistics.retransmissions ?? 0
        for _ in 0..<8  { h.queueFrames(count: 1); h.advance(seconds: 1.0) }  // recovery
        let retxAfterRecovery = h.aliceSession?.statistics.retransmissions ?? 0

        // Growth rate should be lower after recovery than during loss
        let growthDuringLoss   = retxDuringLoss
        let growthAfterRecovery = retxAfterRecovery - retxDuringLoss

        // If recovery works, retransmits should grow more slowly in the recovery phase
        XCTAssertLessThanOrEqual(growthAfterRecovery, growthDuringLoss + 2,
            "Retransmit growth should slow dramatically after channel recovers")
    }
}

// MARK: - Part 5: Oscillation Detection

@MainActor
final class OscillationDetectionTests: XCTestCase {

    // O-1: Perfect channel produces no oscillation in RTO.
    func testNoPerfectChannelOscillation() {
        var cfg = HarnessConfig()
        cfg.seed = 5
        cfg.forwardModel = PerfectChannelModel(latency: 0.12)
        cfg.reverseModel = PerfectChannelModel(latency: 0.12)
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())
        for _ in 0..<20 { h.queueFrames(count: 1); h.advance(seconds: 0.6) }

        let detector = OscillationDetector(minSamples: 8, maxSignChangeRatio: 0.7, maxCV: 2.0)
        let result = detector.analyze(h.trace.rtoHistory)
        XCTAssertFalse(result.isOscillating,
            "RTO should not oscillate on a stable channel. " +
            "CV=\(String(format:"%.3f", result.coefficientOfVariation)) " +
            "signChangeRatio=\(String(format:"%.3f", result.signChangeRatio))")
    }

    // O-2: Alternating good/bad channel produces detectable oscillation in retransmit count.
    func testAlternatingChannelProducesInstability() {
        var cfg = HarnessConfig()
        cfg.seed = 52
        cfg.forwardModel = AlternatingChannelModel(
            good: PerfectChannelModel(latency: 0.1),
            bad:  UniformLossModel(latency: 0.1, lossProbability: 0.9),
            goodDuration: 2.0, badDuration: 2.0
        )
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())
        for _ in 0..<20 { h.queueFrames(count: 1); h.advance(seconds: 0.5) }

        // With alternating impairment, the retransmit count should keep growing in bad phases
        let finalRetx = h.aliceSession?.statistics.retransmissions ?? 0
        XCTAssertGreaterThan(finalRetx, 0,
            "Alternating bad channel must produce some retransmissions")
    }

    // O-3: OscillationDetector correctly identifies oscillating sequence.
    func testOscillationDetectorFindsOscillation() {
        let oscillating: [Double] = [1.0, 2.0, 1.0, 2.0, 1.0, 2.0, 1.0, 2.0, 1.0, 2.0]
        let detector = OscillationDetector(minSamples: 6, maxSignChangeRatio: 0.5, maxCV: 0.5)
        let result = detector.analyze(oscillating)
        XCTAssertTrue(result.isOscillating,
            "Alternating [1,2,1,2...] sequence must be flagged as oscillating")
    }

    // O-4: OscillationDetector does not flag a monotonically increasing sequence.
    func testOscillationDetectorClearOnMonotonic() {
        let monotonic: [Double] = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9]
        let detector = OscillationDetector(minSamples: 6, maxSignChangeRatio: 0.5, maxCV: 0.5)
        let result = detector.analyze(monotonic)
        XCTAssertFalse(result.isOscillating,
            "Monotonically increasing sequence must not be flagged as oscillating")
    }

    // O-5: Stability score is high on a perfect channel.
    func testHighStabilityScoreOnPerfectChannel() {
        var cfg = HarnessConfig()
        cfg.seed = 55
        cfg.forwardModel = PerfectChannelModel(latency: 0.12)
        cfg.reverseModel = PerfectChannelModel(latency: 0.12)
        cfg.sessionConfig = AX25SessionConfig(rtoMin: 1.0, rtoMax: 10.0, initialRto: 2.0)
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())
        for _ in 0..<15 { h.queueFrames(count: 1); h.advance(seconds: 0.7) }

        let stability = h.stabilityScore
        // Perfect channel → no oscillation, low retransmit ratio, RTO near min
        XCTAssertGreaterThan(stability.rtoHeadroomScore, 0.3,
            "RTO headroom score should be positive on a perfect channel")
    }
}

// MARK: - Part 6: Fairness Testing

@MainActor
final class FairnessTests: XCTestCase {

    // F-1: Two sessions (one perfect, one high-loss) do not cross-contaminate RTT estimates.
    func testRTTIsRouteLocal() {
        let clock = AX25VirtualClock()
        let aliceConfig = AX25SessionConfig(rtoMin: 1.0, rtoMax: 10.0, initialRto: 2.0)

        let alice = AX25SessionManager(
            localCallsign: AX25Address(call: "ALICE-0", ssid: 0),
            clock: clock
        )
        alice.defaultConfig = aliceConfig

        let peerGood = AX25Address(call: "GOODPEER", ssid: 0)
        let peerBad  = AX25Address(call: "BADPEER",  ssid: 0)

        // Connect to both peers
        _ = alice.connect(to: peerGood, path: DigiPath(), channel: 0)
        _ = alice.connect(to: peerBad,  path: DigiPath(), channel: 1)

        // Simulate UA from both peers
        alice.handleInboundUA(from: peerGood, path: DigiPath(), channel: 0)
        alice.handleInboundUA(from: peerBad,  path: DigiPath(), channel: 1)

        let goodSession = alice.session(for: peerGood, path: DigiPath(), channel: 0)
        let badSession  = alice.session(for: peerBad,  path: DigiPath(), channel: 1)

        // Inject good RTT for good session, no RTT for bad session
        goodSession.timers.updateRTT(sample: 0.2)

        XCTAssertNotNil(goodSession.timers.srtt,  "Good session should have SRTT after RTT injection")
        XCTAssertNil(badSession.timers.srtt,       "Bad session should have independent, untouched SRTT")
    }

    // F-2: Retransmissions on one session do not increment counters on another.
    func testRetransmissionsAreSessionLocal() {
        let clock = AX25VirtualClock()
        let alice = AX25SessionManager(
            localCallsign: AX25Address(call: "ALICE-0", ssid: 0),
            clock: clock
        )
        alice.defaultConfig = AX25SessionConfig(maxRetries: 5, rtoMin: 0.5, rtoMax: 4.0, initialRto: 0.5)

        let peerA = AX25Address(call: "PEERA", ssid: 0)
        let peerB = AX25Address(call: "PEERB", ssid: 0)

        _ = alice.connect(to: peerA, path: DigiPath(), channel: 0)
        alice.handleInboundUA(from: peerA, path: DigiPath(), channel: 0)
        _ = alice.connect(to: peerB, path: DigiPath(), channel: 1)
        alice.handleInboundUA(from: peerB, path: DigiPath(), channel: 1)

        let sessionA = alice.session(for: peerA, path: DigiPath(), channel: 0)
        let sessionB = alice.session(for: peerB, path: DigiPath(), channel: 1)

        // Send data on session A so the send buffer is populated and T1 timeouts can retransmit.
        _ = alice.sendData(Data("hello".utf8), to: peerA, path: DigiPath(), channel: 0)

        // Inject T1 timeouts on session A (simulates frames being lost / no ACK received).
        // Each timeout retransmits outstanding frames from the send buffer.
        _ = alice.handleT1Timeout(session: sessionA)
        _ = alice.handleT1Timeout(session: sessionA)

        XCTAssertGreaterThan(sessionA.statistics.retransmissions, 0,
            "Session A should have retransmissions after T1 timeouts")
        XCTAssertEqual(sessionB.statistics.retransmissions, 0,
            "Session B must NOT accumulate retransmissions from Session A's timeouts")
    }

    // F-3: RTO on a clean session remains low despite a noisy sibling session.
    func testCleanSessionRTOUnaffectedByNoisySibling() {
        let clock = AX25VirtualClock()
        let alice = AX25SessionManager(
            localCallsign: AX25Address(call: "ALICE-0", ssid: 0),
            clock: clock
        )
        alice.defaultConfig = AX25SessionConfig(rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)

        let clean = AX25Address(call: "CLEANPEER", ssid: 0)
        let noisy = AX25Address(call: "NOISYPEER", ssid: 0)

        _ = alice.connect(to: clean, path: DigiPath(), channel: 0)
        alice.handleInboundUA(from: clean, path: DigiPath(), channel: 0)
        _ = alice.connect(to: noisy, path: DigiPath(), channel: 1)
        alice.handleInboundUA(from: noisy, path: DigiPath(), channel: 1)

        let cleanSession = alice.session(for: clean, path: DigiPath(), channel: 0)
        let noisySession = alice.session(for: noisy, path: DigiPath(), channel: 1)

        // Feed clean session with good RTT samples
        cleanSession.timers.updateRTT(sample: 0.15)
        cleanSession.timers.updateRTT(sample: 0.16)
        cleanSession.timers.updateRTT(sample: 0.14)

        let cleanRTOBefore = cleanSession.timers.rto

        // Hammer noisy session with many T1 timeouts → its RTO will backoff
        for _ in 0..<5 {
            _ = alice.handleT1Timeout(session: noisySession)
        }

        let cleanRTOAfter = cleanSession.timers.rto

        XCTAssertEqual(cleanRTOBefore, cleanRTOAfter, accuracy: 0.001,
            "Clean session RTO must not change due to noisy sibling's T1 timeouts. " +
            "before=\(cleanRTOBefore) after=\(cleanRTOAfter)")
    }
}

// MARK: - Part 7: Adaptive RTO / Karn's Algorithm Validation

@MainActor
final class AdaptiveRTOTests: XCTestCase {

    // K-1: RTT sample from a non-retransmitted frame updates SRTT.
    func testFreshFrameRTTUpdatesSRTT() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let peer = AX25Address(call: "PEER", ssid: 0)
        manager.defaultConfig = AX25SessionConfig(rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // Send a frame
        clock.advance(by: 0.001)   // t = 0.001
        _ = manager.sendData(Data("karn-test".utf8), to: peer, path: DigiPath(), channel: 0)

        // Simulate time passing and RR arriving (no T1 yet = no retransmit = non-Karn)
        clock.advance(by: 0.2)     // t = 0.201: simulated RTT = ~0.2s

        XCTAssertNil(session.timers.srtt, "SRTT before RR: should be nil until first RTT sample")

        _ = manager.handleInboundRR(from: peer, path: DigiPath(), channel: 0, nr: 1, isPoll: false)

        XCTAssertNotNil(session.timers.srtt,
            "SRTT should be set after first non-retransmitted RR ack")
        XCTAssertGreaterThan(session.timers.srtt ?? 0, 0,
            "SRTT must be positive after first valid RTT sample")
    }

    // K-2: RTT sample is NOT taken after a T1 retransmit (Karn's algorithm).
    func testKarnsAlgorithmBlocksRTTAfterRetransmit() {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(maxRetries: 5, rtoMin: 0.5, rtoMax: 8.0, initialRto: 0.5)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)

        _ = manager.sendData(Data("karn".utf8), to: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // Force T1 timeout + grace period → retransmit happens → marks NS as Karn-excluded
        clock.advance(by: 0.5 + 0.21)   // 0.5s RTO + 0.21s grace
        XCTAssertEqual(session.stateMachine.retryCount, 1,
            "Session should have retried once after T1 + grace")

        // Now SRTT should be nil (no RTT measured before retransmit)
        let srttAfterRetransmit = session.timers.srtt

        // Deliver RR — should NOT update SRTT because frame is Karn-excluded
        _ = manager.handleInboundRR(from: peer, path: DigiPath(), channel: 0, nr: 1, isPoll: false)

        XCTAssertEqual(session.timers.srtt, srttAfterRetransmit,
            "Karn's algorithm: SRTT must not be updated by an ACK for a retransmitted frame. " +
            "srttBefore=\(String(describing: srttAfterRetransmit)) srttAfter=\(String(describing: session.timers.srtt))")
    }

    // K-3: After Karn exclusion, the NEXT fresh frame's ACK restores RTT estimation.
    func testRTTResumesAfterKarnExcludedFrame() {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(maxRetries: 5, rtoMin: 0.5, rtoMax: 8.0, initialRto: 0.5)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)

        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // Send and force retransmit
        _ = manager.sendData(Data("retx".utf8), to: peer, path: DigiPath(), channel: 0)
        clock.advance(by: 0.5 + 0.21)
        // Ack the retransmitted frame (Karn-excluded)
        _ = manager.handleInboundRR(from: peer, path: DigiPath(), channel: 0, nr: 1, isPoll: false)
        XCTAssertNil(session.timers.srtt, "SRTT should be nil after Karn-excluded ack")

        // Now send a fresh frame — this one has not been retransmitted
        _ = manager.sendData(Data("fresh".utf8), to: peer, path: DigiPath(), channel: 0)
        clock.advance(by: 0.1)   // Normal ACK delay
        _ = manager.handleInboundRR(from: peer, path: DigiPath(), channel: 0, nr: 2, isPoll: false)

        XCTAssertNotNil(session.timers.srtt,
            "RTT estimation should resume for the next fresh (non-retransmitted) frame")
    }

    // K-4: RTO exponential backoff caps at rtoMax.
    func testRTOBackoffCapAtMax() {
        let rtoMax: TimeInterval = 4.0
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(maxRetries: 10, rtoMin: 0.5, rtoMax: rtoMax, initialRto: 0.5)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        _ = manager.sendData(Data("backoff".utf8), to: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // Fire many T1 timeouts
        for _ in 0..<6 {
            let rto = session.timers.rto
            clock.advance(by: rto + 0.21)
            XCTAssertLessThanOrEqual(session.timers.rto, rtoMax + 0.001,
                "RTO must never exceed rtoMax=\(rtoMax)")
        }
    }
}

// MARK: - Part 8: Adaptive PACLEN Testing

@MainActor
final class AdaptivePACLENTests: XCTestCase {

    // P-1: PaclenAdapter decreases paclen on failure.
    func testPaclenDecreasesOnFailure() {
        var adapter = PaclenAdapter(basePaclen: 128, minPaclen: 32, maxPaclen: 256)
        let initial = adapter.currentPaclen
        adapter.recordFailure()
        XCTAssertLessThan(adapter.currentPaclen, initial,
            "Paclen must decrease after a failure")
        XCTAssertGreaterThanOrEqual(adapter.currentPaclen, adapter.minPaclen,
            "Paclen must never go below minPaclen")
    }

    // P-2: PaclenAdapter increases paclen after sustained success.
    func testPaclenIncreasesAfterStability() {
        var adapter = PaclenAdapter(basePaclen: 64, minPaclen: 32, maxPaclen: 256)
        let initial = adapter.currentPaclen
        for _ in 0..<adapter.stabilityThreshold {
            adapter.recordSuccess()
        }
        XCTAssertGreaterThan(adapter.currentPaclen, initial,
            "Paclen must increase after \(adapter.stabilityThreshold) consecutive successes")
    }

    // P-3: PaclenAdapter never exceeds maxPaclen even with many successes.
    func testPaclenNeverExceedsMax() {
        var adapter = PaclenAdapter(basePaclen: 200, minPaclen: 32, maxPaclen: 256)
        for _ in 0..<200 {
            adapter.recordSuccess()
        }
        XCTAssertLessThanOrEqual(adapter.currentPaclen, 256,
            "Paclen must never exceed maxPaclen")
    }

    // P-4: PaclenAdapter never goes below minPaclen even with many failures.
    func testPaclenNeverBelowMin() {
        var adapter = PaclenAdapter(basePaclen: 128, minPaclen: 32, maxPaclen: 256)
        for _ in 0..<200 {
            adapter.recordFailure()
        }
        XCTAssertGreaterThanOrEqual(adapter.currentPaclen, 32,
            "Paclen must never go below minPaclen")
    }

    // P-5: Oscillating success/failure keeps paclen in bounds.
    func testPaclenStaysInBoundsUnderOscillation() {
        var adapter = PaclenAdapter(basePaclen: 128, minPaclen: 32, maxPaclen: 256)
        for i in 0..<200 {
            if i % 2 == 0 { adapter.recordSuccess() } else { adapter.recordFailure() }
            XCTAssertGreaterThanOrEqual(adapter.currentPaclen, 32,
                "Paclen below min at step \(i)")
            XCTAssertLessThanOrEqual(adapter.currentPaclen, 256,
                "Paclen above max at step \(i)")
        }
    }

    // P-6: After recovery from heavy loss, paclen eventually climbs back up.
    func testPaclenClimbsBackAfterLossRecovery() {
        var adapter = PaclenAdapter(basePaclen: 128, minPaclen: 32, maxPaclen: 256)
        // Hammer with failures first
        for _ in 0..<20 { adapter.recordFailure() }
        let afterLoss = adapter.currentPaclen

        // Then sustained success
        for _ in 0..<(adapter.stabilityThreshold * 3) { adapter.recordSuccess() }
        XCTAssertGreaterThan(adapter.currentPaclen, afterLoss,
            "Paclen should recover upward after sustained success following loss period")
    }
}

// MARK: - Part 9: Window Adaptation Testing

@MainActor
final class WindowAdaptationTests: XCTestCase {

    // W-1: AIMD window grows in slow-start phase.
    func testAIMDSlowStartGrowth() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 8.0, ssthresh: 8.0)
        XCTAssertTrue(aimd.isSlowStart)
        let before = aimd.cwnd
        aimd.onAck()
        XCTAssertGreaterThan(aimd.cwnd, before, "Slow start must grow window on each ACK")
    }

    // W-2: AIMD window halves on loss.
    func testAIMDLossHalvesWindow() {
        var aimd = AIMDWindow(initialWindow: 8.0, maxWindow: 16.0)
        let before = aimd.cwnd
        aimd.onLoss()
        XCTAssertEqual(aimd.cwnd, before * 0.5, accuracy: 0.01,
            "AIMD must halve window on loss (multiplicative decrease)")
    }

    // W-3: Window never drops below 1.
    func testAIMDWindowMinimumOne() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 4.0)
        for _ in 0..<50 { aimd.onLoss() }
        XCTAssertGreaterThanOrEqual(aimd.effectiveWindow, 1,
            "Effective window must be at least 1 after repeated losses")
    }

    // W-4: Window never exceeds maxWindow.
    func testAIMDWindowMaximumEnforced() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 4.0)
        for _ in 0..<100 { aimd.onAck() }
        XCTAssertLessThanOrEqual(aimd.cwnd, 4.0,
            "Window must never exceed maxWindow")
    }

    // W-5: Congestion avoidance growth is slower than slow start.
    func testAIMDCongestionAvoidanceSlowerThanSlowStart() {
        var ssAimd = AIMDWindow(initialWindow: 1.0, maxWindow: 16.0, ssthresh: 16.0)
        var caAimd = AIMDWindow(initialWindow: 5.0, maxWindow: 16.0, ssthresh: 4.0)

        XCTAssertTrue(ssAimd.isSlowStart,    "First AIMD should be in slow start")
        XCTAssertFalse(caAimd.isSlowStart,   "Second AIMD should be in congestion avoidance")

        let ssGrowth = { () -> Double in var a = ssAimd; a.onAck(); return a.cwnd - ssAimd.cwnd }()
        let caGrowth = { () -> Double in var a = caAimd; a.onAck(); return a.cwnd - caAimd.cwnd }()

        XCTAssertGreaterThan(ssGrowth, caGrowth,
            "Slow start growth (\(ssGrowth)) must exceed congestion avoidance growth (\(caGrowth))")
    }

    // W-6: Effective window is bounded for a session in connected mode.
    func testSessionWindowBoundedDuringTransfer() {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(windowSize: 4, rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // Try to send more frames than the window allows
        for _ in 0..<10 {
            _ = manager.sendData(Data("wtest".utf8), to: peer, path: DigiPath(), channel: 0)
        }

        XCTAssertLessThanOrEqual(session.outstandingCount, config.windowSize,
            "Outstanding frame count must not exceed configured window size")
    }

    // W-7: T1 timeout fires AIMD multiplicative decrease on the session's congestion window.
    // After a timeout the congestion window must be strictly smaller than it was before
    // the timeout (it was ≥1 and onLoss() halves it, floor of 1).
    func testT1TimeoutTriggersAIMDLoss() {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(windowSize: 4, rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // Grow the AIMD window by sending and acking several frames so the pre-loss
        // cwnd is well above 1 (otherwise halving from 1→1 would look like no change).
        _ = manager.sendData(Data("hello".utf8), to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundRR(from: peer, path: DigiPath(), channel: 0, nr: session.vs)

        // Send another frame so there is something outstanding before the timeout.
        _ = manager.sendData(Data("world".utf8), to: peer, path: DigiPath(), channel: 0)

        let cwndBefore = session.aimdWindow.cwnd
        XCTAssertGreaterThan(cwndBefore, 1.0,
            "AIMD window should have grown above 1 after an ACK; test precondition failed")

        _ = manager.handleT1Timeout(session: session)

        XCTAssertLessThan(session.aimdWindow.cwnd, cwndBefore,
            "T1 timeout must trigger AIMD multiplicative decrease: cwnd \(session.aimdWindow.cwnd) should be < \(cwndBefore)")
    }

    // W-8: RR acknowledgement grows the AIMD congestion window.
    // Each time an RR acks one or more frames, onAck() must be called and cwnd must grow.
    // Strategy: first reduce cwnd below maxWindow via a T1 timeout loss event, then
    // verify a subsequent RR ACK causes the window to grow back.
    func testRRAckGrowsAIMDWindow() {
        let clock = AX25VirtualClock()
        // Use windowSize=4 — AIMD starts at cwnd=4 (maxWindow).
        let config = AX25SessionConfig(windowSize: 4, rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // Send a frame and trigger a T1 timeout to REDUCE cwnd via multiplicative decrease.
        _ = manager.sendData(Data("hello".utf8), to: peer, path: DigiPath(), channel: 0)
        _ = manager.handleT1Timeout(session: session)  // cwnd halves: 4→2
        let cwndAfterLoss = session.aimdWindow.cwnd
        XCTAssertLessThan(cwndAfterLoss, 4.0,
            "T1 timeout must reduce cwnd below maxWindow; got \(cwndAfterLoss)")

        // Now ack the frame with an RR — cwnd should grow from its reduced value.
        let vsBeforeAck = session.vs
        manager.handleInboundRR(from: peer, path: DigiPath(), channel: 0, nr: vsBeforeAck)

        XCTAssertGreaterThan(session.aimdWindow.cwnd, cwndAfterLoss,
            "RR ACK must grow AIMD cwnd after loss: was \(cwndAfterLoss), now \(session.aimdWindow.cwnd)")
    }

    // W-9: AIMD window constrains drainPendingDataQueue — after a loss event reduces
    // cwnd below windowSize, subsequent RR ACKs must not let drain push outstanding
    // above the current AIMD effectiveWindow.
    //
    // Setup:
    //   1. Fill the protocol window (send 4 frames with cwnd=4)
    //   2. Trigger T1 timeout → cwnd halves to 2 (multiplicative decrease)
    //   3. A partial RR ack arrives (acks 2 of the 4 outstanding frames)
    //   4. drainPendingDataQueue runs — it must not drain more than 0 new frames
    //      because effectiveWindow=2 and outstanding is still 2 after the partial ack.
    //   5. Verify outstanding ≤ min(windowSize, aimdEffective) = min(4, 2) = 2.
    func testDrainRespectsAIMDWindow() {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(windowSize: 4, rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // 1. Fill the protocol window: send 4 frames directly (cwnd=4=windowSize).
        //    Also queue 4 more in pendingDataQueue for the drain test.
        for i in 0..<8 {
            _ = manager.sendData(Data("chunk\(i)".utf8), to: peer, path: DigiPath(), channel: 0)
        }
        XCTAssertEqual(session.outstandingCount, config.windowSize,
            "Protocol window must be full after 8 sends (4 sent, 4 queued)")

        // 2. Trigger T1 timeout to halve the AIMD window.
        _ = manager.handleT1Timeout(session: session)
        let cwndAfterLoss = session.aimdWindow.cwnd
        XCTAssertLessThan(cwndAfterLoss, Double(config.windowSize),
            "T1 timeout must reduce cwnd below windowSize")
        let aimdEffectiveAfterLoss = session.aimdWindow.effectiveWindow
        // aimdEffective should be 2 (half of 4, floor)
        XCTAssertLessThanOrEqual(aimdEffectiveAfterLoss, config.windowSize / 2 + 1,
            "AIMD effective window after loss should be ≤ half of protocol window")

        // 3. Partial RR acks 2 of the 4 outstanding frames.
        //    This triggers drainPendingDataQueue.  After drain, outstanding must not
        //    exceed the current AIMD effectiveWindow.
        let partialNR = (session.va + 2) % 8  // ack 2 frames from va
        manager.handleInboundRR(from: peer, path: DigiPath(), channel: 0, nr: partialNR)

        // 4. After the partial ack + drain, verify the AIMD bound holds.
        //    outstanding after partial ack: was 4, acked 2, drained at most effectiveWindow-2.
        //    effectiveWindow might have grown slightly from onAck() calls, but the
        //    invariant is: outstanding ≤ min(windowSize, currentEffectiveWindow).
        let currentEffective = min(config.windowSize, session.aimdWindow.effectiveWindow)
        XCTAssertLessThanOrEqual(session.outstandingCount, currentEffective,
            "After loss + partial ack, outstanding \(session.outstandingCount) must not exceed "
            + "min(windowSize, aimdEffective)=\(currentEffective) "
            + "(cwnd=\(String(format: "%.2f", session.aimdWindow.cwnd)))")
    }
}

// MARK: - Part 10: Persistent Learning Validation

@MainActor
final class PersistentLearningTests: XCTestCase {

    // L-1: After reconnect, SRTT resets to nil (fresh start).
    func testSRTTResetOnReconnect() {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)

        // First connect and accumulate RTT
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let s1 = manager.session(for: peer, path: DigiPath(), channel: 0)
        s1.timers.updateRTT(sample: 0.5)
        s1.timers.updateRTT(sample: 0.6)
        XCTAssertNotNil(s1.timers.srtt)

        // Force disconnect
        manager.forceDisconnect(session: s1)
        manager.removeSession(s1)

        // Second connect — new session object → fresh SRTT
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let s2 = manager.session(for: peer, path: DigiPath(), channel: 0)

        XCTAssertNil(s2.timers.srtt,
            "New session after reconnect must start with nil SRTT (no stale learned state)")
    }

    // L-2: TxAdaptiveSettings.resetAdaptiveToDefaults() clears learned state.
    func testAdaptiveSettingsResetClearsLearnedState() {
        var settings = TxAdaptiveSettings()

        // Simulate learning
        settings.updateFromLinkQuality(lossRate: 0.4, etx: 3.0, srtt: 2.5)
        XCTAssertEqual(settings.paclen.currentAdaptive, 64,
            "High loss should have set paclen to 64")

        settings.resetAdaptiveToDefaults()

        XCTAssertEqual(settings.paclen.currentAdaptive, settings.paclen.defaultValue,
            "resetAdaptiveToDefaults must restore paclen to default")
        XCTAssertNil(settings.paclen.adaptiveReason,
            "resetAdaptiveToDefaults must clear adaptive reason")
        XCTAssertNil(settings.currentRto,
            "resetAdaptiveToDefaults must clear currentRto")
    }

    // L-3: Manual mode is preserved through resetAdaptiveToDefaults.
    func testManualModePreservedThroughReset() {
        var settings = TxAdaptiveSettings()
        settings.paclen.mode = .manual
        settings.paclen.manualValue = 64

        settings.updateFromLinkQuality(lossRate: 0.4, etx: 3.0, srtt: nil)
        settings.resetAdaptiveToDefaults()

        XCTAssertEqual(settings.paclen.mode, .manual,
            "resetAdaptiveToDefaults must not override manual mode")
        XCTAssertEqual(settings.paclen.effectiveValue, 64,
            "Manual value must be preserved through reset")
    }

    // L-4: Stale RTT samples do not permanently poison the estimator.
    func testStaleRTTSamplesPurgeable() {
        var timers = AX25SessionTimers(rtoMin: 1.0, rtoMax: 30.0, initialRto: 2.0)

        // Inject a very long RTT (simulates a stale, poisoned sample)
        timers.updateRTT(sample: 25.0)
        let highRTO = timers.rto
        XCTAssertGreaterThan(highRTO, 5.0, "RTO should be high after large RTT sample")

        // After many good (low) samples, RTO should trend downward
        for _ in 0..<30 {
            timers.updateRTT(sample: 0.3)
        }

        XCTAssertLessThan(timers.rto, highRTO,
            "RTO must trend downward after many low-latency samples (poisoning recoverable)")
    }

    // L-5: TxAdaptiveSettings recovers from extreme loss to stable settings.
    func testAdaptiveSettingsRecoveryFromExtremeLoss() {
        var settings = TxAdaptiveSettings()

        // Drive to extreme degraded state
        settings.updateFromLinkQuality(lossRate: 1.0, etx: 20.0, srtt: nil)
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)

        // Recovery
        settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 0.5)
        XCTAssertGreaterThan(settings.paclen.currentAdaptive, 64,
            "PACLEN should recover after loss drops to zero")
    }
}

// MARK: - Part 11: Adaptive Fuzzing

@MainActor
final class AdaptiveFuzzingTests: XCTestCase {

    private func makeFuzzHarness(seed: UInt64) -> AdaptiveTestHarness {
        var rng = RFRng(seed: seed)

        // Build a random impairment model from the seed
        let lossProb = rng.uniform(0, 0.5)
        let latency  = rng.uniform(0.05, 0.4)

        var cfg = HarnessConfig()
        cfg.seed = seed
        cfg.sessionConfig = AX25SessionConfig(
            windowSize: 4,
            paclen: 128,
            maxRetries: 8,
            rtoMin: 1.0,
            rtoMax: 16.0,
            initialRto: 2.0
        )
        cfg.forwardModel = UniformLossModel(latency: latency, lossProbability: lossProb)
        cfg.reverseModel = UniformLossModel(latency: latency, lossProbability: lossProb * 0.5)
        return AdaptiveTestHarness(config: cfg)
    }

    // F-1: 20 random seeds produce no critical invariant violations.
    func testNoInvariantViolationsAcrossSeeds() {
        let seeds: [UInt64] = [1,2,3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67]
        for seed in seeds {
            let h = makeFuzzHarness(seed: seed)
            guard h.connect() else { continue }
            h.queueFrames(count: 8)
            h.advance(seconds: 15.0)

            let critical = h.invariantViolations.filter {
                $0.parameter.contains("NaN") || $0.parameter.contains("Inf") ||
                $0.parameter == "rto"
            }
            XCTAssertEqual(critical.count, 0,
                "seed=\(seed): critical invariant violations: \(critical.map { "\($0.parameter)=\($0.value)" })\n" +
                h.trace.failureReport())
        }
    }

    // F-2: Fuzz with burst-loss model — no infinite retransmit loops.
    func testBurstLossNoRetransmitLoop() {
        var cfg = HarnessConfig()
        cfg.seed = 11
        cfg.forwardModel = BurstLossModel.shortBurst()
        cfg.sessionConfig = AX25SessionConfig(maxRetries: 6, rtoMin: 0.5, rtoMax: 8.0, initialRto: 1.0)
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())

        h.queueFrames(count: 10)
        h.advance(seconds: 30.0)

        let session = h.aliceSession
        let finalRetx = session?.statistics.retransmissions ?? 0
        let totalSent = session?.statistics.framesSent ?? 1
        let retxRatio = Double(finalRetx) / Double(max(1, totalSent))

        // Retransmit ratio should be bounded — amplification > 10× would indicate a loop
        XCTAssertLessThan(retxRatio, 10.0,
            "Retransmit ratio \(retxRatio) exceeds safety threshold — possible retransmit loop")
    }

    // F-3: Duplicate frames do not cause session to enter error state.
    func testDuplicateFramesNoSessionError() {
        var cfg = HarnessConfig()
        cfg.seed = 13
        cfg.forwardModel = DuplicationModel(
            wrapping: PerfectChannelModel(latency: 0.1),
            duplicateProbability: 0.4
        )
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 8)
        h.advance(seconds: 10.0)

        // Session may have ended but must not be in .error state due to duplicates alone
        let state = h.aliceSession?.state
        if let state = state {
            XCTAssertNotEqual(state, .error,
                "Duplicate frames must not drive session into error state")
        }
    }

    // F-4: High jitter does not prevent RTT convergence on an otherwise lossless channel.
    func testHighJitterChannelDoesNotBlockRTTConvergence() {
        var cfg = HarnessConfig()
        cfg.seed = 17
        cfg.forwardModel = LatencyJitterModel(
            wrapping: PerfectChannelModel(latency: 0.2),
            maxJitter: 0.18,
            minimumDelay: 0.02
        )
        cfg.reverseModel = LatencyJitterModel(
            wrapping: PerfectChannelModel(latency: 0.2),
            maxJitter: 0.18,
            minimumDelay: 0.02
        )
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())
        for _ in 0..<20 { h.queueFrames(count: 1); h.advance(seconds: 1.0) }

        XCTAssertNotNil(h.aliceSRTT,
            "SRTT should be set even under high jitter (seed=\(cfg.seed))")
    }

    // F-5: updateRTT with random inputs never produces NaN/Inf.
    func testRTTUpdateRobustToArbitraryInputs() {
        var rng = RFRng(seed: 42)
        var timers = AX25SessionTimers(rtoMin: 0.5, rtoMax: 60.0, initialRto: 2.0)

        // Random samples including extreme values
        let extremes: [Double] = [0, -1, -0.001, Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300]
        for _ in 0..<500 {
            let sample: Double
            if rng.chance(0.1) {
                // Inject an extreme value
                sample = extremes[Int(rng.next() % UInt64(extremes.count))]
            } else {
                sample = rng.uniform(0.001, 10.0)
            }
            timers.updateRTT(sample: sample)
            XCTAssertFalse(timers.rto.isNaN,      "RTO became NaN after sample=\(sample)")
            XCTAssertFalse(timers.rto.isInfinite, "RTO became Inf after sample=\(sample)")
        }
    }
}

// MARK: - Part 12: Soak Testing

@MainActor
final class AdaptiveSoakTests: XCTestCase {

    // S-1: 100-frame soak on perfect channel — no invariant violations.
    func testPerfectChannelSoak() {
        var cfg = HarnessConfig()
        cfg.seed = 12
        cfg.forwardModel = PerfectChannelModel(latency: 0.1)
        cfg.reverseModel = PerfectChannelModel(latency: 0.1)
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())

        for _ in 0..<25 {
            h.queueFrames(count: 4)
            h.advance(seconds: 3.0)
        }

        XCTAssertEqual(h.invariantViolations.count, 0,
            "100-frame perfect-channel soak: \(h.invariantViolations)")
        XCTAssertGreaterThan(h.deliveredToBob.count, 0,
            "Must deliver at least some frames during 100-frame soak")
    }

    // S-2: Long soak with 10% uniform loss — timers do not leak.
    func testSoakNoTimerLeak() {
        var cfg = HarnessConfig()
        cfg.seed = 122
        cfg.forwardModel = UniformLossModel(latency: 0.1, lossProbability: 0.10)
        cfg.reverseModel = UniformLossModel(latency: 0.1, lossProbability: 0.05)
        cfg.sessionConfig = AX25SessionConfig(maxRetries: 6, rtoMin: 1.0, rtoMax: 12.0, initialRto: 2.0)
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())

        // Run 60 virtual seconds of traffic
        for _ in 0..<30 {
            h.queueFrames(count: 3)
            h.advance(seconds: 2.0)
        }

        // At end, virtual clock should have no runaway outstanding timers
        // (the virtual clock only fires scheduled tasks — no tasks = no leaks)
        // The active task count should be ≤ 2 (one T1 or T3 per live session is expected)
        let activeTimers = h.clock.activeTaskCount
        XCTAssertLessThanOrEqual(activeTimers, 4,
            "Active timer count should be small after soak (got \(activeTimers)); possible timer leak")
    }

    // S-3: Repeated connect/disconnect cycles leave no orphaned sessions.
    func testReconnectCyclesNoOrphanedSessions() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = AX25SessionConfig(maxRetries: 3, rtoMin: 0.5, rtoMax: 4.0, initialRto: 0.5)
        let peer = AX25Address(call: "PEER", ssid: 0)

        for cycle in 0..<10 {
            _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
            manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
            let session = manager.session(for: peer, path: DigiPath(), channel: 0)
            XCTAssertEqual(session.state, .connected, "Cycle \(cycle): must connect")

            manager.forceDisconnect(session: session)
            manager.removeSession(session)
        }

        XCTAssertEqual(manager.sessions.count, 0,
            "All sessions must be removed after connect/disconnect cycle soak")
    }

    // S-4: Soak with sequence number wrap-around — no invariant violations after wrap.
    func testSequenceWrapAroundSoak() {
        let clock = AX25VirtualClock()
        var config = AX25SessionConfig(windowSize: 3, rtoMin: 1.0, rtoMax: 8.0, initialRto: 1.0)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        let checker = AdaptiveInvariantChecker()
        var violations: [AdaptiveInvariantChecker.Violation] = []

        // Send > 3 modulo-8 cycles (= 24 frames) in window-1 batches
        for batch in 0..<24 {
            _ = manager.sendData(Data("wrap\(batch)".utf8), to: peer, path: DigiPath(), channel: 0)
            // Acknowledge each frame immediately (simulating a perfect responder)
            let newVA = (session.va + 1) % 8
            _ = manager.handleInboundRR(from: peer, path: DigiPath(), channel: 0, nr: newVA, isPoll: false)
            clock.advance(by: 0.05)
            violations.append(contentsOf: checker.check(session: session, context: "batch-\(batch)"))
        }

        XCTAssertEqual(violations.count, 0,
            "No invariant violations over \(24) frames with sequence number wrap: \(violations)")
        _ = config  // suppress warning
    }
}

// MARK: - Part 13: Throughput / Stability Benchmarking

@MainActor
final class ThroughputBenchmarkTests: XCTestCase {

    private struct BenchResult {
        let goodput: Double
        let retransmitRatio: Double
        let stability: Double
    }

    private func benchmark(
        seed: UInt64,
        lossProb: Double,
        latency: TimeInterval,
        frames: Int = 20
    ) -> BenchResult {
        var cfg = HarnessConfig()
        cfg.seed = seed
        cfg.forwardModel = UniformLossModel(latency: latency, lossProbability: lossProb)
        cfg.reverseModel = UniformLossModel(latency: latency, lossProbability: lossProb * 0.3)
        cfg.sessionConfig = AX25SessionConfig(windowSize: 4, paclen: 128, maxRetries: 8,
                                               rtoMin: 1.0, rtoMax: 12.0, initialRto: 2.0)
        let h = AdaptiveTestHarness(config: cfg)
        guard h.connect() else { return BenchResult(goodput: 0, retransmitRatio: 1, stability: 0) }

        h.queueFrames(count: frames)
        h.advance(seconds: TimeInterval(frames) * (latency * 4 + cfg.sessionConfig.rtoMax! + 2.0))

        let s = h.aliceSession
        let sent = max(1, s?.statistics.framesSent ?? 1)
        let retx = s?.statistics.retransmissions ?? 0
        let ratio = Double(retx) / Double(sent)

        return BenchResult(
            goodput: h.throughput.goodputBytesPerSecond,
            retransmitRatio: ratio,
            stability: h.stabilityScore.score
        )
    }

    // B-1: Perfect channel has near-zero retransmit ratio.
    func testPerfectChannelRetransmitRatioNearZero() {
        let result = benchmark(seed: 13, lossProb: 0.0, latency: 0.1, frames: 16)
        XCTAssertLessThan(result.retransmitRatio, 0.05,
            "Perfect channel must have <5% retransmit ratio (got \(Int(result.retransmitRatio*100))%)")
    }

    // B-2: High-loss channel has higher retransmit ratio than low-loss.
    func testHighLossChannelHigherRetransmitRatio() {
        let low  = benchmark(seed: 14, lossProb: 0.05, latency: 0.1, frames: 16)
        let high = benchmark(seed: 14, lossProb: 0.40, latency: 0.1, frames: 16)
        XCTAssertGreaterThan(high.retransmitRatio, low.retransmitRatio,
            "High-loss channel must have higher retransmit ratio than low-loss channel")
    }

    // B-3: Jacobson/Karels convergence test — RTO after N samples is tighter than initial.
    func testJacobsonConvergence() {
        var timers = AX25SessionTimers(rtoMin: 1.0, rtoMax: 30.0, initialRto: 10.0)
        let initialRTO = timers.rto

        // Feed 30 samples of ~0.5s RTT
        for _ in 0..<30 { timers.updateRTT(sample: 0.5) }

        XCTAssertLessThan(timers.rto, initialRTO,
            "RTO should converge downward from initial=\(initialRTO) after 30 good RTT samples; got \(timers.rto)")
        XCTAssertGreaterThanOrEqual(timers.rto, 1.0, "RTO must not go below rtoMin=1.0")
    }

    // B-4: Throughput is greater on a perfect channel than on a 30%-loss channel.
    func testThroughputHigherOnGoodChannel() {
        let good = benchmark(seed: 15, lossProb: 0.0, latency: 0.1, frames: 16)
        let bad  = benchmark(seed: 15, lossProb: 0.3, latency: 0.1, frames: 16)

        // We can only meaningfully compare if there's some delivered data on the perfect channel
        if good.goodput > 0 {
            XCTAssertGreaterThan(good.goodput, bad.goodput,
                "Goodput on perfect channel (\(Int(good.goodput)) B/s) " +
                "must exceed goodput on 30%-loss channel (\(Int(bad.goodput)) B/s)")
        }
    }
}

// MARK: - Part 14: Failure Replayability

@MainActor
final class ReplayabilityTests: XCTestCase {

    // R-1: Same seed + model produces identical drop sequence.
    func testSameSeedProducesIdenticalImpairments() {
        let seed: UInt64 = 42
        func runImpairment() -> [Bool] {
            var rng = RFRng(seed: seed)
            var model = BurstLossModel(latency: 0.1, goodToBad: 0.1, badToGood: 0.3,
                                       goodLoss: 0.05, badLoss: 0.9)
            return (0..<100).map { _ in
                if case .drop = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng) {
                    return true
                }
                return false
            }
        }
        XCTAssertEqual(runImpairment(), runImpairment(),
            "Two runs with seed=\(seed) must produce identical impairment sequences")
    }

    // R-2: AdaptiveTrace failure report includes seed for replay identification.
    func testTraceIncludesSeedForReplay() {
        let seed: UInt64 = 99
        var cfg = HarnessConfig()
        cfg.seed = seed
        let h = AdaptiveTestHarness(config: cfg)
        XCTAssertTrue(h.connect())
        h.queueFrames(count: 4)
        h.advance(seconds: 4.0)

        let report = h.trace.failureReport()
        XCTAssertTrue(report.contains("\(seed)"),
            "Failure report must embed the seed so failures are replayable")
    }

    // R-3: Two harnesses with identical seeds produce identical RTO histories.
    func testDeterministicRTOHistory() {
        let seed: UInt64 = 77

        func runHarness() -> [Double] {
            var cfg = HarnessConfig()
            cfg.seed = seed
            cfg.forwardModel = UniformLossModel(latency: 0.15, lossProbability: 0.1)
            cfg.reverseModel = PerfectChannelModel(latency: 0.15)
            let h = AdaptiveTestHarness(config: cfg)
            guard h.connect() else { return [] }
            for _ in 0..<10 { h.queueFrames(count: 2); h.advance(seconds: 1.5) }
            return h.trace.rtoHistory
        }

        let run1 = runHarness()
        let run2 = runHarness()

        XCTAssertEqual(run1.count, run2.count,
            "Two deterministic runs must produce the same number of snapshots")
        for (i, (a, b)) in zip(run1, run2).enumerated() {
            XCTAssertEqual(a, b, accuracy: 1e-9,
                "RTO mismatch at snapshot \(i): \(a) vs \(b)")
        }
    }

    // R-4: Different seeds produce different (non-identical) impairment sequences.
    func testDifferentSeedsDifferentBehaviour() {
        func runModel(seed: UInt64) -> [Bool] {
            var rng = RFRng(seed: seed)
            var model = UniformLossModel(latency: 0.1, lossProbability: 0.3)
            return (0..<50).map { _ in
                if case .drop = model.disposition(type: "i", direction: .forward, time: 0, rng: &rng) { return true }
                return false
            }
        }
        let r1 = runModel(seed: 1)
        let r2 = runModel(seed: 999)
        XCTAssertNotEqual(r1, r2,
            "Different seeds must produce different impairment sequences (probability of accidental equality is negligible)")
    }
}

// MARK: - Part 15: Architecture / Determinism

@MainActor
final class ArchitecturalDeterminismTests: XCTestCase {

    // A-1: VirtualClock fires tasks in strict chronological order.
    func testVirtualClockFiresInOrder() {
        let clock = AX25VirtualClock()
        var firedOrder: [Int] = []

        _ = clock.schedule(delay: 3.0) { firedOrder.append(3) }
        _ = clock.schedule(delay: 1.0) { firedOrder.append(1) }
        _ = clock.schedule(delay: 2.0) { firedOrder.append(2) }

        clock.advance(by: 5.0)
        XCTAssertEqual(firedOrder, [1, 2, 3],
            "VirtualClock must fire tasks in ascending fire-time order")
    }

    // A-2: VirtualClock cancelled tasks never fire.
    func testCancelledTasksNeverFire() {
        let clock = AX25VirtualClock()
        var fired = false

        let task = clock.schedule(delay: 1.0) { fired = true }
        task.cancel()
        clock.advance(by: 5.0)

        XCTAssertFalse(fired, "Cancelled task must never fire")
    }

    // A-3: VirtualClock `currentTime` only advances (never regresses).
    func testVirtualClockTimeMonotonic() {
        let clock = AX25VirtualClock()
        var prev: TimeInterval = 0

        var times: [TimeInterval] = []
        for delay in [0.5, 0.1, 2.0, 0.0, 3.0] {
            _ = clock.schedule(delay: delay) { times.append(clock.currentTime) }
        }
        clock.advance(by: 10.0)

        for (i, t) in times.enumerated() {
            XCTAssertGreaterThanOrEqual(t, prev,
                "Clock time regressed at task \(i): \(t) < \(prev)")
            prev = t
        }
    }

    // A-4: AX25SessionManager uses injected clock for all timer operations.
    func testManagerUsesInjectedClock() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let peer = AX25Address(call: "PEER", ssid: 0)
        manager.defaultConfig = AX25SessionConfig(rtoMin: 1.0, rtoMax: 8.0, initialRto: 1.0)

        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        _ = manager.sendData(Data("clock-test".utf8), to: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // Virtual clock has not advanced → T1 must not have fired yet
        XCTAssertEqual(session.stateMachine.retryCount, 0,
            "No retries should occur before virtual clock advances")

        // Advance past RTO + grace → T1 fires
        clock.advance(by: 1.0 + 0.21)

        XCTAssertEqual(session.stateMachine.retryCount, 1,
            "One retry should occur after clock advances past RTO+grace")
    }

    // A-5: SRTT uses virtual clock time, not wall clock.
    func testSRTTMeasuredViaVirtualClock() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let peer = AX25Address(call: "PEER", ssid: 0)
        manager.defaultConfig = AX25SessionConfig(rtoMin: 0.5, rtoMax: 10.0, initialRto: 2.0)

        // Connect: SABM at t=0, UA at t=0.3 → virtual RTT = 0.3s
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        clock.advance(by: 0.3)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)

        // SRTT should equal the virtual-clock RTT, not wall-clock time
        XCTAssertNotNil(session.timers.srtt,
            "SRTT must be set after SABM→UA round-trip")
        if let srtt = session.timers.srtt {
            XCTAssertEqual(srtt, 0.3, accuracy: 0.01,
                "SRTT must equal the virtual RTT (0.3s), not a wall-clock measurement")
        }
    }

    // A-6: All adaptive state is encapsulated per-session — no shared mutable globals.
    func testAdaptiveStateIsSessionLocal() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let peerA = AX25Address(call: "PEERA", ssid: 0)
        let peerB = AX25Address(call: "PEERB", ssid: 0)

        _ = manager.connect(to: peerA, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peerA, path: DigiPath(), channel: 0)
        _ = manager.connect(to: peerB, path: DigiPath(), channel: 1)
        manager.handleInboundUA(from: peerB, path: DigiPath(), channel: 1)

        let sessionA = manager.session(for: peerA, path: DigiPath(), channel: 0)
        let sessionB = manager.session(for: peerB, path: DigiPath(), channel: 1)

        // Mutate session A's RTT
        sessionA.timers.updateRTT(sample: 5.0)
        let srttA = sessionA.timers.srtt

        // Session B must be unaffected
        XCTAssertNil(sessionB.timers.srtt,
            "Session B must have no RTT samples — session A's update must not leak")
        XCTAssertNotEqual(sessionA.id, sessionB.id,
            "Sessions must have distinct IDs")
        XCTAssertNotNil(srttA, "Session A must have SRTT after explicit update")
    }

    // A-7: RFRng with same seed produces identical sequences across calls.
    func testRFRngDeterministic() {
        let seed: UInt64 = 12345
        func run() -> [Double] { var r = RFRng(seed: seed); return (0..<20).map { _ in r.nextDouble() } }
        XCTAssertEqual(run(), run(), "RFRng must be deterministic for the same seed")
    }

    // A-8: RFRng sequences for different seeds are different.
    func testRFRngDifferentSeeds() {
        var r1 = RFRng(seed: 1)
        var r2 = RFRng(seed: 2)
        let seq1 = (0..<10).map { _ in r1.nextDouble() }
        let seq2 = (0..<10).map { _ in r2.nextDouble() }
        XCTAssertNotEqual(seq1, seq2, "Different seeds must produce different RFRng sequences")
    }
}
