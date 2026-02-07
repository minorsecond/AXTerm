//
//  TxSchedulerTests.swift
//  AXTermTests
//
//  Tests for TX scheduling components: TokenBucket and RttEstimator.
//

import XCTest
@testable import AXTerm

final class TokenBucketTests: XCTestCase {

    // MARK: - Basic Token Bucket Tests

    func testInitialTokensAtCapacity() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 0)
        // Should allow up to capacity immediately
        XCTAssertTrue(bucket.allow(cost: 100, now: 0))
    }

    func testDenyWhenInsufficientTokens() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 0)
        // Consume all tokens
        XCTAssertTrue(bucket.allow(cost: 100, now: 0))
        // Should deny immediately after
        XCTAssertFalse(bucket.allow(cost: 1, now: 0))
    }

    func testTokensRefillOverTime() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 0)
        // Consume all tokens
        _ = bucket.allow(cost: 100, now: 0)

        // After 5 seconds, should have 50 tokens
        XCTAssertTrue(bucket.allow(cost: 50, now: 5))
        // But not more
        XCTAssertFalse(bucket.allow(cost: 1, now: 5))
    }

    func testTokensCapAtCapacity() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 0)
        // Consume some tokens
        _ = bucket.allow(cost: 50, now: 0)

        // Wait long enough to overfill
        // After 100 seconds at 10/sec = 1000 tokens, but capped at 100
        XCTAssertTrue(bucket.allow(cost: 100, now: 100))
        // Should be empty now
        XCTAssertFalse(bucket.allow(cost: 1, now: 100))
    }

    func testFractionalTokens() {
        var bucket = TokenBucket(ratePerSec: 1, capacity: 10, now: 0)
        // Consume all
        _ = bucket.allow(cost: 10, now: 0)

        // After 0.5 seconds, have 0.5 tokens
        XCTAssertFalse(bucket.allow(cost: 1, now: 0.5))
        // After 1 second, have 1 token
        XCTAssertTrue(bucket.allow(cost: 1, now: 1.0))
    }

    func testZeroCostAlwaysAllowed() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 0)
        // Consume all tokens
        _ = bucket.allow(cost: 100, now: 0)
        // Zero cost should still be allowed
        XCTAssertTrue(bucket.allow(cost: 0, now: 0))
    }

    func testMultipleSmallRequests() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 10, now: 0)

        // 10 requests of cost 1 each
        for i in 0..<10 {
            XCTAssertTrue(bucket.allow(cost: 1, now: TimeInterval(i) * 0.01), "Request \(i) should succeed")
        }

        // 11th should fail
        XCTAssertFalse(bucket.allow(cost: 1, now: 0.1))
    }

    func testBurstThenSteadyState() {
        var bucket = TokenBucket(ratePerSec: 2, capacity: 10, now: 0)

        // Initial burst
        XCTAssertTrue(bucket.allow(cost: 10, now: 0))

        // Now rate-limited to 2/sec
        XCTAssertTrue(bucket.allow(cost: 2, now: 1))
        XCTAssertFalse(bucket.allow(cost: 1, now: 1))

        XCTAssertTrue(bucket.allow(cost: 2, now: 2))
        XCTAssertFalse(bucket.allow(cost: 1, now: 2))
    }

    // MARK: - Edge Cases

    func testNegativeTimeDoesNotAddTokens() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 10)
        _ = bucket.allow(cost: 100, now: 10)

        // "Time travel" backwards should not add tokens
        XCTAssertFalse(bucket.allow(cost: 1, now: 5))
    }

    func testVeryHighRate() {
        var bucket = TokenBucket(ratePerSec: 1000000, capacity: 1000000, now: 0)
        _ = bucket.allow(cost: 1000000, now: 0)

        // After 0.001 seconds, should have 1000 tokens
        XCTAssertTrue(bucket.allow(cost: 1000, now: 0.001))
    }
}

// MARK: - RttEstimator Tests

final class RttEstimatorTests: XCTestCase {

    // MARK: - Basic RttEstimator Tests

    func testInitialState() {
        let estimator = RttEstimator()
        // Before any samples, RTO should be default
        XCTAssertEqual(estimator.rto(), 3.0, accuracy: 0.01)
        XCTAssertNil(estimator.srtt)
    }

    func testFirstSample() {
        var estimator = RttEstimator()
        estimator.update(sample: 2.0)

        // After first sample, SRTT = sample, RTTVAR = sample/2
        XCTAssertEqual(estimator.srtt ?? 0, 2.0, accuracy: 0.01)
        XCTAssertEqual(estimator.rttvar, 1.0, accuracy: 0.01)
        // RTO = SRTT + 4 * RTTVAR = 2 + 4 = 6, but clamped to max 30
        XCTAssertEqual(estimator.rto(), 6.0, accuracy: 0.01)
    }

    func testMultipleSamples() {
        var estimator = RttEstimator()
        // Simulate several RTT samples
        estimator.update(sample: 1.0)
        estimator.update(sample: 1.1)
        estimator.update(sample: 0.9)
        estimator.update(sample: 1.0)

        // SRTT should converge around 1.0
        XCTAssertEqual(estimator.srtt ?? 0, 1.0, accuracy: 0.15)
    }

    func testJacobsonKarelsAlgorithm() {
        var estimator = RttEstimator()

        // First sample initializes
        estimator.update(sample: 1.0)
        let srtt1 = estimator.srtt ?? 0
        let rttvar1 = estimator.rttvar

        // Second sample
        estimator.update(sample: 1.5)

        // RTTVAR = (1 - beta) * RTTVAR + beta * |SRTT - sample|
        // beta = 1/4
        // RTTVAR = 0.75 * 0.5 + 0.25 * |1.0 - 1.5| = 0.375 + 0.125 = 0.5
        let expectedRttvar = (1 - 0.25) * rttvar1 + 0.25 * abs(srtt1 - 1.5)
        XCTAssertEqual(estimator.rttvar, expectedRttvar, accuracy: 0.01)

        // SRTT = (1 - alpha) * SRTT + alpha * sample
        // alpha = 1/8
        // SRTT = 0.875 * 1.0 + 0.125 * 1.5 = 0.875 + 0.1875 = 1.0625
        let expectedSrtt = (1 - 0.125) * srtt1 + 0.125 * 1.5
        XCTAssertEqual(estimator.srtt ?? 0, expectedSrtt, accuracy: 0.01)
    }

    func testRtoMinClamp() {
        var estimator = RttEstimator()
        estimator.update(sample: 0.1)  // Very fast RTT

        // RTO = SRTT + 4 * RTTVAR = 0.1 + 4 * 0.05 = 0.3
        // But clamped to min 1.0
        XCTAssertGreaterThanOrEqual(estimator.rto(), 1.0)
    }

    func testRtoMaxClamp() {
        var estimator = RttEstimator()
        // Simulate highly variable RTT
        estimator.update(sample: 10.0)
        estimator.update(sample: 20.0)
        estimator.update(sample: 5.0)
        estimator.update(sample: 25.0)

        // RTO should be clamped to max 30.0
        XCTAssertLessThanOrEqual(estimator.rto(), 30.0)
    }

    func testCustomMinMax() {
        var estimator = RttEstimator()
        estimator.update(sample: 0.1)

        // Custom bounds
        let rto = estimator.rto(min: 0.5, max: 10.0)
        XCTAssertGreaterThanOrEqual(rto, 0.5)
        XCTAssertLessThanOrEqual(rto, 10.0)
    }

    func testStableRttProducesLowVariance() {
        var estimator = RttEstimator()

        // Feed many identical samples
        for _ in 0..<20 {
            estimator.update(sample: 2.0)
        }

        // Variance should be very low (converges toward 0 with identical samples)
        XCTAssertLessThan(estimator.rttvar, 0.5, "RTTVAR should converge toward 0 with stable RTT")
        // RTO should be close to SRTT when variance is low
        let expectedRto = (estimator.srtt ?? 0) + 4 * estimator.rttvar
        XCTAssertEqual(estimator.rto(), max(1.0, expectedRto), accuracy: 0.5)
    }

    func testHighJitterIncreasesRttvar() {
        var estimator = RttEstimator()

        // Alternating high and low RTTs
        for i in 0..<10 {
            let sample = i % 2 == 0 ? 1.0 : 3.0
            estimator.update(sample: sample)
        }

        // RTTVAR should be significant
        XCTAssertGreaterThan(estimator.rttvar, 0.3)
    }
}
