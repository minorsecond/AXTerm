import Foundation
import GRDB

/// Observed paths that survive a restart.
///
/// The graph analysis is only as good as the traffic it has seen, and what
/// AXTerm holds in memory is a few hundred packets — minutes on a busy
/// channel. A packet network goes quiet for hours without changing shape, so
/// deriving its topology from that window alone means every launch begins
/// convinced the network is empty.
nonisolated protocol NetworkPathStore: Sendable {
    /// Folds these paths into what is already known.
    func record(_ paths: [NetworkPath], now: Date) throws
    /// Paths seen since a cutoff, strongest evidence intact.
    func paths(since: Date) throws -> [NetworkPath]
    /// Drops anything older than the cutoff.
    @discardableResult
    func prune(before: Date) throws -> Int
}

nonisolated final class SQLiteNetworkPathStore: NetworkPathStore, @unchecked Sendable {

    /// How long a path is remembered after it was last seen.
    ///
    /// Two weeks matches packet retention elsewhere in the app. Long enough
    /// that a node heard only on weekends stays on the graph, short enough
    /// that a station that moved away stops being drawn as a neighbour.
    static let retention: TimeInterval = 14 * 24 * 3600

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func record(_ paths: [NetworkPath], now: Date = Date()) throws {
        guard !paths.isEmpty else { return }
        // Fold duplicates before touching the database: the caller hands us
        // whatever the observer derived, which can name one path twice when a
        // digipeated and a direct sighting collapse to the same id.
        let incoming = NetworkPath.merging(paths)

        try dbQueue.write { db in
            for path in incoming {
                let existing = try Self.fetch(id: path.id, in: db)
                let merged = existing.map { NetworkPath.merged($0, path) } ?? path
                try db.execute(sql: """
                    INSERT INTO network_paths
                        (id, fromCall, toCall, via, evidence, observations,
                         firstSeen, lastSeen, unansweredAttempts)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        fromCall = excluded.fromCall,
                        toCall = excluded.toCall,
                        via = excluded.via,
                        evidence = excluded.evidence,
                        observations = excluded.observations,
                        firstSeen = excluded.firstSeen,
                        lastSeen = excluded.lastSeen,
                        unansweredAttempts = excluded.unansweredAttempts
                    """, arguments: [
                        merged.id, merged.from, merged.to,
                        merged.via.joined(separator: ","),
                        merged.evidence.rawValue, merged.observations,
                        merged.firstSeen, merged.lastSeen,
                        merged.unansweredAttempts])
            }
        }
    }

    func paths(since: Date) throws -> [NetworkPath] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM network_paths WHERE lastSeen >= ? ORDER BY id
                """, arguments: [since]).compactMap(Self.path(from:))
        }
    }

    @discardableResult
    func prune(before: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM network_paths WHERE lastSeen < ?",
                           arguments: [before])
            return db.changesCount
        }
    }

    private static func fetch(id: String, in db: Database) throws -> NetworkPath? {
        try Row.fetchOne(db, sql: "SELECT * FROM network_paths WHERE id = ?",
                         arguments: [id]).flatMap(path(from:))
    }

    private static func path(from row: Row) -> NetworkPath? {
        // An unknown evidence value means a row written by a newer build.
        // Dropping it is safer than guessing a level, because every downstream
        // decision is graded on exactly this field.
        guard let evidence = NetworkPath.Evidence(rawValue: row["evidence"]) else {
            return nil
        }
        let via: String = row["via"]
        return NetworkPath(
            from: row["fromCall"], to: row["toCall"],
            via: via.isEmpty ? [] : via.split(separator: ",").map(String.init),
            evidence: evidence,
            observations: row["observations"],
            firstSeen: row["firstSeen"],
            lastSeen: row["lastSeen"],
            unansweredAttempts: row["unansweredAttempts"])
    }
}
