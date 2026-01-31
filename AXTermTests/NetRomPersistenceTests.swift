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

    private func makeNeighbor(call: String, quality: Int, lastSeen: Date) -> NeighborInfo {
        NeighborInfo(call: call, quality: quality, lastSeen: lastSeen)
    }

    private func makeRoute(destination: String, origin: String, quality: Int, path: [String]) -> RouteInfo {
        RouteInfo(destination: destination, origin: origin, quality: quality, path: path)
    }

    private func makeLinkStat(from: String, to: String, quality: Int, lastUpdated: Date) -> LinkStatRecord {
        LinkStatRecord(fromCall: from, toCall: to, quality: quality, lastUpdated: lastUpdated)
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

    // MARK: - Replay Support

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

    // MARK: - Determinism

    func testDeterministicLoading() throws {
        let now = Date(timeIntervalSince1970: 1_700_004_300)
        let neighbors = [
            makeNeighbor(call: "W1XYZ", quality: 150, lastSeen: now),
            makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now)
        ]
        try persistence.saveNeighbors(neighbors, lastPacketID: 800)

        let loaded1 = try persistence.loadNeighbors()
        let loaded2 = try persistence.loadNeighbors()

        XCTAssertEqual(loaded1.map(\.call), loaded2.map(\.call), "Loading should return consistent ordering.")
    }

    // MARK: - Full State Round-Trip

    func testFullStateRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_004_400)
        let neighbors = [
            makeNeighbor(call: "W0ABC", quality: 200, lastSeen: now),
            makeNeighbor(call: "W1XYZ", quality: 180, lastSeen: now)
        ]
        let routes = [
            makeRoute(destination: "W2BBB", origin: "W0ABC", quality: 150, path: ["W0ABC", "W2BBB"])
        ]
        let linkStats = [
            makeLinkStat(from: "W0ABC", to: "N0CALL", quality: 220, lastUpdated: now)
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

        XCTAssertEqual(loadedNeighbors.count, 2)
        XCTAssertEqual(loadedRoutes.count, 1)
        XCTAssertEqual(loadedStats.count, 1)
        XCTAssertEqual(meta?.lastPacketID, 9999)
        XCTAssertEqual(meta?.configHash, configHash)
    }
}
