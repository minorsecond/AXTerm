//
//  LearnedRouteRestartTests.swift
//  AXTermTests
//
//  The coordinator keeps what routes learned in a `LearnedRouteStore` and
//  picks it up at the next launch (smoke run 2026-10-03-1, issue 54 and test
//  11.2; spec §7.3, §7.8.1).
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class LearnedRouteRestartTests: XCTestCase {

    private let route = AdaptiveScope.route(radio: .primary, destination: "DRLNOD", path: "")

    override func tearDown() {
        SessionCoordinator.shared = nil
        super.tearDown()
    }

    private func makeStore() throws -> SQLiteLearnedRouteStore {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteLearnedRouteStore(dbQueue: queue)
    }

    private func learn(on coordinator: SessionCoordinator, srtt: Double = 5.0) {
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: srtt,
                                           source: "session", scope: route,
                                           newFrames: 1, retransmits: 0)
    }

    private func config(_ coordinator: SessionCoordinator) -> AX25SessionConfig? {
        coordinator.sessionManager.getConfigForDestination?("DRLNOD", "", .primary)
    }

    func testARelaunchWithinThirtyMinutesStartsWhereTheRouteLeftOff() throws {
        let store = try makeStore()
        let before = SessionCoordinator()
        before.adaptiveTransmissionEnabled = true
        before.attachLearnedRouteStore(store)
        learn(on: before)
        let learnedRto = try XCTUnwrap(config(before)?.learnedPathRto)
        before.flushLearnedRoutes()

        let after = SessionCoordinator()
        after.adaptiveTransmissionEnabled = true
        after.attachLearnedRouteStore(store)
        let restored = config(after)
        XCTAssertEqual(restored?.learnedPathRto ?? -1, learnedRto, accuracy: 0.01)
        XCTAssertEqual(restored?.startSource, .recentEvidence)
    }

    func testAnOlderSnapshotBringsBackOnlyTheRoundTrip() throws {
        let store = try makeStore()
        var settings = TxAdaptiveSettings()
        settings.windowSize.currentAdaptive = 4
        settings.currentRto = 12.0
        try store.save([LearnedRouteSnapshot(scope: route, settings: settings,
                                             at: Date().addingTimeInterval(-2 * 3600))])

        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.attachLearnedRouteStore(store)
        let restored = config(coordinator)
        XCTAssertEqual(restored?.learnedPathRto ?? -1, 12.0, accuracy: 0.01,
                       "a round trip from two hours ago still seeds T1")
        XCTAssertNotEqual(restored?.startSource, .recentEvidence,
                          "K and paclen from two hours ago are not recent evidence")
    }

    func testARoundTripOlderThanAWeekIsNotUsed() throws {
        let store = try makeStore()
        var settings = TxAdaptiveSettings()
        settings.currentRto = 12.0
        try store.save([LearnedRouteSnapshot(scope: route, settings: settings,
                                             at: Date().addingTimeInterval(-8 * 86_400))])
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.attachLearnedRouteStore(store)
        XCTAssertNil(config(coordinator)?.learnedPathRto)
    }

    func testAdaptiveOffIgnoresARememberedRoundTrip() throws {
        let store = try makeStore()
        var settings = TxAdaptiveSettings()
        settings.currentRto = 12.0
        try store.save([LearnedRouteSnapshot(scope: route, settings: settings,
                                             at: Date().addingTimeInterval(-3600))])
        let coordinator = SessionCoordinator()
        coordinator.attachLearnedRouteStore(store)
        coordinator.adaptiveTransmissionEnabled = false
        XCTAssertNil(config(coordinator)?.learnedPathRto)
    }

    func testSamplesAreWrittenInBatchesNotOneByOne() throws {
        let store = try makeStore()
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.attachLearnedRouteStore(store)
        learn(on: coordinator)
        learn(on: coordinator, srtt: 6.0)
        XCTAssertTrue(try store.load(since: .distantPast).isEmpty, "nothing written per sample")
        coordinator.flushLearnedRoutes()
        let rows = try store.load(since: .distantPast)
        XCTAssertEqual(Set(rows.map(\.scope)), Set([route, .radio(.primary)]),
                       "the route and the channel under it, once each")
    }

    func testQuittingWritesWhatIsPending() throws {
        let store = try makeStore()
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.attachLearnedRouteStore(store)
        learn(on: coordinator)
        coordinator.prepareForTermination()
        XCTAssertFalse(try store.load(since: .distantPast).isEmpty)
    }

    func testClearAllLearnedEmptiesTheStore() throws {
        let store = try makeStore()
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.attachLearnedRouteStore(store)
        learn(on: coordinator)
        coordinator.flushLearnedRoutes()
        coordinator.clearAllLearned()
        XCTAssertTrue(try store.load(since: .distantPast).isEmpty)
        XCTAssertNil(config(coordinator)?.learnedPathRto)
    }

    func testAStationResetForgetsItsRoutesAcrossARestart() throws {
        let store = try makeStore()
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.attachLearnedRouteStore(store)
        learn(on: coordinator)
        coordinator.flushLearnedRoutes()
        coordinator.resetStationToDefault(callsign: "DRLNOD")
        XCTAssertTrue(try store.load(since: .distantPast).allSatisfy { $0.scope.route == nil },
                      "the reset itself does not outlive the process, so its routes must not either")
    }

    func testAttachingDoesNotOverwriteSomethingLearnedSince() throws {
        let store = try makeStore()
        var old = TxAdaptiveSettings()
        old.currentRto = 25.0
        try store.save([LearnedRouteSnapshot(scope: route, settings: old,
                                             at: Date().addingTimeInterval(-60))])
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        learn(on: coordinator)
        let live = try XCTUnwrap(config(coordinator)?.learnedPathRto)
        coordinator.attachLearnedRouteStore(store)
        XCTAssertEqual(config(coordinator)?.learnedPathRto ?? -1, live, accuracy: 0.01)
    }
}
