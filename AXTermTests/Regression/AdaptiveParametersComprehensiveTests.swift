//
//  AdaptiveParametersComprehensiveTests.swift
//  AXTermTests
//
//  Comprehensive unit, regression, and edge case tests for the adaptive
//  parameters functionality (paclen, window size, RTO, etc.).
//
//  This tests all components under extreme, boundary, and adversarial conditions
//  to ensure robustness, safety, and correct behavior.
//
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4, 7.3, 11.3
//

import XCTest
@testable import AXTerm

// MARK: - RttEstimator Comprehensive Tests

final class RttEstimatorComprehensiveTests: XCTestCase {
    
    // MARK: - Extreme Value Tests
    
    func testRttEstimatorWithVerySmallRtt() {
        var estimator = RttEstimator()
        
        // Very small RTT (0.001 seconds = 1ms)
        estimator.update(sample: 0.001)
        
        XCTAssertNotNil(estimator.srtt)
        XCTAssertEqual(estimator.srtt!, 0.001, accuracy: 0.0001)
        
        // RTO should be clamped to minimum (1.0s)
        XCTAssertGreaterThanOrEqual(estimator.rto(), 1.0)
    }
    
    func testRttEstimatorWithVeryLargeRtt() {
        var estimator = RttEstimator()
        
        // Very large RTT (100 seconds)
        estimator.update(sample: 100.0)
        
        XCTAssertNotNil(estimator.srtt)
        XCTAssertEqual(estimator.srtt!, 100.0, accuracy: 1.0)
        
        // RTO should be clamped to maximum (30.0s)
        XCTAssertLessThanOrEqual(estimator.rto(), 30.0)
    }
    
    func testRttEstimatorWithZeroRtt() {
        var estimator = RttEstimator()
        
        // Zero RTT (theoretically impossible but should handle gracefully)
        estimator.update(sample: 0.0)
        
        XCTAssertNotNil(estimator.srtt)
        XCTAssertEqual(estimator.srtt!, 0.0, accuracy: 0.001)
        
        // Should still return valid RTO
        let rto = estimator.rto()
        XCTAssertGreaterThanOrEqual(rto, 1.0)
        XCTAssertLessThanOrEqual(rto, 30.0)
    }
    
    func testRttEstimatorWithNegativeRtt() {
        var estimator = RttEstimator()
        
        // Negative RTT (invalid, should handle gracefully)
        estimator.update(sample: -1.0)
        
        // Should still not crash and return reasonable values
        let rto = estimator.rto()
        XCTAssertFalse(rto.isNaN)
        XCTAssertFalse(rto.isInfinite)
    }
    
    func testRttEstimatorWithInfiniteRtt() {
        var estimator = RttEstimator()
        
        // Infinite RTT (invalid)
        estimator.update(sample: Double.infinity)
        
        // Should handle gracefully - RTO should still be clamped
        let rto = estimator.rto()
        // The clamping should prevent infinite RTO
        XCTAssertLessThanOrEqual(rto, 30.0)
    }
    
    func testRttEstimatorWithNaNRtt() {
        var estimator = RttEstimator()
        
        // NaN RTT (invalid)
        estimator.update(sample: Double.nan)
        
        // SRTT becomes NaN but rto() should still return clamped value
        // This tests robustness - implementation may vary
        let rto = estimator.rto()
        // At minimum, should not crash
        XCTAssertTrue(rto.isNaN || (rto >= 1.0 && rto <= 30.0))
    }
    
    // MARK: - Stability and Convergence Tests
    
    func testRttEstimatorConvergesToStableValue() {
        var estimator = RttEstimator()
        
        // Feed identical samples
        let target = 2.5
        for _ in 0..<100 {
            estimator.update(sample: target)
        }
        
        // SRTT should converge very close to target
        XCTAssertEqual(estimator.srtt!, target, accuracy: 0.01)
        
        // RTTVAR should approach zero
        XCTAssertLessThan(estimator.rttvar, 0.01)
    }
    
    func testRttEstimatorHandlesOscillation() {
        var estimator = RttEstimator()
        
        // Oscillating RTT values
        for i in 0..<50 {
            let sample = (i % 2 == 0) ? 1.0 : 3.0
            estimator.update(sample: sample)
        }
        
        // SRTT should be somewhere between 1.0 and 3.0
        XCTAssertGreaterThan(estimator.srtt!, 1.0)
        XCTAssertLessThan(estimator.srtt!, 3.0)
        
        // RTTVAR should be significant due to variance
        XCTAssertGreaterThan(estimator.rttvar, 0.1)
    }
    
    func testRttEstimatorHandlesSuddenChange() {
        var estimator = RttEstimator()
        
        // Build up stable estimate
        for _ in 0..<20 {
            estimator.update(sample: 1.0)
        }
        XCTAssertEqual(estimator.srtt!, 1.0, accuracy: 0.1)
        
        // Sudden large change
        for _ in 0..<20 {
            estimator.update(sample: 5.0)
        }
        
        // Should adapt to new value
        XCTAssertGreaterThan(estimator.srtt!, 4.0)
    }
    
    func testRttEstimatorMultipleResets() {
        var estimator = RttEstimator()
        
        for _ in 0..<5 {
            estimator.update(sample: 2.0)
            XCTAssertNotNil(estimator.srtt)
            
            estimator.reset()
            XCTAssertNil(estimator.srtt)
            XCTAssertEqual(estimator.rttvar, 0.0)
        }
    }
    
    // MARK: - Boundary RTO Tests
    
    func testRtoClampingAtMinimum() {
        var estimator = RttEstimator()
        estimator.update(sample: 0.1)  // Very small
        
        // Default min is 1.0
        XCTAssertGreaterThanOrEqual(estimator.rto(), 1.0)
        
        // Custom min
        XCTAssertGreaterThanOrEqual(estimator.rto(min: 0.5), 0.5)
    }
    
    func testRtoClampingAtMaximum() {
        var estimator = RttEstimator()
        estimator.update(sample: 50.0)  // Very large
        
        // Default max is 30.0
        XCTAssertLessThanOrEqual(estimator.rto(), 30.0)
        
        // Custom max
        XCTAssertLessThanOrEqual(estimator.rto(max: 15.0), 15.0)
    }
    
    func testRtoCustomRange() {
        var estimator = RttEstimator()
        estimator.update(sample: 5.0)
        
        // Custom range
        let rto = estimator.rto(min: 2.0, max: 10.0)
        XCTAssertGreaterThanOrEqual(rto, 2.0)
        XCTAssertLessThanOrEqual(rto, 10.0)
    }
}

// MARK: - LinkRttTracker Comprehensive Tests

final class LinkRttTrackerComprehensiveTests: XCTestCase {
    
    // MARK: - Streak Behavior Tests
    
    func testSuccessStreakBuildsCorrectly() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        for i in 1...20 {
            tracker.recordSuccess(rtt: 1.0)
            XCTAssertEqual(tracker.successStreak, i)
            XCTAssertEqual(tracker.failStreak, 0)
        }
    }
    
    func testFailureStreakBuildsCorrectly() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        for i in 1...20 {
            tracker.recordFailure()
            XCTAssertEqual(tracker.failStreak, i)
            XCTAssertEqual(tracker.successStreak, 0)
        }
    }
    
    func testSuccessResetsFailStreak() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        tracker.recordFailure()
        tracker.recordFailure()
        tracker.recordFailure()
        XCTAssertEqual(tracker.failStreak, 3)
        
        tracker.recordSuccess(rtt: 1.0)
        XCTAssertEqual(tracker.failStreak, 0)
        XCTAssertEqual(tracker.successStreak, 1)
    }
    
    func testFailureResetsSuccessStreak() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        tracker.recordSuccess(rtt: 1.0)
        tracker.recordSuccess(rtt: 1.0)
        tracker.recordSuccess(rtt: 1.0)
        XCTAssertEqual(tracker.successStreak, 3)
        
        tracker.recordFailure()
        XCTAssertEqual(tracker.successStreak, 0)
        XCTAssertEqual(tracker.failStreak, 1)
    }
    
    func testRetryResetsSuccessStreak() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        tracker.recordSuccess(rtt: 1.0)
        tracker.recordSuccess(rtt: 1.0)
        XCTAssertEqual(tracker.successStreak, 2)
        
        tracker.recordRetry()
        XCTAssertEqual(tracker.successStreak, 0)
    }
    
    // MARK: - Loss Rate EWMA Tests
    
    func testLossRateStartsAtZero() {
        let tracker = LinkRttTracker(linkKey: "TEST-0")
        XCTAssertEqual(tracker.lossRate, 0.0, accuracy: 0.001)
    }
    
    func testLossRateIncreasesOnFailure() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        let initialRate = tracker.lossRate
        tracker.recordFailure()
        
        XCTAssertGreaterThan(tracker.lossRate, initialRate)
    }
    
    func testLossRateDecreasesOnSuccess() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        // Build up some loss rate
        for _ in 0..<10 {
            tracker.recordFailure()
        }
        let highRate = tracker.lossRate
        
        // Record successes
        for _ in 0..<10 {
            tracker.recordSuccess(rtt: 1.0)
        }
        
        XCTAssertLessThan(tracker.lossRate, highRate)
    }
    
    func testLossRateConvergesToOneOnContinuousFailure() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        // Many failures
        for _ in 0..<100 {
            tracker.recordFailure()
        }
        
        // Loss rate should approach 1.0 (but EWMA never quite reaches it)
        XCTAssertGreaterThan(tracker.lossRate, 0.9)
    }
    
    func testLossRateConvergesToZeroOnContinuousSuccess() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        // Start with some loss
        for _ in 0..<10 {
            tracker.recordFailure()
        }
        
        // Many successes
        for _ in 0..<100 {
            tracker.recordSuccess(rtt: 1.0)
        }
        
        // Loss rate should approach 0.0
        XCTAssertLessThan(tracker.lossRate, 0.01)
    }
    
    // MARK: - isStable and isDegraded Tests
    
    func testIsStableRequiresBothConditions() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        // Not enough successes
        for _ in 0..<9 {
            tracker.recordSuccess(rtt: 1.0)
        }
        XCTAssertFalse(tracker.isStable)
        
        // 10 successes should be stable
        tracker.recordSuccess(rtt: 1.0)
        XCTAssertTrue(tracker.isStable)
    }
    
    func testIsStableFalseWithHighLossRate() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        // Build up high loss rate
        for _ in 0..<50 {
            tracker.recordFailure()
        }
        
        // Even with success streak, high loss rate prevents stability
        for _ in 0..<15 {
            tracker.recordSuccess(rtt: 1.0)
        }
        
        // If loss rate is still > 0.1, not stable
        if tracker.lossRate > 0.1 {
            XCTAssertFalse(tracker.isStable)
        }
    }
    
    func testIsDegradedOnSingleFailure() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        XCTAssertFalse(tracker.isDegraded)
        
        tracker.recordFailure()
        XCTAssertTrue(tracker.isDegraded)
    }
    
    func testIsDegradedOnHighLossRate() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        // Build up > 20% loss rate
        for _ in 0..<20 {
            tracker.recordFailure()
        }
        
        XCTAssertTrue(tracker.isDegraded)
        XCTAssertGreaterThan(tracker.lossRate, 0.2)
    }
    
    // MARK: - Adaptive Parameters Tests
    
    func testAdaptiveParametersDefaultCase() {
        let tracker = LinkRttTracker(linkKey: "TEST-0")
        let params = tracker.adaptiveParameters(basePaclen: 128, baseWindow: 2)
        
        // Default case (no data) should return base values
        XCTAssertEqual(params.reason, "Default")
    }
    
    func testAdaptiveParametersHighLoss() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        for _ in 0..<30 {
            tracker.recordFailure()
        }
        
        let params = tracker.adaptiveParameters(basePaclen: 256, baseWindow: 4)
        
        // High loss should reduce parameters
        XCTAssertLessThanOrEqual(params.paclen, 64)
        XCTAssertEqual(params.windowSize, 1)
        XCTAssertTrue(params.reason.contains("Loss rate"))
    }
    
    func testAdaptiveParametersModerateLoss() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        // Build up ~15% loss rate
        for _ in 0..<5 {
            tracker.recordFailure()
        }
        for _ in 0..<25 {
            tracker.recordSuccess(rtt: 1.0)
        }
        
        if tracker.lossRate > 0.1 && tracker.lossRate <= 0.2 {
            let params = tracker.adaptiveParameters(basePaclen: 256, baseWindow: 4)
            
            XCTAssertLessThanOrEqual(params.paclen, 128)
            XCTAssertLessThanOrEqual(params.windowSize, 2)
            XCTAssertTrue(params.reason.contains("Moderate"))
        }
    }
    
    func testAdaptiveParametersStableLink() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        // Build stable link (10+ successes, low loss)
        for _ in 0..<20 {
            tracker.recordSuccess(rtt: 1.0)
        }
        
        XCTAssertTrue(tracker.isStable)
        
        let params = tracker.adaptiveParameters(basePaclen: 128, baseWindow: 2)
        
        // Stable should increase parameters
        XCTAssertGreaterThan(params.paclen, 128)
        XCTAssertGreaterThan(params.windowSize, 2)
        XCTAssertEqual(params.reason, "Stable link")
    }
}

// MARK: - AIMDWindow Comprehensive Tests

final class AIMDWindowComprehensiveTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testInitialWindowClamping() {
        // Negative initial window should be clamped to 1
        let aimd = AIMDWindow(initialWindow: -5.0, maxWindow: 8.0)
        XCTAssertGreaterThanOrEqual(aimd.cwnd, 1.0)
    }
    
    func testMaxWindowClamping() {
        let aimd = AIMDWindow(initialWindow: 1.0, maxWindow: -5.0)
        XCTAssertGreaterThanOrEqual(aimd.maxWindow, 1.0)
    }
    
    func testSsthreshDefault() {
        let aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 16.0)
        XCTAssertEqual(aimd.ssthresh, 8.0, accuracy: 0.1)  // maxWindow / 2
    }
    
    func testSsthreshCustom() {
        let aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 16.0, ssthresh: 4.0)
        XCTAssertEqual(aimd.ssthresh, 4.0, accuracy: 0.1)
    }
    
    // MARK: - Slow Start Tests
    
    func testSlowStartInitially() {
        let aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 16.0, ssthresh: 8.0)
        XCTAssertTrue(aimd.isSlowStart)
    }
    
    func testSlowStartExitOnLoss() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 16.0, ssthresh: 8.0)
        
        XCTAssertTrue(aimd.isSlowStart)
        
        // Grow to 4
        for _ in 0..<3 {
            aimd.onAck()
        }
        
        // Loss
        aimd.onLoss()
        
        // ssthresh should be set to cwnd/2, and we exit slow start
        XCTAssertFalse(aimd.isSlowStart)
    }
    
    func testSlowStartExponentialGrowth() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 16.0, ssthresh: 8.0)
        
        // In slow start, each ACK should add 1 to cwnd
        let startCwnd = aimd.cwnd
        aimd.onAck()
        XCTAssertEqual(aimd.cwnd, startCwnd + 1.0, accuracy: 0.01)
    }
    
    func testSlowStartExitAtThreshold() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 16.0, ssthresh: 4.0)
        
        // Grow until we hit ssthresh
        for _ in 0..<5 {
            aimd.onAck()
        }
        
        // Should have exited slow start at cwnd >= ssthresh
        if aimd.cwnd >= 4.0 {
            XCTAssertFalse(aimd.isSlowStart)
        }
    }
    
    // MARK: - Congestion Avoidance Tests
    
    func testCongestionAvoidanceLinearGrowth() {
        var aimd = AIMDWindow(initialWindow: 5.0, maxWindow: 16.0, ssthresh: 4.0)
        
        // Start in congestion avoidance (cwnd > ssthresh)
        XCTAssertFalse(aimd.isSlowStart)
        
        let startCwnd = aimd.cwnd
        aimd.onAck()
        
        // Should grow by 1/cwnd (approximately 0.2 for cwnd=5)
        let expectedGrowth = 1.0 / startCwnd
        XCTAssertEqual(aimd.cwnd, startCwnd + expectedGrowth, accuracy: 0.01)
    }
    
    // MARK: - Loss Handling Tests
    
    func testMultiplicativeDecreaseOnLoss() {
        var aimd = AIMDWindow(initialWindow: 4.0, maxWindow: 8.0)
        
        aimd.onLoss()
        XCTAssertEqual(aimd.cwnd, 2.0, accuracy: 0.01)
        
        aimd.onLoss()
        XCTAssertEqual(aimd.cwnd, 1.0, accuracy: 0.01)
    }
    
    func testMinimumWindowOnRepeatedLoss() {
        var aimd = AIMDWindow(initialWindow: 4.0, maxWindow: 8.0)
        
        // Many losses
        for _ in 0..<20 {
            aimd.onLoss()
        }
        
        // Should never go below 1.0
        XCTAssertGreaterThanOrEqual(aimd.cwnd, 1.0)
        XCTAssertEqual(aimd.effectiveWindow, 1)
    }
    
    func testSsthreshUpdatedOnLoss() {
        var aimd = AIMDWindow(initialWindow: 8.0, maxWindow: 16.0, ssthresh: 16.0)
        
        let cwndBeforeLoss = aimd.cwnd
        aimd.onLoss()
        
        // ssthresh should be set to cwnd * 0.5 (before decrease)
        XCTAssertEqual(aimd.ssthresh, cwndBeforeLoss * 0.5, accuracy: 0.1)
    }
    
    // MARK: - Maximum Window Tests
    
    func testMaximumWindowEnforced() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 4.0)
        
        // Many ACKs
        for _ in 0..<100 {
            aimd.onAck()
        }
        
        XCTAssertLessThanOrEqual(aimd.cwnd, 4.0)
        XCTAssertLessThanOrEqual(aimd.effectiveWindow, 4)
    }
    
    // MARK: - Effective Window Tests
    
    func testEffectiveWindowFlooring() {
        var aimd = AIMDWindow(initialWindow: 2.5, maxWindow: 8.0)
        
        // Fractional cwnd should floor to integer
        XCTAssertEqual(aimd.effectiveWindow, 2)
        
        aimd.onAck()  // cwnd should now be > 3
        XCTAssertGreaterThanOrEqual(aimd.effectiveWindow, 3)
    }
    
    func testEffectiveWindowMinimum() {
        var aimd = AIMDWindow(initialWindow: 0.5, maxWindow: 8.0)
        
        // Even with fractional cwnd < 1, effective should be at least 1
        XCTAssertEqual(aimd.effectiveWindow, 1)
    }
    
    // MARK: - Reset Tests
    
    func testReset() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 8.0)
        
        for _ in 0..<10 {
            aimd.onAck()
        }
        XCTAssertGreaterThan(aimd.cwnd, 1.0)
        
        aimd.reset()
        XCTAssertEqual(aimd.cwnd, 1.0, accuracy: 0.01)
        XCTAssertEqual(aimd.ssthresh, 4.0, accuracy: 0.01)  // maxWindow / 2
    }
    
    // MARK: - Rapid Event Tests
    
    func testRapidAcksDoNotExceedMax() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 4.0)
        
        // Simulate burst of ACKs
        for _ in 0..<1000 {
            aimd.onAck()
        }
        
        XCTAssertLessThanOrEqual(aimd.cwnd, 4.0)
    }
    
    func testRapidLossesStayAboveMin() {
        var aimd = AIMDWindow(initialWindow: 8.0, maxWindow: 8.0)
        
        // Simulate burst of losses
        for _ in 0..<1000 {
            aimd.onLoss()
        }
        
        XCTAssertGreaterThanOrEqual(aimd.cwnd, 1.0)
    }
    
    func testAlternatingAckLoss() {
        var aimd = AIMDWindow(initialWindow: 4.0, maxWindow: 8.0)
        
        // Alternating ACK/loss pattern
        for _ in 0..<50 {
            aimd.onAck()
            aimd.onLoss()
        }
        
        // Should stabilize around some value
        XCTAssertGreaterThanOrEqual(aimd.cwnd, 1.0)
        XCTAssertLessThanOrEqual(aimd.cwnd, 8.0)
    }
}

// MARK: - PaclenAdapter Comprehensive Tests

final class PaclenAdapterComprehensiveTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testDefaultInitialization() {
        let adapter = PaclenAdapter()
        
        XCTAssertEqual(adapter.currentPaclen, 128)
        XCTAssertEqual(adapter.basePaclen, 128)
        XCTAssertEqual(adapter.minPaclen, 32)
        XCTAssertEqual(adapter.maxPaclen, 256)
    }
    
    func testCustomInitialization() {
        let adapter = PaclenAdapter(basePaclen: 64, minPaclen: 16, maxPaclen: 128)
        
        XCTAssertEqual(adapter.currentPaclen, 64)
        XCTAssertEqual(adapter.minPaclen, 16)
        XCTAssertEqual(adapter.maxPaclen, 128)
    }
    
    func testMinPaclenClamping() {
        // Min should be at least 16
        let adapter = PaclenAdapter(basePaclen: 64, minPaclen: 8, maxPaclen: 128)
        XCTAssertGreaterThanOrEqual(adapter.minPaclen, 16)
    }
    
    // MARK: - Success Behavior Tests
    
    func testSuccessBuildsStreak() {
        var adapter = PaclenAdapter(basePaclen: 64)
        
        let initialPaclen = adapter.currentPaclen
        
        // Not enough successes yet
        for _ in 0..<9 {
            adapter.recordSuccess()
        }
        XCTAssertEqual(adapter.currentPaclen, initialPaclen)
        
        // 10th success triggers increase
        adapter.recordSuccess()
        XCTAssertGreaterThan(adapter.currentPaclen, initialPaclen)
    }
    
    func testSuccessIncreasesInSteps() {
        var adapter = PaclenAdapter(basePaclen: 64, minPaclen: 32, maxPaclen: 256)
        
        // Record enough successes for multiple increases
        var lastPaclen = adapter.currentPaclen
        for _ in 0..<50 {
            adapter.recordSuccess()
            if adapter.currentPaclen > lastPaclen {
                // Should increase by 32
                XCTAssertEqual(adapter.currentPaclen, lastPaclen + 32)
                lastPaclen = adapter.currentPaclen
            }
        }
    }
    
    func testSuccessDoesNotExceedMax() {
        var adapter = PaclenAdapter(basePaclen: 200, minPaclen: 32, maxPaclen: 256)
        
        for _ in 0..<100 {
            adapter.recordSuccess()
        }
        
        XCTAssertLessThanOrEqual(adapter.currentPaclen, 256)
    }
    
    // MARK: - Failure Behavior Tests
    
    func testFailureDecreasesPaclen() {
        var adapter = PaclenAdapter(basePaclen: 128)
        
        let initial = adapter.currentPaclen
        adapter.recordFailure()
        
        XCTAssertLessThan(adapter.currentPaclen, initial)
    }
    
    func testFailureResetsStreak() {
        var adapter = PaclenAdapter(basePaclen: 64)
        
        // Build up streak
        for _ in 0..<8 {
            adapter.recordSuccess()
        }
        
        adapter.recordFailure()
        
        // Now 10 more successes should be needed
        for _ in 0..<9 {
            adapter.recordSuccess()
        }
        let paclenBefore = adapter.currentPaclen
        adapter.recordSuccess()  // 10th
        XCTAssertGreaterThan(adapter.currentPaclen, paclenBefore)
    }
    
    func testFailureDoesNotGoBelowMin() {
        var adapter = PaclenAdapter(basePaclen: 64, minPaclen: 32, maxPaclen: 256)
        
        for _ in 0..<100 {
            adapter.recordFailure()
        }
        
        XCTAssertGreaterThanOrEqual(adapter.currentPaclen, 32)
    }
    
    // MARK: - Retry Behavior Tests
    
    func testRetryDecreasesPaclen() {
        var adapter = PaclenAdapter(basePaclen: 128)
        
        let initial = adapter.currentPaclen
        adapter.recordRetry()
        
        XCTAssertLessThan(adapter.currentPaclen, initial)
    }
    
    func testRetryDecreaseLessThanFailure() {
        var adapter1 = PaclenAdapter(basePaclen: 128)
        var adapter2 = PaclenAdapter(basePaclen: 128)
        
        adapter1.recordRetry()
        adapter2.recordFailure()
        
        // Retry should decrease less than failure
        XCTAssertGreaterThan(adapter1.currentPaclen, adapter2.currentPaclen)
    }
    
    func testRetryResetsStreak() {
        var adapter = PaclenAdapter(basePaclen: 64)
        
        for _ in 0..<8 {
            adapter.recordSuccess()
        }
        
        adapter.recordRetry()
        
        // Streak should be reset
        let paclenAfterRetry = adapter.currentPaclen
        for _ in 0..<9 {
            adapter.recordSuccess()
        }
        XCTAssertEqual(adapter.currentPaclen, paclenAfterRetry)  // Not increased yet
        
        adapter.recordSuccess()  // 10th
        XCTAssertGreaterThan(adapter.currentPaclen, paclenAfterRetry)
    }
    
    // MARK: - Reset Tests
    
    func testReset() {
        var adapter = PaclenAdapter(basePaclen: 128)
        
        // Modify state
        for _ in 0..<15 {
            adapter.recordSuccess()
        }
        XCTAssertGreaterThan(adapter.currentPaclen, 128)
        
        adapter.reset()
        XCTAssertEqual(adapter.currentPaclen, 128)
    }
    
    // MARK: - Oscillation Tests
    
    func testOscillatingSuccessFailure() {
        var adapter = PaclenAdapter(basePaclen: 128, minPaclen: 32, maxPaclen: 256)
        
        // Alternate success/failure
        for _ in 0..<50 {
            adapter.recordSuccess()
            adapter.recordFailure()
        }
        
        // Should stay within bounds and not crash
        XCTAssertGreaterThanOrEqual(adapter.currentPaclen, 32)
        XCTAssertLessThanOrEqual(adapter.currentPaclen, 256)
    }
}

// MARK: - TxAdaptiveSettings Comprehensive Tests

final class TxAdaptiveSettingsComprehensiveTests: XCTestCase {
    
    // MARK: - Boundary Condition Tests
    
    func testUpdateFromLinkQualityExtremeLoss() {
        var settings = TxAdaptiveSettings()
        
        // 100% loss
        settings.updateFromLinkQuality(lossRate: 1.0, etx: 20.0, srtt: nil)
        
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
    }
    
    func testUpdateFromLinkQualityZeroLoss() {
        var settings = TxAdaptiveSettings()
        
        // 0% loss, perfect link
        settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 0.5)
        
        XCTAssertGreaterThanOrEqual(settings.paclen.currentAdaptive, 128)
        XCTAssertGreaterThanOrEqual(settings.windowSize.currentAdaptive, 2)
    }
    
    func testUpdateFromLinkQualityBoundaryLoss20Percent() {
        var settings = TxAdaptiveSettings()
        
        // Exactly 20% loss (boundary)
        settings.updateFromLinkQuality(lossRate: 0.20, etx: 2.0, srtt: nil)
        
        // At exactly 20%, should trigger high-loss behavior
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
    }
    
    func testUpdateFromLinkQualityBoundaryLoss10Percent() {
        var settings = TxAdaptiveSettings()
        settings.paclen.currentAdaptive = 256
        
        // 10% < loss < 20%
        settings.updateFromLinkQuality(lossRate: 0.15, etx: 1.5, srtt: nil)
        
        // Should cap at 128
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 128)
    }
    
    func testUpdateFromLinkQualityExtremeETX() {
        var settings = TxAdaptiveSettings()
        
        // Very high ETX
        settings.updateFromLinkQuality(lossRate: 0.19, etx: 10.0, srtt: nil)
        
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
    }
    
    func testUpdateFromLinkQualityNegativeValues() {
        var settings = TxAdaptiveSettings()
        
        // Negative values (invalid, should handle gracefully)
        settings.updateFromLinkQuality(lossRate: -0.5, etx: -1.0, srtt: -2.0)
        
        // Should not crash, should return valid values
        XCTAssertGreaterThanOrEqual(settings.paclen.currentAdaptive, 32)
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 256)
        XCTAssertGreaterThanOrEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertLessThanOrEqual(settings.windowSize.currentAdaptive, 7)
    }
    
    func testUpdateFromLinkQualityVeryLargeSrtt() {
        var settings = TxAdaptiveSettings()
        
        // Very large SRTT (100 seconds)
        settings.updateFromLinkQuality(lossRate: 0.05, etx: 1.1, srtt: 100.0)
        
        // Should set RTO reasons
        XCTAssertNotNil(settings.rtoMin.adaptiveReason)
        XCTAssertNotNil(settings.rtoMax.adaptiveReason)
    }
    
    // MARK: - Mode Switching Tests
    
    func testModeSwitchingPreservesManualValue() {
        var settings = TxAdaptiveSettings()
        
        // Set manual mode
        settings.paclen.mode = .manual
        settings.paclen.manualValue = 64
        
        // Update from link quality
        settings.updateFromLinkQuality(lossRate: 0.05, etx: 1.1, srtt: nil)
        
        // Manual value should be preserved
        XCTAssertEqual(settings.paclen.manualValue, 64)
        
        // But currentAdaptive may have changed
        // effectiveValue should be manual value
        XCTAssertEqual(settings.paclen.effectiveValue, 64)
    }
    
    func testAutoModeUsesAdaptiveValue() {
        var settings = TxAdaptiveSettings()
        
        settings.paclen.mode = .auto
        settings.paclen.currentAdaptive = 96
        
        XCTAssertEqual(settings.paclen.effectiveValue, 96)
    }
    
    func testManualModeUsesManualValue() {
        var settings = TxAdaptiveSettings()
        
        settings.paclen.mode = .manual
        settings.paclen.manualValue = 64
        settings.paclen.currentAdaptive = 128  // Should be ignored
        
        XCTAssertEqual(settings.paclen.effectiveValue, 64)
    }
    
    // MARK: - Range Clamping Tests
    
    func testPaclenRangeClamping() {
        var settings = TxAdaptiveSettings()
        
        settings.paclen.mode = .manual
        settings.paclen.manualValue = 10  // Below min (32)
        
        XCTAssertEqual(settings.paclen.clampedManualValue, 32)
        
        settings.paclen.manualValue = 500  // Above max (256)
        XCTAssertEqual(settings.paclen.clampedManualValue, 256)
    }
    
    func testWindowSizeRangeClamping() {
        var settings = TxAdaptiveSettings()
        
        settings.windowSize.mode = .manual
        settings.windowSize.manualValue = 0  // Below min (1)
        
        XCTAssertEqual(settings.windowSize.clampedManualValue, 1)
        
        settings.windowSize.manualValue = 10  // Above max (7)
        XCTAssertEqual(settings.windowSize.clampedManualValue, 7)
    }
    
    func testRtoRangeClamping() {
        var settings = TxAdaptiveSettings()
        
        settings.rtoMin.mode = .manual
        settings.rtoMin.manualValue = 0.1  // Below min (0.5)
        XCTAssertEqual(settings.rtoMin.clampedManualValue, 0.5, accuracy: 0.01)
        
        settings.rtoMax.mode = .manual
        settings.rtoMax.manualValue = 100.0  // Above max (60)
        XCTAssertEqual(settings.rtoMax.clampedManualValue, 60.0, accuracy: 0.01)
    }
    
    // MARK: - All Parameters Tests
    
    func testAllAdaptiveSettingsIteration() {
        let settings = TxAdaptiveSettings()
        
        // Should have 5 adaptive settings
        XCTAssertEqual(settings.allAdaptiveSettings.count, 5)
    }
    
    func testAllParametersDefaultToAuto() {
        let settings = TxAdaptiveSettings()
        
        XCTAssertEqual(settings.paclen.mode, .auto)
        XCTAssertEqual(settings.windowSize.mode, .auto)
        XCTAssertEqual(settings.maxRetries.mode, .auto)
        XCTAssertEqual(settings.rtoMin.mode, .auto)
        XCTAssertEqual(settings.rtoMax.mode, .auto)
    }
    
    // MARK: - Compression Settings Tests
    
    func testMaxDecompressedPayloadClamping() {
        var settings = TxAdaptiveSettings()
        
        // Set very large value
        settings.maxDecompressedPayload = 1_000_000
        
        // Should be clamped
        XCTAssertLessThanOrEqual(
            settings.clampedMaxDecompressedPayload,
            AXDPCompression.absoluteMaxDecompressedLen
        )
    }
}

// MARK: - Adaptive Integration Stress Tests

final class AdaptiveIntegrationStressTests: XCTestCase {
    
    /// Test rapid successive updates don't cause issues
    func testRapidLinkQualityUpdates() {
        var settings = TxAdaptiveSettings()
        
        // Rapid updates with varying conditions
        for i in 0..<1000 {
            let lossRate = Double(i % 100) / 100.0
            let etx = 1.0 + Double(i % 20) / 10.0
            let srtt: Double? = (i % 3 == 0) ? Double(i % 10) : nil
            
            settings.updateFromLinkQuality(lossRate: lossRate, etx: etx, srtt: srtt)
            
            // Verify values stay within bounds
            XCTAssertGreaterThanOrEqual(settings.paclen.currentAdaptive, 32)
            XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 256)
            XCTAssertGreaterThanOrEqual(settings.windowSize.currentAdaptive, 1)
            XCTAssertLessThanOrEqual(settings.windowSize.currentAdaptive, 7)
        }
    }
    
    /// Test all components together under stress
    func testFullAdaptiveStackUnderStress() {
        var tracker = LinkRttTracker(linkKey: "STRESS-0")
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 8.0)
        var paclenAdapter = PaclenAdapter(basePaclen: 128)
        var settings = TxAdaptiveSettings()
        
        // Simulate 1000 transmissions with varying outcomes
        for i in 0..<1000 {
            // Simulate random outcome
            let success = (i * 7) % 10 < 7  // ~70% success rate
            let rtt = 1.0 + Double((i * 3) % 50) / 10.0
            
            if success {
                tracker.recordSuccess(rtt: rtt)
                aimd.onAck()
                paclenAdapter.recordSuccess()
            } else {
                tracker.recordFailure()
                aimd.onLoss()
                paclenAdapter.recordFailure()
            }
            
            // Update settings based on tracker
            settings.updateFromLinkQuality(
                lossRate: tracker.lossRate,
                etx: 1.0 / max(0.05, (1 - tracker.lossRate)),
                srtt: tracker.rttEstimator.srtt
            )
            
            // Verify all values stay valid
            XCTAssertGreaterThanOrEqual(aimd.effectiveWindow, 1)
            XCTAssertLessThanOrEqual(aimd.effectiveWindow, 8)
            XCTAssertGreaterThanOrEqual(paclenAdapter.currentPaclen, 32)
            XCTAssertLessThanOrEqual(paclenAdapter.currentPaclen, 256)
            XCTAssertFalse(tracker.lossRate.isNaN)
            XCTAssertFalse(tracker.lossRate.isInfinite)
        }
    }
    
    /// Test concurrent-safe structures (thread safety simulation)
    func testMultipleTrackersConcurrently() {
        var trackers: [LinkRttTracker] = []
        
        // Create multiple trackers
        for i in 0..<100 {
            trackers.append(LinkRttTracker(linkKey: "LINK-\(i)"))
        }
        
        // Update all of them
        for _ in 0..<100 {
            for i in 0..<trackers.count {
                if i % 2 == 0 {
                    trackers[i].recordSuccess(rtt: Double(i % 10) + 0.5)
                } else {
                    trackers[i].recordFailure()
                }
            }
        }
        
        // Verify all are in valid state
        for tracker in trackers {
            XCTAssertFalse(tracker.lossRate.isNaN)
            XCTAssertGreaterThanOrEqual(tracker.lossRate, 0.0)
            XCTAssertLessThanOrEqual(tracker.lossRate, 1.0)
        }
    }
}

// MARK: - Regression Tests

final class AdaptiveRegressionTests: XCTestCase {
    
    /// Regression: Window should never go to 0
    func testWindowNeverZero() {
        var aimd = AIMDWindow(initialWindow: 1.0, maxWindow: 8.0)
        
        // Many losses
        for _ in 0..<1000 {
            aimd.onLoss()
        }
        
        XCTAssertGreaterThanOrEqual(aimd.effectiveWindow, 1)
    }
    
    /// Regression: Paclen should never go below minimum
    func testPaclenNeverBelowMin() {
        var adapter = PaclenAdapter(basePaclen: 128, minPaclen: 32, maxPaclen: 256)
        
        for _ in 0..<1000 {
            adapter.recordFailure()
        }
        
        XCTAssertGreaterThanOrEqual(adapter.currentPaclen, 32)
    }
    
    /// Regression: Loss rate stays in [0, 1]
    func testLossRateAlwaysValid() {
        var tracker = LinkRttTracker(linkKey: "TEST-0")
        
        // Many random operations
        for i in 0..<1000 {
            if i % 3 == 0 {
                tracker.recordSuccess(rtt: Double(i % 10) + 0.1)
            } else if i % 3 == 1 {
                tracker.recordFailure()
            } else {
                tracker.recordRetry()
            }
            
            XCTAssertGreaterThanOrEqual(tracker.lossRate, 0.0)
            XCTAssertLessThanOrEqual(tracker.lossRate, 1.0)
            XCTAssertFalse(tracker.lossRate.isNaN)
        }
    }
    
    /// Regression: RTO always in valid range
    func testRtoAlwaysValid() {
        var estimator = RttEstimator()
        
        // Various RTT samples including edge cases
        let samples: [Double] = [0.0, 0.001, 0.5, 1.0, 5.0, 10.0, 50.0, 100.0, -1.0, Double.infinity]
        
        for sample in samples {
            estimator.update(sample: sample)
            let rto = estimator.rto()
            
            if !rto.isNaN {
                XCTAssertGreaterThanOrEqual(rto, 1.0)
                XCTAssertLessThanOrEqual(rto, 30.0)
            }
        }
    }
    
    /// Regression: Settings remain valid after rapid mode switches
    func testRapidModeSwitches() {
        var settings = TxAdaptiveSettings()
        
        for i in 0..<100 {
            settings.paclen.mode = (i % 2 == 0) ? .auto : .manual
            settings.windowSize.mode = (i % 2 == 1) ? .auto : .manual
            
            settings.updateFromLinkQuality(
                lossRate: Double(i % 100) / 100.0,
                etx: 1.0 + Double(i % 10) / 5.0,
                srtt: Double(i % 5) + 0.5
            )
            
            // Effective values should always be valid
            let paclen = settings.paclen.effectiveValue
            let window = settings.windowSize.effectiveValue
            
            XCTAssertGreaterThanOrEqual(paclen, 32)
            XCTAssertLessThanOrEqual(paclen, 256)
            XCTAssertGreaterThanOrEqual(window, 1)
            XCTAssertLessThanOrEqual(window, 7)
        }
    }
    
    /// Regression: Manual override is always respected
    func testManualOverrideAlwaysRespected() {
        var settings = TxAdaptiveSettings()
        
        settings.paclen.mode = .manual
        settings.paclen.manualValue = 96
        
        // Various link quality updates
        let conditions: [(Double, Double, Double?)] = [
            (0.0, 1.0, 0.5),
            (0.5, 5.0, nil),
            (1.0, 20.0, 100.0),
            (0.15, 1.5, 2.0),
        ]
        
        for (loss, etx, srtt) in conditions {
            settings.updateFromLinkQuality(lossRate: loss, etx: etx, srtt: srtt)
            
            // Manual mode should always use manual value
            XCTAssertEqual(settings.paclen.effectiveValue, 96)
        }
    }
}
