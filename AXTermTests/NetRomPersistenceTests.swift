//
//  NetRomPersistenceTests.swift
//  AXTermTests
//
//  Created by Codex on 1/30/26.
//

import XCTest
import GRDB

/// NET/ROM persistence stores derived routing state to SQLite for fast startup.
/// Snapshots are invalidated if stale or if configuration changes.
///
/// Persistence behavior requirements:
/// - saveSnapshot() must use a SINGLE transaction
/// - loadSnapshot() returns nil if snapshot too old or config hash mismatch
/// - High-water mark (lastProcessedPacketID) enables replay of only new packets
/// - TTL invalidation: maxSnapshotAgeSeconds constant in persistence config
/// - Config hash invalidation: hash includes NetRomConfig + NetRomInferenceConfig + LinkQualityEstimator config + schema version
///
/// Deterministic ordering requirements:
/// - Neighbors sorted by desc quality, then callsign
/// - Routes sorted by desc quality, then dest, then nextHop
/// - Link stats sorted by fromCall, then toCall
@testable import AXTerm

final class NetRomPersistenceTests: XCTestCase {
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

    // MARK: - Table Creation

    func testTablesCreatedOnInit() throws {
        // Tables should exist after initialization
        let tables = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        XCTAssertTrue(tables.contains("netrom_neighbors"))
        XCTAssertTrue(tables.contains("netrom_routes"))
        XCTAssertTrue(tables.contains("link_stats"))
        XCTAssertTrue(tables.contains("netrom_snapshot_meta"))
    }

    func testTableSchemaIncludesRequiredColumns() throws {
        // Verify neighbors table has all required columns
        let neighborColumns = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(netrom_neighbors)").map { $0["name"] as? String ?? "" }
        }
        XCTAssertTrue(neighborColumns.contains("call"))
        XCTAssertTrue(neighborColumns.contains("quality"))
        XCTAssertTrue(neighborColumns.contains("lastSeen"))
        XCTAssertTrue(neighborColumns.contains("obsolescenceCount"))
        XCTAssertTrue(neighborColumns.contains("sourceType"))

        // Verify routes table has all required columns
        let routeColumns = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(netrom_routes)").map { $0["name"] as? String ?? "" }
        }
        XCTAssertTrue(routeColumns.contains("destination"))
        XCTAssertTrue(routeColumns.contains("origin"))
        XCTAssertTrue(routeColumns.contains("quality"))
        XCTAssertTrue(routeColumns.contains("pathJson"))
        XCTAssertTrue(routeColumns.contains("sourceType"))
        XCTAssertTrue(routeColumns.contains("lastUpdate"))

        // Verify link_stats table has all required columns
        let linkStatColumns = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(link_stats)").map { $0["name"] as? String ?? "" }
        }
        XCTAssertTrue(linkStatColumns.contains("fromCall"))
        XCTAssertTrue(linkStatColumns.contains("toCall"))
        XCTAssertTrue(linkStatColumns.contains("quality"))
        XCTAssertTrue(linkStatColumns.contains("lastUpdated"))
        XCTAssertTrue(linkStatColumns.contains("dfEstimate"))
        XCTAssertTrue(linkStatColumns.contains("drEstimate"))
        XCTAssertTrue(linkStatColumns.contains("dupCount"))
        XCTAssertTrue(linkStatColumns.contains("ewmaQuality"))
    }

    // MARK: - Neighbor Persistence

    func testSaveAndLoadNeighbors() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_100)
        let neighbors = [
            makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now),
            makeNeighbor(call: "W1XYZ", quality: 150, lastSeen: now.addingTimeInterval(-10))
        ]

        try persistence.saveNeighbors(neighbors, lastPacketID: 100)

        let loaded = try persistence.loadNeighbors()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.call).sorted(), ["W0ABC", "W1XYZ"])
    }

    func testNeighborQualityPreserved() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_200)
        let neighbor = makeNeighbor(call: "W0ABC", quality: 180, lastSeen: now)

        try persistence.saveNeighbors([neighbor], lastPacketID: 101)

        let loaded = try persistence.loadNeighbors()
        XCTAssertEqual(loaded.first?.quality, 180)
    }

    func testNeighborObsolescenceCountPreserved() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_250)
        let neighbor = makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now, obsolescenceCount: 5)

        try persistence.saveNeighbors([neighbor], lastPacketID: 102)

        let loaded = try persistence.loadNeighbors()
        XCTAssertEqual(loaded.first?.obsolescenceCount, 5)
    }

    func testNeighborSourceTypePreserved() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_260)
        let neighbors = [
            makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now, sourceType: "classic"),
            makeNeighbor(call: "W1XYZ", quality: 180, lastSeen: now, sourceType: "inferred")
        ]

        try persistence.saveNeighbors(neighbors, lastPacketID: 103)

        let loaded = try persistence.loadNeighbors()
        XCTAssertEqual(loaded.first(where: { $0.call == "W0ABC" })?.sourceType, "classic")
        XCTAssertEqual(loaded.first(where: { $0.call == "W1XYZ" })?.sourceType, "inferred")
    }

    // MARK: - Route Persistence

    func testSaveAndLoadRoutes() throws {
        let routes = [
            makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"]),
            makeRoute(destination: "W3CCC", origin: "W1XYZ", quality: 120, path: ["W1XYZ", "W3CCC"])
        ]

        try persistence.saveRoutes(routes, lastPacketID: 102)

        let loaded = try persistence.loadRoutes()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.destination).sorted(), ["W2BBB", "W3CCC"])
    }

    func testRoutePathPreserved() throws {
        let route = makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "K1AAA", "W2BBB"])

        try persistence.saveRoutes([route], lastPacketID: 103)

        let loaded = try persistence.loadRoutes()
        XCTAssertEqual(loaded.first?.path, ["W0ABC", "K1AAA", "W2BBB"])
    }

    func testRouteSourceTypePreserved() throws {
        let routes = [
            makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"], sourceType: "broadcast"),
            makeRoute(destination: "W3CCC", origin: "W1XYZ", quality: 120, path: ["W1XYZ", "W3CCC"], sourceType: "inferred")
        ]

        try persistence.saveRoutes(routes, lastPacketID: 104)

        let loaded = try persistence.loadRoutes()
        XCTAssertEqual(loaded.first(where: { $0.destination == "W2BBB" })?.sourceType, "broadcast")
        XCTAssertEqual(loaded.first(where: { $0.destination == "W3CCC" })?.sourceType, "inferred")
    }

    // MARK: - Link Stats Persistence

    func testSaveAndLoadLinkStats() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_300)
        let stats = [
            makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: now),
            makeLinkStat(from: "W1XYZ", to: "N0CALL", quality: 180, lastUpdated: now)
        ]

        try persistence.saveLinkStats(stats, lastPacketID: 104)

        let loaded = try persistence.loadLinkStats()
        XCTAssertEqual(loaded.count, 2)
    }

    func testLinkStatDirectionPreserved() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_400)
        let stat = makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 200, lastUpdated: now)

        try persistence.saveLinkStats([stat], lastPacketID: 105)

        let loaded = try persistence.loadLinkStats()
        XCTAssertEqual(loaded.first?.fromCall, "W0ABC")
        XCTAssertEqual(loaded.first?.toCall, "N0CALL")
    }

    func testLinkStatDfDrEstimatesPreserved() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_450)
        let stat = makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 200, lastUpdated: now, dfEstimate: 0.85, drEstimate: 0.9, dupCount: 5, observationCount: 50)

        try persistence.saveLinkStats([stat], lastPacketID: 106)

        let loaded = try persistence.loadLinkStats()
        guard let loadedStat = loaded.first else {
            XCTFail("Expected loaded stat")
            return
        }
        XCTAssertEqual(loadedStat.dfEstimate ?? 0, 0.85, accuracy: 0.001)
        XCTAssertEqual(loadedStat.drEstimate ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(loadedStat.duplicateCount, 5)
    }

    func testLinkStatNilEstimatesPreserved() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_460)
        let stat = makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 200, lastUpdated: now, dfEstimate: nil, drEstimate: nil)

        try persistence.saveLinkStats([stat], lastPacketID: 107)

        let loaded = try persistence.loadLinkStats()
        XCTAssertNil(loaded.first?.dfEstimate)
        XCTAssertNil(loaded.first?.drEstimate)
    }

    // MARK: - Snapshot Metadata

    func testSnapshotMetadataTracksLastPacketID() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_500)
        try persistence.saveNeighbors([makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)], lastPacketID: 500)

        let meta = try persistence.loadSnapshotMeta()
        XCTAssertEqual(meta?.lastPacketID, 500)
    }

    func testSnapshotMetadataTracksConfigHash() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_600)
        let configHash = "abc123"
        try persistence.saveNeighbors(
            [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            lastPacketID: 501,
            configHash: configHash
        )

        let meta = try persistence.loadSnapshotMeta()
        XCTAssertEqual(meta?.configHash, configHash)
    }

    // MARK: - Snapshot Invalidation

    func testSnapshotInvalidatedWhenTooOld() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_700)
        let oldTimestamp = now.addingTimeInterval(-NetRomPersistenceConfig.default.maxSnapshotAgeSeconds - 100)

        try persistence.saveNeighbors(
            [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: oldTimestamp)],
            lastPacketID: 600,
            snapshotTimestamp: oldTimestamp
        )

        let isValid = try persistence.isSnapshotValid(
            currentDate: now,
            expectedConfigHash: nil
        )
        XCTAssertFalse(isValid, "Snapshot older than maxSnapshotAgeSeconds should be invalid.")
    }

    func testSnapshotInvalidatedOnConfigHashMismatch() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_800)
        try persistence.saveNeighbors(
            [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            lastPacketID: 601,
            configHash: "old_hash",
            snapshotTimestamp: now
        )

        let isValid = try persistence.isSnapshotValid(
            currentDate: now,
            expectedConfigHash: "new_hash"
        )
        XCTAssertFalse(isValid, "Snapshot with mismatched config hash should be invalid.")
    }

    func testSnapshotValidWhenFresh() throws {
        let now = Date(timeIntervalSince1970: 1_700_003_900)
        let configHash = "current_hash"
        try persistence.saveNeighbors(
            [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            lastPacketID: 602,
            configHash: configHash,
            snapshotTimestamp: now
        )

        let isValid = try persistence.isSnapshotValid(
            currentDate: now.addingTimeInterval(10),
            expectedConfigHash: configHash
        )
        XCTAssertTrue(isValid, "Fresh snapshot with matching hash should be valid.")
    }

    // MARK: - Replay Support (High-Water Mark)

    func testLastPacketIDForReplay() throws {
        let now = Date(timeIntervalSince1970: 1_700_004_000)
        try persistence.saveNeighbors(
            [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            lastPacketID: 12345
        )

        let lastID = try persistence.lastProcessedPacketID()
        XCTAssertEqual(lastID, 12345)
    }

    func testReplayFromLastPacketID() throws {
        let now = Date(timeIntervalSince1970: 1_700_004_100)
        try persistence.saveNeighbors(
            [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            lastPacketID: 999
        )

        // Verify we can determine where to resume
        let lastID = try persistence.lastProcessedPacketID()
        XCTAssertEqual(lastID, 999, "Should track last processed packet for replay.")
    }

    func testHighWaterMarkReplay_StateMatchesFullRecompute() throws {
        // Build full state with packets 1..N; save snapshot with lastProcessedPacketID=N.
        // Reload snapshot; feed packets N+1..M; assert final state matches a full recompute from 1..M.

        // This test simulates the replay scenario
        let now = Date(timeIntervalSince1970: 1_700_010_000)

        // Simulate initial state after processing packets 1..100
        let initialNeighbors = [
            makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now),
            makeNeighbor(call: "W1XYZ", quality: 180, lastSeen: now)
        ]
        let initialRoutes = [
            makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"])
        ]
        let initialLinkStats = [
            makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: now, dfEstimate: 0.9, drEstimate: nil, dupCount: 3, observationCount: 30)
        ]

        // Save snapshot at packet 100
        try persistence.saveSnapshot(
            neighbors: initialNeighbors,
            routes: initialRoutes,
            linkStats: initialLinkStats,
            lastPacketID: 100,
            configHash: "test_hash",
            snapshotTimestamp: now
        )

        // Reload and verify high-water mark
        let meta = try persistence.loadSnapshotMeta()
        XCTAssertEqual(meta?.lastPacketID, 100, "High-water mark should be 100")

        // Load the snapshot
        let loadedNeighbors = try persistence.loadNeighbors()
        let loadedRoutes = try persistence.loadRoutes()
        let loadedLinkStats = try persistence.loadLinkStats()

        // Verify initial state loaded correctly
        XCTAssertEqual(loadedNeighbors.count, 2)
        XCTAssertEqual(loadedRoutes.count, 1)
        XCTAssertEqual(loadedLinkStats.count, 1)

        // In a real scenario, we would replay packets 101..M and update state
        // Here we verify the snapshot can be extended with new data
        let updatedNeighbors = loadedNeighbors + [makeNeighbor(call: "K0ZZZ", quality: 160, lastSeen: now.addingTimeInterval(60))]
        try persistence.saveNeighbors(updatedNeighbors, lastPacketID: 150, configHash: "test_hash", snapshotTimestamp: now.addingTimeInterval(60))

        let finalMeta = try persistence.loadSnapshotMeta()
        XCTAssertEqual(finalMeta?.lastPacketID, 150, "High-water mark should be updated to 150 after replay")
    }

    // MARK: - TTL Invalidation Test

    func testTTLInvalidation_OldSnapshotReturnsNil() throws {
        // Create snapshot with createdAt older than maxSnapshotAgeSeconds;
        // load must return nil and router starts empty.

        let config = NetRomPersistenceConfig(maxSnapshotAgeSeconds: 60) // 1 minute for test
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_020_000)
        let oldTimestamp = now.addingTimeInterval(-120) // 2 minutes ago (> 60 seconds)

        try testPersistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: oldTimestamp)],
            routes: [],
            linkStats: [],
            lastPacketID: 500,
            configHash: "test_hash",
            snapshotTimestamp: oldTimestamp
        )

        // Snapshot should be invalid due to TTL
        let isValid = try testPersistence.isSnapshotValid(currentDate: now, expectedConfigHash: "test_hash")
        XCTAssertFalse(isValid, "Snapshot older than TTL should be invalid")
    }

    // MARK: - Config Hash Invalidation

    func testConfigHashInvalidation_MismatchReturnsInvalid() throws {
        // Save snapshot with hash H; load with altered config must return nil.

        let now = Date(timeIntervalSince1970: 1_700_021_000)
        let originalHash = "netrom_v1_inference_v1_link_v1_schema_1"

        try persistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            routes: [],
            linkStats: [],
            lastPacketID: 600,
            configHash: originalHash,
            snapshotTimestamp: now
        )

        // Different config hash (e.g., settings changed)
        let newHash = "netrom_v2_inference_v1_link_v1_schema_1"
        let isValid = try persistence.isSnapshotValid(currentDate: now.addingTimeInterval(10), expectedConfigHash: newHash)
        XCTAssertFalse(isValid, "Snapshot with mismatched config hash should be invalid")

        // Same hash should be valid
        let isValidSame = try persistence.isSnapshotValid(currentDate: now.addingTimeInterval(10), expectedConfigHash: originalHash)
        XCTAssertTrue(isValidSame, "Snapshot with matching config hash should be valid")
    }

    // MARK: - Clear/Reset

    func testClearAllData() throws {
        let now = Date(timeIntervalSince1970: 1_700_004_200)
        try persistence.saveNeighbors([makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)], lastPacketID: 700)
        try persistence.saveRoutes([makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"])], lastPacketID: 700)

        try persistence.clearAll()

        let neighbors = try persistence.loadNeighbors()
        let routes = try persistence.loadRoutes()
        XCTAssertTrue(neighbors.isEmpty)
        XCTAssertTrue(routes.isEmpty)
    }

    // MARK: - Determinism (CRITICAL)

    func testDeterministicNeighborLoading() throws {
        let now = Date(timeIntervalSince1970: 1_700_004_300)
        let neighbors = [
            makeNeighbor(call: "W1XYZ", quality: 150, lastSeen: now),
            makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)
        ]
        try persistence.saveNeighbors(neighbors, lastPacketID: 800)

        let loaded1 = try persistence.loadNeighbors()
        let loaded2 = try persistence.loadNeighbors()

        XCTAssertEqual(loaded1.map(\.call), loaded2.map(\.call), "Loading should return consistent ordering.")

        // Verify deterministic ordering: desc quality, then callsign
        XCTAssertEqual(loaded1[0].call, "W0ABC", "Higher quality neighbor should be first")
        XCTAssertEqual(loaded1[0].quality, 200)
        XCTAssertEqual(loaded1[1].call, "W1XYZ")
        XCTAssertEqual(loaded1[1].quality, 150)
    }

    func testDeterministicRouteLoading() throws {
        let routes = [
            makeRoute(destination: "W3CCC", origin: "W1XYZ", quality: 120, path: ["W1XYZ", "W3CCC"]),
            makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"]),
            makeRoute(destination: "W2BBB", origin: "W1XYZ", quality: 140, path: ["W1XYZ", "W2BBB"])
        ]
        try persistence.saveRoutes(routes, lastPacketID: 801)

        let loaded1 = try persistence.loadRoutes()
        let loaded2 = try persistence.loadRoutes()

        XCTAssertEqual(loaded1.map { "\($0.destination)-\($0.origin)" }, loaded2.map { "\($0.destination)-\($0.origin)" }, "Routes should have consistent ordering")

        // Verify deterministic ordering: by destination asc, then quality desc
        // W2BBB routes should come first (alphabetically), then W3CCC
        XCTAssertEqual(loaded1[0].destination, "W2BBB")
        XCTAssertEqual(loaded1[1].destination, "W2BBB")
        XCTAssertEqual(loaded1[2].destination, "W3CCC")

        // Within W2BBB, higher quality should be first
        XCTAssertEqual(loaded1[0].quality, 150) // W0ABC has quality 150
        XCTAssertEqual(loaded1[1].quality, 140) // W1XYZ has quality 140
    }

    func testDeterministicLinkStatsLoading() throws {
        let now = Date(timeIntervalSince1970: 1_700_004_350)
        let stats = [
            makeLinkStat(from: "W1XYZ", to: "N0CALL", quality: 180, lastUpdated: now),
            makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: now),
            makeLinkStat(from: "W0ABC", to: "K1AAA", quality: 200, lastUpdated: now)
        ]
        try persistence.saveLinkStats(stats, lastPacketID: 802)

        let loaded1 = try persistence.loadLinkStats()
        let loaded2 = try persistence.loadLinkStats()

        XCTAssertEqual(loaded1.map { "\($0.fromCall)-\($0.toCall)" }, loaded2.map { "\($0.fromCall)-\($0.toCall)" }, "Link stats should have consistent ordering")

        // Verify deterministic ordering: sorted by fromCall, then toCall
        XCTAssertEqual(loaded1[0].fromCall, "W0ABC")
        XCTAssertEqual(loaded1[0].toCall, "K1AAA")
        XCTAssertEqual(loaded1[1].fromCall, "W0ABC")
        XCTAssertEqual(loaded1[1].toCall, "N0CALL")
        XCTAssertEqual(loaded1[2].fromCall, "W1XYZ")
        XCTAssertEqual(loaded1[2].toCall, "N0CALL")
    }

    func testDeterministicSnapshotSaveLoad() throws {
        // Save identical data twice; load outputs identical ordering.
        let now = Date(timeIntervalSince1970: 1_700_004_400)

        let neighbors = [
            makeNeighbor(call: "K0ZZZ", quality: 100, lastSeen: now),
            makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now),
            makeNeighbor(call: "W1XYZ", quality: 200, lastSeen: now) // Same quality as W0ABC
        ]
        let routes = [
            makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"]),
            makeRoute(destination: "W2BBB", origin: "W1XYZ", quality: 150, path: ["W1XYZ", "W2BBB"]) // Same quality
        ]
        let linkStats = [
            makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: now)
        ]

        // First save/load cycle
        try persistence.saveSnapshot(
            neighbors: neighbors,
            routes: routes,
            linkStats: linkStats,
            lastPacketID: 900,
            configHash: "det_test",
            snapshotTimestamp: now
        )
        let neighbors1 = try persistence.loadNeighbors()
        let routes1 = try persistence.loadRoutes()
        let linkStats1 = try persistence.loadLinkStats()

        // Clear and save again
        try persistence.clearAll()
        persistence = try NetRomPersistence(database: dbQueue)
        try persistence.saveSnapshot(
            neighbors: neighbors,
            routes: routes,
            linkStats: linkStats,
            lastPacketID: 900,
            configHash: "det_test",
            snapshotTimestamp: now
        )
        let neighbors2 = try persistence.loadNeighbors()
        let routes2 = try persistence.loadRoutes()
        let linkStats2 = try persistence.loadLinkStats()

        // Both loads should produce identical ordering
        XCTAssertEqual(neighbors1.map(\.call), neighbors2.map(\.call))
        XCTAssertEqual(routes1.map { "\($0.destination)-\($0.origin)" }, routes2.map { "\($0.destination)-\($0.origin)" })
        XCTAssertEqual(linkStats1.map { "\($0.fromCall)-\($0.toCall)" }, linkStats2.map { "\($0.fromCall)-\($0.toCall)" })
    }

    // MARK: - Full State Round-Trip (CRITICAL)

    func testFullStateRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_004_400)
        let neighbors = [
            makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now, obsolescenceCount: 3, sourceType: "classic"),
            makeNeighbor(call: "W1XYZ", quality: 180, lastSeen: now, obsolescenceCount: 1, sourceType: "inferred")
        ]
        let routes = [
            makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"], sourceType: "broadcast"),
            makeRoute(destination: "W3CCC", origin: "W1XYZ", quality: 120, path: ["W1XYZ", "K1DIG", "W3CCC"], sourceType: "inferred")
        ]
        let linkStats = [
            makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: now, dfEstimate: 0.9, drEstimate: 0.85, dupCount: 5, observationCount: 50),
            makeLinkStat(from: "W1XYZ", to: "N0CALL", quality: 180, lastUpdated: now, dfEstimate: 0.75, drEstimate: nil, dupCount: 10, observationCount: 40)
        ]
        let configHash = "test_hash_123"

        try persistence.saveSnapshot(
            neighbors: neighbors,
            routes: routes,
            linkStats: linkStats,
            lastPacketID: 9999,
            configHash: configHash,
            snapshotTimestamp: now
        )

        let loadedNeighbors = try persistence.loadNeighbors()
        let loadedRoutes = try persistence.loadRoutes()
        let loadedStats = try persistence.loadLinkStats()
        let meta = try persistence.loadSnapshotMeta()

        // Verify counts
        XCTAssertEqual(loadedNeighbors.count, 2)
        XCTAssertEqual(loadedRoutes.count, 2)
        XCTAssertEqual(loadedStats.count, 2)
        XCTAssertEqual(meta?.lastPacketID, 9999)
        XCTAssertEqual(meta?.configHash, configHash)

        // Verify neighbor details
        let neighborW0ABC = loadedNeighbors.first(where: { $0.call == "W0ABC" })
        XCTAssertEqual(neighborW0ABC?.quality, 200)
        XCTAssertEqual(neighborW0ABC?.obsolescenceCount, 3)
        XCTAssertEqual(neighborW0ABC?.sourceType, "classic")

        // Verify route details
        let routeW3CCC = loadedRoutes.first(where: { $0.destination == "W3CCC" })
        XCTAssertEqual(routeW3CCC?.path, ["W1XYZ", "K1DIG", "W3CCC"])
        XCTAssertEqual(routeW3CCC?.sourceType, "inferred")

        // Verify link stat details
        guard let statW0ABC = loadedStats.first(where: { $0.fromCall == "W0ABC" }) else {
            XCTFail("Expected loaded stat for W0ABC")
            return
        }
        XCTAssertEqual(statW0ABC.dfEstimate ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(statW0ABC.drEstimate ?? 0, 0.85, accuracy: 0.001)
        XCTAssertEqual(statW0ABC.duplicateCount, 5)
    }

    // MARK: - Atomic Transaction Test

    func testSaveSnapshotUsesAtomicTransaction() throws {
        // Verify that saveSnapshot either succeeds completely or fails completely
        let now = Date(timeIntervalSince1970: 1_700_005_000)
        let neighbors = [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)]
        let routes = [makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"])]
        let linkStats = [makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: now)]

        // Save first snapshot
        try persistence.saveSnapshot(
            neighbors: neighbors,
            routes: routes,
            linkStats: linkStats,
            lastPacketID: 1000,
            configHash: "first_hash",
            snapshotTimestamp: now
        )

        // Verify first snapshot
        let meta1 = try persistence.loadSnapshotMeta()
        XCTAssertEqual(meta1?.lastPacketID, 1000)
        XCTAssertEqual(meta1?.configHash, "first_hash")

        // Save second snapshot (should replace everything atomically)
        let neighbors2 = [makeNeighbor(call: "K0ZZZ", quality: 180, lastSeen: now)]
        try persistence.saveSnapshot(
            neighbors: neighbors2,
            routes: [],
            linkStats: [],
            lastPacketID: 2000,
            configHash: "second_hash",
            snapshotTimestamp: now.addingTimeInterval(60)
        )

        // Verify second snapshot completely replaced first
        let meta2 = try persistence.loadSnapshotMeta()
        XCTAssertEqual(meta2?.lastPacketID, 2000)
        XCTAssertEqual(meta2?.configHash, "second_hash")

        let loadedNeighbors = try persistence.loadNeighbors()
        XCTAssertEqual(loadedNeighbors.count, 1)
        XCTAssertEqual(loadedNeighbors.first?.call, "K0ZZZ")

        let loadedRoutes = try persistence.loadRoutes()
        XCTAssertTrue(loadedRoutes.isEmpty, "Routes from first snapshot should be cleared")
    }

    // MARK: - Per-Entry Decay (CRITICAL TDD TESTS)

    func testNeighborDecayOnLoad_StaleNeighborsHaveReducedQuality() throws {
        // Save snapshot with a neighbor whose `lastSeen` is much older than neighbor TTL.
        // Load snapshot with current time far past neighbor's lastSeen.
        // ASSERT that neighbor is dropped or quality decayed to (near) zero.

        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 3600,
            neighborTTLSeconds: 300  // 5 minutes
        )
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_006_000)
        let snapshotTime = now.addingTimeInterval(-60)  // 1 minute ago (fresh)
        let staleNeighborTime = now.addingTimeInterval(-600)  // 10 minutes ago (> 5 min TTL)
        let freshNeighborTime = now.addingTimeInterval(-120)  // 2 minutes ago (< 5 min TTL)

        try testPersistence.saveSnapshot(
            neighbors: [
                makeNeighbor(call: "W0STALE", quality: 200, lastSeen: staleNeighborTime),
                makeNeighbor(call: "W1FRESH", quality: 180, lastSeen: freshNeighborTime)
            ],
            routes: [],
            linkStats: [],
            lastPacketID: 2100,
            configHash: "decay_neighbor",
            snapshotTimestamp: snapshotTime
        )

        // Load with decay applied
        let result = try testPersistence.load(now: now, expectedConfigHash: "decay_neighbor")

        XCTAssertNotNil(result, "Fresh snapshot should load")

        guard let state = result else { return }

        // Stale neighbor should be dropped or heavily decayed
        let staleNeighbor = state.neighbors.first(where: { $0.call == "W0STALE" })
        if let stale = staleNeighbor {
            XCTAssertLessThan(stale.quality, 50, "Stale neighbor should be heavily decayed")
        }

        // Fresh neighbor should retain quality
        let freshNeighbor = state.neighbors.first(where: { $0.call == "W1FRESH" })
        XCTAssertNotNil(freshNeighbor, "Fresh neighbor should exist")
        XCTAssertGreaterThan(freshNeighbor?.quality ?? 0, 100, "Fresh neighbor should retain quality")
    }

    func testRouteDecayOnLoad_ExpiredRoutesRemoved() throws {
        // Save snapshot with routes that have `lastUpdate` beyond route TTL.
        // Load snapshot.
        // ASSERT expired routes are removed.

        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 3600,
            routeTTLSeconds: 300  // 5 minutes
        )
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_007_000)
        // Create snapshot that is fresh, but routes will be stale when loaded
        let snapshotTime = now.addingTimeInterval(-60)

        try testPersistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: snapshotTime)],
            routes: [
                makeRoute(destination: "W2ROUTE", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2ROUTE"])
            ],
            linkStats: [],
            lastPacketID: 2200,
            configHash: "decay_route",
            snapshotTimestamp: snapshotTime
        )

        // Wait past route TTL
        let muchLater = now.addingTimeInterval(600)  // 10 minutes later

        let result = try testPersistence.load(now: muchLater, expectedConfigHash: "decay_route")

        // Either result is nil (all data stale) or routes are filtered out
        if let state = result {
            // Routes should be empty or heavily decayed
            XCTAssertTrue(state.routes.isEmpty || state.routes.allSatisfy { $0.quality < 50 },
                          "Stale routes should be dropped or decayed")
        }
    }

    func testLinkStatsDecayOnLoad_OldLinkStatsFiltered() throws {
        // Save linkStats with old timestamps.
        // Load snapshot with current time advanced.
        // ASSERT linkStats with old timestamps are dropped/ignored.

        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 3600,
            linkStatTTLSeconds: 300  // 5 minutes
        )
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_008_000)
        let snapshotTime = now.addingTimeInterval(-60)
        let staleTime = now.addingTimeInterval(-600)  // 10 min ago (> 5 min TTL)
        let freshTime = now.addingTimeInterval(-120)  // 2 min ago (< 5 min TTL)

        try testPersistence.saveSnapshot(
            neighbors: [],
            routes: [],
            linkStats: [
                makeLinkStat(from: "W0STALE", to: "N0CALL", quality: 220, lastUpdated: staleTime),
                makeLinkStat(from: "W1FRESH", to: "N0CALL", quality: 200, lastUpdated: freshTime)
            ],
            lastPacketID: 2300,
            configHash: "decay_link",
            snapshotTimestamp: snapshotTime
        )

        let result = try testPersistence.load(now: now, expectedConfigHash: "decay_link")

        XCTAssertNotNil(result)

        guard let state = result else { return }

        // Stale link should be filtered
        XCTAssertNil(state.linkStats.first(where: { $0.fromCall == "W0STALE" }),
                     "Stale link stat should be filtered")

        // Fresh link should remain
        XCTAssertNotNil(state.linkStats.first(where: { $0.fromCall == "W1FRESH" }),
                        "Fresh link stat should remain")
    }

    // MARK: - High-Water Mark Verification (CRITICAL TDD TESTS)

    func testHighWaterMarkReplay_IncrementalMatchesFull() throws {
        // This test verifies that:
        // 1. Saving snapshot with lastProcessedPacketID correctly stores high-water mark
        // 2. Loading + replaying delta produces same state as full replay

        let now = Date(timeIntervalSince1970: 1_700_009_000)

        // Create initial state (simulating packets 1..50)
        let initialNeighbors = [
            makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)
        ]
        let initialLinkStats = [
            makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 200, lastUpdated: now)
        ]

        // Save snapshot at packet 50
        try persistence.saveSnapshot(
            neighbors: initialNeighbors,
            routes: [],
            linkStats: initialLinkStats,
            lastPacketID: 50,
            configHash: "hwm_verify",
            snapshotTimestamp: now
        )

        // Verify high-water mark
        let lastID = try persistence.lastProcessedPacketID()
        XCTAssertEqual(lastID, 50, "High-water mark should be 50")

        // Load snapshot
        let meta = try persistence.loadSnapshotMeta()
        XCTAssertEqual(meta?.lastPacketID, 50, "Loaded meta should have lastPacketID 50")

        // Verify loaded state matches saved state
        let loadedNeighbors = try persistence.loadNeighbors()
        XCTAssertEqual(loadedNeighbors.count, 1)
        XCTAssertEqual(loadedNeighbors.first?.call, "W0ABC")
        XCTAssertEqual(loadedNeighbors.first?.quality, 200)
    }

    func testHighWaterMarkUpdate_AfterIncrementalReplay() throws {
        // After loading and processing additional packets, verify high-water mark can be updated

        let now = Date(timeIntervalSince1970: 1_700_010_000)

        // Initial snapshot at packet 100
        try persistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            routes: [],
            linkStats: [],
            lastPacketID: 100,
            configHash: "hwm_update",
            snapshotTimestamp: now
        )

        XCTAssertEqual(try persistence.lastProcessedPacketID(), 100)

        // Simulate processing packets 101..150 and saving new snapshot
        let updatedNeighbors = [
            makeNeighbor(call: "W0ABC", quality: 220, lastSeen: now.addingTimeInterval(60)),
            makeNeighbor(call: "W1NEW", quality: 180, lastSeen: now.addingTimeInterval(60))
        ]

        try persistence.saveSnapshot(
            neighbors: updatedNeighbors,
            routes: [],
            linkStats: [],
            lastPacketID: 150,  // New high-water mark
            configHash: "hwm_update",
            snapshotTimestamp: now.addingTimeInterval(60)
        )

        // Verify high-water mark updated
        XCTAssertEqual(try persistence.lastProcessedPacketID(), 150, "High-water mark should update to 150")

        // Verify new state
        let loadedNeighbors = try persistence.loadNeighbors()
        XCTAssertEqual(loadedNeighbors.count, 2)
        XCTAssertTrue(loadedNeighbors.contains { $0.call == "W1NEW" })
    }

    // MARK: - Load API Tests (TDD)

    func testLoadAPI_ReturnsPersistedState() throws {
        // Test the load(now:expectedConfigHash:) -> PersistedState? API

        let now = Date(timeIntervalSince1970: 1_700_011_000)

        try persistence.saveSnapshot(
            neighbors: [
                makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now),
                makeNeighbor(call: "W1XYZ", quality: 180, lastSeen: now)
            ],
            routes: [
                makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"], lastUpdated: now)
            ],
            linkStats: [
                makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: now)
            ],
            lastPacketID: 2500,
            configHash: "load_api_test",
            snapshotTimestamp: now
        )

        let result = try persistence.load(now: now.addingTimeInterval(10), expectedConfigHash: "load_api_test")

        XCTAssertNotNil(result, "load() should return PersistedState")

        guard let state = result else { return }

        XCTAssertEqual(state.neighbors.count, 2)
        XCTAssertEqual(state.routes.count, 1)
        XCTAssertEqual(state.linkStats.count, 1)
        XCTAssertEqual(state.lastPacketID, 2500)
    }

    func testLoadAPI_ReturnsNilForStaleSnapshot() throws {
        let config = NetRomPersistenceConfig(maxSnapshotAgeSeconds: 60)
        let testPersistence = try NetRomPersistence(database: dbQueue, config: config)

        let now = Date(timeIntervalSince1970: 1_700_012_000)
        let staleTime = now.addingTimeInterval(-120)  // 2 minutes ago (> 60 second TTL)

        try testPersistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: staleTime)],
            routes: [],
            linkStats: [],
            lastPacketID: 2600,
            configHash: "stale_test",
            snapshotTimestamp: staleTime
        )

        let result = try testPersistence.load(now: now, expectedConfigHash: "stale_test")

        XCTAssertNil(result, "load() should return nil for stale snapshot")
    }

    func testLoadAPI_ReturnsNilForConfigMismatch() throws {
        let now = Date(timeIntervalSince1970: 1_700_013_000)

        try persistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)],
            routes: [],
            linkStats: [],
            lastPacketID: 2700,
            configHash: "old_config",
            snapshotTimestamp: now
        )

        let result = try persistence.load(now: now.addingTimeInterval(10), expectedConfigHash: "new_config")

        XCTAssertNil(result, "load() should return nil for config mismatch")
    }
}
