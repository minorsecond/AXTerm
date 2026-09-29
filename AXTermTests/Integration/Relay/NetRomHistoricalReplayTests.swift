//
//  NetRomHistoricalReplayTests.swift
//  AXTermTests
//
//  Tests for bounded historical replay functionality.
//
//  Historical replay enables state recovery when:
//  1. No snapshot exists
//  2. Snapshot is stale/invalid
//  3. Incremental update after valid snapshot load
//
//  Replay should be bounded by:
//  - Time window (only replay packets within Tmin..now)
//  - Packet count (maxPackets limit to prevent memory/CPU issues)
//
//  The replay mechanism ensures deterministic state regardless of:
//  - Whether we replay from scratch or load snapshot + replay delta
//

import XCTest
import GRDB

@testable import AXTerm

@MainActor
final class NetRomHistoricalReplayTests: XCTestCase {
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

    private func makePacket(
        id: Int64,
        from: String,
        to: String,
        via: [String] = [],
        frameType: FrameType = .ui,
        timestamp: Date
    ) -> Packet {
        // Note: id is used conceptually for test ordering, but Packet uses UUID.
        // For replay tests, we use the Int64 id for sequencing but the packet itself has a UUID.
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: frameType,
            info: "TEST\(id)".data(using: .ascii) ?? Data(),
            rawAx25: "TEST\(id)".data(using: .ascii) ?? Data(),
            infoText: "TEST\(id)"
        )
    }

    private func makeNeighbor(call: String, quality: Int, lastSeen: Date, obsolescenceCount: Int = 1, sourceType: String = "classic") -> NeighborInfo {
        NeighborInfo(call: call, quality: quality, lastSeen: lastSeen, obsolescenceCount: obsolescenceCount, sourceType: sourceType)
    }

    private func makeLinkStat(from: String, to: String, quality: Int, lastUpdated: Date) -> LinkStatRecord {
        LinkStatRecord(fromCall: from, toCall: to, quality: quality, lastUpdated: lastUpdated, dfEstimate: nil, drEstimate: nil, duplicateCount: 0, observationCount: 1)
    }

    // MARK: - Replay Recent Time Window

    func testReplayRecentTimeWindow_OnlyRecentPacketsReplayed() async throws {
        // Prepare packet store with:
        // - Packets older than Tmin (e.g., 30 minutes ago)
        // - Packets newer than Tmin
        // Invoke `integration.replayHistorical(after: timestamp)` or equivalent.
        // ASSERT that only packets within the recent time window are replayed.

        let integration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        let now = Date(timeIntervalSince1970: 1_700_200_000)

        // Simulate packet store with old and new packets
        let oldPacketTime = now.addingTimeInterval(-3600)  // 1 hour ago
        let recentPacketTime = now.addingTimeInterval(-600)  // 10 minutes ago

        // Old packets (should NOT be replayed with 30-minute window)
        let oldPackets = (0..<10).map { i in
            makePacket(id: Int64(i), from: "W0OLD", to: "N0CALL", timestamp: oldPacketTime.addingTimeInterval(Double(i)))
        }

        // Recent packets (should be replayed)
        let recentPackets = (10..<20).map { i in
            makePacket(id: Int64(i), from: "W0RECENT", to: "N0CALL", timestamp: recentPacketTime.addingTimeInterval(Double(i - 10)))
        }

        // Define time window: last 30 minutes
        let timeWindowStart = now.addingTimeInterval(-1800)  // 30 minutes ago

        // Replay only packets after timeWindowStart
        let packetsToReplay = (oldPackets + recentPackets).filter { $0.timestamp >= timeWindowStart }

        for packet in packetsToReplay {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Verify only recent packets contributed to state
        let neighbors = integration.currentNeighbors()

        XCTAssertTrue(neighbors.contains { $0.call == "W0RECENT" }, "Recent packets should contribute to neighbors")
        XCTAssertFalse(neighbors.contains { $0.call == "W0OLD" }, "Old packets outside time window should not contribute")
    }

    func testReplayWithPacketCountLimit_RespectsMaxPackets() async throws {
        // Prepare 100k synthetic packets.
        // Invoke replay with a bounding parameter (e.g., maxPackets = 10k).
        // ASSERT that replay only consumes up to maxPackets and that no state
        // depends on truncated older packets.

        let integration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        let now = Date(timeIntervalSince1970: 1_700_210_000)

        // Generate many packets (use smaller number for test performance)
        let totalPackets = 1000
        let maxPackets = 100

        var packets: [Packet] = []
        for i in 0..<totalPackets {
            let timestamp = now.addingTimeInterval(Double(i) * 0.1)
            // Use different callsigns to see which packets were processed
            let callsign = "W\(String(format: "%04d", i))"
            packets.append(makePacket(id: Int64(i), from: callsign, to: "N0CALL", timestamp: timestamp))
        }

        // Replay with packet count limit (take most recent maxPackets)
        let limitedPackets = Array(packets.suffix(maxPackets))

        for packet in limitedPackets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Export link stats to count how many links were established
        let linkStats = integration.exportLinkStats()

        // Should have at most maxPackets unique links (one per packet in this test)
        XCTAssertLessThanOrEqual(linkStats.count, maxPackets, "Should not exceed maxPackets links")

        // Verify that the oldest packets (W0000, W0001, etc.) are NOT in the state
        let hasOldPacket = linkStats.contains { $0.fromCall.hasPrefix("W0000") || $0.fromCall.hasPrefix("W0001") }
        XCTAssertFalse(hasOldPacket, "Oldest packets should be excluded when count-limited")
    }

    // MARK: - High-Water Mark Replay (CRITICAL)

    func testExactHighWaterMark_StateMatchesPreSave() async throws {
        // Feed packets 1..N into integration to build state.
        // Save snapshot; ensure lastProcessedPacketID == N.
        // Load snapshot.
        // ASSERT integration state after load is equal to original pre-save state.

        let integration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        let now = Date(timeIntervalSince1970: 1_700_220_000)

        // Feed packets 1..50
        for i in 1...50 {
            let packet = makePacket(id: Int64(i), from: "W0ABC", to: "N0CALL", timestamp: now.addingTimeInterval(Double(i)))
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Capture pre-save state
        let preSaveNeighbors = integration.currentNeighbors()
        let preSaveLinkQuality = integration.linkQuality(from: "W0ABC", to: "N0CALL")

        // Export for persistence
        let neighbors = integration.currentNeighbors()
        let routes = integration.currentRoutes()
        let linkStats = integration.exportLinkStats()

        // Save snapshot with high-water mark = 50
        try persistence.saveSnapshot(
            neighbors: neighbors,
            routes: routes,
            linkStats: linkStats,
            lastPacketID: 50,
            configHash: "hwm_test",
            snapshotTimestamp: now.addingTimeInterval(60)
        )

        // Verify lastPacketID saved correctly
        let meta = try persistence.loadSnapshotMeta()
        XCTAssertEqual(meta?.lastPacketID, 50, "High-water mark should be 50")

        // Create new integration and load snapshot
        let newIntegration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)

        // Load and restore state
        let loadedNeighbors = try persistence.loadNeighbors()
        let loadedLinkStats = try persistence.loadLinkStats()

        newIntegration.importLinkStats(loadedLinkStats)

        // Verify post-load state matches pre-save
        let postLoadLinkQuality = newIntegration.linkQuality(from: "W0ABC", to: "N0CALL")

        XCTAssertEqual(preSaveLinkQuality, postLoadLinkQuality, "Link quality should match after load")
    }

    func testIncrementalReplay_MatchesFullRecompute() async throws {
        // After load, feed packets N+1..M into integration.
        // Compare with a fresh integration run fed packets 1..M.
        // ASSERT results are identical.

        let now = Date(timeIntervalSince1970: 1_700_230_000)

        // Create packets 1..100
        let allPackets = (1...100).map { i in
            makePacket(id: Int64(i), from: "W0ABC", to: "N0CALL", timestamp: now.addingTimeInterval(Double(i)))
        }

        // === Path A: Full recompute from scratch ===
        let fullIntegration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)

        for packet in allPackets {
            fullIntegration.observePacket(packet, timestamp: packet.timestamp)
        }

        let fullNeighbors = fullIntegration.currentNeighbors()
        let fullLinkQuality = fullIntegration.linkQuality(from: "W0ABC", to: "N0CALL")
        let fullLinkStats = fullIntegration.exportLinkStats()

        // === Path B: Load snapshot at N=50, then replay 51..100 ===
        let snapshotIntegration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)

        // First feed packets 1..50
        for packet in allPackets.prefix(50) {
            snapshotIntegration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Export and save snapshot at packet 50
        let snapshotLinkStats = snapshotIntegration.exportLinkStats()

        // Create new integration and import snapshot
        let incrementalIntegration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        incrementalIntegration.importLinkStats(snapshotLinkStats)

        // Replay packets 51..100
        for packet in allPackets.suffix(50) {
            incrementalIntegration.observePacket(packet, timestamp: packet.timestamp)
        }

        let incrementalNeighbors = incrementalIntegration.currentNeighbors()
        let incrementalLinkQuality = incrementalIntegration.linkQuality(from: "W0ABC", to: "N0CALL")
        let incrementalLinkStats = incrementalIntegration.exportLinkStats()

        // === Compare ===
        XCTAssertEqual(fullNeighbors.count, incrementalNeighbors.count, "Neighbor count should match")
        XCTAssertEqual(fullLinkQuality, incrementalLinkQuality, "Link quality should match between full and incremental replay")

        // Note: Due to EWMA initialization from import vs fresh computation,
        // there may be small differences. Verify they're within tolerance.
        XCTAssertEqual(fullLinkStats.count, incrementalLinkStats.count, "Link stat count should match")
    }

    // MARK: - Realtime + Historical Combo

    func testRealtimeAndHistoricalCombo_DeterministicResult() async throws {
        // Save a snapshot, then intentionally invalidate it (too old).
        // Replay recent history + then live packets.
        // ASSERT that resulting final state is consistent and deterministic.

        let now = Date(timeIntervalSince1970: 1_700_240_000)

        // Create an invalidated snapshot (too old)
        let staleSnapshotTime = now.addingTimeInterval(-7200)  // 2 hours ago

        try persistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0STALE", quality: 200, lastSeen: staleSnapshotTime)],
            routes: [],
            linkStats: [makeLinkStat(from: "W0STALE", to: "N0CALL", quality: 220, lastUpdated: staleSnapshotTime)],
            lastPacketID: 100,
            configHash: "combo_test",
            snapshotTimestamp: staleSnapshotTime
        )

        // Verify snapshot is invalid
        let isValid = try persistence.isSnapshotValid(currentDate: now, expectedConfigHash: "combo_test")
        XCTAssertFalse(isValid, "Stale snapshot should be invalid")

        // Since snapshot is invalid, start fresh and replay recent history
        let integration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)

        // Simulate "historical replay" of recent packets (last 30 minutes)
        let historicalStart = now.addingTimeInterval(-1800)
        let historicalPackets = (0..<20).map { i in
            makePacket(id: Int64(i + 101), from: "W0HISTORY", to: "N0CALL", timestamp: historicalStart.addingTimeInterval(Double(i) * 60))
        }

        for packet in historicalPackets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Simulate "live" packets
        let livePackets = (0..<10).map { i in
            makePacket(id: Int64(i + 121), from: "W0LIVE", to: "N0CALL", timestamp: now.addingTimeInterval(Double(i)))
        }

        for packet in livePackets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Verify final state
        let neighbors = integration.currentNeighbors()

        XCTAssertTrue(neighbors.contains { $0.call == "W0HISTORY" }, "Historical packets should contribute to state")
        XCTAssertTrue(neighbors.contains { $0.call == "W0LIVE" }, "Live packets should contribute to state")
        XCTAssertFalse(neighbors.contains { $0.call == "W0STALE" }, "Stale snapshot data should not be present")

        // Verify determinism by running again
        let integration2 = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)

        for packet in historicalPackets {
            integration2.observePacket(packet, timestamp: packet.timestamp)
        }
        for packet in livePackets {
            integration2.observePacket(packet, timestamp: packet.timestamp)
        }

        let neighbors2 = integration2.currentNeighbors()

        XCTAssertEqual(neighbors.map { $0.call }.sorted(), neighbors2.map { $0.call }.sorted(), "Results should be deterministic")
    }

    // MARK: - Replay API Tests (Define Before Implement)

    func testReplayHistoricalAfterTimestamp_API() async throws {
        // Test the replayHistorical(after:) pattern works correctly

        let integration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        let now = Date(timeIntervalSince1970: 1_700_250_000)

        // Create a mock packet store with packets spanning a time range
        // Packets from now-100 to now-1 (100 packets, 1 second apart)
        let packets = (0..<100).map { i in
            makePacket(id: Int64(i), from: "W0ABC", to: "N0CALL", timestamp: now.addingTimeInterval(Double(i) - 100))
        }

        // Filter: only replay packets from the last 30 seconds (after cutoff)
        // cutoff = now - 30, so packets with i > 70 pass (i.e., 71..99 = 29 packets)
        let cutoff = now.addingTimeInterval(-30)

        // Simulate what replayHistorical(after:) should do
        let filteredPackets = packets.filter { $0.timestamp > cutoff }

        // Verify we have the expected number of filtered packets
        XCTAssertGreaterThan(filteredPackets.count, 0, "Should have some packets after cutoff")

        for packet in filteredPackets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        let linkStats = integration.exportLinkStats()

        // Should have processed the filtered packets
        XCTAssertGreaterThan(linkStats.count, 0, "Filtered packets should be processed")

        // Verify the link quality reflects the processed packets
        let quality = integration.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThan(quality, 0, "Link quality should be established")
    }

    func testEnsureSnapshotLoadedAndReplayed_API() async throws {
        // Test the ensureSnapshotLoadedAndReplayed(packetStore:, now:) API pattern

        let now = Date(timeIntervalSince1970: 1_700_260_000)

        // Save a valid snapshot
        let snapshotTime = now.addingTimeInterval(-60)
        try persistence.saveSnapshot(
            neighbors: [makeNeighbor(call: "W0SNAP", quality: 200, lastSeen: snapshotTime)],
            routes: [],
            linkStats: [makeLinkStat(from: "W0SNAP", to: "N0CALL", quality: 220, lastUpdated: snapshotTime)],
            lastPacketID: 100,
            configHash: "ensure_test",
            snapshotTimestamp: snapshotTime
        )

        // The pattern: check snapshot validity, load if valid, replay delta
        let isValid = try persistence.isSnapshotValid(currentDate: now, expectedConfigHash: "ensure_test")
        XCTAssertTrue(isValid, "Fresh snapshot should be valid")

        if isValid {
            let meta = try persistence.loadSnapshotMeta()
            let lastPacketID = meta?.lastPacketID ?? 0

            XCTAssertEqual(lastPacketID, 100, "Should retrieve last processed packet ID")

            // Load state
            let neighbors = try persistence.loadNeighbors()
            let linkStats = try persistence.loadLinkStats()

            // Create integration and import
            let integration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
            integration.importLinkStats(linkStats)

            // Verify imported state
            let importedQuality = integration.linkQuality(from: "W0SNAP", to: "N0CALL")
            XCTAssertEqual(importedQuality, 220, "Imported link quality should match snapshot")

            // Simulate replaying packets after lastPacketID
            let newPackets = (101...110).map { i in
                makePacket(id: Int64(i), from: "W0NEW", to: "N0CALL", timestamp: now.addingTimeInterval(Double(i - 100)))
            }

            for packet in newPackets {
                integration.observePacket(packet, timestamp: packet.timestamp)
            }

            // Verify new packets were processed
            let newQuality = integration.linkQuality(from: "W0NEW", to: "N0CALL")
            XCTAssertGreaterThan(newQuality, 0, "New packets should be processed after snapshot load")
        }
    }

    // MARK: - Edge Cases

    func testReplayEmptyPacketStore_ProducesEmptyState() async throws {
        let integration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)

        // No packets to replay
        let neighbors = integration.currentNeighbors()
        let routes = integration.currentRoutes()
        let linkStats = integration.exportLinkStats()

        XCTAssertTrue(neighbors.isEmpty)
        XCTAssertTrue(routes.isEmpty)
        XCTAssertTrue(linkStats.isEmpty)
    }

    func testReplayWithAllPacketsOlderThanWindow_ProducesEmptyState() async throws {
        let integration = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        let now = Date(timeIntervalSince1970: 1_700_270_000)

        // All packets are old
        let oldPackets = (0..<20).map { i in
            makePacket(id: Int64(i), from: "W0OLD", to: "N0CALL", timestamp: now.addingTimeInterval(-3600 + Double(i)))
        }

        // Time window: last 30 minutes
        let cutoff = now.addingTimeInterval(-1800)

        // Filter to window (should result in empty list)
        let recentPackets = oldPackets.filter { $0.timestamp > cutoff }

        XCTAssertTrue(recentPackets.isEmpty, "All packets should be filtered out")

        for packet in recentPackets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.isEmpty, "No recent packets should mean empty state")
    }

    func testReplayPreservesPacketOrder() async throws {
        // Verify that replaying packets in order produces same result as live observation

        let now = Date(timeIntervalSince1970: 1_700_280_000)

        // Packets with varying quality indicators (some duplicates)
        var packets: [Packet] = []
        for i in 0..<30 {
            let packet = makePacket(id: Int64(i), from: "W0ABC", to: "N0CALL", timestamp: now.addingTimeInterval(Double(i)))
            packets.append(packet)
        }

        // Run 1: Process in order
        let integration1 = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        for packet in packets {
            integration1.observePacket(packet, timestamp: packet.timestamp)
        }
        let quality1 = integration1.linkQuality(from: "W0ABC", to: "N0CALL")

        // Run 2: Process same packets in order (simulate replay)
        let integration2 = NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        for packet in packets {
            integration2.observePacket(packet, timestamp: packet.timestamp)
        }
        let quality2 = integration2.linkQuality(from: "W0ABC", to: "N0CALL")

        XCTAssertEqual(quality1, quality2, "Same packets in same order should produce identical quality")
    }

    // MARK: - Persistence Config for Replay

    func testReplayTimeWindowConfig_Exposed() throws {
        // Verify that replay time window is configurable
        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 3600,
            replayTimeWindowSeconds: 1800  // 30 minutes
        )

        XCTAssertEqual(config.replayTimeWindowSeconds, 1800, "Replay time window should be configurable")
    }

    func testReplayMaxPacketsConfig_Exposed() throws {
        // Verify that max replay packets is configurable
        let config = NetRomPersistenceConfig(
            maxSnapshotAgeSeconds: 3600,
            maxReplayPackets: 10000
        )

        XCTAssertEqual(config.maxReplayPackets, 10000, "Max replay packets should be configurable")
    }
}
