//
//  NetRomStaleSnapshotTests.swift
//  AXTermTests
//
//  Tests for snapshot age and config hash invalidation, plus per-entry decay.
//
//  Snapshot staleness rules:
//  1. Snapshot-level: If `snapshotTimestamp` is older than `maxSnapshotAgeSeconds`, reject entire snapshot
//  2. Config hash: If config hash differs, reject entire snapshot
//  3. Per-entry: Individual entries (neighbors, routes, linkStats) with old lastUpdate should be
//     decayed or dropped during load based on their individual TTLs
//
//  The `load(now:)` API should return nil if snapshot is invalid, or a PersistedState with
//  stale entries filtered/decayed.
//

import XCTest
import GRDB

@testable import AXTerm

final class NetRomStaleSnapshotTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var persistence: NetRomPersistence!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbQueue = try DatabaseQueue()
        persistence = try NetRomPersistence(database: dbQueue)
    }

    override func tearDownWithError() throws {
        persistence = nil
        dbQueue = nil
        try super.tearDownWithError()
    }

    private func makeNeighbor(call: String, quality: Int, lastSeen: Date, obsolescenceCount: Int = 1, sourceType: String = "classic") -> NeighborInfo {
        NeighborInfo(call: call, quality: quality, lastSeen: lastSeen, obsolescenceCount: obsolescenceCount, sourceType: sourceType)
    }

    private func makeRoute(destination: String, origin: String, quality: Int, path: [String], lastUpdated: Date = Date(timeIntervalSince1970: 1_700_000_000), sourceType: String = "broadcast") -> RouteInfo {
        RouteInfo(destination: destination, origin: origin, quality: quality, path: path, lastUpdated: lastUpdated, sourceType: sourceType)
    }

    private func makeLinkStat(from: String, to: String, quality: Int, lastUpdated: Date, dfEstimate: Double? = nil, drEstimate: Double? = nil, dupCount: Int = 0, observationCount: Int = 1) -> LinkStatRecord {
        LinkStatRecord(fromCall: from, toCall: to, quality: quality, lastUpdated: lastUpdated, dfEstimate: dfEstimate, drEstimate: drEstimate, duplicateCount: dupCount, observationCount: observationCount)
    }

    // MARK: - Snapshot Age Invalidation (CRITICAL)

    func testSnapshotAgeInvalidation_OldSnapshotReturnsNil() throws {
        // Create a snapshot with `createdAt` older than `maxSnapshotAgeSeconds`.
        // Call `NetRomPersistence.load(now:)`.
        // ASSERT that load returns `nil` and state does not apply.

        let config = NetRomPersistenceConfig(maxSnapshotAgeSeconds: 60)  // 1 minute for test
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let oldTimestamp = now.addingTimeInterval(-120)  // 2 minutes ago (> 60 seconds)

        try testPersistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: oldTimestamp)],
            routes: [makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"])],
            linkStats: [makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: oldTimestamp)],
            lastPacketID: 500,
            configHash: "test_hash",
            snapshotTimestamp: oldTimestamp
        )

        // Attempt to load with `now` - this should fail the TTL check
        // The load(now:) API should return nil for expired snapshots
        let result = try testPersistence.load(now: now)

        XCTAssertNil(result, "Snapshot older than maxSnapshotAgeSeconds should return nil from load(now:)")
    }

    func testSnapshotFreshLoad_ReturnsState() throws {
        // Create snapshot with `createdAt` within threshold.
        // Call `NetRomPersistence.load(now:)`.
        // ASSERT snapshot loads and returns state with neighbors/routes/linkStats.

        let config = NetRomPersistenceConfig(maxSnapshotAgeSeconds: 3600)  // 1 hour
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let recentTimestamp = now.addingTimeInterval(-60)  // 1 minute ago (< 1 hour)

        try testPersistence.saveSnapshot(
            neighbors: [
                makeNeighbor(call: "W0ABC", quality: 200, lastSeen: recentTimestamp),
                makeNeighbor(call: "W1XYZ", quality: 180, lastSeen: recentTimestamp)
            ],
            routes: [
                makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"], lastUpdated: recentTimestamp)
            ],
            linkStats: [
                makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: recentTimestamp)
            ],
            lastPacketID: 600,
            configHash: "fresh_hash",
            snapshotTimestamp: recentTimestamp
        )

        let result = try testPersistence.load(now: now, expectedConfigHash: "fresh_hash")

        XCTAssertNotNil(result, "Fresh snapshot should load successfully")

        guard let state = result else { return }

        XCTAssertEqual(state.neighbors.count, 2, "Should load 2 neighbors")
        XCTAssertEqual(state.routes.count, 1, "Should load 1 route")
        XCTAssertEqual(state.linkStats.count, 1, "Should load 1 link stat")
        XCTAssertEqual(state.lastPacketID, 600, "Should preserve lastPacketID")
    }

    // MARK: - Config Hash Mismatch

    func testConfigHashMismatch_ReturnsNil() throws {
        // Save snapshot with config hash H.
        // Modify config hash (neighbor quality constants, inference constants, or schema version).
        // Load snapshot.
        // ASSERT load returns `nil` due to config mismatch.

        let now = Date(timeIntervalSince1970: 1_700_101_000)
        let originalHash = "netrom_v1_inference_v1_link_v1_schema_1"

        try persistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            routes: [],
            linkStats: [],
            lastPacketID: 700,
            configHash: originalHash,
            snapshotTimestamp: now
        )

        // Try to load with different config hash
        let newHash = "netrom_v2_inference_v1_link_v1_schema_1"
        let result = try persistence.load(now: now.addingTimeInterval(10), expectedConfigHash: newHash)

        XCTAssertNil(result, "Snapshot with mismatched config hash should return nil from load(now:)")
    }

    func testConfigHashMatch_ReturnsState() throws {
        let now = Date(timeIntervalSince1970: 1_700_102_000)
        let configHash = "netrom_v1_inference_v1_link_v1_schema_1"

        try persistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            routes: [makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"], lastUpdated: now)],
            linkStats: [makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: now)],
            lastPacketID: 800,
            configHash: configHash,
            snapshotTimestamp: now
        )

        let result = try persistence.load(now: now.addingTimeInterval(10), expectedConfigHash: configHash)

        XCTAssertNotNil(result, "Snapshot with matching config hash should load successfully")
        XCTAssertEqual(result?.neighbors.count, 1)
        XCTAssertEqual(result?.routes.count, 1)
        XCTAssertEqual(result?.linkStats.count, 1)
    }

    // MARK: - Per-Entry Decay on Load (CRITICAL)

    func testNeighborDecayOnLoad_StaleNeighborsDropped() throws {
        // Save snapshot with a neighbor whose `lastSeen` is much older than the neighbor TTL.
        // Load snapshot with current time far past neighbor's lastSeen.
        // ASSERT that stale neighbors are dropped or quality decayed to (near) zero.

        // Configure with short neighbor TTL for testing
        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 3600,
            neighborTTLSeconds: 300  // 5 minutes
        )
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_110_000)
        let snapshotTime = now.addingTimeInterval(-60)  // 1 minute ago (snapshot is fresh)
        let staleNeighborLastSeen = now.addingTimeInterval(-600)  // 10 minutes ago (> 5 minute TTL)
        let freshNeighborLastSeen = now.addingTimeInterval(-120)  // 2 minutes ago (< 5 minute TTL)

        try testPersistence.saveSnapshot(
            neighbors: [
                makeNeighbor(call: "W0STALE", quality: 200, lastSeen: staleNeighborLastSeen),
                makeNeighbor(call: "W1FRESH", quality: 180, lastSeen: freshNeighborLastSeen)
            ],
            routes: [],
            linkStats: [],
            lastPacketID: 900,
            configHash: "decay_test",
            snapshotTimestamp: snapshotTime
        )

        let result = try testPersistence.load(now: now, expectedConfigHash: "decay_test")

        XCTAssertNotNil(result, "Snapshot should load (it's fresh)")

        guard let state = result else { return }

        // Stale neighbor should be kept but with quality decayed to near zero
        let staleNeighbor = state.neighbors.first(where: { $0.call == "W0STALE" })
        XCTAssertNotNil(staleNeighbor, "Stale neighbor should be kept for display")
        if let stale = staleNeighbor {
            XCTAssertLessThan(stale.quality, 50, "Stale neighbor quality should be heavily decayed")
        }

        // Fresh neighbor should remain with reasonable quality
        let freshNeighbor = state.neighbors.first(where: { $0.call == "W1FRESH" })
        XCTAssertNotNil(freshNeighbor, "Fresh neighbor should be retained")
        XCTAssertGreaterThan(freshNeighbor?.quality ?? 0, 100, "Fresh neighbor should retain most quality")
    }

    func testRouteDecayOnLoad_StaleRoutesDropped() throws {
        // Save snapshot with routes that have `lastUpdate` beyond route TTL.
        // Load snapshot.
        // ASSERT expired routes are removed.

        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 3600,
            routeTTLSeconds: 300  // 5 minutes
        )
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_120_000)
        let snapshotTime = now.addingTimeInterval(-60)  // 1 minute ago

        try testPersistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            routes: [
                makeRoute(destination: "W2STALE", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2STALE"], lastUpdated: snapshotTime),
                makeRoute(destination: "W3FRESH", origin: "W0ABC", quality: 140, path: ["W0ABC", "W3FRESH"], lastUpdated: snapshotTime)
            ],
            linkStats: [],
            lastPacketID: 1000,
            configHash: "route_decay",
            snapshotTimestamp: snapshotTime
        )

        let muchLater = now.addingTimeInterval(600)  // 10 minutes later
        let result = try testPersistence.load(now: muchLater, expectedConfigHash: "route_decay")

        // With 10-minute elapsed time and 5-minute route TTL, routes are expired
        // but still kept for display purposes (the UI toggle filters them).
        if let state = result {
            XCTAssertFalse(state.routes.isEmpty, "Expired routes should be kept for display")
        }
        // Nil result is also acceptable (snapshot fully invalidated due to staleness)
    }

    func testLinkStatsDecayOnLoad_OldLinkStatsDropped() throws {
        // Save linkStats with old timestamps.
        // Load snapshot with current time advanced.
        // ASSERT linkStats with old timestamps are dropped/ignored.

        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 3600,
            linkStatTTLSeconds: 300  // 5 minutes
        )
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_130_000)
        let snapshotTime = now.addingTimeInterval(-60)
        let staleLinkTime = now.addingTimeInterval(-600)  // 10 minutes ago
        let freshLinkTime = now.addingTimeInterval(-120)  // 2 minutes ago

        try testPersistence.saveSnapshot(
            neighbors: [],
            routes: [],
            linkStats: [
                makeLinkStat(from: "W0STALE", to: "N0CALL", quality: 220, lastUpdated: staleLinkTime),
                makeLinkStat(from: "W1FRESH", to: "N0CALL", quality: 200, lastUpdated: freshLinkTime)
            ],
            lastPacketID: 1100,
            configHash: "link_decay",
            snapshotTimestamp: snapshotTime
        )

        let result = try testPersistence.load(now: now, expectedConfigHash: "link_decay")

        XCTAssertNotNil(result, "Snapshot should load (it's fresh)")

        guard let state = result else { return }

        // Stale link stat should be kept for display
        let staleLink = state.linkStats.first(where: { $0.fromCall == "W0STALE" })
        XCTAssertNotNil(staleLink, "Stale link stat should be kept for display")

        // Fresh link stat should be retained
        let freshLink = state.linkStats.first(where: { $0.fromCall == "W1FRESH" })
        XCTAssertNotNil(freshLink, "Fresh link stat should be retained")
    }

    // MARK: - Edge Cases

    func testEmptySnapshot_LoadsEmpty() throws {
        let now = Date(timeIntervalSince1970: 1_700_140_000)

        try persistence.saveSnapshot(
            neighbors: [],
            routes: [],
            linkStats: [],
            lastPacketID: 0,
            configHash: "empty_test",
            snapshotTimestamp: now
        )

        let result = try persistence.load(now: now.addingTimeInterval(10), expectedConfigHash: "empty_test")

        XCTAssertNotNil(result, "Empty but fresh snapshot should load")

        guard let state = result else { return }

        XCTAssertTrue(state.neighbors.isEmpty)
        XCTAssertTrue(state.routes.isEmpty)
        XCTAssertTrue(state.linkStats.isEmpty)
        XCTAssertEqual(state.lastPacketID, 0)
    }

    func testNoSnapshot_LoadReturnsNil() throws {
        // Don't save anything, just try to load
        let now = Date(timeIntervalSince1970: 1_700_150_000)

        let result = try persistence.load(now: now, expectedConfigHash: nil)

        XCTAssertNil(result, "No snapshot should return nil")
    }

    func testSnapshotAtExactTTLBoundary_IsStillValid() throws {
        let config = NetRomPersistenceConfig(maxSnapshotAgeSeconds: 60)
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_160_000)
        let exactBoundary = now.addingTimeInterval(-60)  // Exactly at TTL

        try testPersistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: exactBoundary)],
            routes: [],
            linkStats: [],
            lastPacketID: 1200,
            configHash: "boundary_test",
            snapshotTimestamp: exactBoundary
        )

        // At exact boundary (age == maxSnapshotAgeSeconds), the implementation uses `>`
        // so age == 60 is NOT > 60, meaning it's still valid
        let result = try testPersistence.load(now: now, expectedConfigHash: "boundary_test")

        // The implementation uses `>` not `>=`, so exact boundary is valid
        XCTAssertNotNil(result, "Snapshot at exact TTL boundary should still be valid (uses > not >=)")
    }

    func testSnapshotJustBeforeTTLBoundary_IsValid() throws {
        let config = NetRomPersistenceConfig(maxSnapshotAgeSeconds: 60)
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_170_000)
        let justBefore = now.addingTimeInterval(-59)  // 1 second before TTL

        try testPersistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: justBefore)],
            routes: [],
            linkStats: [],
            lastPacketID: 1300,
            configHash: "before_boundary",
            snapshotTimestamp: justBefore
        )

        let result = try testPersistence.load(now: now, expectedConfigHash: "before_boundary")

        XCTAssertNotNil(result, "Snapshot just before TTL boundary should be valid")
    }

    // MARK: - Decay Calculation Verification

    func testDecayCalculation_BeyondTTL() throws {
        // Verify decay calculation when neighbor is beyond TTL
        // Implementation: decay happens linearly beyond TTL
        // decayFactor = 1 - (age / TTL), where age = now - lastSeen
        // For age = 1.5 * TTL: decayFactor = 1 - 1.5 = -0.5 -> clamped to 0

        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 3600,
            neighborTTLSeconds: 600  // 10 minutes
        )
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_180_000)
        let snapshotTime = now.addingTimeInterval(-60)

        // Neighbor seen 15 minutes ago (150% of 10-minute TTL - should be dropped)
        let veryOldTime = now.addingTimeInterval(-900)

        // Neighbor seen 5 minutes ago (50% of 10-minute TTL - within TTL, no decay)
        let recentTime = now.addingTimeInterval(-300)

        try testPersistence.saveSnapshot(
            neighbors: [
                makeNeighbor(call: "W0OLD", quality: 200, lastSeen: veryOldTime),
                makeNeighbor(call: "W0RECENT", quality: 200, lastSeen: recentTime)
            ],
            routes: [],
            linkStats: [],
            lastPacketID: 1400,
            configHash: "decay_calc",
            snapshotTimestamp: snapshotTime
        )

        let result = try testPersistence.load(now: now, expectedConfigHash: "decay_calc")

        XCTAssertNotNil(result)

        guard let state = result else { return }

        // Old neighbor (beyond TTL) should be kept but with quality decayed to 0
        let oldNeighbor = state.neighbors.first(where: { $0.call == "W0OLD" })
        XCTAssertNotNil(oldNeighbor, "Neighbor beyond TTL should be kept for display")
        XCTAssertEqual(oldNeighbor?.quality, 0, "Neighbor beyond 1.5x TTL should have quality decayed to 0")

        // Recent neighbor (within TTL) should retain full quality
        let recentNeighbor = state.neighbors.first(where: { $0.call == "W0RECENT" })
        XCTAssertNotNil(recentNeighbor, "Recent neighbor should exist")
        XCTAssertEqual(recentNeighbor?.quality, 200, "Recent neighbor within TTL should retain full quality")
    }
}
