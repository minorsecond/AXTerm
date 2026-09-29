import Foundation

/// Every object and item currently on the air, with who placed it and when we
/// heard it.
///
/// Pure and value-typed so the whole lifecycle is testable without a receiver.
/// The lifecycle is the point: an incident map that only ever adds points
/// becomes a list of everything that has ever been wrong, which is worse than
/// no map because it looks current.
nonisolated struct APRSObjectStore: Equatable, Sendable {

    /// One live object, plus everything the packet could not say.
    struct Placed: Equatable, Sendable, Identifiable {
        var report: APRSObjectReport
        /// The station that transmitted it. An object is a claim by a person,
        /// and a claim with no name attached is not one an operator can weigh.
        var reportedBy: String
        /// When this receiver heard it — not the sender's clock, which may be
        /// anything at all.
        var heard: Date
        /// When it was first heard, so "reported 3 h ago, still being repeated"
        /// can be told from "just appeared".
        var firstHeard: Date
        /// How many times it has been repeated. A hazard a station is still
        /// beaconing every ten minutes is being actively maintained; one heard
        /// once may have been a passing mobile's guess.
        var timesHeard: Int

        var id: String { report.key }

        var age: TimeInterval { -heard.timeIntervalSinceNow }
        var position: GreatCircle.Point {
            GreatCircle.Point(latitude: report.latitude, longitude: report.longitude)
        }
    }

    /// Objects stop being shown this long after the last time anyone repeated
    /// them.
    ///
    /// Objects are meant to be re-beaconed while they are true, so silence is
    /// itself information: an object nobody has repeated for six hours is
    /// either over or its owner is off the air, and in both cases it should
    /// stop being drawn as current. This does not delete it — `expired` keeps
    /// it available — it only removes it from the live map.
    static let liveWindow: TimeInterval = 6 * 3600

    private(set) var placed: [String: Placed] = [:]
    /// Objects the sender explicitly killed, kept briefly so the operator can
    /// see that something was stood down rather than watching it vanish.
    private(set) var killed: [String: Placed] = [:]

    /// Files a heard object report.
    ///
    /// - Returns: true when this changed anything worth redrawing for.
    @discardableResult
    mutating func record(_ report: APRSObjectReport, from station: String,
                         at when: Date) -> Bool {
        let key = report.key
        guard !key.isEmpty else { return false }

        guard report.isLive else {
            // A kill. Only the station that owns the object may retire it —
            // otherwise anyone on the channel can silence anyone else's hazard
            // report, which is a safety problem, not just a data one.
            guard let existing = placed[key] else { return false }
            guard existing.reportedBy.caseInsensitiveCompare(station) == .orderedSame
            else { return false }
            placed[key] = nil
            var stood = existing
            stood.report = report
            stood.heard = when
            killed[key] = stood
            return true
        }

        killed[key] = nil
        if var existing = placed[key] {
            let changed = existing.report != report || existing.reportedBy != station
            existing.report = report
            existing.reportedBy = station
            existing.heard = when
            existing.timesHeard += 1
            placed[key] = existing
            return changed
        }
        placed[key] = Placed(report: report, reportedBy: station,
                             heard: when, firstHeard: when, timesHeard: 1)
        return true
    }

    /// Objects still being repeated, most urgent first and then most recent.
    /// This is the order an operator wants to read them in.
    func live(now: Date = Date()) -> [Placed] {
        placed.values
            .filter { now.timeIntervalSince($0.heard) <= Self.liveWindow }
            .sorted {
                if $0.report.urgency != $1.report.urgency {
                    return $0.report.urgency > $1.report.urgency
                }
                if $0.heard != $1.heard { return $0.heard > $1.heard }
                return $0.report.key < $1.report.key
            }
    }

    /// Objects nobody has repeated inside the live window. Kept so the map can
    /// say "this was reported and has gone quiet" rather than silently
    /// dropping a hazard.
    func expired(now: Date = Date()) -> [Placed] {
        placed.values
            .filter { now.timeIntervalSince($0.heard) > Self.liveWindow }
            .sorted { $0.heard > $1.heard }
    }

    /// Live objects whose symbol says something is wrong. What an operator
    /// wants surfaced without going looking.
    func hazards(now: Date = Date()) -> [Placed] {
        live(now: now).filter { $0.report.urgency == .hazard }
    }

    /// Drops everything older than the window entirely. Called rarely; the
    /// live/expired split is what the UI reads.
    mutating func prune(before cutoff: Date) {
        placed = placed.filter { $0.value.heard >= cutoff }
        killed = killed.filter { $0.value.heard >= cutoff }
    }
}
