//
//  PingStatistics.swift
//  AXTerm
//
//  What the probe log adds up to.
//
//  Pure functions over `PingProber.Attempt`, apart from the view for the
//  usual reason: an average is a claim about evidence, and a claim worth
//  showing is worth a test.
//
//  Two rules run through all of it.
//
//  A probe still on the air is not a silence. Counting it as one makes the
//  answer rate dip every time a probe goes out and recover when it lands,
//  which is a rate that measures how recently the screen was opened.
//
//  Latency is reported as a median, not a mean. Packet round trips are a
//  short floor with a long tail — a channel that was busy adds seconds to
//  one probe and says nothing about the path — and a mean of that reports
//  a number no probe ever measured.
//

import Foundation

nonisolated enum PingStatistics {

    // MARK: - Overall

    struct Summary: Equatable {
        /// Probes that have finished, one way or the other.
        var completed: Int = 0
        var answered: Int = 0
        var silent: Int = 0
        /// Probes on the air right now.
        var waiting: Int = 0
        /// Distinct addresses probed.
        var stations: Int = 0
        /// Answered ÷ completed. Nil when nothing has finished, because
        /// "0%" and "nothing to say yet" are different statements.
        var answerRate: Double?
        var medianRTT: TimeInterval?
        var fastestRTT: TimeInterval?
        var slowestRTT: TimeInterval?
        /// How many answers needed the DISC fallback — stations that
        /// ignore XID.
        var escalatedAnswers: Int = 0
        var firstProbe: Date?
        var lastProbe: Date?
    }

    static func summary(_ attempts: [PingProber.Attempt]) -> Summary {
        var summary = Summary()
        var rtts: [TimeInterval] = []
        for attempt in attempts {
            switch attempt.outcome {
            case .waiting:
                summary.waiting += 1
            case .answered:
                summary.completed += 1
                summary.answered += 1
                if attempt.escalated { summary.escalatedAnswers += 1 }
                if let rtt = attempt.rtt { rtts.append(rtt) }
            case .silent:
                summary.completed += 1
                summary.silent += 1
            }
            if summary.firstProbe == nil || attempt.sentAt < summary.firstProbe! {
                summary.firstProbe = attempt.sentAt
            }
            if summary.lastProbe == nil || attempt.sentAt > summary.lastProbe! {
                summary.lastProbe = attempt.sentAt
            }
        }
        summary.stations = Set(attempts.map(\.call)).count
        if summary.completed > 0 {
            summary.answerRate = Double(summary.answered) / Double(summary.completed)
        }
        summary.medianRTT = median(rtts)
        summary.fastestRTT = rtts.min()
        summary.slowestRTT = rtts.max()
        return summary
    }

    // MARK: - Per station

    struct StationRow: Equatable, Identifiable {
        var call: String
        var id: String { call }
        var probes: Int = 0
        var answered: Int = 0
        var silent: Int = 0
        var waiting: Int = 0
        var answerRate: Double?
        var medianRTT: TimeInterval?
        var lastRTT: TimeInterval?
        var lastProbed: Date?
        var lastAnswered: Date?
        /// Straight from the prober's record: how many probes in a row
        /// have gone unanswered, which is what the backoff is doubling on.
        var consecutiveSilences: Int = 0
        /// What answered last: "XID", "DM", "FRMR", "UA".
        var lastAnswerKind: String?
    }

    /// One row per address probed, newest activity first.
    ///
    /// Built from the log, with the running totals from `records` filled in
    /// where the log cannot reach: the log is bounded, so a station probed
    /// for weeks has counts older than any attempt still stored. Where both
    /// know a number, the record's is used — it counts every probe ever
    /// sent, and the log only the ones it still holds.
    static func stations(attempts: [PingProber.Attempt],
                         records: [String: PingProber.Record]) -> [StationRow] {
        var rows: [String: StationRow] = [:]
        var rtts: [String: [TimeInterval]] = [:]

        for attempt in attempts {
            var row = rows[attempt.call] ?? StationRow(call: attempt.call)
            switch attempt.outcome {
            case .waiting: row.waiting += 1
            case .answered:
                row.answered += 1
                if let rtt = attempt.rtt { rtts[attempt.call, default: []].append(rtt) }
            case .silent: row.silent += 1
            }
            row.probes += 1
            if row.lastProbed == nil || attempt.sentAt > row.lastProbed! {
                row.lastProbed = attempt.sentAt
            }
            rows[attempt.call] = row
        }

        // Stations whose probes have all aged out of the log still belong
        // on the list: they were asked, and what came of it is the point.
        for (call, record) in records where rows[call] == nil && record.probes > 0 {
            rows[call] = StationRow(call: call)
        }

        for (call, var row) in rows {
            row.medianRTT = median(rtts[call] ?? [])
            if let record = records[call] {
                row.probes = max(row.probes, record.probes)
                row.answered = max(row.answered, record.answers)
                row.silent = max(0, row.probes - row.answered - row.waiting)
                row.lastRTT = record.lastRTT
                row.lastAnswered = record.lastAnswered
                row.consecutiveSilences = record.consecutiveSilences
                row.lastAnswerKind = record.lastAnswerKind
                if let probed = record.lastProbed,
                   row.lastProbed == nil || probed > row.lastProbed! {
                    row.lastProbed = probed
                }
            }
            let finished = row.answered + row.silent
            row.answerRate = finished > 0 ? Double(row.answered) / Double(finished) : nil
            rows[call] = row
        }

        return rows.values.sorted { lhs, rhs in
            let lhsAt = lhs.lastProbed ?? .distantPast
            let rhsAt = rhs.lastProbed ?? .distantPast
            if lhsAt != rhsAt { return lhsAt > rhsAt }
            return lhs.call < rhs.call
        }
    }

    // MARK: - Activity over time

    struct Bucket: Equatable, Identifiable {
        /// Start of the hour this covers.
        var start: Date
        var id: Date { start }
        var answered: Int = 0
        var silent: Int = 0
        var probes: Int { answered + silent }
    }

    /// Answered and silent probes per hour, over the trailing `hours`,
    /// oldest first — including the empty hours, because a gap in probing
    /// is as much of the shape as a burst is.
    static func hourly(_ attempts: [PingProber.Attempt],
                       now: Date,
                       hours: Int = 24,
                       calendar: Calendar = .current) -> [Bucket] {
        guard hours > 0 else { return [] }
        let thisHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let starts = (0..<hours).reversed().compactMap {
            calendar.date(byAdding: .hour, value: -$0, to: thisHour)
        }
        var buckets = starts.map { Bucket(start: $0) }
        guard let earliest = starts.first else { return buckets }

        for attempt in attempts where attempt.sentAt >= earliest {
            guard let hour = calendar.dateInterval(of: .hour, for: attempt.sentAt)?.start,
                  let index = buckets.firstIndex(where: { $0.start == hour }) else { continue }
            switch attempt.outcome {
            case .answered: buckets[index].answered += 1
            case .silent: buckets[index].silent += 1
            case .waiting: break
            }
        }
        return buckets
    }

    // MARK: - Helpers

    /// Lower median on an even count: with two samples either is as good
    /// a claim, and averaging them invents a round trip nothing measured.
    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }
}
