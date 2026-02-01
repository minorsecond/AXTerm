//
//  LinkQualityControlTests.swift
//  AXTermTests
//
//  Control-aware link quality tests for df/dr/ETX and classification weighting.
//

import XCTest
@testable import AXTerm

final class LinkQualityControlTests: XCTestCase {
    private var testClock: Date = Date(timeIntervalSince1970: 1_700_200_000)

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

    private func makeIFrame(from: String, to: String, ns: UInt8, nr: UInt8, timestamp: Date) -> Packet {
        let control = (ns << 1) & 0x0E
        let controlByte1 = (nr << 5) & 0xE0
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .i,
            control: control,
            controlByte1: controlByte1,
            pid: 0xF0,
            info: Data([0x41, 0x42]),
            rawAx25: Data([0x00])
        )
    }

    private func makeRRFrame(from: String, to: String, nr: UInt8, timestamp: Date) -> Packet {
        let control = UInt8(0x01 | ((nr & 0x07) << 5))
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .s,
            control: control,
            pid: nil,
            info: Data(),
            rawAx25: Data()
        )
    }

    func testGoodLink_DataProgressAndAckEvidenceYieldHighQualityNotPegged() {
        var estimator = makeEstimator()
        let base = Date(timeIntervalSince1970: 1_700_200_100)

        // Forward data (A->B)
        for i in 0..<5 {
            let ts = base.addingTimeInterval(Double(i) * 2)
            testClock = ts
            let packet = makeIFrame(from: "W0ABC", to: "N0CALL", ns: UInt8(i), nr: 0, timestamp: ts)
            estimator.observePacket(packet, timestamp: ts)
        }

        // Reverse ACK progress (B->A)
        for i in 1...5 {
            let ts = base.addingTimeInterval(20 + Double(i))
            testClock = ts
            let packet = makeIFrame(from: "N0CALL", to: "W0ABC", ns: UInt8(i), nr: UInt8(i), timestamp: ts)
            estimator.observePacket(packet, timestamp: ts)
        }

        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")
        XCTAssertNotNil(stats.dfEstimate)
        XCTAssertNotNil(stats.drEstimate)
        if let df = stats.dfEstimate, let dr = stats.drEstimate {
            XCTAssertGreaterThan(df, 0.5)
            XCTAssertGreaterThan(dr, 0.4)
        }
        XCTAssertGreaterThan(stats.ewmaQuality, 120)
        XCTAssertLessThan(stats.ewmaQuality, 255, "Quality should be high but not always pegged unless truly perfect.")
    }

    func testRetryHeavyLinkLowersQuality() {
        var estimator = makeEstimator()
        let base = Date(timeIntervalSince1970: 1_700_200_300)

        for i in 0..<10 {
            let ts = base.addingTimeInterval(Double(i))
            testClock = ts
            let packet = makeIFrame(from: "W0ABC", to: "N0CALL", ns: 1, nr: 0, timestamp: ts)
            let isDup = i % 2 == 0
            estimator.observePacket(packet, timestamp: ts, isDuplicate: isDup)
        }

        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")
        XCTAssertNotNil(stats.dfEstimate)
        XCTAssertGreaterThan(stats.duplicateCount, 0)
        XCTAssertLessThan(stats.ewmaQuality, 200)
    }

    func testMissingDrFallsBackToForwardOnlyETX() {
        var estimator = makeEstimator()
        let base = Date(timeIntervalSince1970: 1_700_200_500)

        for i in 0..<5 {
            let ts = base.addingTimeInterval(Double(i))
            testClock = ts
            let packet = makeIFrame(from: "W0ABC", to: "N0CALL", ns: UInt8(i), nr: 0, timestamp: ts)
            estimator.observePacket(packet, timestamp: ts)
        }

        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")
        XCTAssertNotNil(stats.dfEstimate)
        XCTAssertNil(stats.drEstimate)
        XCTAssertGreaterThan(stats.ewmaQuality, 0)
        XCTAssertLessThan(stats.ewmaQuality, 255)
    }

    func testClassificationWeightsAffectQuality() {
        var estimator = makeEstimator()
        let base = Date(timeIntervalSince1970: 1_700_200_700)

        // DATA frames should produce higher forward estimate than UI beacons.
        for i in 0..<4 {
            let ts = base.addingTimeInterval(Double(i))
            testClock = ts
            let packet = makeIFrame(from: "W0ABC", to: "N0CALL", ns: UInt8(i), nr: 0, timestamp: ts)
            estimator.observePacket(packet, timestamp: ts)
        }
        let dataQuality = estimator.linkQuality(from: "W0ABC", to: "N0CALL")

        var beaconEstimator = makeEstimator()
        for i in 0..<4 {
            let ts = base.addingTimeInterval(Double(i))
            testClock = ts
            let beacon = Packet(
                timestamp: ts,
                from: AX25Address(call: "W0ABC"),
                to: AX25Address(call: "N0CALL"),
                via: [],
                frameType: .ui,
                control: 0x03,
                pid: 0xF0,
                info: Data([0x42]),
                rawAx25: Data([0x00])
            )
            beaconEstimator.observePacket(beacon, timestamp: ts)
        }
        let beaconQuality = beaconEstimator.linkQuality(from: "W0ABC", to: "N0CALL")

        XCTAssertGreaterThan(dataQuality, beaconQuality, "Data progress should influence quality more than UI beacons.")
    }

    func testAsymmetricEvidenceProducesAsymmetricDfDr() {
        var estimator = makeEstimator()
        let base = Date(timeIntervalSince1970: 1_700_200_900)

        for i in 0..<5 {
            let ts = base.addingTimeInterval(Double(i))
            testClock = ts
            let packet = makeIFrame(from: "W0ABC", to: "N0CALL", ns: UInt8(i), nr: 0, timestamp: ts)
            estimator.observePacket(packet, timestamp: ts)
        }

        let stats = estimator.linkStats(from: "W0ABC", to: "N0CALL")
        XCTAssertNotNil(stats.dfEstimate)
        XCTAssertNil(stats.drEstimate)
    }

    func testLinkStatDisplayUsesStoredQuality() {
        let now = Date(timeIntervalSince1970: 1_700_201_100)
        let record = LinkStatRecord(fromCall: "W0ABC", toCall: "N0CALL", quality: 100, lastUpdated: now, dfEstimate: 0.6, drEstimate: nil, duplicateCount: 2, observationCount: 10)
        let display = LinkStatDisplayInfo(from: record, now: now)
        XCTAssertEqual(display.quality, 100)
        XCTAssertGreaterThan(display.qualityPercent, 0)
        XCTAssertLessThan(display.qualityPercent, 100)
    }
}
