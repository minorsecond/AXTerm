import Foundation
import GRDB

/// Persistence for observations that came from another station.
///
/// A type of its own rather than more methods on `SQLiteWinlinkStore`. The
/// remote table must stay unreachable from the queries that feed routing
/// inference, and a separate type with a separate surface makes that a fact
/// about the code rather than a rule someone has to keep in mind.
///
/// The *local* half is injected rather than derived here: building this
/// station's activity needs packets, inferred roles and the identity mode,
/// all of which live in the analytics layer. Reaching down for them would
/// put a store in the business of interpreting traffic.
nonisolated final class SQLiteStationActivityStore: StationActivityStore, @unchecked Sendable {

    private let dbQueue: DatabaseQueue
    private let lock = NSLock()
    private var localSnapshot: [StationActivityPayload] = []

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// The analytics layer hands its station directory down as it rebuilds
    /// it, rather than this store reaching up for packets and inferred
    /// roles. Publishing then reports exactly what the operator is looking
    /// at, instead of a second derivation that could disagree with it.
    func setLocalActivity(_ payloads: [StationActivityPayload]) {
        lock.lock(); defer { lock.unlock() }
        localSnapshot = payloads
    }

    /// Empty until analytics has run once. Publishing nothing is correct
    /// here — a station that has not yet worked out what it heard has no
    /// observations to share, and guessing would be worse.
    func localStationActivity() throws -> [StationActivityPayload] {
        lock.lock(); defer { lock.unlock() }
        return localSnapshot
    }

    /// Upsert keyed on observer + subject.
    ///
    /// A later report from the same receiver about the same station replaces
    /// the earlier one — it is a fresher view of one fact, not a second
    /// fact. Reports from a *different* receiver land alongside, because
    /// those genuinely are separate evidence.
    func saveRemoteStationActivity(_ payloads: [StationActivityPayload]) throws {
        guard !payloads.isEmpty else { return }
        try dbQueue.write { db in
            for payload in payloads {
                try db.execute(
                    sql: """
                    INSERT INTO remoteStationActivity
                        (deviceID, callsign, station, gridSquare, observedAt,
                         roles, firstHeard, lastHeard, frameCount, airtimeSeconds)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceID, callsign) DO UPDATE SET
                        station = excluded.station,
                        gridSquare = excluded.gridSquare,
                        observedAt = excluded.observedAt,
                        roles = excluded.roles,
                        firstHeard = excluded.firstHeard,
                        lastHeard = excluded.lastHeard,
                        frameCount = excluded.frameCount,
                        airtimeSeconds = excluded.airtimeSeconds
                    """,
                    arguments: [
                        payload.provenance.deviceID,
                        payload.callsign,
                        payload.provenance.station,
                        payload.provenance.gridSquare,
                        payload.provenance.observedAt,
                        payload.roles.joined(separator: ","),
                        payload.firstHeard,
                        payload.lastHeard,
                        payload.frameCount,
                        payload.airtimeSeconds,
                    ])
            }
        }
    }

    func remoteStationActivity() throws -> [StationActivityPayload] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM remoteStationActivity ORDER BY lastHeard DESC
                """).map { row in
                StationActivityPayload(
                    callsign: row["callsign"],
                    roles: (row["roles"] as String).split(separator: ",").map(String.init),
                    firstHeard: row["firstHeard"],
                    lastHeard: row["lastHeard"],
                    frameCount: row["frameCount"],
                    airtimeSeconds: row["airtimeSeconds"],
                    provenance: WinlinkSyncProvenance(
                        station: row["station"],
                        deviceID: row["deviceID"],
                        gridSquare: row["gridSquare"],
                        observedAt: row["observedAt"]))
            }
        }
    }
}

// MARK: - Deriving this station's activity

nonisolated enum StationActivityPublication {

    /// Turns the local station directory into publishable observations.
    ///
    /// Only stations heard within the window are offered. Publishing the
    /// whole history on every pass would grow without bound and re-upload
    /// facts that have not changed — the push ledger would suppress the
    /// duplicates, but building them is still work done for nothing.
    static func payloads(from directory: [StationDirectoryEntry],
                         station: String,
                         deviceID: String,
                         gridSquare: String?,
                         now: Date,
                         window: TimeInterval = 7 * 86_400) -> [StationActivityPayload] {
        directory
            .filter { now.timeIntervalSince($0.lastHeard) <= window }
            .map { entry in
                StationActivityPayload(
                    callsign: entry.callsign,
                    roles: entry.roleBadges,
                    firstHeard: entry.firstHeard,
                    lastHeard: entry.lastHeard,
                    frameCount: entry.frameCount,
                    airtimeSeconds: entry.airtimeSeconds,
                    provenance: WinlinkSyncProvenance(
                        station: station,
                        deviceID: deviceID,
                        gridSquare: gridSquare?.isEmpty == false ? gridSquare : nil,
                        observedAt: now))
            }
    }
}
