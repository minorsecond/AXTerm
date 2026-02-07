//
//  NetRomPersistenceDecayTests.swift
//  AXTermTests
//
//  TDD tests for persistence + timestamp integrity with the time-based freshness model.
//
//  These tests verify that:
//  - Timestamps are preserved correctly through persistence
//  - Invalid timestamps are normalized (never show "739648d ago")
//  - Freshness calculations work correctly after loading from persistence
//

import XCTest
import GRDB
@testable import AXTerm

final class NetRomPersistenceDecayTests: XCTestCase {

    // MARK: - Freshness Constants (30-minute TTL with 5-minute plateau)

    let neighborTTL: TimeInterval = 30 * 60
    let routeTTL: TimeInterval = 30 * 60
    let linkStatTTL: TimeInterval = 30 * 60
    let plateau: TimeInterval = 5 * 60

    // MARK: - Test Fixtures

    private var dbQueue: DatabaseQueue!
    private var persistence: NetRomPersistence!
    private var baseTime: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbQueue = try DatabaseQueue()
        persistence = try NetRomPersistence(database: dbQueue)
        baseTime = Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func tearDownWithError() throws {
        persistence = nil
        dbQueue = nil
        baseTime = nil
        try super.tearDownWithError()
    }

    // MARK: - Helper Functions

    private func makeNeighbor(call: String, quality: Int, lastSeen: Date, sourceType: String = "classic") -> NeighborInfo {
        NeighborInfo(call: call, quality: quality, lastSeen: lastSeen, obsolescenceCount: 1, sourceType: sourceType)
    }

    private func makeRoute(destination: String, origin: String, quality: Int, path: [String] = [], lastUpdated: Date, sourceType: String = "broadcast") -> RouteInfo {
        RouteInfo(destination: destination, origin: origin, quality: quality, path: path, lastUpdated: lastUpdated, sourceType: sourceType)
    }

    private func makeLinkStat(from: String, to: String, quality: Int, lastUpdated: Date, obsCount: Int = 10) -> LinkStatRecord {
        LinkStatRecord(
            fromCall: from,
            toCall: to,
            quality: quality,
            lastUpdated: lastUpdated,
            dfEstimate: 0.9,
            drEstimate: nil,
            duplicateCount: 0,
            observationCount: obsCount
        )
    }

    // MARK: - TEST GROUP B: Persistence Preserves Timestamps

    /// Test that neighbor timestamps are preserved correctly through persistence.
    func testPersistencePreservesNeighborTimestamps() throws {
        // Arrange: Create neighbors with specific timestamps
        let neighbor1 = makeNeighbor(call: "W1ABC", quality: 200, lastSeen: baseTime)
        let neighbor2 = makeNeighbor(call: "W2XYZ", quality: 180, lastSeen: baseTime.addingTimeInterval(-300)) // 5 min ago

        // Act: Save and reload
        try persistence.saveNeighbors([neighbor1, neighbor2], lastPacketID: 100, snapshotTimestamp: baseTime)

        let loaded = try persistence.loadNeighbors()

        // Assert: Timestamps should be preserved
        XCTAssertEqual(loaded.count, 2, "Should load both neighbors")

        let loadedN1 = loaded.first { $0.call == "W1ABC" }
        let loadedN2 = loaded.first { $0.call == "W2XYZ" }

        XCTAssertNotNil(loadedN1)
        XCTAssertNotNil(loadedN2)

        // Verify timestamps are preserved (within 1 second tolerance for floating point conversion)
        XCTAssertEqual(loadedN1!.lastSeen.timeIntervalSince1970, baseTime.timeIntervalSince1970, accuracy: 1.0,
            "Neighbor1 lastSeen should be preserved")
        XCTAssertEqual(loadedN2!.lastSeen.timeIntervalSince1970, baseTime.addingTimeInterval(-300).timeIntervalSince1970, accuracy: 1.0,
            "Neighbor2 lastSeen should be preserved")
    }

    /// Test that route timestamps are handled correctly through persistence.
    func testPersistencePreservesRouteData() throws {
        // Arrange: Create routes
        let route1 = makeRoute(destination: "N0DEST", origin: "W1ABC", quality: 200, path: ["W1ABC"], lastUpdated: baseTime)
        let route2 = makeRoute(destination: "N0OTHER", origin: "W2XYZ", quality: 180, path: ["W2XYZ", "W3REL"], lastUpdated: baseTime.addingTimeInterval(-60))

        // Act: Save and reload
        try persistence.saveRoutes([route1, route2], lastPacketID: 100, snapshotTimestamp: baseTime)

        let loaded = try persistence.loadRoutes()

        // Assert: Routes should be preserved with correct data
        XCTAssertEqual(loaded.count, 2, "Should load both routes")

        let loadedR1 = loaded.first { $0.destination == "N0DEST" }
        let loadedR2 = loaded.first { $0.destination == "N0OTHER" }

        XCTAssertNotNil(loadedR1)
        XCTAssertNotNil(loadedR2)

        XCTAssertEqual(loadedR1!.quality, 200)
        XCTAssertEqual(loadedR1!.origin, "W1ABC")
        XCTAssertEqual(loadedR2!.quality, 180)
        XCTAssertEqual(loadedR2!.path, ["W2XYZ", "W3REL"])
    }

    /// Test that link stat timestamps are preserved correctly.
    func testPersistencePreservesLinkStatTimestamps() throws {
        // Arrange: Create link stats with specific timestamps
        let stat1 = makeLinkStat(from: "W1ABC", to: "N0CAL", quality: 200, lastUpdated: baseTime)
        let stat2 = makeLinkStat(from: "W2XYZ", to: "N0CAL", quality: 180, lastUpdated: baseTime.addingTimeInterval(-600))

        // Act: Save and reload
        try persistence.saveLinkStats([stat1, stat2], lastPacketID: 100, snapshotTimestamp: baseTime)

        let loaded = try persistence.loadLinkStats()

        // Assert: Timestamps should be preserved
        XCTAssertEqual(loaded.count, 2, "Should load both link stats")

        let loadedS1 = loaded.first { $0.fromCall == "W1ABC" }
        let loadedS2 = loaded.first { $0.fromCall == "W2XYZ" }

        XCTAssertNotNil(loadedS1)
        XCTAssertNotNil(loadedS2)

        XCTAssertEqual(loadedS1!.lastUpdated.timeIntervalSince1970, baseTime.timeIntervalSince1970, accuracy: 1.0,
            "Stat1 lastUpdated should be preserved")
        XCTAssertEqual(loadedS2!.lastUpdated.timeIntervalSince1970, baseTime.addingTimeInterval(-600).timeIntervalSince1970, accuracy: 1.0,
            "Stat2 lastUpdated should be preserved")
    }

    // MARK: - TEST GROUP B: Persistence Normalizes Invalid Timestamps

    /// Test that invalid timestamps (NULL/zero/distantPast) are normalized on load.
    ///
    /// UX expectation: Broken timestamps should NEVER show as "739648d ago"
    func testPersistenceNormalizesInvalidTimestamps() throws {
        // Arrange: Insert link stats directly with invalid timestamps
        try dbQueue.write { db in
            // Clear existing data
            try db.execute(sql: "DELETE FROM link_stats")
            try db.execute(sql: "DELETE FROM netrom_snapshot_meta")

            // Insert a record with Date.distantPast (which is year 0001)
            let distantPast = Date.distantPast.timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO link_stats (fromCall, toCall, quality, lastUpdated, dfEstimate, drEstimate, dupCount, ewmaQuality, obsCount)
                VALUES ('W1INVALID', 'N0CAL', 200, \(distantPast), 0.9, NULL, 0, 200, 10)
            """)

            // Insert a record with zero timestamp
            try db.execute(sql: """
                INSERT INTO link_stats (fromCall, toCall, quality, lastUpdated, dfEstimate, drEstimate, dupCount, ewmaQuality, obsCount)
                VALUES ('W2ZERO', 'N0CAL', 180, 0, 0.8, NULL, 0, 180, 5)
            """)

            // Add metadata so load() works
            try db.execute(sql: """
                INSERT INTO netrom_snapshot_meta (id, lastPacketID, configHash, snapshotTimestamp)
                VALUES (1, 100, NULL, \(baseTime.timeIntervalSince1970))
            """)
        }

        // Act: Load through persistence (which should normalize)
        let now = baseTime.addingTimeInterval(120)
        let loaded = try persistence.loadLinkStats(now: now)

        // Assert: Invalid timestamps should be normalized
        // They should NOT be Date.distantPast or epoch 0
        for stat in loaded {
            // Should not be Date.distantPast (which is ~2000 years ago)
            XCTAssertGreaterThan(stat.lastUpdated.timeIntervalSince1970, 0,
                "Timestamp for \(stat.fromCall) should not be zero or negative")

            // Age from "now" should be reasonable (< 1 year into the future or past)
            let ageFromNow = abs(now.timeIntervalSince(stat.lastUpdated))
            XCTAssertLessThan(ageFromNow, 365 * 24 * 60 * 60,
                "Timestamp for \(stat.fromCall) should be normalized to current time (got \(Int(ageFromNow / 86400))d difference)")

            // Should not show "739648d ago" - that's Date.distantPast
            let distantPastAge = now.timeIntervalSince(Date.distantPast)
            XCTAssertNotEqual(stat.lastUpdated.timeIntervalSince1970, Date.distantPast.timeIntervalSince1970, accuracy: 1.0,
                "Timestamp for \(stat.fromCall) should not be Date.distantPast")
        }
    }

    /// Test that valid historical timestamps are preserved (not normalized away).
    func testPersistencePreservesValidHistoricalTimestamps() throws {
        let historical = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01T00:00:00Z

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM link_stats")
            try db.execute(sql: "DELETE FROM netrom_snapshot_meta")

            try db.execute(sql: """
                INSERT INTO link_stats (fromCall, toCall, quality, lastUpdated, dfEstimate, drEstimate, dupCount, ewmaQuality, obsCount)
                VALUES ('W1HIST', 'N0CAL', 200, \(historical.timeIntervalSince1970), 0.9, NULL, 0, 200, 10)
            """)

            try db.execute(sql: """
                INSERT INTO netrom_snapshot_meta (id, lastPacketID, configHash, snapshotTimestamp)
                VALUES (1, 100, NULL, \(baseTime.timeIntervalSince1970))
            """)
        }

        let loaded = try persistence.loadLinkStats(now: baseTime)
        let stat = try XCTUnwrap(loaded.first { $0.fromCall == "W1HIST" })
        XCTAssertEqual(stat.lastUpdated.timeIntervalSince1970, historical.timeIntervalSince1970, accuracy: 1.0,
            "Valid historical timestamps should be preserved")
    }

    /// Test that neighbor timestamps are not corrupted through full snapshot cycle.
    func testFullSnapshotCyclePreservesTimestamps() throws {
        // Arrange: Create a full snapshot
        let neighbors = [
            makeNeighbor(call: "W1ABC", quality: 200, lastSeen: baseTime),
            makeNeighbor(call: "W2XYZ", quality: 180, lastSeen: baseTime.addingTimeInterval(-450))
        ]
        let routes = [
            makeRoute(destination: "N0DEST", origin: "W1ABC", quality: 200, path: ["W1ABC"], lastUpdated: baseTime)
        ]
        let linkStats = [
            makeLinkStat(from: "W1ABC", to: "N0CAL", quality: 200, lastUpdated: baseTime)
        ]

        // Act: Save full snapshot
        try persistence.saveSnapshot(
            neighbors: neighbors,
            routes: routes,
            linkStats: linkStats,
            lastPacketID: 100,
            configHash: "test_hash",
            snapshotTimestamp: baseTime
        )

        // Load at a later time
        let loadTime = baseTime.addingTimeInterval(300) // 5 min later
        let loaded = try persistence.load(now: loadTime, expectedConfigHash: "test_hash")

        XCTAssertNotNil(loaded, "Should load persisted state")

        // Assert: Neighbor timestamps preserved
        let loadedNeighbor = loaded!.neighbors.first { $0.call == "W1ABC" }
        XCTAssertNotNil(loadedNeighbor)
        XCTAssertEqual(loadedNeighbor!.lastSeen.timeIntervalSince1970, baseTime.timeIntervalSince1970, accuracy: 1.0,
            "Neighbor timestamp should be preserved through snapshot cycle")

        // Assert: LinkStat timestamps preserved
        let loadedStat = loaded!.linkStats.first { $0.fromCall == "W1ABC" }
        XCTAssertNotNil(loadedStat)
        XCTAssertEqual(loadedStat!.lastUpdated.timeIntervalSince1970, baseTime.timeIntervalSince1970, accuracy: 1.0,
            "LinkStat timestamp should be preserved through snapshot cycle")
    }

    // MARK: - Freshness After Persistence Load

    /// Test that freshness calculations work correctly after loading from persistence.
    func testFreshnessCalculationAfterLoad() throws {
        // Arrange: Save neighbor at baseTime
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)
        try persistence.saveNeighbors([neighbor], lastPacketID: 100, snapshotTimestamp: baseTime)

        // Act: Load at baseTime + 5 min (end of plateau)
        let loadTime = baseTime.addingTimeInterval(plateau)
        let loaded = try persistence.loadNeighbors()

        XCTAssertEqual(loaded.count, 1)
        let loadedNeighbor = loaded[0]

        // Calculate freshness at load time
        let freshness = loadedNeighbor.freshness(now: loadTime, ttl: neighborTTL, plateau: plateau)

        // Assert: Freshness should be ~95% at end of plateau
        XCTAssertEqual(freshness, 0.95, accuracy: 0.02,
            "Freshness should be ~95% at end of plateau after load")
    }

    /// Test that expired entries return 0% freshness after load.
    func testExpiredEntriesAfterLoad() throws {
        // Arrange: Save neighbor at baseTime
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)
        try persistence.saveNeighbors([neighbor], lastPacketID: 100, snapshotTimestamp: baseTime)

        // Act: Load at baseTime + TTL * 2 (well past expiry)
        let loadTime = baseTime.addingTimeInterval(neighborTTL * 2)
        let loaded = try persistence.loadNeighbors()

        XCTAssertEqual(loaded.count, 1)
        let loadedNeighbor = loaded[0]

        // Calculate freshness at load time
        let freshness = loadedNeighbor.freshness(now: loadTime, ttl: neighborTTL, plateau: plateau)

        // Assert: Freshness should be 0% (expired)
        XCTAssertEqual(freshness, 0.0, accuracy: 0.01,
            "Freshness should be 0% when past TTL after load")
    }

    // MARK: - Display Integration

    /// Test that freshness display strings work correctly after persistence load.
    func testFreshnessDisplayAfterLoad() throws {
        // Arrange: Save with known timestamp
        let neighbor = makeNeighbor(call: "W1DISP", quality: 200, lastSeen: baseTime)
        try persistence.saveNeighbors([neighbor], lastPacketID: 100, snapshotTimestamp: baseTime)

        // Load
        let loaded = try persistence.loadNeighbors()
        XCTAssertEqual(loaded.count, 1)
        let loadedNeighbor = loaded[0]

        // At various times (using freshness model)
        let displayAtT0 = loadedNeighbor.freshnessDisplayString(now: baseTime, ttl: neighborTTL, plateau: plateau)
        XCTAssertEqual(displayAtT0, "100%", "At T0, display should be '100%'")

        let displayAtPlateau = loadedNeighbor.freshnessDisplayString(now: baseTime.addingTimeInterval(plateau), ttl: neighborTTL, plateau: plateau)
        XCTAssertEqual(displayAtPlateau, "95%", "At end of plateau, display should be '95%'")

        let displayAtTTL = loadedNeighbor.freshnessDisplayString(now: baseTime.addingTimeInterval(neighborTTL), ttl: neighborTTL, plateau: plateau)
        XCTAssertEqual(displayAtTTL, "0%", "At TTL, display should be '0%'")
    }

    // MARK: - Legacy Decay Tests (Deprecated API Compatibility)

    /// Test that deprecated decay methods still work for backwards compatibility.
    func testLegacyDecayMethodsStillWork() throws {
        let neighbor = makeNeighbor(call: "W1LEGACY", quality: 200, lastSeen: baseTime)
        try persistence.saveNeighbors([neighbor], lastPacketID: 100, snapshotTimestamp: baseTime)

        let loaded = try persistence.loadNeighbors()
        XCTAssertEqual(loaded.count, 1)
        let loadedNeighbor = loaded[0]

        // The deprecated decayFraction method should still work (uses linear decay)
        let legacyTTL: TimeInterval = 15 * 60
        let halfTime = baseTime.addingTimeInterval(legacyTTL / 2)
        let decay = loadedNeighbor.decayFraction(now: halfTime, ttl: legacyTTL)

        XCTAssertEqual(decay, 0.5, accuracy: 0.05,
            "Legacy decayFraction should still work with linear decay")
    }
}
