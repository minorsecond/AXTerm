//
//  LearnedRouteMemoryTests.swift
//  AXTermTests
//
//  What a route learned, kept in the database so a restart does not start
//  every route over (smoke run 2026-10-03-1, issue 54; spec §7.3, §7.8.1).
//

import GRDB
import XCTest
@testable import AXTerm

final class LearnedRouteMemoryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let route = AdaptiveScope.route(radio: .primary, destination: "DRLNOD", path: "")
    private let digiRoute = AdaptiveScope.route(radio: .primary, destination: "KB5YZB-7", path: "DRLNOD")
    private let channel = AdaptiveScope.radio(.primary)

    private func learned(window: Int = 3, paclen: Int = 192, rto: Double? = 9.5) -> TxAdaptiveSettings {
        var s = TxAdaptiveSettings()
        s.windowSize.currentAdaptive = window
        s.paclen.currentAdaptive = paclen
        s.lossRateEWMA = 0.12
        s.forwardLossEWMA = 0.08
        s.etxEWMA = 1.4
        s.currentRto = rto
        s.successStreak = 6
        return s
    }

    private func makeStore() throws -> SQLiteLearnedRouteStore {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteLearnedRouteStore(dbQueue: queue)
    }

    // MARK: Snapshot

    func testASnapshotCarriesTheValuesBackIntoFreshSettings() {
        let snap = LearnedRouteSnapshot(scope: route, settings: learned(), at: now)
        let back = snap.applied(to: TxAdaptiveSettings())
        XCTAssertEqual(back.windowSize.currentAdaptive, 3)
        XCTAssertEqual(back.paclen.currentAdaptive, 192)
        XCTAssertEqual(back.lossRateEWMA ?? -1, 0.12, accuracy: 1e-9)
        XCTAssertEqual(back.forwardLossEWMA ?? -1, 0.08, accuracy: 1e-9)
        XCTAssertEqual(back.etxEWMA ?? -1, 1.4, accuracy: 1e-9)
        XCTAssertEqual(back.currentRto ?? -1, 9.5, accuracy: 1e-9)
        XCTAssertEqual(back.successStreak, 6)
        XCTAssertNil(back.probation)
    }

    func testAnUpgradeOnTrialIsSavedAsTheValuesItWouldRollBackTo() {
        var s = learned(window: 2, paclen: 128)
        s.probation = AdaptiveProbation(priorWindow: 2, priorPaclen: 128, framesRemaining: 5)
        s.windowSize.currentAdaptive = 3
        let snap = LearnedRouteSnapshot(scope: route, settings: s, at: now)
        XCTAssertEqual(snap.windowSize, 2, "an unconfirmed trial value never outlives the process")
        XCTAssertEqual(snap.paclen, 128)
    }

    // MARK: Store

    func testTheStoreRoundTripsRoutesAndChannels() throws {
        let store = try makeStore()
        let rows = [
            LearnedRouteSnapshot(scope: route, settings: learned(), at: now),
            LearnedRouteSnapshot(scope: digiRoute, settings: learned(window: 1, paclen: 64, rto: 21), at: now),
            LearnedRouteSnapshot(scope: channel, settings: learned(window: 2, rto: nil), at: now),
        ]
        try store.save(rows)
        let loaded = try store.load(since: now.addingTimeInterval(-60))
        XCTAssertEqual(Set(loaded.map(\.scope)), Set([route, digiRoute, channel]))
        XCTAssertEqual(loaded.first { $0.scope == digiRoute }, rows[1])
        XCTAssertEqual(loaded.first { $0.scope == channel }?.rto, nil)
    }

    func testSavingARouteAgainReplacesIt() throws {
        let store = try makeStore()
        try store.save([LearnedRouteSnapshot(scope: route, settings: learned(window: 1), at: now)])
        try store.save([LearnedRouteSnapshot(scope: route, settings: learned(window: 4),
                                             at: now.addingTimeInterval(10))])
        let loaded = try store.load(since: .distantPast)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.windowSize, 4)
    }

    func testLoadLeavesOutRowsOlderThanAsked() throws {
        let store = try makeStore()
        try store.save([
            LearnedRouteSnapshot(scope: route, settings: learned(), at: now.addingTimeInterval(-8 * 86_400)),
            LearnedRouteSnapshot(scope: digiRoute, settings: learned(), at: now),
        ])
        XCTAssertEqual(try store.load(since: now.addingTimeInterval(-7 * 86_400)).map(\.scope), [digiRoute])
    }

    func testPruneDropsOldRows() throws {
        let store = try makeStore()
        try store.save([
            LearnedRouteSnapshot(scope: route, settings: learned(), at: now.addingTimeInterval(-8 * 86_400)),
            LearnedRouteSnapshot(scope: digiRoute, settings: learned(), at: now),
        ])
        XCTAssertEqual(try store.prune(before: now.addingTimeInterval(-7 * 86_400)), 1)
        XCTAssertEqual(try store.load(since: .distantPast).map(\.scope), [digiRoute])
    }

    func testRemoveDestinationTakesEveryPathAndRadioToIt() throws {
        let store = try makeStore()
        let otherRadio = AdaptiveScope.route(radio: RadioID(rawValue: "radio-2"), destination: "DRLNOD", path: "")
        let viaDigi = AdaptiveScope.route(radio: .primary, destination: "DRLNOD", path: "W0ARP-7")
        try store.save([route, otherRadio, viaDigi, digiRoute, channel].map {
            LearnedRouteSnapshot(scope: $0, settings: learned(), at: now)
        })
        try store.remove(destination: "DRLNOD")
        XCTAssertEqual(Set(try store.load(since: .distantPast).map(\.scope)), Set([digiRoute, channel]))
    }

    func testRemoveAllEmptiesTheTable() throws {
        let store = try makeStore()
        try store.save([LearnedRouteSnapshot(scope: route, settings: learned(), at: now)])
        try store.removeAll()
        XCTAssertTrue(try store.load(since: .distantPast).isEmpty)
    }

    // MARK: What a restart brings back

    func testARestartWithinThirtyMinutesBringsBackTheWholeEntry() {
        let snap = LearnedRouteSnapshot(scope: route, settings: learned(), at: now.addingTimeInterval(-29 * 60))
        let restored = LearnedRouteMemory.restore([snap], now: now)
        XCTAssertEqual(restored.recent[route]?.windowSize.currentAdaptive, 3)
        XCTAssertEqual(restored.recentAt[route], snap.updatedAt,
                       "the entry keeps its own time, so it still expires 30 minutes after it was learned")
    }

    func testAfterThirtyMinutesOnlyTheRoundTripComesBack() {
        let snap = LearnedRouteSnapshot(scope: route, settings: learned(), at: now.addingTimeInterval(-31 * 60))
        let restored = LearnedRouteMemory.restore([snap], now: now)
        XCTAssertNil(restored.recent[route], "K, paclen and loss describe the channel as it was, not as it is")
        XCTAssertEqual(restored.rto[route]?.value ?? -1, 9.5, accuracy: 1e-9)
    }

    func testTheRoundTripIsKeptForSevenDays() {
        let fresh = LearnedRouteSnapshot(scope: route, settings: learned(), at: now.addingTimeInterval(-6.9 * 86_400))
        let stale = LearnedRouteSnapshot(scope: digiRoute, settings: learned(), at: now.addingTimeInterval(-7.1 * 86_400))
        let restored = LearnedRouteMemory.restore([fresh, stale], now: now)
        XCTAssertNotNil(restored.rto[route])
        XCTAssertNil(restored.rto[digiRoute])
        XCTAssertEqual(LearnedRouteMemory.rtoLifetime, 7 * 86_400)
        XCTAssertEqual(LearnedRouteMemory.recentLifetime, 30 * 60)
    }

    func testAChannelNeverSeedsATimer() {
        let snap = LearnedRouteSnapshot(scope: channel, settings: learned(), at: now)
        XCTAssertNil(LearnedRouteMemory.restore([snap], now: now).rto[channel],
                     "a round trip belongs to one route; the channel has none")
    }

    func testARowFromTheFutureIsIgnored() {
        // A clock set back after the row was written.
        let snap = LearnedRouteSnapshot(scope: route, settings: learned(), at: now.addingTimeInterval(3600))
        let restored = LearnedRouteMemory.restore([snap], now: now)
        XCTAssertNil(restored.recent[route])
        XCTAssertNil(restored.rto[route])
    }
}
