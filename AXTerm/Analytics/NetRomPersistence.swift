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
nonisolated struct NetRomPersistenceConfig {
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
nonisolated struct PersistedState {
    let neighbors: [NeighborInfo]
    let routes: [RouteInfo]
    let linkStats: [LinkStatRecord]
    let lastPacketID: Int64
}

/// Metadata about a persisted snapshot.
nonisolated struct SnapshotMeta: Equatable {
    let lastPacketID: Int64
    let configHash: String?
    let snapshotTimestamp: Date
}

/// GRDB record for neighbors table.
nonisolated private struct NeighborRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "netrom_neighbors"

    let call: String
    let radioID: String
    let quality: Int
    let lastSeen: Double  // TimeInterval since 1970
    let obsolescenceCount: Int
    let sourceType: String
}

/// GRDB record for routes table.
nonisolated private struct RouteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "netrom_routes"

    let destination: String
    let origin: String
    let radioID: String
    let quality: Int
    let pathJson: String
    let sourceType: String
    let lastUpdate: Double  // TimeInterval since 1970
}

/// GRDB record for link stats table.
nonisolated private struct LinkStatDBRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "link_stats"

    let fromCall: String
    let toCall: String
    let radioID: String
    let quality: Int
    let lastUpdated: Double  // TimeInterval since 1970
    let dfEstimate: Double?
    let drEstimate: Double?
    let dupCount: Int
    let ewmaQuality: Int
    let obsCount: Int  // observation count for evidence rehydration
    let sessionObsCount: Int  // of those, how many were connected-mode frames
}

/// GRDB record for snapshot metadata.
nonisolated private struct SnapshotMetaRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "netrom_snapshot_meta"

    var id: Int = 1  // Single row
    let lastPacketID: Int64
    let configHash: String?
    let snapshotTimestamp: Double  // TimeInterval since 1970
}

/// GRDB record for tracking per-origin broadcast intervals.
/// Used for adaptive stale threshold calculation.
nonisolated private struct OriginIntervalRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "netrom_origin_intervals"

    let origin: String  // Primary key
    let estimatedIntervalSeconds: Double
    let lastBroadcastTimestamp: Double  // TimeInterval since 1970
    let broadcastCount: Int
    let intervalSum: Double  // Sum of intervals for rolling average
}

/// Public struct for origin interval data.
nonisolated struct OriginIntervalInfo {
    let origin: String
    let estimatedIntervalSeconds: TimeInterval
    let lastBroadcast: Date
    let broadcastCount: Int
}

/// Persistence layer for NET/ROM routing state.
/// Thread-safe: all database access is serialized by GRDB's `DatabaseWriter`.
nonisolated final class NetRomPersistence: @unchecked Sendable {
    private let database: DatabaseWriter
    private let config: NetRomPersistenceConfig

    init(database: DatabaseWriter, config: NetRomPersistenceConfig = .default) throws {
        self.database = database
        self.config = config
        try createTables()
    }

    // MARK: - Table Creation

    private func createTables() throws {
        try database.write { db in
            // Keyed by radio as well as callsign: a neighbor reachable on two
            // radios is two links with two qualities (CLAUDE.md §8 — evidence
            // gathered by one antenna is not evidence about another).
            try db.create(table: "netrom_neighbors", ifNotExists: true) { t in
                t.column("call", .text).notNull()
                t.column("radioID", .text).notNull().defaults(to: "radio-primary")
                t.column("quality", .integer).notNull()
                t.column("lastSeen", .double).notNull()
                t.column("obsolescenceCount", .integer).notNull().defaults(to: 1)
                t.column("sourceType", .text).notNull().defaults(to: "classic")
                t.primaryKey(["radioID", "call"])
            }

            try db.create(table: "netrom_routes", ifNotExists: true) { t in
                t.column("destination", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("radioID", .text).notNull().defaults(to: "radio-primary")
                t.column("quality", .integer).notNull()
                t.column("pathJson", .text).notNull()
                t.column("sourceType", .text).notNull().defaults(to: "broadcast")
                t.column("lastUpdate", .double).notNull().defaults(to: 0)
                t.primaryKey(["destination", "origin", "radioID"])
            }

            try db.create(table: "link_stats", ifNotExists: true) { t in
                t.column("fromCall", .text).notNull()
                t.column("toCall", .text).notNull()
                t.column("radioID", .text).notNull().defaults(to: "radio-primary")
                t.column("quality", .integer).notNull()
                t.column("lastUpdated", .double).notNull()
                t.column("dfEstimate", .double)
                t.column("drEstimate", .double)
                t.column("dupCount", .integer).notNull().defaults(to: 0)
                t.column("ewmaQuality", .integer).notNull().defaults(to: 0)
                t.column("obsCount", .integer).notNull().defaults(to: 0)  // observation count for evidence rehydration
                t.column("sessionObsCount", .integer).notNull().defaults(to: 0)  // of those, connected-mode frames
                t.primaryKey(["radioID", "fromCall", "toCall"])
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
            // Migration: key the three tables by radio as well as callsign.
            try migrateAddRadioKey(db)
            // Migration: record how much of a link's evidence was connected-mode.
            // After migrateAddRadioKey, which rebuilds the table without it.
            try migrateAddSessionObsCountColumn(db)
            // One-off: clear routing state produced by the APRS faults.
            try purgeAPRSPollutedRouting(db)
        }
    }

    /// Rebuilds a table created before the radio was part of its key.
    ///
    /// SQLite cannot change a primary key in place, so each old-shape table
    /// is copied into its new shape with every row attributed to the one
    /// radio the station had — `RadioID.primary`, the constant
    /// "radio-primary" — and swapped in. Idempotent: a table that already has
    /// the column is left alone.
    private func migrateAddRadioKey(_ db: Database) throws {
        func hasRadio(_ table: String) throws -> Bool {
            try db.columns(in: table).contains { $0.name == "radioID" }
        }
        if try !hasRadio("netrom_neighbors") {
            try db.execute(sql: """
                CREATE TABLE netrom_neighbors_v2 (
                    call TEXT NOT NULL, radioID TEXT NOT NULL DEFAULT 'radio-primary',
                    quality INTEGER NOT NULL, lastSeen DOUBLE NOT NULL,
                    obsolescenceCount INTEGER NOT NULL DEFAULT 1,
                    sourceType TEXT NOT NULL DEFAULT 'classic',
                    PRIMARY KEY (radioID, call));
                INSERT INTO netrom_neighbors_v2 (call, radioID, quality, lastSeen, obsolescenceCount, sourceType)
                    SELECT call, 'radio-primary', quality, lastSeen, obsolescenceCount, sourceType FROM netrom_neighbors;
                DROP TABLE netrom_neighbors;
                ALTER TABLE netrom_neighbors_v2 RENAME TO netrom_neighbors;
                """)
        }
        if try !hasRadio("netrom_routes") {
            try db.execute(sql: """
                CREATE TABLE netrom_routes_v2 (
                    destination TEXT NOT NULL, origin TEXT NOT NULL,
                    radioID TEXT NOT NULL DEFAULT 'radio-primary',
                    quality INTEGER NOT NULL, pathJson TEXT NOT NULL,
                    sourceType TEXT NOT NULL DEFAULT 'broadcast',
                    lastUpdate DOUBLE NOT NULL DEFAULT 0,
                    PRIMARY KEY (destination, origin, radioID));
                INSERT INTO netrom_routes_v2 (destination, origin, radioID, quality, pathJson, sourceType, lastUpdate)
                    SELECT destination, origin, 'radio-primary', quality, pathJson, sourceType, lastUpdate FROM netrom_routes;
                DROP TABLE netrom_routes;
                ALTER TABLE netrom_routes_v2 RENAME TO netrom_routes;
                """)
        }
        if try !hasRadio("link_stats") {
            try db.execute(sql: """
                CREATE TABLE link_stats_v2 (
                    fromCall TEXT NOT NULL, toCall TEXT NOT NULL,
                    radioID TEXT NOT NULL DEFAULT 'radio-primary',
                    quality INTEGER NOT NULL, lastUpdated DOUBLE NOT NULL,
                    dfEstimate DOUBLE, drEstimate DOUBLE,
                    dupCount INTEGER NOT NULL DEFAULT 0,
                    ewmaQuality INTEGER NOT NULL DEFAULT 0,
                    obsCount INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (radioID, fromCall, toCall));
                INSERT INTO link_stats_v2 (fromCall, toCall, radioID, quality, lastUpdated, dfEstimate, drEstimate, dupCount, ewmaQuality, obsCount)
                    SELECT fromCall, toCall, 'radio-primary', quality, lastUpdated, dfEstimate, drEstimate, dupCount, ewmaQuality, obsCount FROM link_stats;
                DROP TABLE link_stats;
                ALTER TABLE link_stats_v2 RENAME TO link_stats;
                """)
        }
    }

    /// Clears routing state that two fixed faults had already written.
    ///
    /// Until 2026-09-17 the passive inference read the next hop from the last
    /// repeated via entry, which for a digipeated APRS frame is the alias the
    /// digipeater consumed rather than the digipeater itself, and it accepted
    /// a beacon as evidence of a routable path. Together those filled the table
    /// with APRS stations reached "via WIDE1", and the node broadcast then
    /// advertised them to the packet network over the air.
    ///
    /// The code no longer produces any of it, but the rows are persisted and
    /// would keep being advertised until they aged out. So they go now:
    ///
    /// - anything routed through a path alias, which is never a station;
    /// - every inferred route and neighbour, because the good ones cannot be
    ///   told from the bad ones after the fact and they re-learn within
    ///   minutes from live traffic.
    ///
    /// Routes from real node broadcasts are untouched. Runs once, recorded in
    /// `netrom_purges` so a later launch leaves the re-learned table alone.
    private func purgeAPRSPollutedRouting(_ db: Database) throws {
        let purgeID = "aprs-polluted-routing-2026-09-17"
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS netrom_purges (
                id TEXT PRIMARY KEY,
                appliedAt DOUBLE NOT NULL);
            """)
        let done = try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM netrom_purges WHERE id = ?)",
            arguments: [purgeID]) ?? false
        guard !done else { return }

        let aliasTest = """
            %@ GLOB 'WIDE*' OR %@ GLOB 'TRACE*' OR %@ GLOB 'RELAY*'
            """
        let routeAlias = String(format: aliasTest, "origin", "origin", "origin")
        let neighborAlias = String(format: aliasTest, "call", "call", "call")
        try db.execute(sql: "DELETE FROM netrom_routes WHERE (\(routeAlias)) OR sourceType = 'inferred'")
        try db.execute(sql: "DELETE FROM netrom_neighbors WHERE (\(neighborAlias)) OR sourceType = 'inferred'")
        try db.execute(sql: "INSERT INTO netrom_purges (id, appliedAt) VALUES (?, ?)",
                       arguments: [purgeID, Date().timeIntervalSince1970])
        #if DEBUG
        print("[NETROM:PERSISTENCE] Purged routing state written by the APRS faults")
        #endif
    }

    /// Adds the sessionObsCount column to link_stats if it doesn't exist.
    ///
    /// Existing rows default to **0**, which is the opposite of what obsCount
    /// does below and is deliberate. obsCount defaults to 1 so a restored link
    /// is not mistaken for one with no evidence at all. This column answers a
    /// narrower question: may this link speak about packet loss? For a row
    /// written before the column existed we do not know, and guessing yes
    /// would let a beacon-only link go on feeding the adaptive tuner the very
    /// figure this column exists to exclude. Guessing no costs one link's
    /// contribution until its next connected-mode frame, which restores it.
    private func migrateAddSessionObsCountColumn(_ db: Database) throws {
        let columns = try db.columns(in: "link_stats")
        guard !columns.contains(where: { $0.name == "sessionObsCount" }) else { return }
        try db.execute(sql: "ALTER TABLE link_stats ADD COLUMN sessionObsCount INTEGER NOT NULL DEFAULT 0")
        #if DEBUG
        print("[NETROM:PERSISTENCE] Migrated link_stats table: added sessionObsCount column")
        #endif
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
                    radioID: neighbor.radioID.rawValue,
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
            let records = try NeighborRecord.order(Column("quality").desc, Column("call").asc, Column("radioID").asc).fetchAll(db)
            return records.map { record in
                NeighborInfo(
                    call: record.call,
                    quality: record.quality,
                    lastSeen: Date(timeIntervalSince1970: record.lastSeen),
                    obsolescenceCount: record.obsolescenceCount,
                    sourceType: record.sourceType,
                    radioID: RadioID(rawValue: record.radioID)
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
                    radioID: route.radioID.rawValue,
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
            let records = try RouteRecord.order(Column("destination").asc, Column("quality").desc, Column("origin").asc, Column("radioID").asc).fetchAll(db)
            return records.map { record in
                let path = (try? JSONDecoder().decode([String].self, from: Data(record.pathJson.utf8))) ?? []
                return RouteInfo(
                    destination: record.destination,
                    origin: record.origin,
                    quality: record.quality,
                    path: path,
                    lastUpdated: Date(timeIntervalSince1970: record.lastUpdate),
                    sourceType: record.sourceType,
                    radioID: RadioID(rawValue: record.radioID)
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
                    radioID: stat.radioID.rawValue,
                    quality: stat.quality,
                    lastUpdated: stat.lastUpdated.timeIntervalSince1970,
                    dfEstimate: stat.dfEstimate,
                    drEstimate: stat.drEstimate,
                    dupCount: stat.duplicateCount,
                    ewmaQuality: stat.quality,
                    obsCount: stat.observationCount,  // Persist evidence count for rehydration
                    sessionObsCount: stat.sessionEvidenceCount
                )
                try record.insert(db)
            }
            try saveMetaInternal(db: db, lastPacketID: lastPacketID, configHash: configHash, timestamp: snapshotTimestamp)
        }
    }

    func loadLinkStats(now: Date) throws -> [LinkStatRecord] {
        return try database.read { db in
            // Deterministic ordering: fromCall asc, then toCall asc
            let records = try LinkStatDBRecord.order(Column("fromCall").asc, Column("toCall").asc, Column("radioID").asc).fetchAll(db)
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
                    observationCount: record.obsCount,  // Load persisted evidence count
                    radioID: RadioID(rawValue: record.radioID),
                    sessionEvidenceCount: record.sessionObsCount
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
                    radioID: neighbor.radioID.rawValue,
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
                    radioID: route.radioID.rawValue,
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
                    radioID: stat.radioID.rawValue,
                    quality: stat.quality,
                    lastUpdated: stat.lastUpdated.timeIntervalSince1970,
                    dfEstimate: stat.dfEstimate,
                    drEstimate: stat.drEstimate,
                    dupCount: stat.duplicateCount,
                    ewmaQuality: stat.quality,
                    obsCount: stat.observationCount,  // Persist evidence count for rehydration
                    sessionObsCount: stat.sessionEvidenceCount
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

        return allNeighbors.map { neighbor -> NeighborInfo in
            let age = now.timeIntervalSince(neighbor.lastSeen)

            // If within TTL, keep as-is
            if neighbor.lastSeen >= cutoff {
                return neighbor
            }

            // Beyond TTL, decay exponentially (half the quality per additional TTL)
            // and keep the entry for display. The old linear formula
            // 1 - age/TTL only ran when age > TTL, so it was always <= 0 and every
            // restart zeroed the quality of any neighbor older than the TTL while
            // its Freshness column still read high.
            let overage = age - config.neighborTTLSeconds
            let decayFactor = exp(-overage * M_LN2 / config.neighborTTLSeconds)
            let decayedQuality = Int((Double(neighbor.quality) * decayFactor).rounded())

            return NeighborInfo(
                call: neighbor.call,
                quality: decayedQuality,
                lastSeen: neighbor.lastSeen,
                obsolescenceCount: neighbor.obsolescenceCount,
                sourceType: neighbor.sourceType,
                isOfficial: neighbor.isOfficial,
                radioID: neighbor.radioID
            )
        }
    }

    /// Load all routes (no TTL filtering — expired entries are kept for display).
    private func loadRoutesWithDecay(now: Date) throws -> [RouteInfo] {
        return try loadRoutes()
    }

    /// Load all link stats (no TTL filtering — expired entries are kept for display).
    private func loadLinkStatsWithDecay(now: Date) throws -> [LinkStatRecord] {
        return try loadLinkStats(now: now)
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
