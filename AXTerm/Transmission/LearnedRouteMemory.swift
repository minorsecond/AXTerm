//
//  LearnedRouteMemory.swift
//  AXTerm
//
//  What each route learned, kept in the database across restarts. Spec §7.3
//  (the learned T1V) and §7.8.1 (where a session starts); smoke run
//  2026-10-03-1, issue 54.
//

import Foundation
import GRDB

/// The part of a route's learning worth keeping past the process.
///
/// Values only: the controller's trial state and counters start over, since
/// a trial that was running when the app quit was never confirmed.
nonisolated struct LearnedRouteSnapshot: Equatable, Sendable {
    var scope: AdaptiveScope
    /// Confirmed K and paclen: an upgrade still on trial counts as the values
    /// it would roll back to.
    var windowSize: Int
    var paclen: Int
    var windowCeiling: Int
    var paclenCeiling: Int
    var lossRate: Double?
    var forwardLoss: Double?
    var etx: Double?
    /// The route's last T1V, which seeds the next session's T1 (§7.3).
    var rto: Double?
    var successStreak: Int
    var upgradeStreakRequirement: Int
    /// Wall-clock time of the last sample.
    var updatedAt: Date

    init(scope: AdaptiveScope, settings: TxAdaptiveSettings, at time: Date) {
        self.scope = scope
        windowSize = settings.confirmedWindow
        paclen = settings.confirmedPaclen
        windowCeiling = settings.windowCeiling
        paclenCeiling = settings.paclenCeiling
        lossRate = settings.lossRateEWMA
        forwardLoss = settings.forwardLossEWMA
        etx = settings.etxEWMA
        rto = settings.currentRto
        successStreak = settings.successStreak
        upgradeStreakRequirement = settings.upgradeStreakRequirement
        updatedAt = time
    }

    fileprivate init(scope: AdaptiveScope, windowSize: Int, paclen: Int, windowCeiling: Int,
                     paclenCeiling: Int, lossRate: Double?, forwardLoss: Double?, etx: Double?,
                     rto: Double?, successStreak: Int, upgradeStreakRequirement: Int, updatedAt: Date) {
        self.scope = scope
        self.windowSize = windowSize
        self.paclen = paclen
        self.windowCeiling = windowCeiling
        self.paclenCeiling = paclenCeiling
        self.lossRate = lossRate
        self.forwardLoss = forwardLoss
        self.etx = etx
        self.rto = rto
        self.successStreak = successStreak
        self.upgradeStreakRequirement = upgradeStreakRequirement
        self.updatedAt = updatedAt
    }

    /// `base` with this route's values put back.
    func applied(to base: TxAdaptiveSettings) -> TxAdaptiveSettings {
        var s = base
        s.windowCeiling = windowCeiling
        s.paclenCeiling = paclenCeiling
        s.windowSize.currentAdaptive = windowSize
        s.paclen.currentAdaptive = paclen
        s.windowSize.adaptiveReason = "Learned on this link before the app restarted"
        s.paclen.adaptiveReason = "Learned on this link before the app restarted"
        s.lossRateEWMA = lossRate
        s.forwardLossEWMA = forwardLoss
        s.etxEWMA = etx
        s.currentRto = rto
        s.successStreak = successStreak
        s.upgradeStreakRequirement = upgradeStreakRequirement
        s.probation = nil
        return s
    }
}

/// How long each part of a snapshot is good for, and what a restart gets back.
nonisolated enum LearnedRouteMemory {

    /// K, paclen and the loss figures describe the channel as it is now:
    /// other traffic, QRM, fading. They come back only within the same 30
    /// minutes a running app trusts them for
    /// (`SessionCoordinator.adaptiveByScopeTTLSeconds`).
    static let recentLifetime: TimeInterval = 30 * 60

    /// The round trip is mostly structure: our key-up, the peer's
    /// turnaround, the digipeaters. It barely moves from day to day, and a
    /// wrong start is corrected by the session's first sample (Select T1).
    static let rtoLifetime: TimeInterval = 7 * 86_400

    struct Restored {
        /// Entries still inside `recentLifetime`, as settings.
        var recent: [AdaptiveScope: TxAdaptiveSettings] = [:]
        /// When each recent entry was learned, so it expires on time.
        var recentAt: [AdaptiveScope: Date] = [:]
        /// Route round trips still inside `rtoLifetime`.
        var rto: [AdaptiveScope: RememberedRto] = [:]
    }

    struct RememberedRto: Equatable, Sendable {
        var value: Double
        var at: Date
    }

    static func restore(_ rows: [LearnedRouteSnapshot], now: Date) -> Restored {
        var out = Restored()
        for row in rows {
            let age = now.timeIntervalSince(row.updatedAt)
            // A row from the future means the clock moved back: its age is
            // unknown, so it is trusted for nothing.
            guard age >= 0 else { continue }
            if age <= recentLifetime {
                out.recent[row.scope] = row.applied(to: TxAdaptiveSettings())
                out.recentAt[row.scope] = row.updatedAt
            }
            if age <= rtoLifetime, row.scope.route != nil,
               let rto = row.rto, rto.isFinite, rto > 0 {
                out.rto[row.scope] = RememberedRto(value: rto, at: row.updatedAt)
            }
        }
        return out
    }
}

/// Where snapshots are kept.
nonisolated protocol LearnedRouteStore: AnyObject, Sendable {
    /// Inserts or replaces one row per scope.
    func save(_ rows: [LearnedRouteSnapshot]) throws
    /// Rows learned at or after `since`.
    func load(since: Date) throws -> [LearnedRouteSnapshot]
    @discardableResult
    func prune(before cutoff: Date) throws -> Int
    /// Every route to a station, on every radio and path (a per-station reset).
    func remove(destination: String) throws
    func removeAll() throws
}

nonisolated final class SQLiteLearnedRouteStore: LearnedRouteStore, @unchecked Sendable {
    static let tableName = "learned_routes"

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func save(_ rows: [LearnedRouteSnapshot]) throws {
        guard !rows.isEmpty else { return }
        try dbQueue.write { db in
            for row in rows {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO learned_routes
                    (radioID, isChannel, destination, path, windowSize, paclen,
                     windowCeiling, paclenCeiling, lossRate, forwardLoss, etx, rto,
                     successStreak, upgradeStreakRequirement, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        row.scope.radio.rawValue,
                        row.scope.route == nil,
                        row.scope.route?.destination ?? "",
                        row.scope.route?.path ?? "",
                        row.windowSize, row.paclen, row.windowCeiling, row.paclenCeiling,
                        row.lossRate, row.forwardLoss, row.etx, row.rto,
                        row.successStreak, row.upgradeStreakRequirement, row.updatedAt,
                    ])
            }
        }
    }

    func load(since: Date) throws -> [LearnedRouteSnapshot] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM learned_routes WHERE updatedAt >= ?
                ORDER BY radioID, isChannel, destination, path
                """, arguments: [since]).map { row in
                let radio = RadioID(rawValue: row["radioID"])
                let isChannel: Bool = row["isChannel"]
                let scope: AdaptiveScope = isChannel
                    ? .radio(radio)
                    : .route(radio: radio, destination: row["destination"], path: row["path"])
                return LearnedRouteSnapshot(
                    scope: scope,
                    windowSize: row["windowSize"], paclen: row["paclen"],
                    windowCeiling: row["windowCeiling"], paclenCeiling: row["paclenCeiling"],
                    lossRate: row["lossRate"], forwardLoss: row["forwardLoss"], etx: row["etx"],
                    rto: row["rto"], successStreak: row["successStreak"],
                    upgradeStreakRequirement: row["upgradeStreakRequirement"],
                    updatedAt: row["updatedAt"])
            }
        }
    }

    @discardableResult
    func prune(before cutoff: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM learned_routes WHERE updatedAt < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    func remove(destination: String) throws {
        let key = destination.trimmingCharacters(in: .whitespaces).uppercased()
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM learned_routes WHERE isChannel = 0 AND destination = ?",
                           arguments: [key])
        }
    }

    func removeAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM learned_routes")
        }
    }
}
