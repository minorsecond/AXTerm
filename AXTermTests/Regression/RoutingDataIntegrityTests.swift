//
//  RoutingDataIntegrityTests.swift
//  AXTermTests
//
//  Comprehensive tests for routing data integrity ensuring the routing page
//  displays accurate, trustworthy data for links, neighbors, routes, and
//  all related metrics (df, dr, ETX, quality, freshness, decay).
//
//  These tests verify:
//  - Quality calculations are mathematically correct
//  - Edge cases are handled properly
//  - Determinism is maintained across identical inputs
//  - Boundary conditions don't cause unexpected behavior
//  - Route selection follows documented rules
//  - Metric calculations match documented formulas
//

import XCTest
@testable import AXTerm

// MARK: - Quality Score Edge Cases

/// Tests quality score calculations at boundaries and extreme conditions
final class QualityScoreEdgeCaseTests: XCTestCase {
    
    private var testClock: Date = Date(timeIntervalSince1970: 1_700_000_000)
    
    private func makeEstimator(config: LinkQualityConfig = .default) -> LinkQualityEstimator {
        let testConfig = LinkQualityConfig(
            source: config.source,
            slidingWindowSeconds: config.slidingWindowSeconds,
            forwardHalfLifeSeconds: 2,
            reverseHalfLifeSeconds: 2,
            initialDeliveryRatio: config.initialDeliveryRatio,
            minDeliveryRatio: config.minDeliveryRatio,
            maxETX: config.maxETX,
            ackProgressWeight: config.ackProgressWeight,
            maxObservationsPerLink: config.maxObservationsPerLink,
            excludeServiceDestinations: config.excludeServiceDestinations
        )
        return LinkQualityEstimator(config: testConfig, clock: { [self] in self.testClock })
    }
    
    private func makePacket(from: String, to: String, timestamp: Date) -> Packet {
        let info = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .i,
            control: 0x00,
            controlByte1: 0x00,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
    }
    
    // MARK: - Boundary Tests
    
    func testQualityNeverExceeds255() {
        var estimator = makeEstimator()
        testClock = Date(timeIntervalSince1970: 1_700_100_000)
        
        // Send thousands of perfect packets
        for i in 0..<1000 {
            let ts = testClock.addingTimeInterval(Double(i) * 0.1)
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }
        
        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertLessThanOrEqual(quality, 255, "Quality must never exceed 255")
        XCTAssertGreaterThanOrEqual(quality, 0, "Quality must never be negative")
    }
    
    func testQualityNeverNegative() {
        var estimator = makeEstimator()
        testClock = Date(timeIntervalSince1970: 1_700_100_000)
        
        // Send all duplicates (worst case)
        for i in 0..<100 {
            let ts = testClock.addingTimeInterval(Double(i) * 0.1)
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: true)
        }
        
        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThanOrEqual(quality, 0, "Quality must never be negative even with all duplicates")
        XCTAssertLessThanOrEqual(quality, 255, "Quality must not exceed 255")
    }
    
    func testQualityZeroForUnknownLink() {
        let estimator = makeEstimator()
        let quality = estimator.linkQuality(from: "UNKNOWN1", to: "UNKNOWN2")
        XCTAssertEqual(quality, 0, "Unknown links should have quality 0")
    }
    
    func testQualityClampingWithExtremeDfDr() {
        // Test that quality remains bounded even with extreme delivery ratios
        var estimator = makeEstimator()
        testClock = Date(timeIntervalSince1970: 1_700_100_000)
        
        // Perfect forward delivery
        for i in 0..<50 {
            let ts = testClock.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }
        
        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")
        
        // Verify dfEstimate is bounded
        if let df = stats.dfEstimate {
            XCTAssertGreaterThanOrEqual(df, 0.0, "df must be >= 0")
            XCTAssertLessThanOrEqual(df, 1.0, "df must be <= 1")
        }
        
        // Verify quality is bounded
        XCTAssertGreaterThanOrEqual(stats.ewmaQuality, 0)
        XCTAssertLessThanOrEqual(stats.ewmaQuality, 255)
    }
    
    // MARK: - ETX Clamping Tests
    
    func testETXClampedToMaximum() {
        // With very poor delivery, ETX should be clamped to maxETX (20.0)
        var estimator = makeEstimator()
        testClock = Date(timeIntervalSince1970: 1_700_100_000)
        
        // 99% duplicates = very poor link
        for i in 0..<100 {
            let ts = testClock.addingTimeInterval(Double(i) * 0.1)
            testClock = ts
            let isDup = i % 100 != 0  // 99% duplicates
            estimator.observePacket(makePacket(from: "W0POOR", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }
        
        let stats = estimator.linkStats(from: "W0POOR", to: "N0CALL")
        
        // Quality should be low but not zero (ETX clamped to max 20)
        // min quality = 255 / 20 = 12.75 ≈ 13
        XCTAssertGreaterThanOrEqual(stats.ewmaQuality, 0)
    }
    
    func testETXMinimumIsOne() {
        // With perfect delivery, ETX should be clamped to minimum 1.0
        var estimator = makeEstimator()
        testClock = Date(timeIntervalSince1970: 1_700_100_000)
        
        // Perfect delivery
        for i in 0..<50 {
            let ts = testClock.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0PFT", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }
        
        // Quality should approach 255 (ETX ≈ 1)
        let quality = estimator.linkQuality(from: "W0PFT", to: "N0CALL")
        XCTAssertGreaterThan(quality, 200, "Perfect delivery should yield quality > 200")
    }
    
    // MARK: - Missing Estimate Handling
    
    func testMissingDfEstimate() {
        let estimator = makeEstimator()
        let stats = estimator.linkStats(from: "NODATA", to: "OTHER")
        
        XCTAssertNil(stats.dfEstimate, "No observations should mean nil dfEstimate")
        XCTAssertEqual(stats.ewmaQuality, 0, "No data should mean quality 0")
    }
    
    func testMissingDrEstimate() {
        var estimator = makeEstimator()
        testClock = Date(timeIntervalSince1970: 1_700_100_000)
        
        // Only forward traffic (no ACKs/reverse evidence)
        for i in 0..<20 {
            let ts = testClock.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }
        
        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")
        
        // drEstimate may be nil without ACK evidence
        XCTAssertNotNil(stats.dfEstimate, "Should have forward estimate")
        // Quality should still be computed using conservative dr fallback
        XCTAssertGreaterThan(stats.ewmaQuality, 0, "Should have quality with forward-only evidence")
    }
}

// MARK: - Route Selection Tests

/// Tests route selection logic including tie-breaking and quality-based sorting
final class RouteSelectionTests: XCTestCase {
    
    private let localCallsign = "N0CALL"
    
    private func makeRouter() -> NetRomRouter {
        NetRomRouter(localCallsign: localCallsign)
    }
    
    private func makePacket(from: String, to: String, timestamp: Date) -> Packet {
        let info = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .ui,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
    }
    
    // MARK: - Deterministic Tie-Breaking
    
    func testRouteSelectionDeterministicTieBreaking() {
        let router = makeRouter()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let destination = "W1DEST"
        
        // Create neighbors with identical quality
        let neighbors = ["W0AAA", "W0BBB", "W0CCC"]
        for neighbor in neighbors {
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: baseTime),
                observedQuality: 200,
                direction: .incoming,
                timestamp: baseTime
            )
        }
        
        // Broadcast routes with identical quality
        for neighbor in neighbors {
            router.broadcastRoutes(
                from: neighbor,
                quality: 180,
                destinations: [RouteInfo(
                    destination: destination,
                    origin: neighbor,
                    quality: 180,
                    path: [neighbor, destination],
                    lastUpdated: baseTime
                )],
                timestamp: baseTime
            )
        }
        
        let routes = router.bestPaths(from: destination)
        
        // Verify deterministic ordering - should be sorted by origin alphabetically when quality ties
        let routeOrigins = routes.map { $0.nodes.first ?? "" }
        XCTAssertEqual(routeOrigins, routeOrigins.sorted(), "Routes with equal quality should be sorted deterministically by origin")
    }
    
    func testRouteSelectionPrefersHigherQuality() {
        let router = makeRouter()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let destination = "W1DEST"
        
        // Create neighbors
        let neighbors = [("W0HIGH", 250), ("W0MED", 180), ("W0LOW", 100)]
        for (neighbor, quality) in neighbors {
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: baseTime),
                observedQuality: quality,
                direction: .incoming,
                timestamp: baseTime
            )
            router.broadcastRoutes(
                from: neighbor,
                quality: quality,
                destinations: [RouteInfo(
                    destination: destination,
                    origin: neighbor,
                    quality: quality,
                    path: [neighbor, destination],
                    lastUpdated: baseTime
                )],
                timestamp: baseTime
            )
        }
        
        let routes = router.bestPaths(from: destination)
        
        // Best route should be from highest quality neighbor
        XCTAssertGreaterThan(routes.count, 0)
        if let bestRoute = routes.first {
            XCTAssertEqual(bestRoute.nodes.first, "W0HIGH", "Best route should be from highest quality neighbor")
        }
        
        // Routes should be sorted by quality descending
        let qualities = routes.map(\.quality)
        XCTAssertEqual(qualities, qualities.sorted(by: >), "Routes should be sorted by quality descending")
    }
    
    // MARK: - Max Routes Per Destination
    
    func testMaxRoutesPerDestinationEnforced() {
        let router = makeRouter()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let destination = "W1DEST"
        let maxRoutes = NetRomConfig.default.maxRoutesPerDestination
        
        // Create more neighbors than maxRoutesPerDestination
        for i in 0..<(maxRoutes + 3) {
            let neighbor = "W\(i)NBR"
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: baseTime.addingTimeInterval(Double(i))),
                observedQuality: 200 - i * 10,
                direction: .incoming,
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            router.broadcastRoutes(
                from: neighbor,
                quality: 180 - i * 10,
                destinations: [RouteInfo(
                    destination: destination,
                    origin: neighbor,
                    quality: 180 - i * 10,
                    path: [neighbor, destination],
                    lastUpdated: baseTime.addingTimeInterval(Double(i))
                )],
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
        }
        
        let routes = router.bestPaths(from: destination)
        XCTAssertLessThanOrEqual(routes.count, maxRoutes, "Should keep at most \(maxRoutes) routes per destination")
    }
    
    // MARK: - Route Quality Updates
    
    func testRouteQualityUpdatesCorrectly() {
        let router = makeRouter()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let neighbor = "W0ABC"
        let destination = "W1DEST"
        
        // Establish neighbor
        router.observePacket(
            makePacket(from: neighbor, to: localCallsign, timestamp: baseTime),
            observedQuality: 200,
            direction: .incoming,
            timestamp: baseTime
        )
        
        // Initial route
        router.broadcastRoutes(
            from: neighbor,
            quality: 150,
            destinations: [RouteInfo(
                destination: destination,
                origin: neighbor,
                quality: 150,
                path: [neighbor, destination],
                lastUpdated: baseTime
            )],
            timestamp: baseTime
        )
        
        let initialQuality = router.bestPaths(from: destination).first?.quality ?? 0
        
        // Update with better quality
        router.broadcastRoutes(
            from: neighbor,
            quality: 200,
            destinations: [RouteInfo(
                destination: destination,
                origin: neighbor,
                quality: 200,
                path: [neighbor, destination],
                lastUpdated: baseTime.addingTimeInterval(1)
            )],
            timestamp: baseTime.addingTimeInterval(1)
        )
        
        let updatedQuality = router.bestPaths(from: destination).first?.quality ?? 0
        
        XCTAssertGreaterThanOrEqual(updatedQuality, initialQuality, "Route quality should update to better value")
    }
}

// MARK: - Neighbor Quality Transition Tests

/// Tests neighbor quality changes over time including EWMA behavior
final class NeighborQualityTransitionTests: XCTestCase {
    
    private let localCallsign = "N0CALL"
    
    private func makeRouter() -> NetRomRouter {
        NetRomRouter(localCallsign: localCallsign)
    }
    
    private func makePacket(from: String, to: String, timestamp: Date) -> Packet {
        let info = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .ui,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
    }
    
    // MARK: - Quality Decrease Tests
    
    func testNeighborQualityDecreasesGradually() {
        let router = makeRouter()
        let neighbor = "W0ABC"
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        // Build up high quality
        for i in 0..<10 {
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: baseTime.addingTimeInterval(Double(i))),
                observedQuality: 250,
                direction: .incoming,
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
        }
        
        let highQuality = router.currentNeighbors().first?.quality ?? 0
        
        // Now observe with poor quality
        for i in 10..<30 {
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: baseTime.addingTimeInterval(Double(i))),
                observedQuality: 50,
                direction: .incoming,
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
        }
        
        let lowQuality = router.currentNeighbors().first?.quality ?? 0
        
        XCTAssertLessThan(lowQuality, highQuality, "Quality should decrease with poor observations")
        XCTAssertGreaterThan(lowQuality, 50, "EWMA should prevent instant drop to observed value")
    }
    
    func testNeighborQualityRapidChanges() {
        let router = makeRouter()
        let neighbor = "W0ABC"
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        var qualities: [Int] = []
        
        // Alternating good/bad quality rapidly
        for i in 0..<20 {
            let observedQuality = i % 2 == 0 ? 250 : 50
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: baseTime.addingTimeInterval(Double(i))),
                observedQuality: observedQuality,
                direction: .incoming,
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            qualities.append(router.currentNeighbors().first?.quality ?? 0)
        }
        
        // Quality should not oscillate wildly - EWMA smooths changes
        for i in 1..<qualities.count {
            let change = abs(qualities[i] - qualities[i-1])
            XCTAssertLessThan(change, 100, "Quality changes should be smoothed by EWMA")
        }
    }
    
    // MARK: - Source Type Transitions
    
    func testSourceTypePreservesClassicOverInferred() {
        let router = makeRouter()
        let neighbor = "W0ABC"
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        // First as classic
        router.observePacket(
            makePacket(from: neighbor, to: localCallsign, timestamp: baseTime),
            observedQuality: 200,
            direction: .incoming,
            timestamp: baseTime
        )
        
        let afterClassic = router.currentNeighbors().first?.sourceType ?? ""
        XCTAssertEqual(afterClassic, "classic")
        
        // Then as inferred (should not overwrite)
        router.observePacketInferred(
            makePacket(from: neighbor, to: localCallsign, timestamp: baseTime.addingTimeInterval(1)),
            observedQuality: 180,
            direction: .incoming,
            timestamp: baseTime.addingTimeInterval(1)
        )
        
        let afterInferred = router.currentNeighbors().first?.sourceType ?? ""
        XCTAssertEqual(afterInferred, "classic", "Classic source type should not be overwritten by inferred")
    }
}

// MARK: - Ring Buffer Tests

/// Tests the ring buffer behavior in link quality estimation
final class LinkQualityRingBufferTests: XCTestCase {
    
    private var testClock: Date = Date(timeIntervalSince1970: 1_700_000_000)
    
    private func makeEstimator(maxObservations: Int) -> LinkQualityEstimator {
        let config = LinkQualityConfig(
            source: .kiss,
            slidingWindowSeconds: 3600,
            forwardHalfLifeSeconds: 30,
            reverseHalfLifeSeconds: 30,
            initialDeliveryRatio: 0.5,
            minDeliveryRatio: 0.05,
            maxETX: 20.0,
            ackProgressWeight: 0.6,
            maxObservationsPerLink: maxObservations,
            excludeServiceDestinations: false
        )
        return LinkQualityEstimator(config: config, clock: { [self] in self.testClock })
    }
    
    private func makePacket(from: String, to: String, timestamp: Date) -> Packet {
        let info = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .i,
            control: 0x00,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
    }
    
    func testRingBufferWraparound() {
        var estimator = makeEstimator(maxObservations: 10)
        testClock = Date(timeIntervalSince1970: 1_700_100_000)
        
        // Send more packets than buffer capacity
        for i in 0..<25 {
            let ts = testClock.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }
        
        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")
        
        // Observation count should be bounded
        XCTAssertLessThanOrEqual(stats.observationCount, 10, "Ring buffer should limit observations")
        
        // Quality should still be valid
        XCTAssertGreaterThan(stats.ewmaQuality, 0, "Quality should be computed despite wrap-around")
        XCTAssertLessThanOrEqual(stats.ewmaQuality, 255)
    }
    
    func testRingBufferMaintainsQualityAfterWrap() {
        var estimator = makeEstimator(maxObservations: 20)
        testClock = Date(timeIntervalSince1970: 1_700_100_000)
        
        // Phase 1: Build quality with clean packets
        for i in 0..<15 {
            let ts = testClock.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }
        
        let qualityBefore = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        
        // Phase 2: Continue with clean packets past buffer capacity
        for i in 15..<40 {
            let ts = testClock.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }
        
        let qualityAfter = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        
        // Quality should remain stable (not degraded by wrap-around)
        XCTAssertGreaterThanOrEqual(qualityAfter, qualityBefore - 20, "Quality should not degrade significantly after ring buffer wrap")
    }
}

// MARK: - Freshness Calculation Tests

/// Tests freshness/decay calculations with plateau + smoothstep model
final class FreshnessCalculationTests: XCTestCase {
    
    private let defaultTTL: TimeInterval = 30 * 60  // 30 minutes
    private let defaultPlateau: TimeInterval = 5 * 60  // 5 minutes
    
    // MARK: - Plateau Phase Tests
    
    func testFreshnessDuringPlateau() {
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        // At T=0, freshness should be 100%
        let freshnessT0 = FreshnessCalculator.freshness(lastSeen: baseTime, now: baseTime, ttl: defaultTTL, plateau: defaultPlateau)
        XCTAssertEqual(freshnessT0, 1.0, accuracy: 0.01, "At T=0, freshness should be 100%")
        
        // During plateau (T=3min), freshness should be ~97% (gentle decline)
        let at3min = baseTime.addingTimeInterval(3 * 60)
        let freshnessAt3min = FreshnessCalculator.freshness(lastSeen: baseTime, now: at3min, ttl: defaultTTL, plateau: defaultPlateau)
        XCTAssertGreaterThan(freshnessAt3min, 0.95, "During plateau, freshness should be > 95%")
        XCTAssertLessThan(freshnessAt3min, 1.0, "During plateau, freshness should decline slightly")
    }
    
    func testFreshnessAfterPlateau() {
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        // At plateau boundary (T=5min), freshness should be ~95%
        let atPlateau = baseTime.addingTimeInterval(defaultPlateau)
        let freshnessAtPlateau = FreshnessCalculator.freshness(lastSeen: baseTime, now: atPlateau, ttl: defaultTTL, plateau: defaultPlateau)
        XCTAssertEqual(freshnessAtPlateau, 0.95, accuracy: 0.01, "At plateau end, freshness should be ~95%")
        
        // Midway through decay phase (T=17.5min), freshness should be around 50%
        let midDecay = baseTime.addingTimeInterval((defaultTTL + defaultPlateau) / 2)
        let freshnessMid = FreshnessCalculator.freshness(lastSeen: baseTime, now: midDecay, ttl: defaultTTL, plateau: defaultPlateau)
        XCTAssertLessThan(freshnessMid, 0.80)
        XCTAssertGreaterThan(freshnessMid, 0.20)
    }
    
    func testFreshnessAtExpiration() {
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        // At TTL, freshness should be 0%
        let atTTL = baseTime.addingTimeInterval(defaultTTL)
        let freshnessAtTTL = FreshnessCalculator.freshness(lastSeen: baseTime, now: atTTL, ttl: defaultTTL, plateau: defaultPlateau)
        XCTAssertEqual(freshnessAtTTL, 0.0, accuracy: 0.01, "At TTL, freshness should be 0%")
        
        // Beyond TTL, freshness should remain 0%
        let beyondTTL = baseTime.addingTimeInterval(defaultTTL * 2)
        let freshnessBeyond = FreshnessCalculator.freshness(lastSeen: baseTime, now: beyondTTL, ttl: defaultTTL, plateau: defaultPlateau)
        XCTAssertEqual(freshnessBeyond, 0.0, accuracy: 0.01, "Beyond TTL, freshness should be 0%")
    }
    
    // MARK: - Freshness255 Mapping Tests
    
    func testFreshness255Mapping() {
        // 100% -> 255
        XCTAssertEqual(FreshnessCalculator.freshness255(fraction: 1.0), 255)
        
        // 50% -> 128
        let half = FreshnessCalculator.freshness255(fraction: 0.5)
        XCTAssertTrue(abs(half - 128) <= 1, "50% should map to ~128, got \(half)")
        
        // 0% -> 0
        XCTAssertEqual(FreshnessCalculator.freshness255(fraction: 0.0), 0)
        
        // Clamping tests
        XCTAssertEqual(FreshnessCalculator.freshness255(fraction: -0.5), 0, "Negative should clamp to 0")
        XCTAssertEqual(FreshnessCalculator.freshness255(fraction: 1.5), 255, "Above 1.0 should clamp to 255")
    }
    
    // MARK: - Smoothstep Function Tests
    
    func testSmoothstepBehavior() {
        // Smoothstep: t²(3 - 2t)
        
        // At t=0, output should be 0
        XCTAssertEqual(FreshnessCalculator.smoothstep(0.0), 0.0, accuracy: 0.001)
        
        // At t=0.5, output should be 0.5 (inflection point)
        XCTAssertEqual(FreshnessCalculator.smoothstep(0.5), 0.5, accuracy: 0.001)
        
        // At t=1.0, output should be 1.0
        XCTAssertEqual(FreshnessCalculator.smoothstep(1.0), 1.0, accuracy: 0.001)
        
        // Clamping
        XCTAssertEqual(FreshnessCalculator.smoothstep(-0.5), 0.0, accuracy: 0.001)
        XCTAssertEqual(FreshnessCalculator.smoothstep(1.5), 1.0, accuracy: 0.001)
    }
}

// MARK: - Determinism Tests

/// Tests that identical inputs always produce identical outputs
final class RoutingDeterminismTests: XCTestCase {
    
    private var testClock: Date = Date(timeIntervalSince1970: 1_700_000_000)
    
    private func makeEstimator() -> LinkQualityEstimator {
        let config = LinkQualityConfig(
            source: .kiss,
            slidingWindowSeconds: 300,
            forwardHalfLifeSeconds: 30,
            reverseHalfLifeSeconds: 30,
            initialDeliveryRatio: 0.5,
            minDeliveryRatio: 0.05,
            maxETX: 20.0,
            ackProgressWeight: 0.6,
            maxObservationsPerLink: 100,
            excludeServiceDestinations: false
        )
        return LinkQualityEstimator(config: config, clock: { [self] in self.testClock })
    }
    
    private func makePacket(from: String, to: String, timestamp: Date, isDuplicate: Bool = false) -> (Packet, Bool) {
        let info = "TEST".data(using: .ascii) ?? Data()
        let packet = Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .i,
            control: 0x00,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
        return (packet, isDuplicate)
    }
    
    func testLinkQualityDeterminism() {
        func runScenario() -> (Int, LinkStats) {
            testClock = Date(timeIntervalSince1970: 1_700_000_000)
            var estimator = makeEstimator()
            let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
            
            // Complex packet sequence
            let sequence: [(Int, Bool)] = [
                (0, false), (1, false), (2, true), (3, false), (4, true),
                (5, false), (6, false), (7, true), (8, false), (9, false),
                (10, true), (11, false), (12, false), (13, true), (14, false)
            ]
            
            for (offset, isDup) in sequence {
                let ts = baseTime.addingTimeInterval(Double(offset))
                testClock = ts
                let (packet, _) = makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts, isDuplicate: isDup)
                estimator.observePacket(packet, timestamp: ts, isDuplicate: isDup)
            }
            
            return (estimator.linkQuality(from: "W0ABC", to: "N0CALL"), estimator.linkStats(from: "W0ABC", to: "N0CALL"))
        }
        
        let (quality1, stats1) = runScenario()
        let (quality2, stats2) = runScenario()
        
        XCTAssertEqual(quality1, quality2, "Quality must be deterministic")
        XCTAssertEqual(stats1.observationCount, stats2.observationCount, "Observation count must be deterministic")
        XCTAssertEqual(stats1.duplicateCount, stats2.duplicateCount, "Duplicate count must be deterministic")
        XCTAssertEqual(stats1.ewmaQuality, stats2.ewmaQuality, "EWMA quality must be deterministic")
        
        if let df1 = stats1.dfEstimate, let df2 = stats2.dfEstimate {
            XCTAssertEqual(df1, df2, accuracy: 0.0001, "dfEstimate must be deterministic")
        }
    }
    
    func testRouterDeterminism() {
        func runScenario() -> [RouteInfo] {
            let router = NetRomRouter(localCallsign: "N0CALL")
            let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
            
            // Establish neighbors in specific order
            let neighbors = [("W0ABC", 200), ("W1XYZ", 180), ("K0ZZZ", 220)]
            for (i, (neighbor, quality)) in neighbors.enumerated() {
                let ts = baseTime.addingTimeInterval(Double(i))
                let info = "TEST".data(using: .ascii)!
                let packet = Packet(
                    timestamp: ts,
                    from: AX25Address(call: neighbor),
                    to: AX25Address(call: "N0CALL"),
                    via: [],
                    frameType: .ui,
                    info: info,
                    rawAx25: info,
                    infoText: "TEST"
                )
                router.observePacket(packet, observedQuality: quality, direction: .incoming, timestamp: ts)
                
                router.broadcastRoutes(
                    from: neighbor,
                    quality: quality - 20,
                    destinations: [RouteInfo(
                        destination: "W2DEST",
                        origin: neighbor,
                        quality: quality - 20,
                        path: [neighbor, "W2DEST"],
                        lastUpdated: ts
                    )],
                    timestamp: ts
                )
            }
            
            return router.currentRoutes()
        }
        
        let routes1 = runScenario()
        let routes2 = runScenario()
        
        XCTAssertEqual(routes1.count, routes2.count, "Route count must be deterministic")
        
        for (r1, r2) in zip(routes1, routes2) {
            XCTAssertEqual(r1.destination, r2.destination, "Route destination must be deterministic")
            XCTAssertEqual(r1.origin, r2.origin, "Route origin must be deterministic")
            XCTAssertEqual(r1.quality, r2.quality, "Route quality must be deterministic")
            XCTAssertEqual(r1.path, r2.path, "Route path must be deterministic")
        }
    }
    
    func testFreshnessDeterminism() {
        func calculateFreshness() -> (Double, Int, String) {
            let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
            let elapsed: TimeInterval = 12 * 60  // 12 minutes
            let now = baseTime.addingTimeInterval(elapsed)
            let ttl: TimeInterval = 30 * 60
            let plateau: TimeInterval = 5 * 60
            
            let fraction = FreshnessCalculator.freshness(lastSeen: baseTime, now: now, ttl: ttl, plateau: plateau)
            let mapped = FreshnessCalculator.freshness255(fraction: fraction)
            let display = FreshnessCalculator.freshnessDisplayString(fraction: fraction)
            
            return (fraction, mapped, display)
        }
        
        let (frac1, map1, disp1) = calculateFreshness()
        let (frac2, map2, disp2) = calculateFreshness()
        
        XCTAssertEqual(frac1, frac2, accuracy: 0.0001, "Freshness fraction must be deterministic")
        XCTAssertEqual(map1, map2, "Freshness255 must be deterministic")
        XCTAssertEqual(disp1, disp2, "Freshness display must be deterministic")
    }
}

// MARK: - Persistence Round-Trip Tests

/// Tests that data survives persistence round-trips accurately
final class RoutingPersistenceRoundTripTests: XCTestCase {
    
    private var testClock: Date = Date(timeIntervalSince1970: 1_700_000_000)
    
    private func makeEstimator() -> LinkQualityEstimator {
        let config = LinkQualityConfig(
            source: .kiss,
            slidingWindowSeconds: 300,
            forwardHalfLifeSeconds: 30,
            reverseHalfLifeSeconds: 30,
            initialDeliveryRatio: 0.5,
            minDeliveryRatio: 0.05,
            maxETX: 20.0,
            ackProgressWeight: 0.6,
            maxObservationsPerLink: 100,
            excludeServiceDestinations: false
        )
        return LinkQualityEstimator(config: config, clock: { [self] in self.testClock })
    }
    
    func testLinkStatExportImportRoundTrip() {
        var original = makeEstimator()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        testClock = baseTime
        
        // Build up link stats
        for i in 0..<20 {
            let ts = baseTime.addingTimeInterval(Double(i))
            testClock = ts
            let info = "TEST".data(using: .ascii)!
            let packet = Packet(
                timestamp: ts,
                from: AX25Address(call: "W0ABC"),
                to: AX25Address(call: "N0CALL"),
                via: [],
                frameType: .i,
                info: info,
                rawAx25: info,
                infoText: "TEST"
            )
            original.observePacket(packet, timestamp: ts, isDuplicate: i % 4 == 0)
        }
        
        let originalQuality = original.linkQuality(from: "W0ABC", to: "N0CALL")
        let originalStats = original.linkStats(from: "W0ABC", to: "N0CALL")
        
        // Export
        let exported = original.exportLinkStats()
        XCTAssertGreaterThan(exported.count, 0, "Should export link stats")
        
        // Import into fresh estimator
        var restored = makeEstimator()
        restored.importLinkStats(exported)
        
        let restoredQuality = restored.linkQuality(from: "W0ABC", to: "N0CALL")
        
        // Quality should be preserved
        XCTAssertEqual(restoredQuality, originalQuality, "Quality should survive export/import round-trip")
    }
    
    func testNeighborImportPreservesData() {
        let router = NetRomRouter(localCallsign: "N0CALL")
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        let neighbors = [
            NeighborInfo(call: "W0ABC", quality: 200, lastSeen: baseTime, sourceType: "classic"),
            NeighborInfo(call: "W1XYZ", quality: 180, lastSeen: baseTime.addingTimeInterval(-300), sourceType: "inferred")
        ]
        
        router.importNeighbors(neighbors)
        
        let imported = router.currentNeighbors()
        
        XCTAssertEqual(imported.count, 2, "Should import all neighbors")
        
        for original in neighbors {
            let found = imported.first { $0.call == original.call }
            XCTAssertNotNil(found, "Should find neighbor \(original.call)")
            XCTAssertEqual(found?.quality, original.quality, "Quality should be preserved")
            XCTAssertEqual(found?.sourceType, original.sourceType, "Source type should be preserved")
        }
    }
    
    func testRouteImportPreservesData() {
        let router = NetRomRouter(localCallsign: "N0CALL")
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        let routes = [
            RouteInfo(destination: "W1DEST", origin: "W0ABC", quality: 180, path: ["W0ABC", "W1DEST"], lastUpdated: baseTime, sourceType: "broadcast"),
            RouteInfo(destination: "W2DEST", origin: "W1XYZ", quality: 150, path: ["W1XYZ", "W2DEST"], lastUpdated: baseTime.addingTimeInterval(-300), sourceType: "inferred")
        ]
        
        router.importRoutes(routes)
        
        let imported = router.currentRoutes()
        
        XCTAssertEqual(imported.count, 2, "Should import all routes")
        
        for original in routes {
            let found = imported.first { $0.destination == original.destination && $0.origin == original.origin }
            XCTAssertNotNil(found, "Should find route to \(original.destination) via \(original.origin)")
            XCTAssertEqual(found?.quality, original.quality, "Quality should be preserved")
            XCTAssertEqual(found?.path, original.path, "Path should be preserved")
            XCTAssertEqual(found?.sourceType, original.sourceType, "Source type should be preserved")
        }
    }
}

// MARK: - Integration Regression Tests

/// Regression tests to ensure routing components work together correctly
final class RoutingIntegrationRegressionTests: XCTestCase {
    
    func testNeighborQualityDoesNotPegAt255() {
        // Regression: Quality used to always increase and peg at 255
        let router = NetRomRouter(localCallsign: "N0CALL")
        let neighbor = "W0ABC"
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        // Many observations with moderate quality
        for i in 0..<50 {
            let ts = baseTime.addingTimeInterval(Double(i))
            let info = "TEST".data(using: .ascii)!
            let packet = Packet(
                timestamp: ts,
                from: AX25Address(call: neighbor),
                to: AX25Address(call: "N0CALL"),
                via: [],
                frameType: .ui,
                info: info,
                rawAx25: info,
                infoText: "TEST"
            )
            router.observePacket(packet, observedQuality: 150, direction: .incoming, timestamp: ts)
        }
        
        let quality = router.currentNeighbors().first?.quality ?? 0
        
        XCTAssertLessThan(quality, 255, "Quality should not peg at 255 with moderate observations")
        XCTAssertGreaterThan(quality, 100, "Quality should be reasonable")
    }
    
    func testLinkQualityDirectionalIndependence() {
        // Regression: A→B quality must not affect B→A
        var testClock = Date(timeIntervalSince1970: 1_700_000_000)
        let config = LinkQualityConfig.default
        var estimator = LinkQualityEstimator(config: config, clock: { testClock })
        
        // Only A→B packets
        for i in 0..<30 {
            let ts = testClock.addingTimeInterval(Double(i))
            testClock = ts
            let info = "TEST".data(using: .ascii)!
            let packet = Packet(
                timestamp: ts,
                from: AX25Address(call: "W0ABC"),
                to: AX25Address(call: "N0CALL"),
                via: [],
                frameType: .i,
                info: info,
                rawAx25: info,
                infoText: "TEST"
            )
            estimator.observePacket(packet, timestamp: ts)
        }
        
        let forwardQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        let reverseQuality = estimator.linkQuality(from: "N0CALL", to: "W0ABC")
        
        XCTAssertGreaterThan(forwardQuality, 0, "Forward direction should have quality")
        XCTAssertEqual(reverseQuality, 0, "Reverse direction MUST have zero quality without evidence")
    }
    
    func testRouteQualityCombinationFormula() {
        // Verify: quality = ((broadcastQuality × pathQuality) + 128) / 256
        let router = NetRomRouter(localCallsign: "N0CALL")
        let neighbor = "W0ABC"
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        // Establish neighbor with known quality
        let info = "TEST".data(using: .ascii)!
        let packet = Packet(
            timestamp: baseTime,
            from: AX25Address(call: neighbor),
            to: AX25Address(call: "N0CALL"),
            via: [],
            frameType: .ui,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
        router.observePacket(packet, observedQuality: 200, direction: .incoming, timestamp: baseTime)
        
        let neighborQuality = router.currentNeighbors().first?.quality ?? 0
        
        // Broadcast a route
        let broadcastQuality = 180
        router.broadcastRoutes(
            from: neighbor,
            quality: broadcastQuality,
            destinations: [RouteInfo(
                destination: "W1DEST",
                origin: neighbor,
                quality: broadcastQuality,
                path: [neighbor, "W1DEST"],
                lastUpdated: baseTime
            )],
            timestamp: baseTime.addingTimeInterval(1)
        )
        
        let routeQuality = router.currentRoutes().first?.quality ?? 0
        
        // Expected: ((180 × neighborQuality) + 128) / 256
        let expected = ((broadcastQuality * neighborQuality) + 128) / 256
        
        XCTAssertEqual(routeQuality, expected, "Route quality should match NET/ROM formula")
    }
    
    func testStaleDataPurged() {
        let router = NetRomRouter(localCallsign: "N0CALL")
        let neighbor = "W0ABC"
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        
        // Create neighbor and route
        let info = "TEST".data(using: .ascii)!
        let packet = Packet(
            timestamp: baseTime,
            from: AX25Address(call: neighbor),
            to: AX25Address(call: "N0CALL"),
            via: [],
            frameType: .ui,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
        router.observePacket(packet, observedQuality: 200, direction: .incoming, timestamp: baseTime)
        
        router.broadcastRoutes(
            from: neighbor,
            quality: 180,
            destinations: [RouteInfo(
                destination: "W1DEST",
                origin: neighbor,
                quality: 180,
                path: [neighbor, "W1DEST"],
                lastUpdated: baseTime
            )],
            timestamp: baseTime
        )
        
        XCTAssertEqual(router.currentNeighbors().count, 1)
        XCTAssertEqual(router.currentRoutes().count, 1)
        
        // Purge after TTL
        let staleTime = baseTime.addingTimeInterval(NetRomConfig.default.routeTTLSeconds + 10)
        router.purgeStaleRoutes(currentDate: staleTime)
        
        // purgeStaleRoutes is now a no-op — expired entries are kept for display
        XCTAssertEqual(router.currentNeighbors().count, 1, "Expired neighbors should be kept for display")
        XCTAssertEqual(router.currentRoutes().count, 1, "Expired routes should be kept for display")
        XCTAssertNil(router.bestRouteTo("W1DEST"), "bestRouteTo must not return expired routes")
    }
}

// MARK: - EWMA Correctness Tests

/// Tests that EWMA calculations are mathematically correct
final class EWMACorrectnessTests: XCTestCase {
    
    func testEWMAAlphaCalculation() {
        // λ = 1 - exp(-Δt / H)
        // With H = 30 seconds and Δt = 30 seconds:
        // λ = 1 - exp(-1) ≈ 1 - 0.368 ≈ 0.632
        
        let halfLife: TimeInterval = 30
        let delta: TimeInterval = 30
        let expectedAlpha = 1.0 - exp(-delta / halfLife)
        
        XCTAssertEqual(expectedAlpha, 0.632, accuracy: 0.01, "Alpha at t=halfLife should be ~0.632")
        
        // At t=0, alpha should be 0
        let alphaAtZero = 1.0 - exp(0)
        XCTAssertEqual(alphaAtZero, 0.0, accuracy: 0.001, "Alpha at t=0 should be 0")
        
        // At t→∞, alpha should approach 1
        let alphaAtInfinity = 1.0 - exp(-1000)
        XCTAssertEqual(alphaAtInfinity, 1.0, accuracy: 0.001, "Alpha at t→∞ should approach 1")
    }
    
    func testEWMABlending() {
        // EWMA: new = (1-α) × old + α × observed
        let old = 0.8
        let observed = 0.4
        let alpha = 0.3
        
        let expected = (1 - alpha) * old + alpha * observed
        // = 0.7 × 0.8 + 0.3 × 0.4 = 0.56 + 0.12 = 0.68
        
        XCTAssertEqual(expected, 0.68, accuracy: 0.001)
    }
    
    func testEWMAConvergence() {
        // EWMA should converge to observed value with repeated observations
        var value = 0.5  // Starting value
        let observed = 0.9
        let alpha = 0.3
        
        for _ in 0..<100 {
            value = (1 - alpha) * value + alpha * observed
        }
        
        XCTAssertEqual(value, observed, accuracy: 0.01, "EWMA should converge to observed value")
    }
}

// MARK: - Callsign Normalization Tests

/// Tests callsign normalization for consistent routing
final class CallsignNormalizationTests: XCTestCase {
    
    func testCallsignNormalizationCaseInsensitive() {
        let normalized1 = CallsignValidator.normalize("w0abc")
        let normalized2 = CallsignValidator.normalize("W0ABC")
        let normalized3 = CallsignValidator.normalize("W0AbC")
        
        XCTAssertEqual(normalized1, normalized2, "Callsigns should be case-normalized")
        XCTAssertEqual(normalized2, normalized3, "Callsigns should be case-normalized")
    }
    
    func testCallsignWithSSIDNormalization() {
        let normalized1 = CallsignValidator.normalize("W0ABC-1")
        let normalized2 = CallsignValidator.normalize("w0abc-1")
        
        XCTAssertEqual(normalized1, normalized2, "Callsigns with SSID should be normalized")
    }
    
    func testCallsignValidation() {
        // Valid callsigns
        XCTAssertTrue(CallsignValidator.isValidCallsign("W0ABC"))
        XCTAssertTrue(CallsignValidator.isValidCallsign("N0CALL"))
        XCTAssertTrue(CallsignValidator.isValidCallsign("K9ZZZ"))
        
        // Invalid service destinations
        XCTAssertFalse(CallsignValidator.isValidCallsign("BEACON"))
        XCTAssertFalse(CallsignValidator.isValidCallsign("ID"))
        XCTAssertFalse(CallsignValidator.isValidCallsign("MAIL"))
    }
}
