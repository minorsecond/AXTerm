//
//  NetRomLinkQualityTests.swift
//  AXTermTests
//
//  Created by Codex on 1/30/26.
//

import XCTest

/// Link quality estimation uses ETX-style metrics (De Couto/Roofnet lineage) to compute
/// directional quality between stations. The ETX (Expected Transmission Count) formula is:
///
///   ETX = 1 / (df * dr)
///
/// where df = forward delivery probability and dr = reverse delivery probability.
/// Quality mapping: quality = clamp(round(255 / ETX), 0...255) = clamp(round(255 * df * dr), 0...255)
///
/// Since AX.25 often has UI-only (no ACK), dr is frequently unobservable. We support:
/// 1) Full ETX when both df and dr are estimable
/// 2) Unidirectional ETX fallback: quality ≈ 255 * df when dr is unknown
///
/// EWMA smoothing is applied for stability (alpha configurable).
/// Directionality: A→B stats MUST NOT affect B→A unless there is explicit reverse evidence.
@testable import AXTerm

final class NetRomLinkQualityTests: XCTestCase {

    // Injectable time source for deterministic tests
    private var testClock: Date = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEstimator(config: LinkQualityConfig = .default) -> LinkQualityEstimator {
        LinkQualityEstimator(config: config, clock: { [self] in self.testClock })
    }

    private func makePacket(
        from: String,
        to: String,
        via: [String] = [],
        frameType: FrameType = .ui,
        timestamp: Date
    ) -> Packet {
        let info = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: frameType,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
    }

    // MARK: - Basic Quality Estimation

    func testInitialQualityFromSinglePacket() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_000)
        testClock = now
        let packet = makePacket(from: "W0ABC", to: "N0CALL", timestamp: now)

        estimator.observePacket(packet, timestamp: now)

        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThan(quality, 0, "First packet should establish non-zero quality.")
        XCTAssertLessThanOrEqual(quality, 255)
    }

    func testQualityIncreasesWithMorePackets() {
        var estimator = makeEstimator()
        let start = Date(timeIntervalSince1970: 1_700_002_100)
        testClock = start

        estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: start), timestamp: start)
        let initialQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

        for offset in 1..<10 {
            let ts = start.addingTimeInterval(Double(offset))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let finalQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThanOrEqual(finalQuality, initialQuality, "Quality should improve with consistent delivery.")
    }

    // MARK: - Directionality (CRITICAL)

    func testDirectionalQualityIsIndependent() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_200)
        testClock = now

        // Only A→B packets
        for offset in 0..<5 {
            let ts = now.addingTimeInterval(Double(offset))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let aToBQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        let bToAQuality = estimator.linkQuality(from: "N0CALL", to: "W0ABC")

        XCTAssertGreaterThan(aToBQuality, 0)
        XCTAssertEqual(bToAQuality, 0, "Reverse direction should have no observations - A→B stats MUST NOT affect B→A.")
    }

    func testBidirectionalQualityRequiresBothDirections() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_300)
        testClock = now

        // A→B packets
        for offset in 0..<3 {
            let ts = now.addingTimeInterval(Double(offset))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        // B→A packets
        for offset in 3..<6 {
            let ts = now.addingTimeInterval(Double(offset))
            testClock = ts
            estimator.observePacket(makePacket(from: "N0CALL", to: "W0ABC", timestamp: ts), timestamp: ts)
        }

        let aToBQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        let bToAQuality = estimator.linkQuality(from: "N0CALL", to: "W0ABC")

        XCTAssertGreaterThan(aToBQuality, 0)
        XCTAssertGreaterThan(bToAQuality, 0)
    }

    func testDirectionalityPreservation_AtoB_DoesNotAffect_BtoA() {
        // This test explicitly verifies that observations in one direction
        // do not leak into the reverse direction stats
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_010_000)
        testClock = now

        // Observe 50 packets A→B with some duplicates (simulating retries)
        for i in 0..<50 {
            let ts = now.addingTimeInterval(Double(i) * 0.5)
            testClock = ts
            let isDup = i % 5 == 0 // 20% duplicates
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }

        let statsAB = estimator.linkStats(from: "W0ABC", to: "N0CALL")
        let statsBA = estimator.linkStats(from: "N0CALL", to: "W0ABC")

        XCTAssertGreaterThan(statsAB.observationCount, 0)
        XCTAssertEqual(statsBA.observationCount, 0, "B→A should have ZERO observations when only A→B traffic exists")
        XCTAssertEqual(statsBA.ewmaQuality, 0, "B→A quality must be 0 without observations")
    }

    // MARK: - ETX Calculation (De Couto/Roofnet formula)

    func testETXQualityCalculation() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_400)
        testClock = now

        // Simulate perfect delivery (no retries observed)
        for offset in 0..<20 {
            let ts = now.addingTimeInterval(Double(offset) * 2)
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        // With perfect delivery, df ≈ 1.0, so quality ≈ 255 * df = 255 (unidirectional fallback)
        XCTAssertGreaterThan(quality, 200, "Perfect delivery should yield high quality.")
    }

    func testDuplicatesIndicateRetries() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_500)
        testClock = now

        // Simulate some retries by marking packets as duplicates
        for offset in 0..<10 {
            let ts = now.addingTimeInterval(Double(offset))
            testClock = ts
            let packet = makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts)
            estimator.observePacket(packet, timestamp: ts, isDuplicate: offset % 3 == 0)
        }

        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        // With duplicates (retries), quality should be lower than perfect
        XCTAssertGreaterThan(quality, 0)
        XCTAssertLessThan(quality, 255)
    }

    func testETXMappingSanity_WhenDeliveryRatiosKnown() {
        // Test the ETX formula: quality ≈ round(255 * df * dr)
        // When df and dr are explicitly set by synthetic evidence
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_020_000)
        testClock = now

        // Simulate df ≈ 0.8 (80% delivery) by having 20% duplicates
        // In unidirectional mode (no ACK), dr is assumed 1.0
        // Expected: quality ≈ 255 * 0.8 * 1.0 = 204

        // Send 100 packets, 20 marked as duplicates (indicating retries needed)
        for i in 0..<100 {
            let ts = now.addingTimeInterval(Double(i) * 0.2)
            testClock = ts
            let isDup = i % 5 == 0 // 20% duplicates
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }

        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")

        // dfEstimate should be approximately 0.8 (80% unique = successful first transmission)
        if let df = stats.dfEstimate {
            XCTAssertGreaterThan(df, 0.7, "df should be around 0.8 with 20% duplicates")
            XCTAssertLessThan(df, 0.9, "df should be around 0.8 with 20% duplicates")
        }

        // Quality should be in the range of 255 * 0.8 = 204 (with EWMA smoothing)
        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThan(quality, 150, "Quality with 80% delivery should be reasonable")
        XCTAssertLessThanOrEqual(quality, 255)
    }

    // MARK: - Duplicate Burst Implies Lower Quality (CRITICAL TEST)

    func testDuplicateBurstImpliesLowerQuality() {
        // Build two synthetic streams A→B:
        // (a) clean: unique packets spaced out
        // (b) retry-ish: many duplicates within a short window
        // Assert quality(A,B) for (b) < (a), with a meaningful gap.

        let now = Date(timeIntervalSince1970: 1_700_030_000)

        // (a) Clean stream - no duplicates
        var cleanEstimator = makeEstimator()
        testClock = now
        for i in 0..<50 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            cleanEstimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }
        let cleanQuality = cleanEstimator.linkQuality(from: "W0ABC", to: "N0CALL")

        // (b) Retry-ish stream - 50% duplicates
        var retryEstimator = makeEstimator()
        testClock = now
        for i in 0..<50 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            let isDup = i % 2 == 0 // 50% duplicates
            retryEstimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }
        let retryQuality = retryEstimator.linkQuality(from: "W0ABC", to: "N0CALL")

        // The retry-ish stream should have MEANINGFULLY lower quality
        XCTAssertLessThan(retryQuality, cleanQuality, "Duplicate-heavy stream should have lower quality than clean stream")
        XCTAssertGreaterThan(cleanQuality - retryQuality, 30, "Quality gap should be meaningful (>30 points)")
    }

    // MARK: - EWMA Smoothing (CRITICAL)

    func testEWMASmoothingPreventsSpikes() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_600)
        testClock = now

        // Build up good quality
        for offset in 0..<20 {
            let ts = now.addingTimeInterval(Double(offset))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let stableQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

        // Simulate a burst of duplicates (bad link)
        for offset in 20..<25 {
            let ts = now.addingTimeInterval(Double(offset))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: true)
        }

        let afterBurstQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        // EWMA should smooth the drop, not crash immediately
        XCTAssertGreaterThan(afterBurstQuality, stableQuality / 2, "EWMA should prevent drastic quality drops.")
    }

    func testEWMARecoveryAfterBadBurst() {
        // A bad burst should reduce quality but then recover gradually when clean traffic resumes.
        // Assert it does not instantly jump back to max after a few clean packets (prove smoothing).

        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_040_000)
        testClock = now

        // Build up good quality with clean packets
        for i in 0..<30 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }
        let goodQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

        // Inject a bad burst (100% duplicates)
        for i in 30..<45 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: true)
        }
        let afterBadBurstQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertLessThan(afterBadBurstQuality, goodQuality, "Quality should drop after bad burst")

        // Send just 3 clean packets
        for i in 45..<48 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }
        let partialRecoveryQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

        // Quality should have improved but NOT jumped back to max
        XCTAssertGreaterThan(partialRecoveryQuality, afterBadBurstQuality, "Quality should improve with clean traffic")
        XCTAssertLessThan(partialRecoveryQuality, goodQuality, "Quality should NOT instantly return to max (EWMA smoothing)")

        // Continue clean traffic to approach full recovery
        for i in 48..<70 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }
        let fullRecoveryQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

        // Should be close to original good quality now
        XCTAssertGreaterThan(fullRecoveryQuality, goodQuality - 30, "Should approach full recovery after sustained clean traffic")
    }

    // MARK: - Sliding Window

    func testOldObservationsExpire() {
        let config = LinkQualityConfig(
            slidingWindowSeconds: 60,
            ewmaAlpha: 0.25,
            initialDeliveryRatio: 0.5,
            maxObservationsPerLink: 100
        )
        var estimator = makeEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_002_700)
        testClock = start

        // Old observations
        for offset in 0..<5 {
            let ts = start.addingTimeInterval(Double(offset))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let earlyQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThan(earlyQuality, 0)

        // Purge old data
        let later = start.addingTimeInterval(config.slidingWindowSeconds + 10)
        testClock = later
        estimator.purgeStaleData(currentDate: later)

        let afterPurgeQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertEqual(afterPurgeQuality, 0, "Old observations should expire after window.")
    }

    // MARK: - Determinism (CRITICAL)

    func testDeterministicOutput() {
        func runEstimation() -> Int {
            testClock = Date(timeIntervalSince1970: 1_700_002_800)
            var estimator = makeEstimator()
            let start = Date(timeIntervalSince1970: 1_700_002_800)
            for offset in 0..<10 {
                let ts = start.addingTimeInterval(Double(offset))
                testClock = ts
                estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
            }
            return estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        }

        let first = runEstimation()
        let second = runEstimation()
        XCTAssertEqual(first, second, "Same inputs must produce same outputs.")
    }

    func testDeterministicLinkStats() {
        // Feed the same packet list twice -> identical LinkStats + quality outputs.

        func runAndGetStats() -> (LinkStats, Int) {
            testClock = Date(timeIntervalSince1970: 1_700_050_000)
            var estimator = makeEstimator()
            let now = Date(timeIntervalSince1970: 1_700_050_000)

            for i in 0..<25 {
                let ts = now.addingTimeInterval(Double(i) * 0.5)
                testClock = ts
                let isDup = i % 4 == 0 // 25% duplicates
                estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
            }

            let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")
            let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
            return (stats, quality)
        }

        let (stats1, quality1) = runAndGetStats()
        let (stats2, quality2) = runAndGetStats()

        XCTAssertEqual(quality1, quality2, "Quality must be deterministic")
        XCTAssertEqual(stats1.observationCount, stats2.observationCount, "Observation count must be deterministic")
        XCTAssertEqual(stats1.duplicateCount, stats2.duplicateCount, "Duplicate count must be deterministic")
        XCTAssertEqual(stats1.ewmaQuality, stats2.ewmaQuality, "EWMA quality must be deterministic")
    }

    // MARK: - Quality Clamping

    func testQualityClampedTo0To255() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_900)
        testClock = now

        // Many packets to maximize quality
        for offset in 0..<100 {
            let ts = now.addingTimeInterval(Double(offset) * 0.1)
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThanOrEqual(quality, 0)
        XCTAssertLessThanOrEqual(quality, 255)
    }

    // MARK: - LinkStats API

    func testLinkStatsExposesRequiredFields() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_060_000)
        testClock = now

        // Send 20 packets, 5 duplicates
        for i in 0..<20 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            let isDup = i < 5 // First 5 are duplicates
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }

        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")

        // Verify LinkStats exposes required fields
        XCTAssertEqual(stats.observationCount, 20, "Should track total observation count")
        XCTAssertEqual(stats.duplicateCount, 5, "Should track duplicate/retry proxy count")
        XCTAssertGreaterThan(stats.ewmaQuality, 0, "Should have EWMA quality")
        XCTAssertLessThanOrEqual(stats.ewmaQuality, 255)
        XCTAssertNotNil(stats.lastUpdate, "Should have lastUpdate timestamp")

        // dfEstimate should be present (forward delivery probability)
        if let df = stats.dfEstimate {
            XCTAssertGreaterThan(df, 0.0)
            XCTAssertLessThanOrEqual(df, 1.0)
            // With 5 duplicates out of 20, df should be around 0.75
            XCTAssertGreaterThan(df, 0.5, "df should reflect ~75% unique packets")
        }
    }

    func testLinkStatsForUnknownLinkReturnsEmptyStats() {
        let estimator = makeEstimator()

        let stats = estimator.linkStats(from: "UNKNOWN1", to: "UNKNOWN2")

        XCTAssertEqual(stats.observationCount, 0)
        XCTAssertEqual(stats.duplicateCount, 0)
        XCTAssertEqual(stats.ewmaQuality, 0)
        XCTAssertNil(stats.dfEstimate)
        XCTAssertNil(stats.drEstimate)
    }

    // MARK: - Symmetric Link Quality (Optional)

    func testSymmetricLinkQualityOnlyWhenBothDirectionsHaveEvidence() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_070_000)
        testClock = now

        // Only A→B traffic
        for i in 0..<10 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        // Symmetric quality should be nil (or 0) when only one direction has data
        let symmetricWithOneDir = estimator.symmetricLinkQuality(a: "W0ABC", b: "N0CALL")
        XCTAssertNil(symmetricWithOneDir, "Symmetric quality should be nil with only one direction of evidence")

        // Now add B→A traffic
        for i in 10..<20 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "N0CALL", to: "W0ABC", timestamp: ts), timestamp: ts)
        }

        // Now symmetric quality should be present
        let symmetricWithBothDir = estimator.symmetricLinkQuality(a: "W0ABC", b: "N0CALL")
        XCTAssertNotNil(symmetricWithBothDir, "Symmetric quality should exist with both directions")
        if let sym = symmetricWithBothDir {
            XCTAssertGreaterThan(sym, 0)
            XCTAssertLessThanOrEqual(sym, 255)
        }
    }

    // MARK: - Bounded Ring Buffer

    func testBoundedObservationStorage() {
        let config = LinkQualityConfig(
            slidingWindowSeconds: 3600,
            ewmaAlpha: 0.25,
            initialDeliveryRatio: 0.5,
            maxObservationsPerLink: 50 // Bounded to 50
        )
        var estimator = makeEstimator(config: config)
        let now = Date(timeIntervalSince1970: 1_700_080_000)
        testClock = now

        // Send 100 packets (exceeds bound)
        for i in 0..<100 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")

        // Observations should be bounded (ring buffer behavior)
        XCTAssertLessThanOrEqual(stats.observationCount, 50, "Observation count should be bounded by maxObservationsPerLink")
    }

    // MARK: - Integration with Neighbor Quality

    func testLinkQualityCanFeedNeighborPathQuality() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_003_000)
        testClock = now

        for offset in 0..<10 {
            let ts = now.addingTimeInterval(Double(offset))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let linkQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThan(linkQuality, 0, "Link quality should be usable for neighbor path quality.")
    }

    // MARK: - Export/Import Persistence Support

    func testExportLinkStatsForPersistence() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_090_000)
        testClock = now

        // Build up link stats
        for i in 0..<15 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }
        for i in 15..<25 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W1XYZ", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: i % 3 == 0)
        }

        let exported = estimator.exportLinkStats()

        // Should export both links, sorted by fromCall, then toCall
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(exported[0].fromCall, "W0ABC")
        XCTAssertEqual(exported[1].fromCall, "W1XYZ")

        // Each record should have quality preserved
        XCTAssertGreaterThan(exported[0].quality, 0)
        XCTAssertGreaterThan(exported[1].quality, 0)
    }

    func testImportLinkStatsRestoresState() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        testClock = now

        let recordsToImport = [
            LinkStatRecord(fromCall: "W0ABC", toCall: "N0CALL", quality: 200, lastUpdated: now, dfEstimate: 0.9, drEstimate: nil, duplicateCount: 2, observationCount: 20),
            LinkStatRecord(fromCall: "W1XYZ", toCall: "N0CALL", quality: 150, lastUpdated: now, dfEstimate: 0.7, drEstimate: nil, duplicateCount: 6, observationCount: 20)
        ]

        estimator.importLinkStats(recordsToImport)

        // Verify imported quality
        XCTAssertEqual(estimator.linkQuality(from: "W0ABC", to: "N0CALL"), 200)
        XCTAssertEqual(estimator.linkQuality(from: "W1XYZ", to: "N0CALL"), 150)
    }

    // MARK: - ETX Formula Verification (CRITICAL TDD TESTS)

    func testETXFormulaMapping_PerfectDelivery() {
        // Given: df = 1.0, dr = 1.0 (assumed for unidirectional)
        // ETX = 1 / (df * dr) = 1
        // Quality = 255 / ETX = 255

        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_110_000)
        testClock = now

        // 100% successful transmissions (no duplicates)
        for i in 0..<50 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0PFT", to: "N0CAL", timestamp: ts), timestamp: ts, isDuplicate: false)
        }

        let quality = estimator.linkQuality(from: "W0PFT", to: "N0CAL")

        // With perfect delivery (df ≈ 1.0), quality should approach 255
        XCTAssertGreaterThan(quality, 230, "Perfect delivery should yield quality > 230")
        XCTAssertLessThanOrEqual(quality, 255, "Quality should not exceed 255")
    }

    func testETXFormulaMapping_50PercentDelivery() {
        // Given: df ≈ 0.5 (50% duplicates indicate 50% first-transmission success)
        // Quality ≈ 255 * 0.5 = 127

        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_120_000)
        testClock = now

        // 50% duplicates
        for i in 0..<100 {
            let ts = now.addingTimeInterval(Double(i) * 0.2)
            testClock = ts
            let isDup = i % 2 == 0  // 50% duplicates
            estimator.observePacket(makePacket(from: "W0HALF", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }

        let quality = estimator.linkQuality(from: "W0HALF", to: "N0CALL")
        let stats = estimator.linkStats(from: "W0HALF", to: "N0CALL")

        // dfEstimate should be approximately 0.5
        if let df = stats.dfEstimate {
            XCTAssertEqual(df, 0.5, accuracy: 0.1, "df should be approximately 0.5 with 50% duplicates")
        }

        // Due to EWMA smoothing from initial value, the quality may not be exactly 127
        // but should be in the range of 100-170
        XCTAssertGreaterThan(quality, 80, "Quality with 50% delivery should be > 80")
        XCTAssertLessThan(quality, 180, "Quality with 50% delivery should be < 180")
    }

    func testETXFormulaMapping_HighDuplicates() {
        // Given: heavy duplicates (df ≈ 0.2)
        // Quality ≈ 255 * 0.2 = 51

        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_130_000)
        testClock = now

        // 80% duplicates (20% success rate)
        for i in 0..<100 {
            let ts = now.addingTimeInterval(Double(i) * 0.2)
            testClock = ts
            let isDup = i % 5 != 0  // 80% duplicates
            estimator.observePacket(makePacket(from: "W0LOW", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }

        let quality = estimator.linkQuality(from: "W0LOW", to: "N0CALL")

        // Should be low but non-zero
        XCTAssertLessThan(quality, 100, "Quality with 20% delivery should be < 100")
        XCTAssertGreaterThan(quality, 0, "Quality should not be zero with some successful transmissions")
    }

    // MARK: - Unidirectional Fallback (CRITICAL)

    func testUnidirectionalFallback_NoReverseEvidence() {
        // Feed only A→B packets (no reverse evidence).
        // ASSERT that linkQuality(A,B) > 0
        // ASSERT that linkQuality(B,A) is 0 (no data)
        // ASSERT that drop of reverse evidence does not crash

        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_140_000)
        testClock = now

        // Only A→B packets
        for i in 0..<30 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let forwardQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        let reverseQuality = estimator.linkQuality(from: "N0CALL", to: "W0ABC")

        XCTAssertGreaterThan(forwardQuality, 0, "Forward direction should have quality")
        XCTAssertEqual(reverseQuality, 0, "Reverse direction should have no quality without evidence")

        // Verify no crash when querying stats for non-existent direction
        let reverseStats = estimator.linkStats(from: "N0CALL", to: "W0ABC")
        XCTAssertEqual(reverseStats.observationCount, 0, "No observations in reverse direction")
        XCTAssertNil(reverseStats.dfEstimate, "No df estimate for reverse direction")
    }

    func testUnidirectionalFallback_AsymmetricLinks() {
        // Real radio links can be asymmetric - A can hear B but B cannot hear A
        // This is common with different antenna heights, power levels, or terrain

        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_150_000)
        testClock = now

        // Strong A→B link (high power station to low power)
        for i in 0..<30 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            estimator.observePacket(makePacket(from: "W0HIGH", to: "K1LOW", timestamp: ts), timestamp: ts, isDuplicate: false)
        }

        // Weak B→A link (low power station has many retries)
        for i in 30..<60 {
            let ts = now.addingTimeInterval(Double(i))
            testClock = ts
            let isDup = i % 3 == 0  // 33% duplicates
            estimator.observePacket(makePacket(from: "K1LOW", to: "W0HIGH", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }

        let highToLowQuality = estimator.linkQuality(from: "W0HIGH", to: "K1LOW")
        let lowToHighQuality = estimator.linkQuality(from: "K1LOW", to: "W0HIGH")

        // Links should be asymmetric
        XCTAssertGreaterThan(highToLowQuality, lowToHighQuality, "High-power to low-power should be better quality")
        XCTAssertGreaterThan(highToLowQuality, 200, "Strong link should have high quality")
        XCTAssertLessThan(lowToHighQuality, highToLowQuality - 30, "Weak link should be noticeably worse")
    }

    // MARK: - EWMA with Fake Clock (CRITICAL)

    func testEWMASmoothingWithFakeClock_Deterministic() {
        // Simulate an initial stream of clean packets → record quality.
        // Introduce a short burst of degraded/duplicate packets → ASSERT quality drops moderately.
        // After resumption of clean packets → ASSERT quality recovers gradually.
        // ASSERT that behavior is reproducible with a fake clock.

        func runWithFakeClock() -> (beforeBurst: Int, afterBurst: Int, afterRecovery: Int) {
            testClock = Date(timeIntervalSince1970: 1_700_160_000)
            var estimator = makeEstimator()
            let start = Date(timeIntervalSince1970: 1_700_160_000)

            // Phase 1: Clean packets (establish baseline)
            for i in 0..<30 {
                let ts = start.addingTimeInterval(Double(i))
                testClock = ts
                estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
            }
            let beforeBurst = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

            // Phase 2: Bad burst (heavy duplicates)
            for i in 30..<45 {
                let ts = start.addingTimeInterval(Double(i))
                testClock = ts
                estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: true)
            }
            let afterBurst = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

            // Phase 3: Recovery (clean packets)
            for i in 45..<80 {
                let ts = start.addingTimeInterval(Double(i))
                testClock = ts
                estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: false)
            }
            let afterRecovery = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

            return (beforeBurst, afterBurst, afterRecovery)
        }

        let run1 = runWithFakeClock()
        let run2 = runWithFakeClock()

        // Verify determinism
        XCTAssertEqual(run1.beforeBurst, run2.beforeBurst, "Before burst should be identical")
        XCTAssertEqual(run1.afterBurst, run2.afterBurst, "After burst should be identical")
        XCTAssertEqual(run1.afterRecovery, run2.afterRecovery, "After recovery should be identical")

        // Verify behavior
        XCTAssertLessThan(run1.afterBurst, run1.beforeBurst, "Quality should drop after burst")
        XCTAssertGreaterThan(run1.afterRecovery, run1.afterBurst, "Quality should recover after clean traffic")
        XCTAssertGreaterThan(run1.afterRecovery, run1.beforeBurst - 30, "Should approach full recovery")
    }

    // MARK: - Duplicate Stream Comparison (CRITICAL)

    func testDuplicateStreamComparison_MeaningfulQualityGap() {
        // Create two streams:
        // - Stream 1: mostly unique packets
        // - Stream 2: heavy duplicates in short window
        // ASSERT that quality(Stream2) < quality(Stream1) with meaningful gap (>30 points)

        let now = Date(timeIntervalSince1970: 1_700_170_000)

        // Stream 1: Clean (5% duplicates)
        var cleanEstimator = makeEstimator()
        testClock = now
        for i in 0..<100 {
            let ts = now.addingTimeInterval(Double(i) * 0.2)
            testClock = ts
            let isDup = i % 20 == 0  // 5% duplicates
            cleanEstimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }
        let cleanQuality = cleanEstimator.linkQuality(from: "W0ABC", to: "N0CALL")

        // Stream 2: Heavy duplicates (60%)
        var heavyDupEstimator = makeEstimator()
        testClock = now
        for i in 0..<100 {
            let ts = now.addingTimeInterval(Double(i) * 0.2)
            testClock = ts
            let isDup = i % 5 != 0  // 60% duplicates
            heavyDupEstimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
        }
        let heavyDupQuality = heavyDupEstimator.linkQuality(from: "W0ABC", to: "N0CALL")

        // Verify meaningful gap
        XCTAssertLessThan(heavyDupQuality, cleanQuality, "Heavy duplicate stream should have lower quality")
        XCTAssertGreaterThan(cleanQuality - heavyDupQuality, 30, "Quality gap should be meaningful (>30 points)")
    }

    // MARK: - Full Determinism Verification

    func testFullDeterminism_ComplexScenario() {
        // Feed the exact same input twice (same timestamps, same duplicates).
        // ASSERT that linkQuality outputs are identical.
        // Also verify LinkStats are identical.

        func runComplexScenario() -> (quality: Int, stats: LinkStats) {
            testClock = Date(timeIntervalSince1970: 1_700_180_000)
            var estimator = makeEstimator()
            let start = Date(timeIntervalSince1970: 1_700_180_000)

            // Mix of clean and duplicate packets
            for i in 0..<50 {
                let ts = start.addingTimeInterval(Double(i) * 0.5)
                testClock = ts
                // Pattern: clean, clean, dup, clean, dup
                let isDup = i % 5 == 2 || i % 5 == 4
                estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: isDup)
            }

            // Add some packets to a second link
            for i in 50..<70 {
                let ts = start.addingTimeInterval(Double(i) * 0.5)
                testClock = ts
                estimator.observePacket(makePacket(from: "W1XYZ", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: i % 3 == 0)
            }

            let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
            let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")

            return (quality, stats)
        }

        let run1 = runComplexScenario()
        let run2 = runComplexScenario()

        XCTAssertEqual(run1.quality, run2.quality, "Quality must be identical for identical inputs")
        XCTAssertEqual(run1.stats.observationCount, run2.stats.observationCount, "Observation count must match")
        XCTAssertEqual(run1.stats.duplicateCount, run2.stats.duplicateCount, "Duplicate count must match")
        XCTAssertEqual(run1.stats.ewmaQuality, run2.stats.ewmaQuality, "EWMA quality must match")

        if let df1 = run1.stats.dfEstimate, let df2 = run2.stats.dfEstimate {
            XCTAssertEqual(df1, df2, accuracy: 0.0001, "dfEstimate must be identical")
        } else {
            XCTAssertEqual(run1.stats.dfEstimate, run2.stats.dfEstimate, "dfEstimate nil state must match")
        }
    }
}
