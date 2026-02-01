//
//  AdaptiveTuningTests.swift
//  AXTermTests
//
//  TDD tests for adaptive tuning: RTT estimation, AIMD, paclen adaptation.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4 & 7.3
//

import XCTest
@testable import AXTerm

final class AdaptiveTuningTests: XCTestCase {

    // MARK: - RttEstimator Tests

    func testRttEstimatorInitialState() {
        let estimator = RttEstimator()

        XCTAssertNil(estimator.srtt)
        XCTAssertEqual(estimator.rttvar, 0.0)
        XCTAssertEqual(estimator.rto(), 3.0)  // Default RTO
    }

    func testRttEstimatorFirstSample() {
        var estimator = RttEstimator()

        estimator.update(sample: 2.0)

        XCTAssertEqual(estimator.srtt!, 2.0, accuracy: 0.01)
        XCTAssertEqual(estimator.rttvar, 1.0, accuracy: 0.01)  // sample/2
    }

    func testRttEstimatorMultipleSamples() {
        var estimator = RttEstimator()

        estimator.update(sample: 2.0)
        estimator.update(sample: 2.0)  // Same RTT

        // SRTT should stay at 2.0
        XCTAssertEqual(estimator.srtt!, 2.0, accuracy: 0.01)

        // RTTVAR should decrease (variance approaches 0)
        XCTAssertLessThan(estimator.rttvar, 1.0)
    }

    func testRttEstimatorRTOClamping() {
        var estimator = RttEstimator()

        // Very small RTT
        estimator.update(sample: 0.1)
        XCTAssertGreaterThanOrEqual(estimator.rto(), 1.0)  // Min 1.0s

        // Very large RTT
        estimator.reset()
        estimator.update(sample: 100.0)
        XCTAssertLessThanOrEqual(estimator.rto(), 30.0)  // Max 30.0s
    }

    func testRttEstimatorConvergence() {
        var estimator = RttEstimator()

        // Feed consistent samples
        for _ in 0..<20 {
            estimator.update(sample: 1.5)
        }

        // SRTT should converge to 1.5
        XCTAssertEqual(estimator.srtt!, 1.5, accuracy: 0.1)

        // RTTVAR should be small
        XCTAssertLessThan(estimator.rttvar, 0.1)

        // RTO should be close to SRTT + small variance
        XCTAssertEqual(estimator.rto(), estimator.srtt! + 4 * estimator.rttvar, accuracy: 0.1)
    }

    func testRttEstimatorReset() {
        var estimator = RttEstimator()
        estimator.update(sample: 2.0)

        estimator.reset()

        XCTAssertNil(estimator.srtt)
        XCTAssertEqual(estimator.rttvar, 0.0)
    }

    // MARK: - LinkRttTracker Tests

    func testLinkTrackerInitialState() {
        let tracker = LinkRttTracker(linkKey: "N0CALL-1")

        XCTAssertEqual(tracker.linkKey, "N0CALL-1")
        XCTAssertEqual(tracker.successStreak, 0)
        XCTAssertEqual(tracker.failStreak, 0)
        XCTAssertEqual(tracker.lossRate, 0.0)
        XCTAssertFalse(tracker.isStable)
        XCTAssertFalse(tracker.isDegraded)
    }

    func testLinkTrackerSuccessStreak() {
        var tracker = LinkRttTracker(linkKey: "N0CALL-1")

        for i in 1...10 {
            tracker.recordSuccess(rtt: 1.0)
            XCTAssertEqual(tracker.successStreak, i)
        }

        XCTAssertTrue(tracker.isStable)
        XCTAssertFalse(tracker.isDegraded)
    }

    func testLinkTrackerFailureResetsStreak() {
        var tracker = LinkRttTracker(linkKey: "N0CALL-1")

        tracker.recordSuccess(rtt: 1.0)
        tracker.recordSuccess(rtt: 1.0)
        XCTAssertEqual(tracker.successStreak, 2)

        tracker.recordFailure()
        XCTAssertEqual(tracker.successStreak, 0)
        XCTAssertEqual(tracker.failStreak, 1)
        XCTAssertTrue(tracker.isDegraded)
    }

    func testLinkTrackerLossRateEWMA() {
        var tracker = LinkRttTracker(linkKey: "N0CALL-1")

        // Start with successes (loss rate stays low)
        for _ in 0..<10 {
            tracker.recordSuccess(rtt: 1.0)
        }
        XCTAssertLessThan(tracker.lossRate, 0.01)

        // Add some failures
        for _ in 0..<5 {
            tracker.recordFailure()
        }
        // Loss rate should have increased
        XCTAssertGreaterThan(tracker.lossRate, 0.3)
    }

    func testLinkTrackerRetryResetsSuccessStreak() {
        var tracker = LinkRttTracker(linkKey: "N0CALL-1")

        tracker.recordSuccess(rtt: 1.0)
        tracker.recordSuccess(rtt: 1.0)
        XCTAssertEqual(tracker.successStreak, 2)

        tracker.recordRetry()
        XCTAssertEqual(tracker.successStreak, 0)
    }

    // MARK: - AdaptiveParameters Tests

    func testAdaptiveParametersStableLink() {
        var tracker = LinkRttTracker(linkKey: "N0CALL-1")

        // Build up stable link
        for _ in 0..<15 {
            tracker.recordSuccess(rtt: 1.0)
        }

        let params = tracker.adaptiveParameters(basePaclen: 128, baseWindow: 2)

        // Should increase parameters
        XCTAssertGreaterThan(params.paclen, 128)
        XCTAssertGreaterThan(params.windowSize, 2)
        XCTAssertEqual(params.reason, "Stable link")
    }

    func testAdaptiveParametersDegradedLink() {
        var tracker = LinkRttTracker(linkKey: "N0CALL-1")

        // Simulate degraded link
        for _ in 0..<5 {
            tracker.recordFailure()
        }

        let params = tracker.adaptiveParameters(basePaclen: 256, baseWindow: 4)

        // Should decrease parameters
        XCTAssertLessThanOrEqual(params.paclen, 64)
        XCTAssertEqual(params.windowSize, 1)
        XCTAssertTrue(params.reason.contains("Loss rate"))
    }

    // MARK: - AIMD Congestion Window Tests

    func testAIMDWindowInitialState() {
        let aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 8.0)

        XCTAssertEqual(aimd.cwnd, 1.0, accuracy: 0.01)
        XCTAssertEqual(aimd.effectiveWindow, 1)
    }

    func testAIMDWindowAdditiveIncrease() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 8.0)

        aimd.onAck()
        XCTAssertGreaterThan(aimd.cwnd, 1.0)

        // Multiple acks should increase window
        for _ in 0..<10 {
            aimd.onAck()
        }
        XCTAssertGreaterThan(aimd.cwnd, 2.0)
    }

    func testAIMDWindowMultiplicativeDecrease() {
        var aimd = AIMDWindow(initialWindow: 4.0, maxWindow: 8.0)

        aimd.onLoss()

        // Should halve window
        XCTAssertEqual(aimd.cwnd, 2.0, accuracy: 0.01)

        aimd.onLoss()
        XCTAssertEqual(aimd.cwnd, 1.0, accuracy: 0.01)
    }

    func testAIMDWindowMinimum() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 8.0)

        // Multiple losses shouldn't go below 1.0
        for _ in 0..<10 {
            aimd.onLoss()
        }

        XCTAssertGreaterThanOrEqual(aimd.cwnd, 1.0)
        XCTAssertEqual(aimd.effectiveWindow, 1)
    }

    func testAIMDWindowMaximum() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 4.0)

        // Many acks shouldn't exceed max
        for _ in 0..<100 {
            aimd.onAck()
        }

        XCTAssertLessThanOrEqual(aimd.cwnd, 4.0)
        XCTAssertLessThanOrEqual(aimd.effectiveWindow, 4)
    }

    func testAIMDWindowSlowStart() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 16.0, ssthresh: 8.0)

        // In slow start, should double on each RTT's worth of acks
        XCTAssertTrue(aimd.isSlowStart)

        // Simulate slow start growth
        for _ in 0..<8 {
            aimd.onAck()
        }

        // After loss, should exit slow start
        aimd.onLoss()
        XCTAssertFalse(aimd.isSlowStart)
    }

    // MARK: - Paclen Adaptation Tests

    func testPaclenAdapterInitialState() {
        let adapter = PaclenAdapter(basePaclen: 128)

        XCTAssertEqual(adapter.currentPaclen, 128)
        XCTAssertEqual(adapter.minPaclen, 32)
        XCTAssertEqual(adapter.maxPaclen, 256)
    }

    func testPaclenAdapterDecreasesOnFailure() {
        var adapter = PaclenAdapter(basePaclen: 128)

        adapter.recordFailure()
        XCTAssertLessThan(adapter.currentPaclen, 128)
    }

    func testPaclenAdapterIncreasesOnStability() {
        var adapter = PaclenAdapter(basePaclen: 64)

        // Record enough successes to trigger increase
        for _ in 0..<15 {
            adapter.recordSuccess()
        }

        XCTAssertGreaterThan(adapter.currentPaclen, 64)
    }

    func testPaclenAdapterRespectsMinMax() {
        var adapter = PaclenAdapter(basePaclen: 64, minPaclen: 32, maxPaclen: 256)

        // Many failures shouldn't go below min
        for _ in 0..<20 {
            adapter.recordFailure()
        }
        XCTAssertGreaterThanOrEqual(adapter.currentPaclen, 32)

        // Reset and test max
        adapter = PaclenAdapter(basePaclen: 200, minPaclen: 32, maxPaclen: 256)
        for _ in 0..<50 {
            adapter.recordSuccess()
        }
        XCTAssertLessThanOrEqual(adapter.currentPaclen, 256)
    }
}
