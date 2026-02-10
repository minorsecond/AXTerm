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

    /// When no links involve the local station, should return nil.
    func testAggregateExcludesNonLocalLinks() {
        let stats: [LinkStatRecord] = [
            makeStat(from: "W0ARP-1", to: "N0CALL-2", df: 0.50, dr: 0.50),
            makeStat(from: "W1ABC-3", to: "N0CALL-2", df: 0.80, dr: 0.75),
        ]

        let result = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "KB5YZB-7")
        XCTAssertNil(result, "Should return nil when no local station links exist")
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
