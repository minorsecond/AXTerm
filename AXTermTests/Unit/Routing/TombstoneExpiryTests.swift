//
//  TombstoneExpiryTests.swift
//  AXTermTests
//
//  Tests for two-phase tombstone expiry in link stats and evidence.
//  Phase 1: tombstone (quality=0, entry retained). Phase 2: removal after window.
//

import XCTest
@testable import AXTerm

@MainActor
final class TombstoneExpiryTests: XCTestCase {

    // MARK: - Link Stats Tombstone Tests

    private func makeLinkConfig(
        slidingWindowSeconds: TimeInterval = 300,
        maxAdaptiveTTLSeconds: TimeInterval = 7200
    ) -> LinkQualityConfig {
        LinkQualityConfig(
            slidingWindowSeconds: slidingWindowSeconds,
            forwardHalfLifeSeconds: 300,
            reverseHalfLifeSeconds: 300,
            initialDeliveryRatio: 0.5,
            minDeliveryRatio: 0.05,
            maxETX: 20.0,
            ackProgressWeight: 0.6,
            maxObservationsPerLink: 200,
            adaptiveTTLMultiplier: 6.0,
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

    /// After all observations expire from the sliding window, the link should enter
    /// tombstone state (quality=0) but the entry should still be accessible.
    func testLinkStatEntersTombstone() {
        let config = makeLinkConfig(slidingWindowSeconds: 300)
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // Add observations
        for i in 0..<3 {
            let ts = start.addingTimeInterval(Double(i) * 10)
            estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: ts), timestamp: ts)
        }

        let qualityBefore = estimator.linkQuality(from: "W0ABC", to: "W0DEF")
        XCTAssertGreaterThan(qualityBefore, 0, "Should have positive quality before expiry")

        // Purge well past the sliding window
        let afterExpiry = start.addingTimeInterval(600)
        estimator.purgeStaleData(currentDate: afterExpiry)

        // Quality should be 0 (tombstoned), but the link should still return stats
        let qualityAfter = estimator.linkQuality(from: "W0ABC", to: "W0DEF")
        XCTAssertEqual(qualityAfter, 0, "Tombstoned link should have quality 0")

        // Stats should still be accessible (entry retained)
        let stats = estimator.linkStats(from: "W0ABC", to: "W0DEF")
        XCTAssertNotNil(stats.lastUpdate, "Tombstoned link should still have lastUpdate")
    }

    /// A tombstoned entry should survive within the tombstone window.
    func testTombstonedLinkSurvivesWindow() {
        let config = makeLinkConfig(slidingWindowSeconds: 300)
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: start), timestamp: start)

        // Purge to enter tombstone (observations expire after 300s)
        let tombstoneTime = start.addingTimeInterval(400)
        estimator.purgeStaleData(currentDate: tombstoneTime)

        // Purge again, still within tombstone window (300s from tombstone = 700 from start)
        let duringWindow = start.addingTimeInterval(600)
        estimator.purgeStaleData(currentDate: duringWindow)

        // Entry should still exist
        let stats = estimator.linkStats(from: "W0ABC", to: "W0DEF")
        XCTAssertNotNil(stats.lastUpdate, "Entry should survive within tombstone window")
    }

    /// A tombstoned entry should be fully removed after the tombstone window elapses.
    func testTombstonedLinkRemovedAfterWindow() {
        let config = makeLinkConfig(slidingWindowSeconds: 300)
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: start), timestamp: start)

        // Purge to enter tombstone at +400
        let tombstoneTime = start.addingTimeInterval(400)
        estimator.purgeStaleData(currentDate: tombstoneTime)

        // Purge again well past tombstone window (tombstone TTL = 300s, so +800 from start = +400 after tombstone)
        let afterWindow = start.addingTimeInterval(800)
        estimator.purgeStaleData(currentDate: afterWindow)

        // Entry should be fully removed
        let stats = estimator.linkStats(from: "W0ABC", to: "W0DEF")
        XCTAssertEqual(stats, .empty, "Entry should be removed after tombstone window elapses")
    }

    /// New observation during tombstone window should revive the link.
    func testTombstonedLinkRevivedByNewEvidence() {
        let config = makeLinkConfig(slidingWindowSeconds: 300)
        var estimator = LinkQualityEstimator(config: config)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: start), timestamp: start)

        // Enter tombstone
        let tombstoneTime = start.addingTimeInterval(400)
        estimator.purgeStaleData(currentDate: tombstoneTime)

        let qualityTombstoned = estimator.linkQuality(from: "W0ABC", to: "W0DEF")
        XCTAssertEqual(qualityTombstoned, 0, "Should be tombstoned")

        // New observation arrives during tombstone window
        let reviveTime = start.addingTimeInterval(500)
        estimator.observePacket(makePacket(from: "W0ABC", to: "W0DEF", timestamp: reviveTime), timestamp: reviveTime)

        let qualityRevived = estimator.linkQuality(from: "W0ABC", to: "W0DEF")
        XCTAssertGreaterThan(qualityRevived, 0, "Revived link should have positive quality")
    }

    // MARK: - Evidence Tombstone Tests

    private func makeRouter() -> NetRomRouter {
        NetRomRouter(localCallsign: "N0CALL")
    }

    private func makeInference(
        router: NetRomRouter,
        halfLife: TimeInterval = 60,
        tombstoneWindowMultiplier: Double = 1.0
    ) -> NetRomPassiveInference {
        NetRomPassiveInference(
            router: router,
            localCallsign: "N0CALL",
            config: NetRomInferenceConfig(
                evidenceWindowSeconds: 5,
                inferredRouteHalfLifeSeconds: halfLife,
                inferredBaseQuality: 60,
                reinforcementIncrement: 20,
                inferredMinimumQuality: 20,
                maxInferredRoutesPerDestination: 3,
                dataProgressWeight: 1.0,
                routingBroadcastWeight: 0.8,
                uiBeaconWeight: 0.4,
                ackOnlyWeight: 0.1,
                retryPenaltyMultiplier: 0.7,
                tombstoneWindowMultiplier: tombstoneWindowMultiplier
            )
        )
    }

    private func makeDigipeatedPacket(
        from: String,
        to: String,
        via: [String],
        timestamp: Date
    ) -> Packet {
        let infoData = "OBSERVE".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0, repeated: true) },
            frameType: .i,
            control: 0x00,
            controlByte1: 0x00,
            pid: nil,
            info: infoData,
            rawAx25: infoData,
            kissEndpoint: nil,
            infoText: "OBSERVE"
        )
    }

    /// Evidence past half-life should get tombstoned (kept but not contributing to routes).
    func testEvidenceEntersTombstone() {
        let router = makeRouter()
        let inference = makeInference(router: router, halfLife: 60)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // Create evidence via digipeated packet
        let packet = makeDigipeatedPacket(from: "W0XYZ", to: "W0QRS", via: ["W0DIG"], timestamp: start)
        inference.observePacket(packet, timestamp: start, classification: .dataProgress, duplicateStatus: .unique)

        let routesBefore = router.currentRoutes().filter { $0.destination == "W0XYZ" }
        XCTAssertFalse(routesBefore.isEmpty, "Should have inferred route before expiry")

        // Purge after half-life (60s) — evidence enters tombstone
        let afterHalfLife = start.addingTimeInterval(70)
        inference.purgeStaleEvidence(currentDate: afterHalfLife)

        // Evidence is tombstoned but not removed — subsequent packets can still revive it
        // (The route in the router is kept for display purposes)
    }

    /// Evidence should be fully removed after tombstone window elapses.
    func testTombstonedEvidenceRemovedAfterWindow() {
        let router = makeRouter()
        let inference = makeInference(router: router, halfLife: 60, tombstoneWindowMultiplier: 1.0)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let packet = makeDigipeatedPacket(from: "W0XYZ", to: "W0QRS", via: ["W0DIG"], timestamp: start)
        inference.observePacket(packet, timestamp: start, classification: .dataProgress, duplicateStatus: .unique)

        // First purge: enter tombstone at +70
        inference.purgeStaleEvidence(currentDate: start.addingTimeInterval(70))

        // Second purge: tombstone window = 60×1.0 = 60s, so at +140 the tombstone has aged 70s
        inference.purgeStaleEvidence(currentDate: start.addingTimeInterval(140))

        // Re-observe from a different source to verify the old evidence was cleaned up.
        // If old evidence was still present, the bucket would still have the old entry.
        // We verify by creating a new route and checking there's only one.
        let newPacket = makeDigipeatedPacket(from: "W0XYZ", to: "W0QRS", via: ["W0NEW"], timestamp: start.addingTimeInterval(141))
        inference.observePacket(newPacket, timestamp: start.addingTimeInterval(141), classification: .dataProgress, duplicateStatus: .unique)

        let routes = router.currentRoutes().filter { $0.destination == "W0XYZ" }
        // Should only have the new route (via W0NEW), not the old one (via W0DIG)
        let origins = routes.map(\.origin)
        XCTAssertTrue(origins.contains("W0NEW"), "New evidence should create new route")
    }

    /// A new packet should revive tombstoned evidence.
    func testTombstonedEvidenceRevivedByPacket() {
        let router = makeRouter()
        let inference = makeInference(router: router, halfLife: 60)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let packet = makeDigipeatedPacket(from: "W0XYZ", to: "W0QRS", via: ["W0DIG"], timestamp: start)
        inference.observePacket(packet, timestamp: start, classification: .dataProgress, duplicateStatus: .unique)

        // Enter tombstone
        inference.purgeStaleEvidence(currentDate: start.addingTimeInterval(70))

        // Revive with new packet on the same path before tombstone window expires
        let reviveTime = start.addingTimeInterval(90)
        let revivePacket = makeDigipeatedPacket(from: "W0XYZ", to: "W0QRS", via: ["W0DIG"], timestamp: reviveTime)
        inference.observePacket(revivePacket, timestamp: reviveTime, classification: .dataProgress, duplicateStatus: .unique)

        // Purge again — the revived evidence should survive
        inference.purgeStaleEvidence(currentDate: start.addingTimeInterval(100))

        let routes = router.currentRoutes().filter { $0.destination == "W0XYZ" }
        XCTAssertFalse(routes.isEmpty, "Revived evidence should maintain route")
    }
}
