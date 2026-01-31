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

    static let `default` = NetRomPersistenceConfig(
        maxSnapshotAgeSeconds: 3600  // 1 hour
    )
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
}

/// GRDB record for snapshot metadata.
private struct SnapshotMetaRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "netrom_snapshot_meta"

    let id: Int = 1  // Single row
    let lastPacketID: Int64
    let configHash: String?
    let snapshotTimestamp: Double  // TimeInterval since 1970
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
                t.primaryKey(["fromCall", "toCall"])
            }

            try db.create(table: "netrom_snapshot_meta", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey()
                t.column("lastPacketID", .integer).notNull()
                t.column("configHash", .text)
                t.column("snapshotTimestamp", .double).notNull()
            }
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
                    lastUpdate: Date().timeIntervalSince1970
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
                    ewmaQuality: stat.quality
                )
                try record.insert(db)
            }
            try saveMetaInternal(db: db, lastPacketID: lastPacketID, configHash: configHash, timestamp: snapshotTimestamp)
        }
    }

    func loadLinkStats() throws -> [LinkStatRecord] {
        try database.read { db in
            // Deterministic ordering: fromCall asc, then toCall asc
            let records = try LinkStatDBRecord.order(Column("fromCall").asc, Column("toCall").asc).fetchAll(db)
            return records.map { record in
                LinkStatRecord(
                    fromCall: record.fromCall,
                    toCall: record.toCall,
                    quality: record.quality,
                    lastUpdated: Date(timeIntervalSince1970: record.lastUpdated),
                    dfEstimate: record.dfEstimate,
                    drEstimate: record.drEstimate,
                    duplicateCount: record.dupCount,
                    observationCount: 0  // Not stored, but can be reconstructed
                )
            }
        }
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
                    lastUpdate: snapshotTimestamp.timeIntervalSince1970
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
                    ewmaQuality: stat.quality
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

    // MARK: - Clear

    func clearAll() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM netrom_neighbors")
            try db.execute(sql: "DELETE FROM netrom_routes")
            try db.execute(sql: "DELETE FROM link_stats")
            try db.execute(sql: "DELETE FROM netrom_snapshot_meta")
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
