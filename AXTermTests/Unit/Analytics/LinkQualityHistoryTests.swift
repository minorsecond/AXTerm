//
//  LinkQualityHistoryTests.swift
//  AXTermTests
//
//  `link_stats` holds only the current estimate per link, so the app could say
//  what a path is like now and never whether it had changed. A station that
//  degraded over an afternoon looked identical to one that was never good.
//

import XCTest
import GRDB
@testable import AXTerm

final class LinkQualityHistoryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SQLiteLinkQualityHistoryStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteLinkQualityHistoryStore(dbQueue: queue)
    }

    private func stat(_ from: String, _ to: String, quality: Int,
                      df: Double? = nil, dr: Double? = nil,
                      dups: Int = 0) -> LinkStatRecord {
        LinkStatRecord(fromCall: from, toCall: to, quality: quality,
                       lastUpdated: t0, dfEstimate: df, drEstimate: dr,
                       duplicateCount: dups, observationCount: 1)
    }

    // MARK: - Recording

    func testASampleIsStoredAndReadBack() throws {
        let store = try makeStore()
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 68, df: 0.73, dr: 0.37)], at: t0)

        let history = try store.history(from: "K0EPI-7", to: "W0ARP-10",
                                        since: t0.addingTimeInterval(-60))
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].quality, 68)
        XCTAssertEqual(try XCTUnwrap(history[0].dfEstimate), 0.73, accuracy: 0.001)
    }

    func testDirectionIsKeptSeparate() throws {
        let store = try makeStore()
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 68),
                          stat("W0ARP-10", "K0EPI-7", quality: 247)], at: t0)

        // The whole point of the feature is that these two numbers differ.
        let out = try store.history(from: "K0EPI-7", to: "W0ARP-10", since: t0.addingTimeInterval(-60))
        let back = try store.history(from: "W0ARP-10", to: "K0EPI-7", since: t0.addingTimeInterval(-60))
        XCTAssertEqual(out.map(\.quality), [68])
        XCTAssertEqual(back.map(\.quality), [247])
    }

    func testBetweenReturnsBothDirectionsInTimeOrder() throws {
        let store = try makeStore()
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 68)], at: t0)
        try store.record([stat("W0ARP-10", "K0EPI-7", quality: 247)],
                         at: t0.addingTimeInterval(3600))

        let both = try store.history(between: "K0EPI-7", and: "W0ARP-10",
                                     since: t0.addingTimeInterval(-60))
        XCTAssertEqual(both.count, 2)
        XCTAssertLessThan(both[0].sampledAt, both[1].sampledAt)
    }

    // MARK: - Rate limiting

    func testASecondSampleTooSoonIsSkipped() throws {
        let store = try makeStore()
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 68)], at: t0)
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 70)],
                         at: t0.addingTimeInterval(60))

        // A sample a minute is far finer than link quality moves and would
        // make the table thirty times bigger than it needs to be.
        let history = try store.history(from: "K0EPI-7", to: "W0ARP-10",
                                        since: t0.addingTimeInterval(-60))
        XCTAssertEqual(history.count, 1)
    }

    func testASampleAfterTheIntervalIsKept() throws {
        let store = try makeStore()
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 68)], at: t0)
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 70)],
                         at: t0.addingTimeInterval(SQLiteLinkQualityHistoryStore.minimumInterval + 1))

        XCTAssertEqual(try store.history(from: "K0EPI-7", to: "W0ARP-10",
                                         since: t0.addingTimeInterval(-60)).count, 2)
    }

    func testRateLimitingIsPerLinkNotGlobal() throws {
        let store = try makeStore()
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 68)], at: t0)
        // A newly heard station must be recorded at once rather than waiting
        // for a window opened by an unrelated link.
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 70),
                          stat("K0EPI-7", "K0NTS-10", quality: 58)],
                         at: t0.addingTimeInterval(60))

        XCTAssertEqual(try store.history(from: "K0EPI-7", to: "W0ARP-10",
                                         since: t0.addingTimeInterval(-60)).count, 1)
        XCTAssertEqual(try store.history(from: "K0EPI-7", to: "K0NTS-10",
                                         since: t0.addingTimeInterval(-60)).count, 1)
    }

    // MARK: - Pruning and windows

    func testPruningDropsOnlyWhatIsOlderThanTheCutoff() throws {
        let store = try makeStore()
        let old = t0
        let recent = t0.addingTimeInterval(SQLiteLinkQualityHistoryStore.minimumInterval * 2)
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 10)], at: old)
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 20)], at: recent)

        let removed = try store.prune(before: t0.addingTimeInterval(60))

        XCTAssertEqual(removed, 1)
        let left = try store.history(from: "K0EPI-7", to: "W0ARP-10",
                                     since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(left.map(\.quality), [20])
    }

    func testTheSinceWindowExcludesOlderSamples() throws {
        let store = try makeStore()
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 10)], at: t0)
        try store.record([stat("K0EPI-7", "W0ARP-10", quality: 20)],
                         at: t0.addingTimeInterval(SQLiteLinkQualityHistoryStore.minimumInterval * 2))

        let recent = try store.history(from: "K0EPI-7", to: "W0ARP-10",
                                       since: t0.addingTimeInterval(60))
        XCTAssertEqual(recent.map(\.quality), [20])
    }

    func testAnEmptyBatchWritesNothing() throws {
        let store = try makeStore()
        try store.record([], at: t0)
        XCTAssertTrue(try store.history(from: "K0EPI-7", to: "W0ARP-10",
                                        since: Date(timeIntervalSince1970: 0)).isEmpty)
    }

    // MARK: - Trend

    private func samples(_ qualities: [Int]) -> [LinkQualityHistorySample] {
        qualities.enumerated().map { index, quality in
            LinkQualityHistorySample(
                fromCall: "K0EPI-7", toCall: "W0ARP-10",
                sampledAt: t0.addingTimeInterval(Double(index) * 1800),
                quality: quality, dfEstimate: nil, drEstimate: nil, dupCount: 0)
        }
    }

    func testTooFewSamplesGiveNoTrend() {
        // Better to say nothing than to call two readings a direction.
        XCTAssertNil(NodeProfile.trend(samples([100, 40])))
    }

    func testADegradingLinkTrendsDown() {
        let trend = try? XCTUnwrap(NodeProfile.trend(samples([200, 200, 190, 90, 80, 70])))
        XCTAssertNotNil(trend)
        XCTAssertLessThan(trend ?? 0, 0)
    }

    func testAnImprovingLinkTrendsUp() {
        let trend = try? XCTUnwrap(NodeProfile.trend(samples([60, 70, 65, 180, 190, 200])))
        XCTAssertGreaterThan(trend ?? 0, 0)
    }

    func testASteadyLinkBarelyMoves() {
        let trend = try? XCTUnwrap(NodeProfile.trend(samples([120, 118, 122, 119, 121, 120])))
        XCTAssertLessThan(abs(trend ?? 99), 5, "a flat link must not look like a change")
    }

    // MARK: - Direction splitting on the profile

    func testProfileSplitsHistoryByDirection() {
        let out = LinkQualityHistorySample(
            fromCall: "K0EPI-7", toCall: "W0ARP-10", sampledAt: t0,
            quality: 68, dfEstimate: nil, drEstimate: nil, dupCount: 0)
        let back = LinkQualityHistorySample(
            fromCall: "W0ARP-10", toCall: "K0EPI-7", sampledAt: t0,
            quality: 247, dfEstimate: nil, drEstimate: nil, dupCount: 0)
        let profile = NodeProfile.make(
            callsign: "W0ARP-10", localCallsign: "K0EPI-7", linkHistory: [back, out])

        XCTAssertEqual(profile.history(fromUs: true, localCallsign: "K0EPI-7").map(\.quality), [68])
        XCTAssertEqual(profile.history(fromUs: false, localCallsign: "K0EPI-7").map(\.quality), [247])
    }

    func testHistoryIsSortedOldestFirst() {
        let later = LinkQualityHistorySample(
            fromCall: "K0EPI-7", toCall: "W0ARP-10", sampledAt: t0.addingTimeInterval(3600),
            quality: 70, dfEstimate: nil, drEstimate: nil, dupCount: 0)
        let earlier = LinkQualityHistorySample(
            fromCall: "K0EPI-7", toCall: "W0ARP-10", sampledAt: t0,
            quality: 68, dfEstimate: nil, drEstimate: nil, dupCount: 0)
        let profile = NodeProfile.make(callsign: "W0ARP-10", linkHistory: [later, earlier])
        XCTAssertEqual(profile.linkHistory.map(\.quality), [68, 70],
                       "a chart drawn from unsorted samples zig-zags")
    }
}
