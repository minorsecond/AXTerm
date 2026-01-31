//
//  AnalyticsEngine.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-18.
//

import Foundation

enum AnalyticsEngine {
    static func normalizePackets(_ packets: [Packet]) -> [PacketEvent] {
        packets.map { PacketEvent(packet: $0) }
    }

    static func uniqueStationsCount(packets: [Packet], includeViaInUniqueStations: Bool = true) -> Int {
        let events = normalizePackets(packets)
        return uniqueStationsCount(events: events, includeViaInUniqueStations: includeViaInUniqueStations)
    }

    static func computeSummary(
        packets: [Packet],
        includeViaInUniqueStations: Bool = true,
        topLimit: Int = 5
    ) -> AnalyticsSummary {
        let events = normalizePackets(packets)
        return computeSummary(
            events: events,
            includeViaInUniqueStations: includeViaInUniqueStations,
            topLimit: topLimit
        )
    }

    static func computeSeries(
        packets: [Packet],
        bucket: TimeBucket,
        calendar: Calendar,
        includeViaInUniqueStations: Bool = true
    ) -> AnalyticsSeries {
        guard !packets.isEmpty else { return .empty }
        let events = normalizePackets(packets)
        var packetCounts: [BucketKey: Int] = [:]
        var payloadBytes: [BucketKey: Int] = [:]
        var uniqueStations: [BucketKey: Set<String>] = [:]

        events.forEach { event in
            let key = BucketKey(date: event.timestamp, bucket: bucket, calendar: calendar)
            packetCounts[key, default: 0] += 1
            payloadBytes[key, default: 0] += event.payloadBytes
            if let from = event.from {
                uniqueStations[key, default: []].insert(from)
            }
            if let to = event.to {
                uniqueStations[key, default: []].insert(to)
            }
            if includeViaInUniqueStations {
                event.via.forEach { station in
                    uniqueStations[key, default: []].insert(station)
                }
            }
        }

        let bucketKeys = packetCounts.keys.sorted()
        let packets = bucketKeys.map { AnalyticsSeriesPoint(bucket: $0.date, value: packetCounts[$0, default: 0]) }
        let bytes = bucketKeys.map { AnalyticsSeriesPoint(bucket: $0.date, value: payloadBytes[$0, default: 0]) }
        let unique = bucketKeys.map { AnalyticsSeriesPoint(bucket: $0.date, value: uniqueStations[$0]?.count ?? 0) }

        return AnalyticsSeries(
            packetsPerBucket: packets,
            bytesPerBucket: bytes,
            uniqueStationsPerBucket: unique
        )
    }

    private static func computeSummary(
        events: [PacketEvent],
        includeViaInUniqueStations: Bool,
        topLimit: Int
    ) -> AnalyticsSummary {
        let packetCount = events.count
        let totalPayloadBytes = events.reduce(0) { $0 + $1.payloadBytes }
        let infoTextCount = events.reduce(0) { $1.infoTextPresent ? $0 + 1 : $0 }
        let infoTextRatio = packetCount > 0 ? Double(infoTextCount) / Double(packetCount) : 0

        var frameTypeCounts: [FrameType: Int] = [:]
        frameTypeCounts.reserveCapacity(FrameType.allCases.count)
        events.forEach { event in
            frameTypeCounts[event.frameType, default: 0] += 1
        }

        let uniqueStationsCount = uniqueStationsCount(events: events, includeViaInUniqueStations: includeViaInUniqueStations)

        let topTalkersByFrom = topStations(from: events.compactMap { $0.from }, limit: topLimit)
        let topDestinationsByTo = topStations(from: events.compactMap { $0.to }, limit: topLimit)

        return AnalyticsSummary(
            packetCount: packetCount,
            uniqueStationsCount: uniqueStationsCount,
            topTalkersByFrom: topTalkersByFrom,
            topDestinationsByTo: topDestinationsByTo,
            frameTypeCounts: frameTypeCounts,
            infoTextRatio: infoTextRatio,
            totalPayloadBytes: totalPayloadBytes
        )
    }

    private static func uniqueStationsCount(
        events: [PacketEvent],
        includeViaInUniqueStations: Bool
    ) -> Int {
        var uniqueStations: Set<String> = []
        events.forEach { event in
            if let from = event.from {
                uniqueStations.insert(from)
            }
            if let to = event.to {
                uniqueStations.insert(to)
            }
            if includeViaInUniqueStations {
                event.via.forEach { uniqueStations.insert($0) }
            }
        }
        return uniqueStations.count
    }

    private static func topStations(from stations: [String], limit: Int) -> [StationCount] {
        guard limit > 0 else { return [] }
        var counts: [String: Int] = [:]
        stations.forEach { station in
            counts[station, default: 0] += 1
        }
        return counts
            .map { StationCount(station: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.station < rhs.station
            }
            return lhs.count > rhs.count
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func points(from values: [BucketKey: Int]) -> [AnalyticsSeriesPoint] {
        values
            .map { AnalyticsSeriesPoint(bucket: $0.key.date, value: $0.value) }
            .sorted { lhs, rhs in
                if lhs.bucket == rhs.bucket {
                    return lhs.value < rhs.value
                }
                return lhs.bucket < rhs.bucket
            }
    }
}
