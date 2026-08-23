//
//  AdaptiveNetworkPollFilterTests.swift
//  AXTermTests
//
//  Tests for network poll link quality aggregation filtering by local callsign.
//

import XCTest
@testable import AXTerm

@MainActor
final class AdaptiveNetworkPollFilterTests: XCTestCase {

    // MARK: - Helpers

    private func makeStat(
        from: String, to: String,
        df: Double, dr: Double,
        obs: Int = 10
    ) -> LinkStatRecord {
        LinkStatRecord(
            fromCall: from,
            toCall: to,
            quality: 200,
            lastUpdated: Date(),
            dfEstimate: df,
            drEstimate: dr,
            duplicateCount: 0,
            observationCount: obs
        )
    }

    // MARK: - Tests

    /// Local station link (good) should not be polluted by other stations' poor links.
    func testAggregateFiltersByLocalCallsign() {
        let stats: [LinkStatRecord] = [
            // Our good link
            makeStat(from: "KB5YZB-7", to: "N0CALL-1", df: 0.99, dr: 0.98),
            // Someone else's poor link (should be excluded when filtering)
            makeStat(from: "W0ARP-1", to: "N0CALL-2", df: 0.20, dr: 0.15),
        ]

        // Without filter: aggregate includes the poor link
        let unfiltered = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: nil)
        XCTAssertNotNil(unfiltered)

        // With filter: only our link
        let filtered = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "KB5YZB-7")
        XCTAssertNotNil(filtered)
        // Our link has df=0.99, so loss rate should be very low
        XCTAssertLessThan(filtered!.lossRate, 0.05, "Filtered result should reflect only our good link")
        XCTAssertLessThan(filtered!.etx, 1.1, "ETX should be close to 1.0 for our good link")
    }

    /// Nil local callsign should use all stats (backward-compatible fallback).
    func testAggregateWithNilLocalCallsignUsesAllStats() {
        let stats: [LinkStatRecord] = [
            makeStat(from: "KB5YZB-7", to: "N0CALL-1", df: 0.99, dr: 0.98),
            makeStat(from: "W0ARP-1", to: "N0CALL-2", df: 0.50, dr: 0.50),
        ]

        let result = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: nil)
        XCTAssertNotNil(result, "Should aggregate all links when no local callsign specified")
    }

    /// A passive-monitoring station (no links of its own yet) must not starve:
    /// with zero usable local evidence, channel-wide traffic is the fallback.
    func testAggregateFallsBackToChannelWideWhenNoLocalLinks() {
        let stats: [LinkStatRecord] = [
            makeStat(from: "W0ARP-1", to: "N0CALL-2", df: 0.50, dr: 0.50),
            makeStat(from: "W1ABC-3", to: "N0CALL-2", df: 0.80, dr: 0.75),
        ]

        let result = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "KB5YZB-7")
        XCTAssertNotNil(result, "Channel-wide traffic is evidence about shared channel conditions")
        XCTAssertEqual(result?.scope, .channelWide)
    }

    /// Local links that exist but fail the evidence gates (the df=0 poisoned-row
    /// case) count as no usable local evidence — fall back, don't starve.
    func testAggregateFallsBackWhenLocalLinksFailGates() {
        let stats: [LinkStatRecord] = [
            makeStat(from: "KB5YZB-7", to: "N0CALL-1", df: 0.0, dr: 0.31, obs: 18),
            makeStat(from: "W0ARP-1", to: "N0CALL-2", df: 0.80, dr: 0.75),
        ]

        let result = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "KB5YZB-7")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.scope, .channelWide)
    }

    /// Usable local evidence always wins over the channel-wide fallback.
    func testAggregatePrefersLocalEvidenceOverChannelWide() {
        let stats: [LinkStatRecord] = [
            makeStat(from: "KB5YZB-7", to: "N0CALL-1", df: 0.99, dr: 0.98),
            makeStat(from: "W0ARP-1", to: "N0CALL-2", df: 0.20, dr: 0.15),
        ]

        let result = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "KB5YZB-7")
        XCTAssertEqual(result?.scope, .localLinks)
        XCTAssertLessThan(result!.lossRate, 0.05, "Third-party loss must not pollute usable local evidence")
    }

    /// When nothing anywhere passes the gates, there is still no sample.
    func testAggregateReturnsNilWhenNothingPassesGates() {
        let stats: [LinkStatRecord] = [
            makeStat(from: "W0ARP-1", to: "N0CALL-2", df: 0.01, dr: 0.50),
            makeStat(from: "W1ABC-3", to: "N0CALL-2", df: 0.80, dr: 0.75, obs: 2),
        ]

        let result = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "KB5YZB-7")
        XCTAssertNil(result)
    }

    /// Callsign normalization: lowercase input should still match.
    func testAggregateNormalizesCallsign() {
        let stats: [LinkStatRecord] = [
            makeStat(from: "KB5YZB-7", to: "N0CALL-1", df: 0.95, dr: 0.93),
        ]

        let result = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "kb5yzb-7")
        XCTAssertNotNil(result, "Lowercase callsign should still match via normalization")
    }
}
