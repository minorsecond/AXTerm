import Foundation
import GRDB

/// What the whole log says about one station, rather than what happens to be
/// in memory.
///
/// The profile counted from `PacketEngine.packets`, which is capped at 5,000
/// frames so the UI stays quick. That cap is a few hours on a busy channel,
/// so "Heard 42 frames" meant "42 of the last 5,000 frames on the air came
/// from this station" while the database held 136 going back to 22 August.
/// The number was presented as a lifetime count and read as one.
///
/// Nothing here is new machinery. `idx_packets_from_receivedAt` covers
/// (fromCall, fromSSID, receivedAt) and has since the schema was written, and
/// the migration already creates `v_station_counts` over exactly this
/// question. Neither was ever read from Swift. On this operator's 25,000-row
/// log a full per-station roll-up returns in under a millisecond.
nonisolated struct StationStats: Equatable, Sendable {

    /// Every frame from this station that survives in the log.
    var frameCount: Int
    /// Frames that reached us with no digipeater in the path, which is the
    /// count that says something about the path between the two antennas.
    var directCount: Int
    var firstHeard: Date?
    var lastHeard: Date?
    /// Frames per hour over the trailing day, oldest first.
    var hourlyCounts: [Int]

    var digipeatedCount: Int { max(0, frameCount - directCount) }

    /// True when the in-memory window would have told a different story, and
    /// the profile is therefore worth sourcing from here.
    func exceeds(_ inMemoryCount: Int) -> Bool { frameCount > inMemoryCount }
}

nonisolated protocol StationStatsReading: Sendable {
    func stats(forStation callsign: String, ssid: Int, now: Date) throws -> StationStats
    /// Every station's lifetime count in one pass, for the places that need
    /// all of them at once rather than one at a time.
    func allStationCounts() throws -> [String: Int]
}

nonisolated final class SQLiteStationStatsStore: StationStatsReading, @unchecked Sendable {

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func stats(forStation callsign: String, ssid: Int,
               now: Date = Date()) throws -> StationStats {
        let call = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !call.isEmpty else {
            return StationStats(frameCount: 0, directCount: 0, firstHeard: nil,
                                lastHeard: nil, hourlyCounts: [])
        }

        return try dbQueue.read { db in
            // One pass for the totals. `hasDigipeaters` is a stored column
            // with its own index, so "direct" does not mean re-parsing every
            // via path.
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                       SUM(CASE WHEN hasDigipeaters = 0 THEN 1 ELSE 0 END) AS direct,
                       MIN(receivedAt) AS first,
                       MAX(receivedAt) AS last
                FROM packets
                WHERE fromCall = ? AND fromSSID = ?
                """, arguments: [call, ssid])

            let total = row?["total"] as Int? ?? 0
            // SUM over no rows is NULL, not zero.
            let direct = row?["direct"] as Int? ?? 0

            return StationStats(
                frameCount: total,
                directCount: direct,
                firstHeard: row?["first"] as Date?,
                lastHeard: row?["last"] as Date?,
                hourlyCounts: try Self.hourlyCounts(db: db, call: call, ssid: ssid, now: now))
        }
    }

    /// Every station's lifetime count, keyed by display callsign.
    ///
    /// One pass over `v_station_counts`, which the schema has always created
    /// and nothing has ever read. The sidebar needs all of them at once and
    /// asking per station would be thirty queries per refresh; this is one,
    /// and the caller is expected to hold the answer rather than ask on every
    /// render.
    func allStationCounts() throws -> [String: Int] {
        try dbQueue.read { db in
            var counts: [String: Int] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT fromCall, fromSSID, packetCount FROM v_station_counts
                """)
            for row in rows {
                guard let call = row["fromCall"] as String?,
                      let ssid = row["fromSSID"] as Int?,
                      let count = row["packetCount"] as Int? else { continue }
                let display = ssid == 0 ? call : "\(call)-\(ssid)"
                counts[display.uppercased(), default: 0] += count
            }
            return counts
        }
    }

    /// Frames per hour over the trailing day.
    ///
    /// Bucketed in Swift rather than with `strftime`, because the buckets are
    /// hours *back from now* rather than hours on the clock: at half past the
    /// hour, grouping by clock hour puts the first and last buckets half
    /// empty and the chart reads as a station that went quiet.
    private static func hourlyCounts(db: Database, call: String, ssid: Int,
                                     now: Date, hours: Int = 24) throws -> [Int] {
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
        let stamps = try Date.fetchAll(db, sql: """
            SELECT receivedAt FROM packets
            WHERE fromCall = ? AND fromSSID = ? AND receivedAt >= ?
            """, arguments: [call, ssid, cutoff])

        var buckets = Array(repeating: 0, count: max(1, hours))
        for stamp in stamps {
            let age = now.timeIntervalSince(stamp)
            guard age >= 0, age < Double(hours) * 3600 else { continue }
            buckets[buckets.count - 1 - Int(age / 3600)] += 1
        }
        return buckets
    }
}
