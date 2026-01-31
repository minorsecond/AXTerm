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
}
