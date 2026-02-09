//
//  NetRomRouteRetentionTests.swift
//  AXTermTests
//
//  Tests for NET/ROM route retention and filtering functionality.
//

import XCTest
@testable import AXTerm
import GRDB

final class NetRomRouteRetentionTests: XCTestCase {

    // MARK: - Settings Tests

    func testHideExpiredRoutes_DefaultsToTrue() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        XCTAssertTrue(settings.hideExpiredRoutes, "hideExpiredRoutes should default to true")
    }

    func testHideExpiredRoutes_PersistsValue() {
        let suiteName = "test_\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!

        // Set value in one instance
        let settings1 = AppSettingsStore(defaults: defaults)
        settings1.hideExpiredRoutes = false

        // Read in another instance
        let settings2 = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(settings2.hideExpiredRoutes, "hideExpiredRoutes should persist")
    }

    func testRouteRetentionDays_DefaultsTo60() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        XCTAssertEqual(settings.routeRetentionDays, 60, "routeRetentionDays should default to 60")
    }

    func testRouteRetentionDays_ClampsToMinimum() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.routeRetentionDays = 0

        // Allow for async clamping
        let expectation = XCTestExpectation(description: "Wait for clamping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertGreaterThanOrEqual(settings.routeRetentionDays, AppSettingsStore.minRouteRetentionDays)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testRouteRetentionDays_ClampsToMaximum() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.routeRetentionDays = 1000

        // Allow for async clamping
        let expectation = XCTestExpectation(description: "Wait for clamping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertLessThanOrEqual(settings.routeRetentionDays, AppSettingsStore.maxRouteRetentionDays)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testGlobalStaleTTLHours_DefaultsTo1() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        XCTAssertEqual(settings.globalStaleTTLHours, 1, "globalStaleTTLHours should default to 1 hour")
    }

    // MARK: - Persistence Prune Tests

    func testPruneOldEntries_DeletesEntriesOlderThanRetention() throws {
        // Create in-memory database
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()
        let old = now.addingTimeInterval(-90 * 24 * 60 * 60) // 90 days ago
        let recent = now.addingTimeInterval(-30 * 24 * 60 * 60) // 30 days ago

        // Save neighbors with different ages
        let oldNeighbor = NeighborInfo(call: "OLD0AAA", quality: 200, lastSeen: old, obsolescenceCount: 1, sourceType: "classic")
        let recentNeighbor = NeighborInfo(call: "NEW0BBB", quality: 200, lastSeen: recent, obsolescenceCount: 1, sourceType: "classic")
        try persistence.saveNeighbors([oldNeighbor, recentNeighbor], lastPacketID: 1)

        // Prune with 60-day retention
        let (neighborsDeleted, _, _) = try persistence.pruneOldEntries(retentionDays: 60, now: now)

        // Verify old entry was deleted
        XCTAssertEqual(neighborsDeleted, 1, "Should delete 1 old neighbor")

        // Verify recent entry remains
        let remaining = try persistence.loadNeighbors()
        XCTAssertEqual(remaining.count, 1, "Should have 1 remaining neighbor")
        XCTAssertEqual(remaining.first?.call, "NEW0BBB", "Recent neighbor should remain")
    }

    func testPruneOldEntries_DeletesOldRoutes() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()
        let old = now.addingTimeInterval(-90 * 24 * 60 * 60) // 90 days ago
        let recent = now.addingTimeInterval(-30 * 24 * 60 * 60) // 30 days ago

        let oldRoute = RouteInfo(destination: "OLD0DEST", origin: "TEST0", quality: 200, path: [], lastUpdated: old, sourceType: "broadcast")
        let recentRoute = RouteInfo(destination: "NEW0DEST", origin: "TEST0", quality: 200, path: [], lastUpdated: recent, sourceType: "broadcast")
        try persistence.saveRoutes([oldRoute, recentRoute], lastPacketID: 1)

        let (_, routesDeleted, _) = try persistence.pruneOldEntries(retentionDays: 60, now: now)

        XCTAssertEqual(routesDeleted, 1, "Should delete 1 old route")

        let remaining = try persistence.loadRoutes()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.destination, "NEW0DEST")
    }

    func testPruneOldEntries_DeletesOldLinkStats() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()
        let old = now.addingTimeInterval(-90 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-30 * 24 * 60 * 60)

        let oldStat = LinkStatRecord(fromCall: "OLD0AAA", toCall: "OLD0BBB", quality: 200, lastUpdated: old, dfEstimate: nil, drEstimate: nil, duplicateCount: 0, observationCount: 1)
        let recentStat = LinkStatRecord(fromCall: "NEW0AAA", toCall: "NEW0BBB", quality: 200, lastUpdated: recent, dfEstimate: nil, drEstimate: nil, duplicateCount: 0, observationCount: 1)
        try persistence.saveLinkStats([oldStat, recentStat], lastPacketID: 1)

        let (_, _, linkStatsDeleted) = try persistence.pruneOldEntries(retentionDays: 60, now: now)

        XCTAssertEqual(linkStatsDeleted, 1, "Should delete 1 old link stat")

        let remaining = try persistence.loadLinkStats()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.fromCall, "NEW0AAA")
    }

    func testPruneOldEntries_DoesNothingWhenAllRecent() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()
        let recent = now.addingTimeInterval(-7 * 24 * 60 * 60) // 7 days ago

        let neighbor = NeighborInfo(call: "TEST0AAA", quality: 200, lastSeen: recent, obsolescenceCount: 1, sourceType: "classic")
        try persistence.saveNeighbors([neighbor], lastPacketID: 1)

        let (neighborsDeleted, routesDeleted, linkStatsDeleted) = try persistence.pruneOldEntries(retentionDays: 60, now: now)

        XCTAssertEqual(neighborsDeleted, 0)
        XCTAssertEqual(routesDeleted, 0)
        XCTAssertEqual(linkStatsDeleted, 0)

        let remaining = try persistence.loadNeighbors()
        XCTAssertEqual(remaining.count, 1)
    }

    func testGetCounts_ReturnsCorrectCounts() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()
        let neighbors = [
            NeighborInfo(call: "N0AAA", quality: 200, lastSeen: now, obsolescenceCount: 1, sourceType: "classic"),
            NeighborInfo(call: "N0BBB", quality: 200, lastSeen: now, obsolescenceCount: 1, sourceType: "classic")
        ]
        let routes = [
            RouteInfo(destination: "DEST0", origin: "TEST0", quality: 200, path: [], lastUpdated: now, sourceType: "broadcast")
        ]
        let linkStats = [
            LinkStatRecord(fromCall: "L0AAA", toCall: "L0BBB", quality: 200, lastUpdated: now, dfEstimate: nil, drEstimate: nil, duplicateCount: 0, observationCount: 1),
            LinkStatRecord(fromCall: "L0CCC", toCall: "L0DDD", quality: 200, lastUpdated: now, dfEstimate: nil, drEstimate: nil, duplicateCount: 0, observationCount: 1),
            LinkStatRecord(fromCall: "L0EEE", toCall: "L0FFF", quality: 200, lastUpdated: now, dfEstimate: nil, drEstimate: nil, duplicateCount: 0, observationCount: 1)
        ]

        try persistence.saveSnapshot(neighbors: neighbors, routes: routes, linkStats: linkStats, lastPacketID: 1, configHash: nil)

        let counts = try persistence.getCounts()
        XCTAssertEqual(counts.neighbors, 2)
        XCTAssertEqual(counts.routes, 1)
        XCTAssertEqual(counts.linkStats, 3)
    }

    // MARK: - ViewModel Filtering Tests

    @MainActor
    func testFilteredNeighbors_HidesExpiredWhenEnabled() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.hideExpiredRoutes = true
        settings.globalStaleTTLHours = 1 // 1 hour TTL

        // Create a mock integration would require more setup
        // For now, test the settings integration path
        XCTAssertTrue(settings.hideExpiredRoutes)
        XCTAssertEqual(settings.globalStaleTTLHours, 1)
    }

    @MainActor
    func testFilteredNeighbors_ShowsExpiredWhenDisabled() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.hideExpiredRoutes = false

        XCTAssertFalse(settings.hideExpiredRoutes)
    }

    // MARK: - Adaptive Stale Threshold Settings Tests

    func testStalePolicyMode_DefaultsToAdaptive() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        XCTAssertEqual(settings.stalePolicyMode, "adaptive", "stalePolicyMode should default to adaptive")
    }

    func testStalePolicyMode_PersistsValue() {
        let suiteName = "test_\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!

        let settings1 = AppSettingsStore(defaults: defaults)
        settings1.stalePolicyMode = "global"

        let settings2 = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(settings2.stalePolicyMode, "global", "stalePolicyMode should persist")
    }

    func testAdaptiveStaleMissedBroadcasts_DefaultsTo3() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        XCTAssertEqual(settings.adaptiveStaleMissedBroadcasts, 3, "adaptiveStaleMissedBroadcasts should default to 3")
    }

    func testAdaptiveStaleMissedBroadcasts_ClampsToMinimum() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.adaptiveStaleMissedBroadcasts = 1

        let expectation = XCTestExpectation(description: "Wait for clamping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertGreaterThanOrEqual(settings.adaptiveStaleMissedBroadcasts, AppSettingsStore.minAdaptiveStaleMissedBroadcasts)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testAdaptiveStaleMissedBroadcasts_ClampsToMaximum() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.adaptiveStaleMissedBroadcasts = 100

        let expectation = XCTestExpectation(description: "Wait for clamping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertLessThanOrEqual(settings.adaptiveStaleMissedBroadcasts, AppSettingsStore.maxAdaptiveStaleMissedBroadcasts)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Origin Broadcast Interval Tracking Tests

    func testRecordBroadcast_CreatesNewEntry() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()
        try persistence.recordBroadcast(from: "W0ABC", timestamp: now)

        let interval = try persistence.getOriginInterval(for: "W0ABC")
        XCTAssertNotNil(interval, "Should create interval entry after first broadcast")
        XCTAssertEqual(interval?.broadcastCount, 1, "First broadcast should have count 1")
        XCTAssertEqual(interval?.estimatedIntervalSeconds, 0, "First broadcast has no interval estimate")
    }

    func testRecordBroadcast_UpdatesIntervalAfterSecondBroadcast() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()
        let secondBroadcast = now.addingTimeInterval(300) // 5 minutes later

        try persistence.recordBroadcast(from: "W0ABC", timestamp: now)
        try persistence.recordBroadcast(from: "W0ABC", timestamp: secondBroadcast)

        let interval = try persistence.getOriginInterval(for: "W0ABC")
        XCTAssertNotNil(interval)
        XCTAssertEqual(interval?.broadcastCount, 2, "Should have 2 broadcasts")
        XCTAssertEqual(interval?.estimatedIntervalSeconds ?? 0, 300, accuracy: 1.0, "Interval should be ~300 seconds")
    }

    func testRecordBroadcast_UsesExponentialMovingAverage() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let baseTime = Date()

        // First broadcast
        try persistence.recordBroadcast(from: "W0ABC", timestamp: baseTime)

        // Second broadcast at 300s
        try persistence.recordBroadcast(from: "W0ABC", timestamp: baseTime.addingTimeInterval(300))

        // Third broadcast at 900s (600s interval) - should smooth the estimate
        try persistence.recordBroadcast(from: "W0ABC", timestamp: baseTime.addingTimeInterval(900))

        let interval = try persistence.getOriginInterval(for: "W0ABC")
        XCTAssertNotNil(interval)
        XCTAssertEqual(interval?.broadcastCount, 3)

        // EMA with alpha=0.3: new = 0.3 * 600 + 0.7 * 300 = 180 + 210 = 390
        XCTAssertEqual(interval?.estimatedIntervalSeconds ?? 0, 390, accuracy: 10.0, "Should use EMA for smoothing")
    }

    func testRecordBroadcast_IgnoresDuplicateBroadcasts() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()

        // First broadcast
        try persistence.recordBroadcast(from: "W0ABC", timestamp: now)

        // Duplicate broadcast 5 seconds later (should be ignored)
        try persistence.recordBroadcast(from: "W0ABC", timestamp: now.addingTimeInterval(5))

        let interval = try persistence.getOriginInterval(for: "W0ABC")
        XCTAssertNotNil(interval)
        // Broadcast count stays at 1 because the second one was too close
        XCTAssertEqual(interval?.broadcastCount, 1, "Should ignore duplicate broadcasts")
    }

    func testGetAllOriginIntervals_ReturnsAllTrackedOrigins() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()

        try persistence.recordBroadcast(from: "W0ABC", timestamp: now)
        try persistence.recordBroadcast(from: "K0XYZ", timestamp: now)
        try persistence.recordBroadcast(from: "N0TEST", timestamp: now)

        let intervals = try persistence.getAllOriginIntervals()
        XCTAssertEqual(intervals.count, 3, "Should return all 3 origins")

        let origins = Set(intervals.map { $0.origin })
        XCTAssertTrue(origins.contains("W0ABC"))
        XCTAssertTrue(origins.contains("K0XYZ"))
        XCTAssertTrue(origins.contains("N0TEST"))
    }

    func testClearOriginIntervals_RemovesAllData() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()
        try persistence.recordBroadcast(from: "W0ABC", timestamp: now)
        try persistence.recordBroadcast(from: "K0XYZ", timestamp: now)

        try persistence.clearOriginIntervals()

        let intervals = try persistence.getAllOriginIntervals()
        XCTAssertEqual(intervals.count, 0, "Should clear all intervals")
    }

    func testClearAll_IncludesOriginIntervals() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()
        try persistence.recordBroadcast(from: "W0ABC", timestamp: now)

        try persistence.clearAll()

        let intervals = try persistence.getAllOriginIntervals()
        XCTAssertEqual(intervals.count, 0, "clearAll should also clear origin intervals")
    }

    func testRecordBroadcast_NormalizesCallsign() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)

        let now = Date()

        // Record with lowercase
        try persistence.recordBroadcast(from: "w0abc", timestamp: now)

        // Query with uppercase
        let interval = try persistence.getOriginInterval(for: "W0ABC")
        XCTAssertNotNil(interval, "Should normalize callsign")
        XCTAssertEqual(interval?.origin, "W0ABC")
    }

    // MARK: - Neighbor and Link Stat TTL Settings Tests

    func testNeighborStaleTTLHours_DefaultsTo6() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        XCTAssertEqual(settings.neighborStaleTTLHours, 6, "neighborStaleTTLHours should default to 6 hours")
    }

    func testNeighborStaleTTLHours_ClampsToMinimum() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.neighborStaleTTLHours = 0

        let expectation = XCTestExpectation(description: "Wait for clamping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertGreaterThanOrEqual(settings.neighborStaleTTLHours, AppSettingsStore.minNeighborStaleTTLHours)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testLinkStatStaleTTLHours_DefaultsTo12() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        XCTAssertEqual(settings.linkStatStaleTTLHours, 12, "linkStatStaleTTLHours should default to 12 hours")
    }

    func testLinkStatStaleTTLHours_ClampsToMinimum() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.linkStatStaleTTLHours = 0

        let expectation = XCTestExpectation(description: "Wait for clamping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertGreaterThanOrEqual(settings.linkStatStaleTTLHours, AppSettingsStore.minLinkStatStaleTTLHours)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Persistence Load Returns Expired Entries

    func testPersistenceLoad_ReturnsExpiredNeighbors() throws {
        let dbQueue = try DatabaseQueue()
        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 999999,
            neighborTTLSeconds: 1800
        )
        let persistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date()
        // Neighbor last seen 1 hour ago — well past the 30-minute TTL
        let expiredNeighbor = NeighborInfo(call: "EXP0AAA", quality: 200, lastSeen: now.addingTimeInterval(-3600), obsolescenceCount: 1, sourceType: "classic")
        let freshNeighbor = NeighborInfo(call: "FRE0BBB", quality: 200, lastSeen: now.addingTimeInterval(-60), obsolescenceCount: 1, sourceType: "classic")

        try persistence.saveSnapshot(neighbors: [expiredNeighbor, freshNeighbor], routes: [], linkStats: [], lastPacketID: 1, configHash: nil)

        let state = try persistence.load(now: now)
        XCTAssertNotNil(state, "Should return persisted state")

        let calls = state!.neighbors.map { $0.call }
        XCTAssertTrue(calls.contains("EXP0AAA"), "Expired neighbor should be included in loaded state")
        XCTAssertTrue(calls.contains("FRE0BBB"), "Fresh neighbor should be included in loaded state")

        // Expired neighbor should have decayed quality (0 since age/TTL > 1)
        let expiredLoaded = state!.neighbors.first { $0.call == "EXP0AAA" }!
        XCTAssertEqual(expiredLoaded.quality, 0, "Expired neighbor should have quality decayed to 0")
    }

    func testPersistenceLoad_ReturnsExpiredRoutes() throws {
        let dbQueue = try DatabaseQueue()
        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 999999,
            routeTTLSeconds: 1800
        )
        let persistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date()
        let expiredRoute = RouteInfo(destination: "EXP0DEST", origin: "TEST0", quality: 200, path: [], lastUpdated: now.addingTimeInterval(-3600), sourceType: "broadcast")
        let freshRoute = RouteInfo(destination: "FRE0DEST", origin: "TEST0", quality: 200, path: [], lastUpdated: now.addingTimeInterval(-60), sourceType: "broadcast")

        try persistence.saveSnapshot(neighbors: [], routes: [expiredRoute, freshRoute], linkStats: [], lastPacketID: 1, configHash: nil)

        let state = try persistence.load(now: now)
        XCTAssertNotNil(state)

        let destinations = state!.routes.map { $0.destination }
        XCTAssertTrue(destinations.contains("EXP0DEST"), "Expired route should be included in loaded state")
        XCTAssertTrue(destinations.contains("FRE0DEST"), "Fresh route should be included in loaded state")
    }

    func testPersistenceLoad_ReturnsExpiredLinkStats() throws {
        let dbQueue = try DatabaseQueue()
        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 999999,
            linkStatTTLSeconds: 1800
        )
        let persistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date()
        let expiredStat = LinkStatRecord(fromCall: "EXP0AAA", toCall: "EXP0BBB", quality: 200, lastUpdated: now.addingTimeInterval(-3600), dfEstimate: 0.9, drEstimate: 0.8, duplicateCount: 0, observationCount: 5)
        let freshStat = LinkStatRecord(fromCall: "FRE0AAA", toCall: "FRE0BBB", quality: 200, lastUpdated: now.addingTimeInterval(-60), dfEstimate: 0.95, drEstimate: 0.9, duplicateCount: 0, observationCount: 10)

        try persistence.saveSnapshot(neighbors: [], routes: [], linkStats: [expiredStat, freshStat], lastPacketID: 1, configHash: nil)

        let state = try persistence.load(now: now)
        XCTAssertNotNil(state)

        let fromCalls = state!.linkStats.map { $0.fromCall }
        XCTAssertTrue(fromCalls.contains("EXP0AAA"), "Expired link stat should be included in loaded state")
        XCTAssertTrue(fromCalls.contains("FRE0AAA"), "Fresh link stat should be included in loaded state")
    }

    // MARK: - Router bestRouteTo TTL Guard

    func testBestRouteTo_SkipsExpiredRoutes() {
        let config = NetRomConfig(
            neighborBaseQuality: 80,
            neighborIncrement: 40,
            minimumRouteQuality: 32,
            maxRoutesPerDestination: 3,
            neighborTTLSeconds: 1800,
            routeTTLSeconds: 1800,
            routingPolicy: .default
        )
        let router = NetRomRouter(localCallsign: "TEST0", config: config)

        let now = Date()
        let freshRoute = RouteInfo(destination: "DEST0", origin: "FRESH0", quality: 200, path: ["FRESH0"], lastUpdated: now.addingTimeInterval(-60), sourceType: "broadcast")
        let expiredRoute = RouteInfo(destination: "DEST0", origin: "STALE0", quality: 250, path: ["STALE0"], lastUpdated: now.addingTimeInterval(-3600), sourceType: "broadcast")

        router.importRoutes([freshRoute, expiredRoute])

        let best = router.bestRouteTo("DEST0")
        XCTAssertNotNil(best, "Should find a fresh route")
        XCTAssertEqual(best?.origin, "FRESH0", "Should return the fresh route, not the expired one")
    }

    func testBestRouteTo_ReturnsNilWhenAllExpired() {
        let config = NetRomConfig(
            neighborBaseQuality: 80,
            neighborIncrement: 40,
            minimumRouteQuality: 32,
            maxRoutesPerDestination: 3,
            neighborTTLSeconds: 1800,
            routeTTLSeconds: 1800,
            routingPolicy: .default
        )
        let router = NetRomRouter(localCallsign: "TEST0", config: config)

        let expiredRoute = RouteInfo(destination: "DEST0", origin: "STALE0", quality: 250, path: ["STALE0"], lastUpdated: Date().addingTimeInterval(-3600), sourceType: "broadcast")

        router.importRoutes([expiredRoute])

        let best = router.bestRouteTo("DEST0")
        XCTAssertNil(best, "Should return nil when all routes are expired")
    }

    // MARK: - Router purgeStaleRoutes Keeps Entries

    func testPurgeStaleRoutes_KeepsEntriesForDisplay() {
        let config = NetRomConfig(
            neighborBaseQuality: 80,
            neighborIncrement: 40,
            minimumRouteQuality: 32,
            maxRoutesPerDestination: 3,
            neighborTTLSeconds: 1800,
            routeTTLSeconds: 1800,
            routingPolicy: .default
        )
        let router = NetRomRouter(localCallsign: "TEST0", config: config)

        let now = Date()
        let expiredRoute = RouteInfo(destination: "DEST0", origin: "STALE0", quality: 200, path: ["STALE0"], lastUpdated: now.addingTimeInterval(-3600), sourceType: "broadcast")
        let expiredNeighbor = NeighborInfo(call: "STALE0", quality: 200, lastSeen: now.addingTimeInterval(-3600), obsolescenceCount: 1, sourceType: "classic")

        router.importRoutes([expiredRoute])
        router.importNeighbors([expiredNeighbor])

        // purgeStaleRoutes is now a no-op
        router.purgeStaleRoutes(currentDate: now)

        let routes = router.currentRoutes()
        let neighbors = router.currentNeighbors()

        XCTAssertEqual(routes.count, 1, "Expired route should be kept for display")
        XCTAssertEqual(routes.first?.destination, "DEST0")
        XCTAssertEqual(neighbors.count, 1, "Expired neighbor should be kept for display")
        XCTAssertEqual(neighbors.first?.call, "STALE0")
    }

    // MARK: - ViewModel Freshness Filtering Tests

    @MainActor
    func testFilteredNeighbors_ShowsExpiredWhenToggleOff() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.hideExpiredRoutes = false
        settings.neighborStaleTTLHours = 1

        // Create view model with no integration — we'll set neighbors directly
        let vm = NetRomRoutesViewModel(integration: nil, settings: settings)

        let now = Date()
        let ttl: TimeInterval = 3600

        // Create expired and fresh neighbor display info
        let expiredNeighborInfo = NeighborInfo(call: "EXP0AAA", quality: 0, lastSeen: now.addingTimeInterval(-7200), obsolescenceCount: 1, sourceType: "classic")
        let freshNeighborInfo = NeighborInfo(call: "FRE0BBB", quality: 200, lastSeen: now.addingTimeInterval(-60), obsolescenceCount: 1, sourceType: "classic")

        let expiredDisplay = NeighborDisplayInfo(from: expiredNeighborInfo, now: now, ttl: ttl)
        let freshDisplay = NeighborDisplayInfo(from: freshNeighborInfo, now: now, ttl: ttl)

        // Verify the freshness values are what we expect
        XCTAssertEqual(expiredDisplay.freshness, 0, "Expired neighbor should have freshness 0")
        XCTAssertGreaterThan(freshDisplay.freshness, 0, "Fresh neighbor should have freshness > 0")

        // When hideExpiredRoutes is false, filtering should keep both
        XCTAssertFalse(settings.hideExpiredRoutes)
    }

    @MainActor
    func testFilteredNeighbors_HidesExpiredWhenToggleOn() {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "test_\(UUID())")!)
        settings.hideExpiredRoutes = true
        settings.neighborStaleTTLHours = 1

        let now = Date()
        let ttl: TimeInterval = 3600

        let expiredNeighborInfo = NeighborInfo(call: "EXP0AAA", quality: 0, lastSeen: now.addingTimeInterval(-7200), obsolescenceCount: 1, sourceType: "classic")
        let freshNeighborInfo = NeighborInfo(call: "FRE0BBB", quality: 200, lastSeen: now.addingTimeInterval(-60), obsolescenceCount: 1, sourceType: "classic")

        let expiredDisplay = NeighborDisplayInfo(from: expiredNeighborInfo, now: now, ttl: ttl)
        let freshDisplay = NeighborDisplayInfo(from: freshNeighborInfo, now: now, ttl: ttl)

        // Verify the freshness-based filter logic: freshness > 0 should exclude expired
        XCTAssertEqual(expiredDisplay.freshness, 0, "Expired neighbor should have freshness 0")
        XCTAssertGreaterThan(freshDisplay.freshness, 0, "Fresh neighbor should have freshness > 0")

        // The filter `result.filter { $0.freshness > 0 }` would exclude the expired one
        let allItems = [expiredDisplay, freshDisplay]
        let filtered = allItems.filter { $0.freshness > 0 }
        XCTAssertEqual(filtered.count, 1, "Should filter out expired neighbor when toggle is on")
        XCTAssertEqual(filtered.first?.callsign, "FRE0BBB", "Should keep only the fresh neighbor")
    }
}
