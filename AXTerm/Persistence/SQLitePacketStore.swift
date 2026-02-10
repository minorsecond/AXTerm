//
//  SQLitePacketStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
import GRDB

nonisolated final class SQLitePacketStore: PacketStore, PacketStoreAnalyticsQuerying, PacketStoreTimeRangeQuerying, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    convenience init() throws {
        try self.init(dbQueue: DatabaseManager.makeDatabaseQueue())
    }

    func save(_ packet: Packet) throws {
        guard let endpoint = packet.kissEndpoint else {
            throw PacketStoreError.missingKISSEndpoint
        }
        let record = try PacketRecord(packet: packet, endpoint: endpoint)
        try dbQueue.write { db in
            try record.insert(db)
        }
    }

    func loadRecent(limit: Int) throws -> [PacketRecord] {
        try dbQueue.read { db in
            try PacketRecord
                .order(Column("receivedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func loadPackets(in timeframe: DateInterval) throws -> [Packet] {
        try dbQueue.read { db in
            let sql = """
                SELECT id, receivedAt, fromCall, fromSSID, toCall, toSSID, viaPath, frameType, controlHex, pid
                FROM \(PacketRecord.databaseTableName)
                WHERE receivedAt >= ? AND receivedAt < ?
                ORDER BY receivedAt ASC
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [timeframe.start, timeframe.end])
            return rows.map { row in
                let id: UUID = row["id"]
                let timestamp: Date = row["receivedAt"]
                let fromCall: String = row["fromCall"]
                let fromSSID: Int = row["fromSSID"]
                let toCall: String = row["toCall"]
                let toSSID: Int = row["toSSID"]
                let viaPath: String = row["viaPath"]
                let frameTypeRaw: String = row["frameType"]
                let controlHex: String = row["controlHex"]
                let pidValue: Int? = row["pid"]

                return Packet(
                    id: id,
                    timestamp: timestamp,
                    from: AX25Address(call: fromCall, ssid: fromSSID),
                    to: AX25Address(call: toCall, ssid: toSSID),
                    via: PacketEncoding.decodeViaPath(viaPath),
                    frameType: FrameType(rawValue: frameTypeRaw) ?? .unknown,
                    control: PacketEncoding.decodeControl(controlHex),
                    pid: pidValue.map { UInt8(clamping: $0) },
                    info: Data(),
                    rawAx25: Data(),
                    kissEndpoint: nil,
                    infoText: nil
                )
            }
        }
    }

    func deleteAll() throws {
        try dbQueue.write { db in
            _ = try PacketRecord.deleteAll(db)
            // Reclaim disk space immediately
            try db.execute(sql: "PRAGMA incremental_vacuum")
        }
    }

    func setPinned(packetId: UUID, pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(PacketRecord.databaseTableName) SET pinned = ? WHERE id = ?",
                arguments: [pinned, packetId]
            )
        }
    }

    func pruneIfNeeded(retentionLimit: Int) throws {
        guard retentionLimit > 0 else { return }
        try dbQueue.write { db in
            let total = try PacketRecord.fetchCount(db)
            guard total > retentionLimit else { return }
            let overflow = total - retentionLimit
            if overflow <= 0 { return }
            try db.execute(
                sql: """
                DELETE FROM \(PacketRecord.databaseTableName)
                WHERE id IN (
                    SELECT id FROM \(PacketRecord.databaseTableName)
                    ORDER BY receivedAt ASC
                    LIMIT ?
                )
                """,
                arguments: [overflow]
            )
            // Reclaim disk space incrementally (up to 100 pages ~400KB at a time)
            try db.execute(sql: "PRAGMA incremental_vacuum(100)")
        }
    }

    func count() throws -> Int {
        try dbQueue.read { db in
            try PacketRecord.fetchCount(db)
        }
    }

    /// Load all packets in chronological order (oldest first) for replay.
    /// Used by debug rebuild functionality.
    func loadAllChronological() throws -> [PacketRecord] {
        try dbQueue.read { db in
            try PacketRecord
                .order(Column("receivedAt").asc)
                .fetchAll(db)
        }
    }

    func aggregateAnalytics(
        in timeframe: DateInterval,
        bucket: TimeBucket,
        calendar: Calendar,
        options: AnalyticsAggregator.Options
    ) throws -> AnalyticsAggregationResult {
        try dbQueue.read { db in
            let start = timeframe.start
            let end = timeframe.end

            guard end > start else {
                return Self.emptyAggregation(interval: timeframe, bucket: bucket, calendar: calendar)
            }

            let baseSQL = """
                SELECT receivedAt, fromCall, fromSSID, toCall, toSSID, viaPath, frameType, infoText, infoLen
                FROM \(PacketRecord.databaseTableName)
                WHERE receivedAt >= ? AND receivedAt < ?
            """
            let args: StatementArguments = [start, end]

            var totalPackets = 0
            var totalPayloadBytes = 0
            var infoTextCount = 0
            var uiFrames = 0
            var iFrames = 0
            var maxPayload = 0

            var uniqueStations: Set<String> = []
            var packetCounts: [BucketKey: Int] = [:]
            var payloadBytes: [BucketKey: Int] = [:]
            var uniqueStationsByBucket: [BucketKey: Set<String>] = [:]
            var heatmapCounts: [Date: [Int]] = [:]
            var talkerCounts: [String: Int] = [:]
            var destinationCounts: [String: Int] = [:]
            var digipeaterCounts: [String: Int] = [:]

            let clampedEnd = max(start, end.addingTimeInterval(-0.001))
            let heatmapStartDay = calendar.startOfDay(for: start)
            let heatmapEndDay = calendar.startOfDay(for: clampedEnd)

            var day = heatmapStartDay
            while day <= heatmapEndDay {
                heatmapCounts[day] = Array(repeating: 0, count: 24)
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }

            let rows = try Row.fetchCursor(db, sql: baseSQL, arguments: args)
            while let row = try rows.next() {
                totalPackets += 1

                let timestamp: Date = row["receivedAt"]
                let fromCall: String = row["fromCall"]
                let fromSSID: Int = row["fromSSID"]
                let toCall: String = row["toCall"]
                let toSSID: Int = row["toSSID"]
                let viaPath: String = row["viaPath"]
                let frameTypeRaw: String = row["frameType"]
                let infoText: String? = row["infoText"]
                let payloadLength: Int = row["infoLen"]

                totalPayloadBytes += payloadLength
                maxPayload = max(maxPayload, payloadLength)
                if let infoText, !infoText.isEmpty {
                    infoTextCount += 1
                }

                if frameTypeRaw == FrameType.ui.rawValue {
                    uiFrames += 1
                } else if frameTypeRaw == FrameType.i.rawValue {
                    iFrames += 1
                }

                let fromDisplay = CallsignNormalizer.display(call: fromCall, ssid: fromSSID)
                let toDisplay = CallsignNormalizer.display(call: toCall, ssid: toSSID)
                let from = StationNormalizer.normalize(fromDisplay)
                let to = StationNormalizer.normalize(toDisplay)
                let via = PacketEncoding.decodeViaPath(viaPath).compactMap { StationNormalizer.normalize($0.display) }

                if let from {
                    talkerCounts[from, default: 0] += 1
                    uniqueStations.insert(from)
                }
                if let to {
                    talkerCounts[to, default: 0] += 1
                    destinationCounts[to, default: 0] += 1
                    uniqueStations.insert(to)
                }

                if options.includeViaDigipeaters {
                    for station in via {
                        uniqueStations.insert(station)
                    }
                }
                for station in via {
                    digipeaterCounts[station, default: 0] += 1
                }

                let seriesKey = BucketKey(date: timestamp, bucket: bucket, calendar: calendar)
                packetCounts[seriesKey, default: 0] += 1
                payloadBytes[seriesKey, default: 0] += payloadLength

                var bucketStations = uniqueStationsByBucket[seriesKey, default: []]
                if let from { bucketStations.insert(from) }
                if let to { bucketStations.insert(to) }
                if options.includeViaDigipeaters {
                    for station in via {
                        bucketStations.insert(station)
                    }
                }
                uniqueStationsByBucket[seriesKey] = bucketStations

                let packetDay = calendar.startOfDay(for: timestamp)
                let packetHour = calendar.component(.hour, from: timestamp)
                if var rowCounts = heatmapCounts[packetDay], packetHour >= 0, packetHour < 24 {
                    rowCounts[packetHour] += 1
                    heatmapCounts[packetDay] = rowCounts
                }
            }

            let summary = AnalyticsSummaryMetrics(
                totalPackets: totalPackets,
                uniqueStations: uniqueStations.count,
                totalPayloadBytes: totalPayloadBytes,
                uiFrames: uiFrames,
                iFrames: iFrames,
                infoTextRatio: totalPackets > 0 ? Double(infoTextCount) / Double(totalPackets) : 0
            )

            let seriesBucketKeys = Self.bucketKeys(interval: timeframe, bucket: bucket, calendar: calendar)
            let series = AnalyticsSeries(
                packetsPerBucket: seriesBucketKeys.map { AnalyticsSeriesPoint(bucket: $0.date, value: packetCounts[$0, default: 0]) },
                bytesPerBucket: seriesBucketKeys.map { AnalyticsSeriesPoint(bucket: $0.date, value: payloadBytes[$0, default: 0]) },
                uniqueStationsPerBucket: seriesBucketKeys.map { AnalyticsSeriesPoint(bucket: $0.date, value: uniqueStationsByBucket[$0]?.count ?? 0) }
            )

            let days = Self.dayRange(startDay: heatmapStartDay, endDay: heatmapEndDay, calendar: calendar)
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            let heatmap = HeatmapData(
                matrix: days.map { heatmapCounts[$0] ?? Array(repeating: 0, count: 24) },
                xLabels: (0..<24).map { String(format: "%02d", $0) },
                yLabels: days.map { formatter.string(from: $0) }
            )

            let histogram = try Self.computeHistogram(
                db: db,
                start: start,
                end: end,
                maxPayload: maxPayload,
                binCount: options.histogramBinCount
            )

            return AnalyticsAggregationResult(
                summary: summary,
                series: series,
                heatmap: heatmap,
                histogram: histogram,
                topTalkers: Self.rankRows(from: talkerCounts, limit: options.topLimit),
                topDestinations: Self.rankRows(from: destinationCounts, limit: options.topLimit),
                topDigipeaters: Self.rankRows(from: digipeaterCounts, limit: options.topLimit)
            )
        }
    }

    private static func computeHistogram(
        db: Database,
        start: Date,
        end: Date,
        maxPayload: Int,
        binCount: Int
    ) throws -> HistogramData {
        guard binCount > 0 else { return .empty }
        let bucketSize = max(1, Int(ceil(Double(maxPayload + 1) / Double(binCount))))
        var bins = Array(repeating: 0, count: binCount)

        let payloadRows = try Row.fetchCursor(
            db,
            sql: """
                SELECT infoLen
                FROM \(PacketRecord.databaseTableName)
                WHERE receivedAt >= ? AND receivedAt < ?
            """,
            arguments: [start, end]
        )
        while let row = try payloadRows.next() {
            let payload: Int = row["infoLen"]
            let index = min(binCount - 1, max(0, payload / bucketSize))
            bins[index] += 1
        }

        let histogramBins = bins.enumerated().map { index, count in
            HistogramBin(
                lowerBound: index * bucketSize,
                upperBound: (index + 1) * bucketSize - 1,
                count: count
            )
        }
        return HistogramData(bins: histogramBins, maxValue: maxPayload)
    }

    private static func bucketKeys(interval: DateInterval, bucket: TimeBucket, calendar: Calendar) -> [BucketKey] {
        guard interval.end > interval.start else { return [] }
        let clampedEnd = max(interval.start, interval.end.addingTimeInterval(-0.001))
        let start = bucket.normalizedStart(for: interval.start, calendar: calendar)
        let end = bucket.normalizedStart(for: clampedEnd, calendar: calendar)
        guard start <= end else { return [] }

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
            return calendar.date(byAdding: .second, value: 10, to: date) ?? date.addingTimeInterval(10)
        case .minute:
            return calendar.date(byAdding: .minute, value: 1, to: date) ?? date.addingTimeInterval(60)
        case .fiveMinutes:
            return calendar.date(byAdding: .minute, value: 5, to: date) ?? date.addingTimeInterval(300)
        case .fifteenMinutes:
            return calendar.date(byAdding: .minute, value: 15, to: date) ?? date.addingTimeInterval(900)
        case .hour:
            return calendar.date(byAdding: .hour, value: 1, to: date) ?? date.addingTimeInterval(3_600)
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        }
    }

    private static func dayRange(startDay: Date, endDay: Date, calendar: Calendar) -> [Date] {
        guard startDay <= endDay else { return [] }
        var days: [Date] = []
        var current = startDay
        while current <= endDay {
            days.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? current.addingTimeInterval(86_400)
        }
        return days
    }

    private static func rankRows(from counts: [String: Int], limit: Int) -> [RankRow] {
        guard limit > 0 else { return [] }
        return counts
            .filter { CallsignValidator.isValidCallsign($0.key) }
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

    private static func emptyAggregation(
        interval: DateInterval,
        bucket: TimeBucket,
        calendar: Calendar
    ) -> AnalyticsAggregationResult {
        let keys = bucketKeys(interval: interval, bucket: bucket, calendar: calendar)
        let emptySeries = AnalyticsSeries(
            packetsPerBucket: keys.map { AnalyticsSeriesPoint(bucket: $0.date, value: 0) },
            bytesPerBucket: keys.map { AnalyticsSeriesPoint(bucket: $0.date, value: 0) },
            uniqueStationsPerBucket: keys.map { AnalyticsSeriesPoint(bucket: $0.date, value: 0) }
        )
        return AnalyticsAggregationResult(
            summary: AnalyticsSummaryMetrics(
                totalPackets: 0,
                uniqueStations: 0,
                totalPayloadBytes: 0,
                uiFrames: 0,
                iFrames: 0,
                infoTextRatio: 0
            ),
            series: emptySeries,
            heatmap: .empty,
            histogram: .empty,
            topTalkers: [],
            topDestinations: [],
            topDigipeaters: []
        )
    }
}

nonisolated enum PacketStoreError: Error {
    case missingKISSEndpoint
}
