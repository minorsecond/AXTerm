//
//  NetRomPersistence.swift
//  AXTerm
//
//  SQLite persistence for NET/ROM routing state using GRDB.
//
//  Design principles:
//  - Persist DERIVED state (neighbors, routes, link stats) for fast startup
//  - saveSnapshot() uses a SINGLE transaction for atomicity
//  - High-water mark (lastProcessedPacketID) enables replay of only new packets
//  - TTL invalidation: maxSnapshotAgeSeconds constant in config
//  - Config hash invalidation: if config changes, reject stale snapshot
//
//  Deterministic ordering:
//  - Neighbors: sorted by desc quality, then callsign
//  - Routes: sorted by destination asc, then quality desc
//  - Link stats: sorted by fromCall, then toCall
//

import Foundation
import GRDB

/// Configuration for NET/ROM persistence.
struct NetRomPersistenceConfig {
    let maxSnapshotAgeSeconds: TimeInterval

    /// TTL for individual neighbor entries (seconds). Neighbors older than this are decayed on load.
    let neighborTTLSeconds: TimeInterval

    /// TTL for individual route entries (seconds). Routes older than this are removed on load.
    let routeTTLSeconds: TimeInterval

    /// TTL for link stat entries (seconds). Link stats older than this are filtered on load.
    let linkStatTTLSeconds: TimeInterval

    /// Time window for historical replay (seconds). Only replay packets within this window.
    let replayTimeWindowSeconds: TimeInterval

    /// Maximum number of packets to replay when restoring state.
    let maxReplayPackets: Int

    init(
        maxSnapshotAgeSeconds: TimeInterval = 3600,
        neighborTTLSeconds: TimeInterval = 1800,
        routeTTLSeconds: TimeInterval = 1800,
        linkStatTTLSeconds: TimeInterval = 1800,
        replayTimeWindowSeconds: TimeInterval = 1800,
        maxReplayPackets: Int = 10000
    ) {
        self.maxSnapshotAgeSeconds = maxSnapshotAgeSeconds
        self.neighborTTLSeconds = neighborTTLSeconds
        self.routeTTLSeconds = routeTTLSeconds
        self.linkStatTTLSeconds = linkStatTTLSeconds
        self.replayTimeWindowSeconds = replayTimeWindowSeconds
        self.maxReplayPackets = maxReplayPackets
    }

    static let `default` = NetRomPersistenceConfig()
}

/// Persisted state returned by load(now:).
/// Contains neighbors, routes, and link stats with stale entries filtered/decayed.
struct PersistedState {
    let neighbors: [NeighborInfo]
    let routes: [RouteInfo]
    let linkStats: [LinkStatRecord]
    let lastPacketID: Int64
}

/// Metadata about a persisted snapshot.
struct SnapshotMeta: Equatable {
    let lastPacketID: Int64
    let configHash: String?
    let snapshotTimestamp: Date
}

/// GRDB record for neighbors table.
private struct NeighborRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "netrom_neighbors"

    let call: String
    let quality: Int
    let lastSeen: Double  // TimeInterval since 1970
    let obsolescenceCount: Int
    let sourceType: String
}

/// GRDB record for routes table.
private struct RouteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "netrom_routes"

    let destination: String
    let origin: String
    let quality: Int
    let pathJson: String
    let sourceType: String
    let lastUpdate: Double  // TimeInterval since 1970
}

/// GRDB record for link stats table.
private struct LinkStatDBRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "link_stats"

    let fromCall: String
    let toCall: String
    let quality: Int
    let lastUpdated: Double  // TimeInterval since 1970
    let dfEstimate: Double?
    let drEstimate: Double?
    let dupCount: Int
    let ewmaQuality: Int
    let obsCount: Int  // observation count for evidence rehydration
}

/// GRDB record for snapshot metadata.
private struct SnapshotMetaRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "netrom_snapshot_meta"

    let id: Int = 1  // Single row
    let lastPacketID: Int64
    let configHash: String?
    let snapshotTimestamp: Double  // TimeInterval since 1970
}

/// GRDB record for tracking per-origin broadcast intervals.
/// Used for adaptive stale threshold calculation.
private struct OriginIntervalRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "netrom_origin_intervals"

    let origin: String  // Primary key
    let estimatedIntervalSeconds: Double
    let lastBroadcastTimestamp: Double  // TimeInterval since 1970
    let broadcastCount: Int
    let intervalSum: Double  // Sum of intervals for rolling average
}

/// Public struct for origin interval data.
struct OriginIntervalInfo {
    let origin: String
    let estimatedIntervalSeconds: TimeInterval
    let lastBroadcast: Date
    let broadcastCount: Int
}

/// Persistence layer for NET/ROM routing state.
final class NetRomPersistence {
    private let database: DatabaseWriter
    private let config: NetRomPersistenceConfig
    #if DEBUG
    private static var retainedForTests: [NetRomPersistence] = []
    #endif

    init(database: DatabaseWriter, config: NetRomPersistenceConfig = .default) throws {
        self.database = database
        self.config = config
        try createTables()
        #if DEBUG
        Self.retainedForTests.append(self)
        #endif
    }

    // MARK: - Table Creation

    private func createTables() throws {
        try database.write { db in
            try db.create(table: "netrom_neighbors", ifNotExists: true) { t in
                t.column("call", .text).primaryKey()
                t.column("quality", .integer).notNull()
                t.column("lastSeen", .double).notNull()
                t.column("obsolescenceCount", .integer).notNull().defaults(to: 1)
                t.column("sourceType", .text).notNull().defaults(to: "classic")
            }

            try db.create(table: "netrom_routes", ifNotExists: true) { t in
                t.column("destination", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("quality", .integer).notNull()
                t.column("pathJson", .text).notNull()
                t.column("sourceType", .text).notNull().defaults(to: "broadcast")
                t.column("lastUpdate", .double).notNull().defaults(to: 0)
                t.primaryKey(["destination", "origin"])
            }

            try db.create(table: "link_stats", ifNotExists: true) { t in
                t.column("fromCall", .text).notNull()
                t.column("toCall", .text).notNull()
                t.column("quality", .integer).notNull()
                t.column("lastUpdated", .double).notNull()
                t.column("dfEstimate", .double)
                t.column("drEstimate", .double)
                t.column("dupCount", .integer).notNull().defaults(to: 0)
                t.column("ewmaQuality", .integer).notNull().defaults(to: 0)
                t.column("obsCount", .integer).notNull().defaults(to: 0)  // observation count for evidence rehydration
                t.primaryKey(["fromCall", "toCall"])
            }

            try db.create(table: "netrom_snapshot_meta", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey()
                t.column("lastPacketID", .integer).notNull()
                t.column("configHash", .text)
                t.column("snapshotTimestamp", .double).notNull()
            }

            // Origin broadcast interval tracking for adaptive stale threshold
            try db.create(table: "netrom_origin_intervals", ifNotExists: true) { t in
                t.column("origin", .text).primaryKey()
                t.column("estimatedIntervalSeconds", .double).notNull().defaults(to: 0)
                t.column("lastBroadcastTimestamp", .double).notNull()
                t.column("broadcastCount", .integer).notNull().defaults(to: 1)
                t.column("intervalSum", .double).notNull().defaults(to: 0)
            }

            // Migration: Add obsCount column to existing link_stats tables
            // This handles databases created before the obsCount column was added
            try migrateAddObsCountColumn(db)
        }
    }

    /// Adds the obsCount column to link_stats if it doesn't exist.
    /// For existing rows, defaults to 1 (assume at least one observation) to avoid
    /// treating valid persisted links as having zero evidence.
    private func migrateAddObsCountColumn(_ db: Database) throws {
        // Check if obsCount column already exists
        let columns = try db.columns(in: "link_stats")
        let hasObsCount = columns.contains { $0.name == "obsCount" }

        if !hasObsCount {
            // Add the column with a default of 1 for existing rows
            // This ensures old data isn't treated as having zero observations
            try db.execute(sql: "ALTER TABLE link_stats ADD COLUMN obsCount INTEGER NOT NULL DEFAULT 1")

            #if DEBUG
            print("[NETROM:PERSISTENCE] Migrated link_stats table: added obsCount column")
            #endif
        }
    }

    // MARK: - Neighbor Persistence

    func saveNeighbors(
        _ neighbors: [NeighborInfo],
        lastPacketID: Int64,
        configHash: String? = nil,
        snapshotTimestamp: Date = Date()
    ) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM netrom_neighbors")
            for neighbor in neighbors {
                let record = NeighborRecord(
                    call: neighbor.call,
                    quality: neighbor.quality,
                    lastSeen: neighbor.lastSeen.timeIntervalSince1970,
                    obsolescenceCount: neighbor.obsolescenceCount,
                    sourceType: neighbor.sourceType
                )
                try record.insert(db)
            }
            try saveMetaInternal(db: db, lastPacketID: lastPacketID, configHash: configHash, timestamp: snapshotTimestamp)
        }
    }

    func loadNeighbors() throws -> [NeighborInfo] {
        try database.read { db in
            // Deterministic ordering: desc quality, then callsign asc
            let records = try NeighborRecord.order(Column("quality").desc, Column("call").asc).fetchAll(db)
            return records.map { record in
                NeighborInfo(
                    call: record.call,
                    quality: record.quality,
                    lastSeen: Date(timeIntervalSince1970: record.lastSeen),
                    obsolescenceCount: record.obsolescenceCount,
                    sourceType: record.sourceType
                )
            }
        }
    }

    // MARK: - Route Persistence

    func saveRoutes(
        _ routes: [RouteInfo],
        lastPacketID: Int64,
        configHash: String? = nil,
        snapshotTimestamp: Date = Date()
    ) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM netrom_routes")
            for route in routes {
                let pathJson = (try? JSONEncoder().encode(route.path)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let record = RouteRecord(
                    destination: route.destination,
                    origin: route.origin,
                    quality: route.quality,
                    pathJson: pathJson,
                    sourceType: route.sourceType,
                    lastUpdate: route.lastUpdated.timeIntervalSince1970
                )
                try record.insert(db)
            }
            try saveMetaInternal(db: db, lastPacketID: lastPacketID, configHash: configHash, timestamp: snapshotTimestamp)
        }
    }

    func loadRoutes() throws -> [RouteInfo] {
        try database.read { db in
            // Deterministic ordering: destination asc, then quality desc
            let records = try RouteRecord.order(Column("destination").asc, Column("quality").desc).fetchAll(db)
            return records.map { record in
                let path = (try? JSONDecoder().decode([String].self, from: Data(record.pathJson.utf8))) ?? []
                return RouteInfo(
                    destination: record.destination,
                    origin: record.origin,
                    quality: record.quality,
                    path: path,
                    lastUpdated: Date(timeIntervalSince1970: record.lastUpdate),
                    sourceType: record.sourceType
                )
            }
        }
    }

    // MARK: - Link Stats Persistence

    func saveLinkStats(
        _ stats: [LinkStatRecord],
        lastPacketID: Int64,
        configHash: String? = nil,
        snapshotTimestamp: Date = Date()
    ) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM link_stats")
            for stat in stats {
                let record = LinkStatDBRecord(
                    fromCall: stat.fromCall,
                    toCall: stat.toCall,
                    quality: stat.quality,
                    lastUpdated: stat.lastUpdated.timeIntervalSince1970,
                    dfEstimate: stat.dfEstimate,
                    drEstimate: stat.drEstimate,
                    dupCount: stat.duplicateCount,
                    ewmaQuality: stat.quality,
                    obsCount: stat.observationCount  // Persist evidence count for rehydration
                )
                try record.insert(db)
            }
            try saveMetaInternal(db: db, lastPacketID: lastPacketID, configHash: configHash, timestamp: snapshotTimestamp)
        }
    }

    func loadLinkStats(now: Date) throws -> [LinkStatRecord] {
        return try database.read { db in
            // Deterministic ordering: fromCall asc, then toCall asc
            let records = try LinkStatDBRecord.order(Column("fromCall").asc, Column("toCall").asc).fetchAll(db)
            return records.map { record in
                // Sanitize timestamp: reject Date.distantPast, epoch 0, or very old dates
                let rawDate = Date(timeIntervalSince1970: record.lastUpdated)
                let sanitizedDate = Self.sanitizeTimestamp(rawDate, fallback: now)

                return LinkStatRecord(
                    fromCall: record.fromCall,
                    toCall: record.toCall,
                    quality: record.quality,
                    lastUpdated: sanitizedDate,
                    dfEstimate: record.dfEstimate,
                    drEstimate: record.drEstimate,
                    duplicateCount: record.dupCount,
                    observationCount: record.obsCount  // Load persisted evidence count
                )
            }
        }
    }

    func loadLinkStats() throws -> [LinkStatRecord] {
        try loadLinkStats(now: Date())
    }

    /// Sanitize a timestamp - replace truly invalid timestamps with the fallback.
    /// Invalid timestamps are: Date.distantPast (year 0001), epoch 0 (1970), or negative values.
    private static func sanitizeTimestamp(_ date: Date, fallback: Date) -> Date {
        if date == Date.distantPast {
            return fallback
        }
        if date.timeIntervalSince1970 <= 0 {
            return fallback
        }
        return date
    }

    // MARK: - Full Snapshot (Atomic Transaction)

    func saveSnapshot(
        neighbors: [NeighborInfo],
        routes: [RouteInfo],
        linkStats: [LinkStatRecord],
        lastPacketID: Int64,
        configHash: String?,
        snapshotTimestamp: Date = Date()
    ) throws {
        try database.write { db in
            // Clear all tables in single transaction
            try db.execute(sql: "DELETE FROM netrom_neighbors")
            try db.execute(sql: "DELETE FROM netrom_routes")
            try db.execute(sql: "DELETE FROM link_stats")

            // Save neighbors
            for neighbor in neighbors {
                let record = NeighborRecord(
                    call: neighbor.call,
                    quality: neighbor.quality,
                    lastSeen: neighbor.lastSeen.timeIntervalSince1970,
                    obsolescenceCount: neighbor.obsolescenceCount,
                    sourceType: neighbor.sourceType
                )
                try record.insert(db)
            }

            // Save routes
            for route in routes {
                let pathJson = (try? JSONEncoder().encode(route.path)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let record = RouteRecord(
                    destination: route.destination,
                    origin: route.origin,
                    quality: route.quality,
                    pathJson: pathJson,
                    sourceType: route.sourceType,
                    lastUpdate: route.lastUpdated.timeIntervalSince1970
                )
                try record.insert(db)
            }

            // Save link stats
            for stat in linkStats {
                let record = LinkStatDBRecord(
                    fromCall: stat.fromCall,
                    toCall: stat.toCall,
                    quality: stat.quality,
                    lastUpdated: stat.lastUpdated.timeIntervalSince1970,
                    dfEstimate: stat.dfEstimate,
                    drEstimate: stat.drEstimate,
                    dupCount: stat.duplicateCount,
                    ewmaQuality: stat.quality,
                    obsCount: stat.observationCount  // Persist evidence count for rehydration
                )
                try record.insert(db)
            }

            // Save metadata (atomically with data)
            try saveMetaInternal(db: db, lastPacketID: lastPacketID, configHash: configHash, timestamp: snapshotTimestamp)
        }
    }

    // MARK: - Metadata

    func loadSnapshotMeta() throws -> SnapshotMeta? {
        try database.read { db in
            guard let record = try SnapshotMetaRecord.fetchOne(db, key: 1) else { return nil }
            return SnapshotMeta(
                lastPacketID: record.lastPacketID,
                configHash: record.configHash,
                snapshotTimestamp: Date(timeIntervalSince1970: record.snapshotTimestamp)
            )
        }
    }

    func lastProcessedPacketID() throws -> Int64? {
        try loadSnapshotMeta()?.lastPacketID
    }

    // MARK: - Validation

    func isSnapshotValid(currentDate: Date, expectedConfigHash: String?) throws -> Bool {
        guard let meta = try loadSnapshotMeta() else { return false }

        // Check age (TTL invalidation)
        let age = currentDate.timeIntervalSince(meta.snapshotTimestamp)
        if age > config.maxSnapshotAgeSeconds {
            return false
        }

        // Check config hash if provided
        if let expected = expectedConfigHash, meta.configHash != expected {
            return false
        }

        return true
    }

    // MARK: - Unified Load with Decay

    /// Load persisted state with TTL validation and per-entry decay.
    ///
    /// Returns `nil` if:
    /// - No snapshot exists
    /// - Snapshot is older than `maxSnapshotAgeSeconds`
    /// - Config hash doesn't match `expectedConfigHash` (if provided)
    ///
    /// When loading, applies per-entry decay:
    /// - Neighbors with `lastSeen` older than `neighborTTLSeconds` are decayed/dropped
    /// - Routes with stale `lastUpdate` are removed
    /// - LinkStats with `lastUpdated` older than `linkStatTTLSeconds` are filtered
    func load(now: Date, expectedConfigHash: String? = nil) throws -> PersistedState? {
        // First validate snapshot-level freshness
        guard try isSnapshotValid(currentDate: now, expectedConfigHash: expectedConfigHash) else {
            return nil
        }

        guard let meta = try loadSnapshotMeta() else {
            return nil
        }

        // Load and filter/decay entries based on their individual timestamps
        let neighbors = try loadNeighborsWithDecay(now: now)
        let routes = try loadRoutesWithDecay(now: now)
        let linkStats = try loadLinkStatsWithDecay(now: now)

        return PersistedState(
            neighbors: neighbors,
            routes: routes,
            linkStats: linkStats,
            lastPacketID: meta.lastPacketID
        )
    }

    /// Load neighbors with per-entry decay based on lastSeen timestamp.
    private func loadNeighborsWithDecay(now: Date) throws -> [NeighborInfo] {
        let allNeighbors = try loadNeighbors()
        let cutoff = now.addingTimeInterval(-config.neighborTTLSeconds)

        return allNeighbors.compactMap { neighbor -> NeighborInfo? in
            let age = now.timeIntervalSince(neighbor.lastSeen)

            // If within TTL, keep as-is
            if neighbor.lastSeen >= cutoff {
                return neighbor
            }

            // If beyond TTL, apply linear decay
            // decayFactor = 1 - (age / TTL), clamped to [0, 1]
            let decayFactor = max(0, 1 - (age / config.neighborTTLSeconds))
            let decayedQuality = Int(Double(neighbor.quality) * decayFactor)

            // Drop if quality decays to near zero
            if decayedQuality < 10 {
                return nil
            }

            return NeighborInfo(
                call: neighbor.call,
                quality: decayedQuality,
                lastSeen: neighbor.lastSeen,
                obsolescenceCount: neighbor.obsolescenceCount,
                sourceType: neighbor.sourceType
            )
        }
    }

    /// Load routes with per-entry filtering based on lastUpdate.
    private func loadRoutesWithDecay(now: Date) throws -> [RouteInfo] {
        let allRoutes = try loadRoutes()

        let cutoff = now.addingTimeInterval(-config.routeTTLSeconds)

        return allRoutes.filter { $0.lastUpdated >= cutoff }
    }

    /// Load link stats with per-entry filtering based on lastUpdated timestamp.
    private func loadLinkStatsWithDecay(now: Date) throws -> [LinkStatRecord] {
        let allStats = try loadLinkStats(now: now)
        let cutoff = now.addingTimeInterval(-config.linkStatTTLSeconds)

        return allStats.filter { $0.lastUpdated >= cutoff }
    }

    // MARK: - Clear

    func clearAll() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM netrom_neighbors")
            try db.execute(sql: "DELETE FROM netrom_routes")
            try db.execute(sql: "DELETE FROM link_stats")
            try db.execute(sql: "DELETE FROM netrom_snapshot_meta")
            try db.execute(sql: "DELETE FROM netrom_origin_intervals")
        }
    }

    // MARK: - Prune (Retention Policy)

    /// Delete all entries older than the specified retention period.
    /// This is the retention prune job that runs periodically.
    ///
    /// - Parameters:
    ///   - retentionDays: Number of days to retain data. Entries older than this are deleted.
    ///   - now: Current date for calculating cutoff.
    /// - Returns: Tuple with counts of deleted (neighbors, routes, linkStats).
    @discardableResult
    func pruneOldEntries(retentionDays: Int, now: Date = Date()) throws -> (neighbors: Int, routes: Int, linkStats: Int) {
        let cutoffTimestamp = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60).timeIntervalSince1970

        return try database.write { db in
            // Delete old neighbors
            let neighborsBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM netrom_neighbors") ?? 0
            try db.execute(sql: "DELETE FROM netrom_neighbors WHERE lastSeen < ?", arguments: [cutoffTimestamp])
            let neighborsAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM netrom_neighbors") ?? 0
            let neighborsDeleted = neighborsBefore - neighborsAfter

            // Delete old routes
            let routesBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM netrom_routes") ?? 0
            try db.execute(sql: "DELETE FROM netrom_routes WHERE lastUpdate < ?", arguments: [cutoffTimestamp])
            let routesAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM netrom_routes") ?? 0
            let routesDeleted = routesBefore - routesAfter

            // Delete old link stats
            let linkStatsBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM link_stats") ?? 0
            try db.execute(sql: "DELETE FROM link_stats WHERE lastUpdated < ?", arguments: [cutoffTimestamp])
            let linkStatsAfter = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM link_stats") ?? 0
            let linkStatsDeleted = linkStatsBefore - linkStatsAfter

            #if DEBUG
            if neighborsDeleted > 0 || routesDeleted > 0 || linkStatsDeleted > 0 {
                print("[NETROM:PERSISTENCE] Pruned old entries (retention: \(retentionDays) days):")
                print("  - Neighbors: \(neighborsDeleted) deleted")
                print("  - Routes: \(routesDeleted) deleted")
                print("  - Link stats: \(linkStatsDeleted) deleted")
            }
            #endif

            return (neighbors: neighborsDeleted, routes: routesDeleted, linkStats: linkStatsDeleted)
        }
    }

    /// Get counts of all stored entries.
    func getCounts() throws -> (neighbors: Int, routes: Int, linkStats: Int) {
        try database.read { db in
            let neighbors = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM netrom_neighbors") ?? 0
            let routes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM netrom_routes") ?? 0
            let linkStats = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM link_stats") ?? 0
            return (neighbors: neighbors, routes: routes, linkStats: linkStats)
        }
    }

    // MARK: - Origin Broadcast Interval Tracking

    /// Record a broadcast from an origin station.
    /// Updates the estimated broadcast interval using a rolling average.
    ///
    /// - Parameters:
    ///   - origin: The callsign of the broadcasting station.
    ///   - timestamp: The timestamp of the broadcast.
    func recordBroadcast(from origin: String, timestamp: Date) throws {
        try database.write { db in
            let normalizedOrigin = CallsignValidator.normalize(origin)
            guard !normalizedOrigin.isEmpty else { return }

            let timestampValue = timestamp.timeIntervalSince1970

            // Check for existing record
            if let existing = try OriginIntervalRecord.fetchOne(db, key: normalizedOrigin) {
                // Calculate interval since last broadcast
                let intervalSinceLast = timestampValue - existing.lastBroadcastTimestamp

                // Only update if interval is reasonable (> 10 seconds, < 24 hours)
                // This filters out duplicate broadcasts and unrealistic intervals
                if intervalSinceLast > 10 && intervalSinceLast < 86400 {
                    let newCount = existing.broadcastCount + 1
                    let newSum = existing.intervalSum + intervalSinceLast

                    // Use exponential moving average for smoother estimates
                    // Weight recent intervals more heavily
                    let alpha = 0.3  // Smoothing factor
                    let newEstimate: Double
                    if existing.estimatedIntervalSeconds > 0 {
                        newEstimate = alpha * intervalSinceLast + (1 - alpha) * existing.estimatedIntervalSeconds
                    } else {
                        newEstimate = intervalSinceLast
                    }

                    let updated = OriginIntervalRecord(
                        origin: normalizedOrigin,
                        estimatedIntervalSeconds: newEstimate,
                        lastBroadcastTimestamp: timestampValue,
                        broadcastCount: newCount,
                        intervalSum: newSum
                    )
                    try updated.update(db)

                    #if DEBUG
                    print("[NETROM:PERSISTENCE] Updated broadcast interval for \(normalizedOrigin): \(String(format: "%.0f", newEstimate))s (count: \(newCount))")
                    #endif
                } else {
                    // Just update the timestamp without changing interval estimate
                    try db.execute(
                        sql: "UPDATE netrom_origin_intervals SET lastBroadcastTimestamp = ? WHERE origin = ?",
                        arguments: [timestampValue, normalizedOrigin]
                    )
                }
            } else {
                // First broadcast from this origin - insert new record
                let record = OriginIntervalRecord(
                    origin: normalizedOrigin,
                    estimatedIntervalSeconds: 0,  // Unknown until second broadcast
                    lastBroadcastTimestamp: timestampValue,
                    broadcastCount: 1,
                    intervalSum: 0
                )
                try record.insert(db)

                #if DEBUG
                print("[NETROM:PERSISTENCE] First broadcast recorded for \(normalizedOrigin)")
                #endif
            }
        }
    }

    /// Get the estimated broadcast interval for an origin.
    ///
    /// - Parameter origin: The callsign of the origin station.
    /// - Returns: The interval info, or nil if no data exists.
    func getOriginInterval(for origin: String) throws -> OriginIntervalInfo? {
        try database.read { db in
            let normalizedOrigin = CallsignValidator.normalize(origin)
            guard let record = try OriginIntervalRecord.fetchOne(db, key: normalizedOrigin) else {
                return nil
            }
            return OriginIntervalInfo(
                origin: record.origin,
                estimatedIntervalSeconds: record.estimatedIntervalSeconds,
                lastBroadcast: Date(timeIntervalSince1970: record.lastBroadcastTimestamp),
                broadcastCount: record.broadcastCount
            )
        }
    }

    /// Get all tracked origin intervals.
    ///
    /// - Returns: Array of all origin interval info.
    func getAllOriginIntervals() throws -> [OriginIntervalInfo] {
        try database.read { db in
            let records = try OriginIntervalRecord.order(Column("origin").asc).fetchAll(db)
            return records.map { record in
                OriginIntervalInfo(
                    origin: record.origin,
                    estimatedIntervalSeconds: record.estimatedIntervalSeconds,
                    lastBroadcast: Date(timeIntervalSince1970: record.lastBroadcastTimestamp),
                    broadcastCount: record.broadcastCount
                )
            }
        }
    }

    /// Clear all origin interval tracking data.
    func clearOriginIntervals() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM netrom_origin_intervals")
        }
    }

    // MARK: - Private Helpers

    private func saveMetaInternal(db: Database, lastPacketID: Int64, configHash: String?, timestamp: Date) throws {
        try db.execute(sql: "DELETE FROM netrom_snapshot_meta")
        let record = SnapshotMetaRecord(
            lastPacketID: lastPacketID,
            configHash: configHash,
            snapshotTimestamp: timestamp.timeIntervalSince1970
        )
        try record.insert(db)
    }
}
