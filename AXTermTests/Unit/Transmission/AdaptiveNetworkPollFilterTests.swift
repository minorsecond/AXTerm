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
        df: Double, dr: Double?,
        obs: Int = 10,
        session: Int = 10
    ) -> LinkStatRecord {
        LinkStatRecord(
            fromCall: from,
            toCall: to,
            quality: 200,
            lastUpdated: Date(),
            dfEstimate: df,
            drEstimate: dr,
            duplicateCount: 0,
            observationCount: obs,
            sessionEvidenceCount: session
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

    // MARK: - One-sided evidence (field capture 2026-08-23: a BBS mail
    // transfer filled df on the sender's row and dr on the acker's row —
    // hundreds of frames, zero rows passing a both-directions gate).

    func testDataSenderRowWithUnmeasuredReverseQualifies() {
        let stats: [LinkStatRecord] = [
            // K0NTS-10 pumping I-frames: perfect forward, reverse unmeasured.
            makeStat(from: "K0NTS-10", to: "WN6OTL", df: 1.0, dr: nil, obs: 67),
            // The acking side: no forward evidence — still excluded.
            makeStat(from: "WN6OTL", to: "K0NTS-10", df: 0.04, dr: 0.33, obs: 68),
        ]

        let result = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "KB5YZB-7")
        XCTAssertNotNil(result, "A one-way transfer is real channel evidence")
        XCTAssertEqual(result?.scope, .channelWide)
        // Symmetry prior for the unmeasured reverse: ETX = 1/(1.0 * 1.0)
        XCTAssertEqual(result!.etx, 1.0, accuracy: 0.01)
        XCTAssertLessThan(result!.lossRate, 0.05)
    }

    func testLocalOneSidedRowQualifiesToo() {
        let stats: [LinkStatRecord] = [
            makeStat(from: "KB5YZB-7", to: "N0CALL-1", df: 0.9, dr: nil, obs: 10),
        ]

        let result = ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "KB5YZB-7")
        XCTAssertEqual(result?.scope, .localLinks)
    }

    func testRowsWithoutForwardEvidenceStayExcluded() {
        let stats: [LinkStatRecord] = [
            makeStat(from: "W0ARP-1", to: "N0CALL-2", df: 0.02, dr: 0.5, obs: 20),
        ]
        XCTAssertNil(ContentView.aggregateLinkQualityForAdaptive(stats, localCallsign: "KB5YZB-7"),
                     "Ack-only rows carry no forward-delivery evidence")
    }

    // MARK: - Launch warm-up cadence

    func testSamplerRetriesFastUntilFirstSample() {
        XCTAssertEqual(ContentView.networkSampleDelaySeconds(didSampleEver: false, attempts: 1), 1,
                       "The first sample must not wait behind a 30 s sleep at launch")
        XCTAssertEqual(ContentView.networkSampleDelaySeconds(didSampleEver: false, attempts: 29), 1)
    }

    func testSamplerSettlesToSteadyCadenceAfterFirstSample() {
        XCTAssertEqual(ContentView.networkSampleDelaySeconds(didSampleEver: true, attempts: 2), 30)
    }

    func testWarmupBudgetCapsFastPollingWhenNothingQualifies() {
        XCTAssertEqual(ContentView.networkSampleDelaySeconds(didSampleEver: false, attempts: 30), 30,
                       "A channel with no qualifying evidence must not be polled every second forever")
    }
}


/// The network-inference fallback, split by radio.
///
/// This is the sample that fires when no session is open, and it used to be a
/// single figure computed across every radio and then applied to transmissions
/// on all of them. A station with a clean UHF link and a marginal VHF one got
/// one blended answer that was wrong for both.
final class AdaptiveNetworkPerRadioTests: XCTestCase {

    private let vhf = RadioID(rawValue: "vhf")
    private let uhf = RadioID(rawValue: "uhf")

    private func record(_ from: String, _ to: String, df: Double, radio: RadioID) -> LinkStatRecord {
        LinkStatRecord(fromCall: from, toCall: to, quality: 200, lastUpdated: Date(),
                       dfEstimate: df, drEstimate: df, duplicateCount: 0,
                       observationCount: 50, radioID: radio,
                       sessionEvidenceCount: 50)
    }

    /// Two channels, two answers, and neither is the average of the other.
    func testEachRadioGetsItsOwnFigure() throws {
        let records = [
            record("K0EPI", "W0ARP", df: 0.95, radio: uhf),
            record("K0EPI", "N0CALL", df: 0.95, radio: uhf),
            record("K0EPI", "KB5YZB", df: 0.45, radio: vhf),
            record("K0EPI", "DRLNOD", df: 0.45, radio: vhf),
        ]
        let byRadio = ContentView.aggregateLinkQualityPerRadio(records, localCallsign: "K0EPI")
        XCTAssertEqual(Set(byRadio.keys), [vhf, uhf])

        let clean = try XCTUnwrap(byRadio[uhf])
        let marginal = try XCTUnwrap(byRadio[vhf])
        XCTAssertEqual(clean.lossRate, 0.05, accuracy: 0.02)
        XCTAssertEqual(marginal.lossRate, 0.55, accuracy: 0.02)
        XCTAssertLessThan(clean.etx, marginal.etx)
    }

    /// A radio with too little evidence says nothing rather than guessing —
    /// and crucially does not borrow the other radio's evidence.
    func testARadioWithNoEvidenceIsAbsentRatherThanBorrowing() {
        let records = [
            record("K0EPI", "W0ARP", df: 0.95, radio: uhf),
            LinkStatRecord(fromCall: "K0EPI", toCall: "KB5YZB", quality: 10, lastUpdated: Date(),
                           dfEstimate: 0.45, drEstimate: 0.45, duplicateCount: 0,
                           observationCount: 1, radioID: vhf,
                           sessionEvidenceCount: 1),
        ]
        let byRadio = ContentView.aggregateLinkQualityPerRadio(records, localCallsign: "K0EPI")
        XCTAssertEqual(Set(byRadio.keys), [uhf], "the VHF radio has one observation, not evidence")
    }

    /// The blend this replaced: had the two channels been averaged, the answer
    /// would have been wrong for both. Pinned so nobody reintroduces it.
    func testTheBlendedFigureIsWrongForBothChannels() throws {
        let records = [
            record("K0EPI", "W0ARP", df: 0.95, radio: uhf),
            record("K0EPI", "KB5YZB", df: 0.45, radio: vhf),
        ]
        let blended = try XCTUnwrap(
            ContentView.aggregateLinkQualityForAdaptive(records, localCallsign: "K0EPI"))
        let byRadio = ContentView.aggregateLinkQualityPerRadio(records, localCallsign: "K0EPI")
        let clean = try XCTUnwrap(byRadio[uhf])
        let marginal = try XCTUnwrap(byRadio[vhf])
        XCTAssertGreaterThan(blended.lossRate, clean.lossRate + 0.1,
                             "the blend libels the good channel")
        XCTAssertLessThan(blended.lossRate, marginal.lossRate - 0.1,
                          "and flatters the bad one")
    }
}
