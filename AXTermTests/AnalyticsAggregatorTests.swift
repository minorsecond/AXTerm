import Foundation
import Testing
@testable import AXTerm

struct AnalyticsAggregatorTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    @Test
    func bucketingCountsAcrossBoundaries() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let packets = [
            makePacket(timestamp: base.addingTimeInterval(60 * 5), from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base.addingTimeInterval(60 * 55), from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base.addingTimeInterval(60 * 65), from: "CHARLIE", to: "BRAVO")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .hour,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3)
        )

        let counts = result.series.packetsPerBucket.map { $0.value }
        #expect(counts.count == 2)
        #expect(counts[0] == 2)
        #expect(counts[1] == 1)
    }

    @Test
    func bytesSumCorrect() {
        let base = Date(timeIntervalSince1970: 1_700_010_000)
        let packets = [
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO", infoBytes: 10),
            makePacket(timestamp: base.addingTimeInterval(60), from: "BRAVO", to: "ALPHA", infoBytes: 22)
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3)
        )

        #expect(result.summary.totalPayloadBytes == 32)
    }

    @Test
    func uniqueStationsPerBucketCorrect() {
        let base = Date(timeIntervalSince1970: 1_700_020_000)
        let packets = [
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base, from: "ALPHA", to: "DELTA"),
            makePacket(timestamp: base.addingTimeInterval(3600), from: "ECHO", to: "FOXTROT")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .hour,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3)
        )

        let uniqueCounts = result.series.uniqueStationsPerBucket.map { $0.value }
        #expect(uniqueCounts.count == 2)
        #expect(uniqueCounts[0] == 3)
        #expect(uniqueCounts[1] == 2)
    }

    @Test
    func heatmapSumMatchesPacketTotal() {
        let base = Date(timeIntervalSince1970: 1_700_030_000)
        let packets = [
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base.addingTimeInterval(3600), from: "BRAVO", to: "CHARLIE"),
            makePacket(timestamp: base.addingTimeInterval(7200), from: "DELTA", to: "ECHO")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .hour,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3)
        )

        let heatmapTotal = result.heatmap.matrix.flatMap { $0 }.reduce(0, +)
        #expect(heatmapTotal == result.summary.totalPackets)
    }

    @Test
    func histogramBinningCorrect() {
        let base = Date(timeIntervalSince1970: 1_700_040_000)
        let packets = [
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO", infoBytes: 5),
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO", infoBytes: 15),
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO", infoBytes: 35)
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 2, topLimit: 3)
        )

        #expect(result.histogram.bins.count == 2)
        #expect(result.histogram.bins[0].count == 2)
        #expect(result.histogram.bins[1].count == 1)
    }

    @Test
    func topNRankingStableForTies() {
        let base = Date(timeIntervalSince1970: 1_700_050_000)
        let packets = [
            makePacket(timestamp: base, from: "BRAVO", to: "ALPHA"),
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base, from: "CHARLIE", to: "ALPHA")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 2)
        )

        #expect(result.topTalkers.map { $0.label } == ["ALPHA", "BRAVO"])
    }

    private func makePacket(
        timestamp: Date,
        from: String,
        to: String,
        via: [String] = [],
        infoBytes: Int = 10
    ) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: .ui,
            info: Data(repeating: 0x41, count: infoBytes)
        )
    }
}
