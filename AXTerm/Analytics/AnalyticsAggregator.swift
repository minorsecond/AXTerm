//
//  AnalyticsAggregator.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-01.
//

import Foundation

struct AnalyticsAggregator {
    struct Options: Hashable, Sendable {
        let includeViaDigipeaters: Bool
        let histogramBinCount: Int
        let topLimit: Int
    }

    static func aggregate(
        packets: [Packet],
        bucket: TimeBucket,
        calendar: Calendar,
        options: Options
    ) -> AnalyticsAggregationResult {
        let events = packets.map { PacketEvent(packet: $0) }

        let summary = computeSummary(events: events, includeVia: options.includeViaDigipeaters)
        let series = computeSeries(events: events, bucket: bucket, calendar: calendar, includeVia: options.includeViaDigipeaters)
        let heatmap = computeHeatmap(events: events, calendar: calendar)
        let histogram = computeHistogram(events: events, binCount: options.histogramBinCount)

        let topTalkers = rankTop(
            stations: events.compactMap { $0.from } + events.compactMap { $0.to },
            limit: options.topLimit
        )
        let topDestinations = rankTop(stations: events.compactMap { $0.to }, limit: options.topLimit)
        let topDigipeaters = rankTop(stations: events.flatMap { $0.via }, limit: options.topLimit)

        return AnalyticsAggregationResult(
            summary: summary,
            series: series,
            heatmap: heatmap,
            histogram: histogram,
            topTalkers: topTalkers,
            topDestinations: topDestinations,
            topDigipeaters: topDigipeaters
        )
    }

    private static func computeSummary(events: [PacketEvent], includeVia: Bool) -> AnalyticsSummaryMetrics {
        let totalPackets = events.count
        let totalPayloadBytes = events.reduce(0) { $0 + $1.payloadBytes }
        let infoTextCount = events.reduce(0) { $1.infoTextPresent ? $0 + 1 : $0 }
        let infoTextRatio = totalPackets > 0 ? Double(infoTextCount) / Double(totalPackets) : 0

        var uniqueStations: Set<String> = []
        var uiFrames = 0
        var iFrames = 0
        for event in events {
            if let from = event.from {
                uniqueStations.insert(from)
            }
            if let to = event.to {
                uniqueStations.insert(to)
            }
            if includeVia {
                event.via.forEach { uniqueStations.insert($0) }
            }

            switch event.frameType {
            case .ui:
                uiFrames += 1
            case .i:
                iFrames += 1
            default:
                break
            }
        }

        return AnalyticsSummaryMetrics(
            totalPackets: totalPackets,
            uniqueStations: uniqueStations.count,
            totalPayloadBytes: totalPayloadBytes,
            uiFrames: uiFrames,
            iFrames: iFrames,
            infoTextRatio: infoTextRatio
        )
    }

    private static func computeSeries(
        events: [PacketEvent],
        bucket: TimeBucket,
        calendar: Calendar,
        includeVia: Bool
    ) -> AnalyticsSeries {
        guard !events.isEmpty else { return .empty }

        var packetCounts: [BucketKey: Int] = [:]
        var payloadBytes: [BucketKey: Int] = [:]
        var uniqueStations: [BucketKey: Set<String>] = [:]

        for event in events {
            let key = BucketKey(date: event.timestamp, bucket: bucket, calendar: calendar)
            packetCounts[key, default: 0] += 1
            payloadBytes[key, default: 0] += event.payloadBytes
            if let from = event.from {
                uniqueStations[key, default: []].insert(from)
            }
            if let to = event.to {
                uniqueStations[key, default: []].insert(to)
            }
            if includeVia {
                event.via.forEach { uniqueStations[key, default: []].insert($0) }
            }
        }

        let buckets = sortedBucketKeys(from: events, bucket: bucket, calendar: calendar)

        let packets = buckets.map { bucketKey in
            AnalyticsSeriesPoint(bucket: bucketKey.date, value: packetCounts[bucketKey, default: 0])
        }
        let bytes = buckets.map { bucketKey in
            AnalyticsSeriesPoint(bucket: bucketKey.date, value: payloadBytes[bucketKey, default: 0])
        }
        let unique = buckets.map { bucketKey in
            AnalyticsSeriesPoint(bucket: bucketKey.date, value: uniqueStations[bucketKey]?.count ?? 0)
        }

        return AnalyticsSeries(
            packetsPerBucket: packets,
            bytesPerBucket: bytes,
            uniqueStationsPerBucket: unique
        )
    }

    private static func sortedBucketKeys(from events: [PacketEvent], bucket: TimeBucket, calendar: Calendar) -> [BucketKey] {
        guard let minDate = events.map({ $0.timestamp }).min(),
              let maxDate = events.map({ $0.timestamp }).max() else {
            return []
        }

        let start = bucket.normalizedStart(for: minDate, calendar: calendar)
        let end = bucket.normalizedStart(for: maxDate, calendar: calendar)

        var current = start
        var keys: [BucketKey] = []
        while current <= end {
            keys.append(BucketKey(date: current, bucket: bucket, calendar: calendar))
            current = advance(date: current, bucket: bucket, calendar: calendar)
        }
        return keys
    }

    private static func advance(date: Date, bucket: TimeBucket, calendar: Calendar) -> Date {
        switch bucket {
        case .tenSeconds:
            return calendar.date(byAdding: .second, value: 10, to: date) ?? date
        case .minute:
            return calendar.date(byAdding: .minute, value: 1, to: date) ?? date
        case .fiveMinutes:
            return calendar.date(byAdding: .minute, value: 5, to: date) ?? date
        case .fifteenMinutes:
            return calendar.date(byAdding: .minute, value: 15, to: date) ?? date
        case .hour:
            return calendar.date(byAdding: .hour, value: 1, to: date) ?? date
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
    }

    private static func computeHeatmap(events: [PacketEvent], calendar: Calendar) -> HeatmapData {
        guard !events.isEmpty else { return .empty }

        let dayStarts = events
            .map { calendar.startOfDay(for: $0.timestamp) }
            .sorted()

        guard let firstDay = dayStarts.first, let lastDay = dayStarts.last else {
            return .empty
        }

        var days: [Date] = []
        var current = firstDay
        while current <= lastDay {
            days.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? current
        }

        let dayIndex = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, $0.offset) })

        var matrix = Array(repeating: Array(repeating: 0, count: 24), count: days.count)

        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            guard let row = dayIndex[day] else { continue }
            let hour = calendar.component(.hour, from: event.timestamp)
            matrix[row][hour] += 1
        }

        let xLabels = (0..<24).map { String(format: "%02d", $0) }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let yLabels = days.map { formatter.string(from: $0) }

        return HeatmapData(matrix: matrix, xLabels: xLabels, yLabels: yLabels)
    }

    private static func computeHistogram(events: [PacketEvent], binCount: Int) -> HistogramData {
        guard !events.isEmpty, binCount > 0 else { return .empty }

        let payloads = events.map { $0.payloadBytes }
        let maxValue = payloads.max() ?? 0
        let bucketSize = max(1, Int(ceil(Double(maxValue + 1) / Double(binCount))))

        var bins = Array(repeating: 0, count: binCount)
        for value in payloads {
            let index = min(binCount - 1, value / bucketSize)
            bins[index] += 1
        }

        let histogramBins: [HistogramBin] = bins.enumerated().map { index, count in
            let lower = index * bucketSize
            let upper = (index + 1) * bucketSize - 1
            return HistogramBin(lowerBound: lower, upperBound: upper, count: count)
        }

        return HistogramData(bins: histogramBins, maxValue: maxValue)
    }

    private static func rankTop(stations: [String], limit: Int) -> [RankRow] {
        guard limit > 0 else { return [] }
        var counts: [String: Int] = [:]
        for station in stations {
            counts[station, default: 0] += 1
        }

        return counts
            .map { RankRow(label: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
                return lhs.count > rhs.count
            }
            .prefix(limit)
            .map { $0 }
    }
}
