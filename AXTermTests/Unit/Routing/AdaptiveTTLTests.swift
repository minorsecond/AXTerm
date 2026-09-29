//
//  AdaptiveTTLTests.swift
//  AXTermTests
//
//  Tests for adaptive TTL based on inter-arrival time tracking.
//  Links with sparse traffic get longer TTLs; frequent links stay at the base.
//

import XCTest
@testable import AXTerm

@MainActor
final class AdaptiveTTLTests: XCTestCase {

    private func makeConfig(
        slidingWindowSeconds: TimeInterval = 1800,
        adaptiveTTLMultiplier: Double = 6.0,
        maxAdaptiveTTLSeconds: TimeInterval = 7200,
        maxObservationsPerLink: Int = 200
    ) -> LinkQualityConfig {
        LinkQualityConfig(
            slidingWindowSeconds: slidingWindowSeconds,
            forwardHalfLifeSeconds: 1800,
            reverseHalfLifeSeconds: 1800,
            initialDeliveryRatio: 0.5,
            minDeliveryRatio: 0.05,
            maxETX: 20.0,
            ackProgressWeight: 0.6,
            maxObservationsPerLink: maxObservationsPerLink,
            adaptiveTTLMultiplier: adaptiveTTLMultiplier,
            maxAdaptiveTTLSeconds: maxAdaptiveTTLSeconds
        )
    }

    private func makePacket(
        from: String,
        to: String,
        timestamp: Date
    ) -> Packet {
        let infoData = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .ui,
            info: infoData,
            rawAx25: infoData,
            infoText: "TEST"
        )
    }

    /// With fewer than 3 arrivals, effectiveTTL should return the base TTL.
    func testBaseTTLWithInsufficientSamples() {
        let config = makeConfig()
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // Only 2 observations
        for i in 0..<2 {
            let ts = start.addingTimeInterval(Double(i) * 60)
            estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: ts), timestamp: ts)
        }

        let ttl = estimator.effectiveTTL(from: "W0ABC", to: "W0DEF")
        XCTAssertEqual(ttl, 1800, "Should return base TTL with <3 arrivals")
    }

    /// Frequent traffic (30s inter-arrival): adaptive = 6×30=180s, but base 1800s wins.
    func testAdaptiveTTLForFrequentTraffic() {
        let config = makeConfig()
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // 5 observations at 30s intervals
        for i in 0..<5 {
            let ts = start.addingTimeInterval(Double(i) * 30)
            estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: ts), timestamp: ts)
        }

        let ttl = estimator.effectiveTTL(from: "W0ABC", to: "W0DEF")
        XCTAssertEqual(ttl, 1800, "Frequent traffic should use base TTL (1800 > 6×30)")
    }

    /// Sparse traffic (20min inter-arrival): adaptive = 6×1200=7200s.
    func testAdaptiveTTLForSparseTraffic() {
        let config = makeConfig()
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // 5 observations at 20min intervals
        for i in 0..<5 {
            let ts = start.addingTimeInterval(Double(i) * 1200)
            estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: ts), timestamp: ts)
        }

        let ttl = estimator.effectiveTTL(from: "W0ABC", to: "W0DEF")
        // EWMA with α=0.3 converges toward 1200 but may not reach exact value.
        // With 4 inter-arrival gaps of 1200s each:
        // avg = 1200 (all gaps identical, EWMA converges exactly)
        // adaptive = 6 × 1200 = 7200
        XCTAssertEqual(ttl, 7200, "Sparse traffic should get adaptive TTL of 6× inter-arrival")
    }

    /// Very sparse traffic (60min inter-arrival): adaptive = 6×3600=21600, but capped at 7200.
    func testAdaptiveTTLCappedAtMax() {
        let config = makeConfig()
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // 4 observations at 60min intervals
        for i in 0..<4 {
            let ts = start.addingTimeInterval(Double(i) * 3600)
            estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: ts), timestamp: ts)
        }

        let ttl = estimator.effectiveTTL(from: "W0ABC", to: "W0DEF")
        XCTAssertEqual(ttl, 7200, "Adaptive TTL should be capped at maxAdaptiveTTLSeconds")
    }

    /// Sparse link observations should survive past the base TTL when adaptive TTL is longer.
    func testPurgeUsesAdaptiveTTL() {
        let config = makeConfig()
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // Create a sparse link: 5 observations at 20min intervals
        for i in 0..<5 {
            let ts = start.addingTimeInterval(Double(i) * 1200)
            estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: ts), timestamp: ts)
        }

        // Last observation at start + 4800s. Purge at start + 6000s (2000s after last obs).
        // Base TTL is 1800s so base cutoff = 6000-1800 = 4200. Last obs at 4800 > 4200 → survives base.
        // But let's purge much later: at start + 7000s (2200s after last obs).
        // Base cutoff = 7000-1800 = 5200. Last obs at 4800 < 5200 → would be purged with base TTL.
        // Adaptive TTL is 7200s. Adaptive cutoff = 7000-7200 = -200 → all survive.
        let purgeTime = start.addingTimeInterval(7000)
        estimator.purgeStaleData(currentDate: purgeTime)

        let quality = estimator.linkQuality(from: "W0ABC", to: "W0DEF")
        XCTAssertGreaterThan(quality, 0, "Sparse link should survive past base TTL due to adaptive TTL")
    }

    /// A single outlier gap should not spike the effective TTL due to EWMA smoothing.
    func testInterArrivalEWMASmoothing() {
        let config = makeConfig()
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // 4 observations at 60s intervals
        for i in 0..<4 {
            let ts = start.addingTimeInterval(Double(i) * 60)
            estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: ts), timestamp: ts)
        }

        // One outlier: 30min gap
        let outlier = start.addingTimeInterval(3 * 60 + 1800)
        estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: outlier), timestamp: outlier)

        // Resume normal: 60s after outlier
        let afterOutlier = outlier.addingTimeInterval(60)
        estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: afterOutlier), timestamp: afterOutlier)

        let ttl = estimator.effectiveTTL(from: "W0ABC", to: "W0DEF")
        // Without EWMA, a single 1800s outlier could push TTL to 6×1800=10800 (capped to 7200).
        // With EWMA smoothing (α=0.3), the outlier is dampened:
        // avg ≈ 425s after recovery, so adaptive = 6×425 ≈ 2552, which is < 7200.
        XCTAssertLessThan(ttl, 7200, "EWMA should dampen outlier inter-arrival gap")
        // The TTL should be above base since the outlier still has some influence
        XCTAssertGreaterThan(ttl, 1800, "Outlier should push TTL above base but not to max")
    }
}
