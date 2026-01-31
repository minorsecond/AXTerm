//
//  NetRomLinkQualityTests.swift
//  AXTermTests
//
//  Created by Codex on 1/30/26.
//

import XCTest

/// Link quality estimation uses ETX-style metrics to compute directional
/// quality between stations. Quality is derived from observed packet delivery
/// ratios and uses EWMA smoothing for stability.
@testable import AXTerm

final class NetRomLinkQualityTests: XCTestCase {
    private func makeEstimator() -> LinkQualityEstimator {
        LinkQualityEstimator(config: .default)
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
        let packet = makePacket(from: "W0ABC", to: "N0CALL", timestamp: now)

        estimator.observePacket(packet, timestamp: now)

        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThan(quality, 0, "First packet should establish non-zero quality.")
        XCTAssertLessThanOrEqual(quality, 255)
    }

    func testQualityIncreasesWithMorePackets() {
        var estimator = makeEstimator()
        let start = Date(timeIntervalSince1970: 1_700_002_100)

        estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: start), timestamp: start)
        let initialQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

        for offset in 1..<10 {
            let ts = start.addingTimeInterval(Double(offset))
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let finalQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThanOrEqual(finalQuality, initialQuality, "Quality should improve with consistent delivery.")
    }

    // MARK: - Directionality

    func testDirectionalQualityIsIndependent() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_200)

        // Only A→B packets
        for offset in 0..<5 {
            let ts = now.addingTimeInterval(Double(offset))
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let aToBQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        let bToAQuality = estimator.linkQuality(from: "N0CALL", to: "W0ABC")

        XCTAssertGreaterThan(aToBQuality, 0)
        XCTAssertEqual(bToAQuality, 0, "Reverse direction should have no observations.")
    }

    func testBidirectionalQualityRequiresBothDirections() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_300)

        // A→B packets
        for offset in 0..<3 {
            let ts = now.addingTimeInterval(Double(offset))
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        // B→A packets
        for offset in 3..<6 {
            let ts = now.addingTimeInterval(Double(offset))
            estimator.observePacket(makePacket(from: "N0CALL", to: "W0ABC", timestamp: ts), timestamp: ts)
        }

        let aToBQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        let bToAQuality = estimator.linkQuality(from: "N0CALL", to: "W0ABC")

        XCTAssertGreaterThan(aToBQuality, 0)
        XCTAssertGreaterThan(bToAQuality, 0)
    }

    // MARK: - ETX Calculation

    func testETXQualityCalculation() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_400)

        // Simulate perfect delivery (no retries observed)
        for offset in 0..<20 {
            let ts = now.addingTimeInterval(Double(offset) * 2)
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        // With perfect delivery, ETX ≈ 1, quality should be high (close to 255)
        XCTAssertGreaterThan(quality, 200, "Perfect delivery should yield high quality.")
    }

    func testDuplicatesIndicateRetries() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_500)

        // Simulate some retries by marking packets as duplicates
        for offset in 0..<10 {
            let ts = now.addingTimeInterval(Double(offset))
            let packet = makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts)
            estimator.observePacket(packet, timestamp: ts, isDuplicate: offset % 3 == 0)
        }

        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        // With duplicates (retries), quality should be lower than perfect
        XCTAssertGreaterThan(quality, 0)
        XCTAssertLessThan(quality, 255)
    }

    // MARK: - EWMA Smoothing

    func testEWMASmoothingPreventsSpikes() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_600)

        // Build up good quality
        for offset in 0..<20 {
            let ts = now.addingTimeInterval(Double(offset))
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let stableQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

        // Simulate a burst of duplicates (bad link)
        for offset in 20..<25 {
            let ts = now.addingTimeInterval(Double(offset))
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts, isDuplicate: true)
        }

        let afterBurstQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        // EWMA should smooth the drop, not crash immediately
        XCTAssertGreaterThan(afterBurstQuality, stableQuality / 2, "EWMA should prevent drastic quality drops.")
    }

    // MARK: - Sliding Window

    func testOldObservationsExpire() {
        let config = LinkQualityConfig(
            slidingWindowSeconds: 60,
            ewmaAlpha: 0.25,
            initialDeliveryRatio: 0.5
        )
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_002_700)

        // Old observations
        for offset in 0..<5 {
            let ts = start.addingTimeInterval(Double(offset))
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let earlyQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThan(earlyQuality, 0)

        // Purge old data
        let later = start.addingTimeInterval(config.slidingWindowSeconds + 10)
        estimator.purgeStaleData(currentDate: later)

        let afterPurgeQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertEqual(afterPurgeQuality, 0, "Old observations should expire after window.")
    }

    // MARK: - Determinism

    func testDeterministicOutput() {
        func runEstimation() -> Int {
            var estimator = makeEstimator()
            let start = Date(timeIntervalSince1970: 1_700_002_800)
            for offset in 0..<10 {
                let ts = start.addingTimeInterval(Double(offset))
                estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
            }
            return estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        }

        let first = runEstimation()
        let second = runEstimation()
        XCTAssertEqual(first, second, "Same inputs must produce same outputs.")
    }

    // MARK: - Quality Clamping

    func testQualityClampedTo0To255() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_002_900)

        // Many packets to maximize quality
        for offset in 0..<100 {
            let ts = now.addingTimeInterval(Double(offset) * 0.1)
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let quality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThanOrEqual(quality, 0)
        XCTAssertLessThanOrEqual(quality, 255)
    }

    // MARK: - Integration with Neighbor Quality

    func testLinkQualityCanFeedNeighborPathQuality() {
        var estimator = makeEstimator()
        let now = Date(timeIntervalSince1970: 1_700_003_000)

        for offset in 0..<10 {
            let ts = now.addingTimeInterval(Double(offset))
            estimator.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let linkQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThan(linkQuality, 0, "Link quality should be usable for neighbor path quality.")
    }
}
