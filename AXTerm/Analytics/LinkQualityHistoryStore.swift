import Foundation
import GRDB

/// One measurement of one direction of a link, at a moment.
nonisolated struct LinkQualityHistorySample: Equatable, Sendable, Identifiable {
    var fromCall: String
    var toCall: String
    var sampledAt: Date
    var quality: Int
    var dfEstimate: Double?
    var drEstimate: Double?
    var dupCount: Int

    var id: String { "\(fromCall)>\(toCall)@\(sampledAt.timeIntervalSince1970)" }
}

/// Keeps the history of what links have been like.
///
/// `link_stats` answers "what is this path like now". It cannot answer "was it
/// always like this", which is the question that separates a station that has
/// degraded from one that was never good — and the one an operator actually
/// asks before blaming their own antenna.
nonisolated protocol LinkQualityHistoryStore: Sendable {
    /// Appends one sample per link. Cheap enough to call on every snapshot.
    func record(_ stats: [LinkStatRecord], at time: Date) throws
    /// Samples for one directed link, oldest first.
    func history(from: String, to: String, since: Date) throws -> [LinkQualityHistorySample]
    /// Both directions between two stations, oldest first.
    func history(between a: String, and b: String, since: Date) throws -> [LinkQualityHistorySample]
    /// Drops samples older than the cutoff. Returns how many went.
    @discardableResult
    func prune(before cutoff: Date) throws -> Int
}

nonisolated final class SQLiteLinkQualityHistoryStore: LinkQualityHistoryStore, @unchecked Sendable {

    /// How long history is kept.
    ///
    /// A fortnight covers "has this got worse since last weekend" — the span
    /// an operator reasons over — while keeping the table small: one row per
    /// link per minute is about 20k rows per link per fortnight, and a station
    /// tracks a handful of links.
    static let retention: TimeInterval = 14 * 24 * 3600

    /// A sample every minute is far finer than link quality actually moves,
    /// and it would make the table thirty times bigger than it needs to be.
    /// Half an hour still shows a slow degradation clearly.
    static let minimumInterval: TimeInterval = 1800

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func record(_ stats: [LinkStatRecord], at time: Date) throws {
        guard !stats.isEmpty else { return }
        try dbQueue.write { db in
            for stat in stats {
                // Skip links whose last sample is too recent. Checked per link
                // rather than globally so a newly seen station is recorded at
                // once instead of waiting for the next window.
                let last = try Date.fetchOne(db, sql: """
                    SELECT MAX(sampledAt) FROM link_quality_history
                    WHERE fromCall = ? AND toCall = ?
                    """, arguments: [stat.fromCall, stat.toCall])
                if let last, time.timeIntervalSince(last) < Self.minimumInterval { continue }

                try db.execute(sql: """
                    INSERT INTO link_quality_history
                    (fromCall, toCall, sampledAt, quality, dfEstimate, drEstimate, dupCount)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        stat.fromCall, stat.toCall, time, stat.quality,
                        stat.dfEstimate, stat.drEstimate, stat.duplicateCount,
                    ])
            }
        }
    }

    func history(from: String, to: String, since: Date) throws -> [LinkQualityHistorySample] {
        try dbQueue.read { db in
            try Self.rows(db, sql: """
                SELECT fromCall, toCall, sampledAt, quality, dfEstimate, drEstimate, dupCount
                FROM link_quality_history
                WHERE fromCall = ? AND toCall = ? AND sampledAt >= ?
                ORDER BY sampledAt ASC
                """, arguments: [from, to, since])
        }
    }

    func history(between a: String, and b: String, since: Date) throws -> [LinkQualityHistorySample] {
        try dbQueue.read { db in
            try Self.rows(db, sql: """
                SELECT fromCall, toCall, sampledAt, quality, dfEstimate, drEstimate, dupCount
                FROM link_quality_history
                WHERE ((fromCall = ? AND toCall = ?) OR (fromCall = ? AND toCall = ?))
                  AND sampledAt >= ?
                ORDER BY sampledAt ASC
                """, arguments: [a, b, b, a, since])
        }
    }

    @discardableResult
    func prune(before cutoff: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM link_quality_history WHERE sampledAt < ?",
                           arguments: [cutoff])
            return db.changesCount
        }
    }

    private static func rows(_ db: Database, sql: String,
                             arguments: StatementArguments) throws -> [LinkQualityHistorySample] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            LinkQualityHistorySample(
                fromCall: row["fromCall"],
                toCall: row["toCall"],
                sampledAt: row["sampledAt"],
                quality: row["quality"],
                dfEstimate: row["dfEstimate"],
                drEstimate: row["drEstimate"],
                dupCount: row["dupCount"])
        }
    }
}
