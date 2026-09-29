//
//  CaptureCoverage.swift
//  AXTerm
//
//  Models WHEN the app was actually listening, so analytics can distinguish
//  "the channel was silent" from "we were not receiving". Without this, every
//  wall-clock window computed over an app-closed gap silently indicts the
//  network for our own absence.
//
//  Policy (most conservative honest estimate):
//  - A coverage interval starts at a TNC "Connected" event.
//  - It ends at the strongest available end evidence before the next connect:
//    an explicit "Disconnected" event, else the last heartbeat, else the last
//    packet received in that span, else the connect instant itself (a connect
//    with no further evidence proves nothing beyond the moment it happened).
//  - The most recent interval extends to `now` only when the caller states the
//    capture is currently live.
//  - Packet evidence that predates the first connect event (history from before
//    disconnect logging existed, or after event-log pruning) is clustered:
//    consecutive packets closer than `maxEvidenceGap` form an estimated
//    coverage interval. This can under-estimate coverage on a quiet channel —
//    which is the safe direction: we never claim to have been listening when
//    we cannot show evidence of it.
//

import Foundation

nonisolated struct CaptureCoverage: Equatable, Sendable {
    /// Sorted, non-overlapping listening intervals.
    let intervals: [DateInterval]

    static let empty = CaptureCoverage(intervals: [])

    /// Seconds of the window during which we were listening.
    func coveredSeconds(in window: DateInterval) -> TimeInterval {
        intervals.reduce(0) { total, interval in
            guard let overlap = interval.intersection(with: window) else { return total }
            return total + overlap.duration
        }
    }

    /// Fraction of the window covered, 0...1. An empty window counts as covered
    /// (there was nothing to miss).
    func coverageFraction(in window: DateInterval) -> Double {
        guard window.duration > 0 else { return 1 }
        return min(1, coveredSeconds(in: window) / window.duration)
    }

    /// The listening spans clipped to the window.
    func coveredIntervals(in window: DateInterval) -> [DateInterval] {
        intervals.compactMap { $0.intersection(with: window) }
    }

    /// The complement: spans of the window where we were NOT listening.
    func uncoveredIntervals(in window: DateInterval) -> [DateInterval] {
        var gaps: [DateInterval] = []
        var cursor = window.start
        for covered in coveredIntervals(in: window) {
            if covered.start > cursor {
                gaps.append(DateInterval(start: cursor, end: covered.start))
            }
            cursor = max(cursor, covered.end)
        }
        if cursor < window.end {
            gaps.append(DateInterval(start: cursor, end: window.end))
        }
        return gaps
    }

    /// Covered fraction per local hour-of-day (24 entries) across the window —
    /// used to mark hours of the activity profile we never listened to.
    func coverageFractionByHour(in window: DateInterval, calendar: Calendar) -> [Double] {
        var coveredByHour = [TimeInterval](repeating: 0, count: 24)
        var totalByHour = [TimeInterval](repeating: 0, count: 24)

        // Walk the window in hour-aligned slices.
        var sliceStart = window.start
        while sliceStart < window.end {
            let hour = calendar.component(.hour, from: sliceStart)
            let nextBoundary = calendar.date(
                bySettingHour: hour, minute: 0, second: 0, of: sliceStart
            ).flatMap { calendar.date(byAdding: .hour, value: 1, to: $0) } ?? sliceStart.addingTimeInterval(3600)
            let sliceEnd = min(nextBoundary, window.end)
            guard sliceEnd > sliceStart else { break }
            let slice = DateInterval(start: sliceStart, end: sliceEnd)
            guard hour >= 0 && hour < 24 else { sliceStart = sliceEnd; continue }
            totalByHour[hour] += slice.duration
            coveredByHour[hour] += coveredSeconds(in: slice)
            sliceStart = sliceEnd
        }

        return (0..<24).map { hour in
            totalByHour[hour] > 0 ? min(1, coveredByHour[hour] / totalByHour[hour]) : 1
        }
    }
}

nonisolated enum CaptureCoverageBuilder {
    /// Packets closer together than this are assumed to belong to one listening
    /// span when no connection events are available for that era.
    static let maxEvidenceGap: TimeInterval = 15 * 60

    static func build(
        connectEvents: [Date],
        disconnectEvents: [Date],
        evidenceTimes: [Date],
        now: Date,
        isCurrentlyConnected: Bool
    ) -> CaptureCoverage {
        let connects = connectEvents.sorted()
        let disconnects = disconnectEvents.sorted()
        let evidence = evidenceTimes.sorted()

        var raw: [DateInterval] = []

        for (index, connect) in connects.enumerated() {
            let boundary = index + 1 < connects.count ? connects[index + 1] : Date.distantFuture
            let isLast = index == connects.count - 1

            // Strongest end evidence within (connect, boundary)
            let disconnectEnd = disconnects.last(where: { $0 > connect && $0 < boundary })
            let evidenceEnd = evidence.last(where: { $0 > connect && $0 < boundary })

            let end: Date
            if isLast && isCurrentlyConnected {
                end = max(now, connect)
            } else if let disconnectEnd {
                end = disconnectEnd
            } else if let evidenceEnd {
                end = evidenceEnd
            } else {
                end = connect
            }
            if end > connect {
                raw.append(DateInterval(start: connect, end: end))
            }
        }

        // Evidence predating the first connect event: cluster into estimated spans.
        let firstConnect = connects.first ?? Date.distantFuture
        let orphanEvidence = evidence.filter { $0 < firstConnect }
        var clusterStart: Date?
        var clusterEnd: Date?
        for time in orphanEvidence {
            if let end = clusterEnd, time.timeIntervalSince(end) <= maxEvidenceGap {
                clusterEnd = time
            } else {
                if let start = clusterStart, let end = clusterEnd, end > start {
                    raw.append(DateInterval(start: start, end: end))
                }
                clusterStart = time
                clusterEnd = time
            }
        }
        if let start = clusterStart, let end = clusterEnd, end > start {
            raw.append(DateInterval(start: start, end: end))
        }

        return CaptureCoverage(intervals: merge(raw))
    }

    private static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                if interval.end > last.end {
                    merged[merged.count - 1] = DateInterval(start: last.start, end: interval.end)
                }
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
