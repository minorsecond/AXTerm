//
//  AnalyticsAggregator.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-01.
//

import Foundation

nonisolated struct AnalyticsAggregator {
    struct Options: Hashable, Sendable {
        let includeViaDigipeaters: Bool
        let histogramBinCount: Int
        let topLimit: Int
        /// Groups stations the same way the network graph does: `.station`
        /// collapses SSIDs to the base callsign so "Unique stations" and the top
        /// lists agree with the graph and the health panel; `.ssid` counts each
        /// SSID separately.
        let stationIdentityMode: StationIdentityMode

        init(
            includeViaDigipeaters: Bool,
            histogramBinCount: Int,
            topLimit: Int,
            stationIdentityMode: StationIdentityMode = .ssid
        ) {
            self.includeViaDigipeaters = includeViaDigipeaters
            self.histogramBinCount = histogramBinCount
            self.topLimit = topLimit
            self.stationIdentityMode = stationIdentityMode
        }
    }

    static func aggregate(
        packets: [Packet],
        bucket: TimeBucket,
        calendar: Calendar,
        options: Options,
        timeframeInterval: DateInterval? = nil
    ) -> AnalyticsAggregationResult {
        let events = packets.map { PacketEvent(packet: $0) }

        let summary = computeSummary(events: events, includeVia: options.includeViaDigipeaters, identityMode: options.stationIdentityMode)
        let series = computeSeries(
            events: events,
            bucket: bucket,
            calendar: calendar,
            includeVia: options.includeViaDigipeaters,
            identityMode: options.stationIdentityMode,
            timeframeInterval: timeframeInterval
        )
        let heatmap = computeHeatmap(events: events, calendar: calendar, timeframeInterval: timeframeInterval)
        let histogram = computeHistogram(events: events, binCount: options.histogramBinCount)

        // Talkers are ranked by frames *sent*. Counting destinations here would let a
        // popular receive-only station top the "talkers" list.
        let topTalkers = rankTop(stations: events.compactMap { $0.from }, limit: options.topLimit, identityMode: options.stationIdentityMode)
        let topDestinations = rankTop(stations: events.compactMap { $0.to }, limit: options.topLimit, identityMode: options.stationIdentityMode)
        // Only digipeaters that actually repeated the frame (H bit set) earn credit;
        // a requested-but-unused path entry is not evidence the station was on air.
        let topDigipeaters = rankTop(
            stations: events.flatMap { $0.repeatedVia },
            limit: options.topLimit,
            identityMode: options.stationIdentityMode
        )

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

    private static func computeSummary(events: [PacketEvent], includeVia: Bool, identityMode: StationIdentityMode) -> AnalyticsSummaryMetrics {
        let totalPackets = events.count
        let totalPayloadBytes = events.reduce(0) { $0 + $1.payloadBytes }
        let infoTextCount = events.reduce(0) { $1.infoTextPresent ? $0 + 1 : $0 }
        let infoTextRatio = totalPackets > 0 ? Double(infoTextCount) / Double(totalPackets) : 0

        var uniqueStations: Set<String> = []
        var uiFrames = 0
        var iFrames = 0
        for event in events {
            if let from = event.from {
                if isStationIncludedInMetrics(from) {
                    uniqueStations.insert(CallsignParser.identityKey(for: from, mode: identityMode))
                }
            }
            if let to = event.to {
                if isStationIncludedInMetrics(to) {
                    uniqueStations.insert(CallsignParser.identityKey(for: to, mode: identityMode))
                }
            }
            if includeVia {
                event.repeatedVia.forEach { via in
                    if isStationIncludedInMetrics(via) {
                        uniqueStations.insert(CallsignParser.identityKey(for: via, mode: identityMode))
                    }
                }
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
        includeVia: Bool,
        identityMode: StationIdentityMode,
        timeframeInterval: DateInterval?
    ) -> AnalyticsSeries {
        guard !events.isEmpty else { return .empty }

        var packetCounts: [BucketKey: Int] = [:]
        var payloadBytes: [BucketKey: Int] = [:]
        var uniqueStations: [BucketKey: Set<String>] = [:]
        var uiCounts: [BucketKey: Int] = [:]
        var iCounts: [BucketKey: Int] = [:]
        var otherCounts: [BucketKey: Int] = [:]
        var rejectCounts: [BucketKey: Int] = [:]

        for event in events {
            let key = BucketKey(date: event.timestamp, bucket: bucket, calendar: calendar)
            packetCounts[key, default: 0] += 1
            payloadBytes[key, default: 0] += event.payloadBytes
            switch event.frameType {
            case .ui: uiCounts[key, default: 0] += 1
            case .i: iCounts[key, default: 0] += 1
            default: otherCounts[key, default: 0] += 1
            }
            if event.isRejectFrame {
                rejectCounts[key, default: 0] += 1
            }
            if let from = event.from {
                if isStationIncludedInMetrics(from) {
                    uniqueStations[key, default: []].insert(CallsignParser.identityKey(for: from, mode: identityMode))
                }
            }
            if let to = event.to {
                if isStationIncludedInMetrics(to) {
                    uniqueStations[key, default: []].insert(CallsignParser.identityKey(for: to, mode: identityMode))
                }
            }
            if includeVia {
                event.repeatedVia.forEach { via in
                    if isStationIncludedInMetrics(via) {
                        uniqueStations[key, default: []].insert(CallsignParser.identityKey(for: via, mode: identityMode))
                    }
                }
            }
        }

        let buckets = sortedBucketKeys(
            from: events,
            bucket: bucket,
            calendar: calendar,
            timeframeInterval: timeframeInterval
        )

        let packets = buckets.map { bucketKey in
            AnalyticsSeriesPoint(bucket: bucketKey.date, value: packetCounts[bucketKey, default: 0])
        }
        let bytes = buckets.map { bucketKey in
            AnalyticsSeriesPoint(bucket: bucketKey.date, value: payloadBytes[bucketKey, default: 0])
        }
        let unique = buckets.map { bucketKey in
            AnalyticsSeriesPoint(bucket: bucketKey.date, value: uniqueStations[bucketKey]?.count ?? 0)
        }
        let ui = buckets.map { AnalyticsSeriesPoint(bucket: $0.date, value: uiCounts[$0, default: 0]) }
        let iFrames = buckets.map { AnalyticsSeriesPoint(bucket: $0.date, value: iCounts[$0, default: 0]) }
        let other = buckets.map { AnalyticsSeriesPoint(bucket: $0.date, value: otherCounts[$0, default: 0]) }
        let rejects = buckets.map { AnalyticsSeriesPoint(bucket: $0.date, value: rejectCounts[$0, default: 0]) }

        return AnalyticsSeries(
            packetsPerBucket: packets,
            bytesPerBucket: bytes,
            uniqueStationsPerBucket: unique,
            uiFramesPerBucket: ui,
            iFramesPerBucket: iFrames,
            otherFramesPerBucket: other,
            rejectFramesPerBucket: rejects
        )
    }

    private static func sortedBucketKeys(
        from events: [PacketEvent],
        bucket: TimeBucket,
        calendar: Calendar,
        timeframeInterval: DateInterval?
    ) -> [BucketKey] {
        if let timeframeInterval {
            let clampedEnd = max(timeframeInterval.start, timeframeInterval.end.addingTimeInterval(-0.001))
            let start = bucket.normalizedStart(for: timeframeInterval.start, calendar: calendar)
            let end = bucket.normalizedStart(for: clampedEnd, calendar: calendar)
            guard start <= end else { return [] }
            return generateBucketKeys(start: start, end: end, bucket: bucket, calendar: calendar)
        }

        guard let minDate = events.map({ $0.timestamp }).min(),
              let maxDate = events.map({ $0.timestamp }).max() else {
            return []
        }

        let start = bucket.normalizedStart(for: minDate, calendar: calendar)
        let end = bucket.normalizedStart(for: maxDate, calendar: calendar)
        return generateBucketKeys(start: start, end: end, bucket: bucket, calendar: calendar)
    }

    private static func generateBucketKeys(
        start: Date,
        end: Date,
        bucket: TimeBucket,
        calendar: Calendar
    ) -> [BucketKey] {
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

    private static func computeHeatmap(
        events: [PacketEvent],
        calendar: Calendar,
        timeframeInterval: DateInterval?
    ) -> HeatmapData {
        guard !events.isEmpty else { return .empty }

        let firstDay: Date
        let lastDay: Date
        if let timeframeInterval {
            let clampedEnd = max(timeframeInterval.start, timeframeInterval.end.addingTimeInterval(-0.001))
            firstDay = calendar.startOfDay(for: timeframeInterval.start)
            lastDay = calendar.startOfDay(for: clampedEnd)
        } else {
            let dayStarts = events
                .map { calendar.startOfDay(for: $0.timestamp) }
                .sorted()
            guard let eventFirstDay = dayStarts.first, let eventLastDay = dayStarts.last else {
                return .empty
            }
            firstDay = eventFirstDay
            lastDay = eventLastDay
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

        // Zero-payload frames (RR/UA/SABM/DISC and friends) are the majority of
        // connected-mode traffic and would flood the first bin, collapsing the
        // distribution of actual data frames into one bar.
        let payloads = events.map { $0.payloadBytes }.filter { $0 > 0 }
        guard !payloads.isEmpty else { return .empty }
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

    private static func rankTop(
        stations: [String],
        limit: Int,
        identityMode: StationIdentityMode
    ) -> [RankRow] {
        guard limit > 0 else { return [] }
        var counts: [String: Int] = [:]
        for station in stations {
            // Tactical aliases (NET/ROM node idents) are real stations and rank
            // like callsigns; service endpoints and garbage stay excluded.
            guard CallsignValidator.isValidRoutingNode(station) else { continue }
            counts[CallsignParser.identityKey(for: station, mode: identityMode), default: 0] += 1
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

    private static func isStationIncludedInMetrics(_ station: String) -> Bool {
        CallsignValidator.isValidRoutingNode(station)
    }
}
