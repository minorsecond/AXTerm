import Foundation
import XCTest
@testable import AXTerm

final class AnalyticsAggregatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    func testBucketingCountsAcrossBoundaries() {
        let seed = Date(timeIntervalSince1970: 1_700_000_000)
        let base = calendar.dateInterval(of: .hour, for: seed)?.start ?? seed
        let packets = [
            makePacket(timestamp: base.addingTimeInterval(60 * 5), from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(60 * 55), from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(60 * 65), from: "N3CHR", to: "W5BRV")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .hour,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3)
        )

        let counts = result.series.packetsPerBucket.map { $0.value }
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts[0], 2)
        XCTAssertEqual(counts[1], 1)
    }

    func testBytesSumCorrect() {
        let base = Date(timeIntervalSince1970: 1_700_010_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV", infoBytes: 10),
            makePacket(timestamp: base.addingTimeInterval(60), from: "W5BRV", to: "K9ALP", infoBytes: 22)
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3)
        )

        XCTAssertEqual(result.summary.totalPayloadBytes, 32)
    }

    func testUniqueStationsPerBucketCorrect() {
        let base = Date(timeIntervalSince1970: 1_700_020_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base, from: "K9ALP", to: "W4DEL"),
            makePacket(timestamp: base.addingTimeInterval(3600), from: "K5ECH", to: "W6FOX")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .hour,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3)
        )

        let uniqueCounts = result.series.uniqueStationsPerBucket.map { $0.value }
        XCTAssertEqual(uniqueCounts.count, 2)
        XCTAssertEqual(uniqueCounts[0], 3)
        XCTAssertEqual(uniqueCounts[1], 2)
    }

    func testHeatmapSumMatchesPacketTotal() {
        let base = Date(timeIntervalSince1970: 1_700_030_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(3600), from: "W5BRV", to: "N3CHR"),
            makePacket(timestamp: base.addingTimeInterval(7200), from: "W4DEL", to: "K5ECH")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .hour,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3)
        )

        let heatmapTotal = result.heatmap.matrix.flatMap { $0 }.reduce(0, +)
        XCTAssertEqual(heatmapTotal, result.summary.totalPackets)
    }

    func testHistogramBinningCorrect() {
        let base = Date(timeIntervalSince1970: 1_700_040_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV", infoBytes: 5),
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV", infoBytes: 15),
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV", infoBytes: 35)
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 2, topLimit: 3)
        )

        XCTAssertEqual(result.histogram.bins.count, 2)
        XCTAssertEqual(result.histogram.bins[0].count, 2)
        XCTAssertEqual(result.histogram.bins[1].count, 1)
    }

    func testTopNRankingStableForTies() {
        let base = Date(timeIntervalSince1970: 1_700_050_000)
        let packets = [
            makePacket(timestamp: base, from: "W5BRV", to: "K9ALP"),
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base, from: "N3CHR", to: "K9ALP")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 2)
        )

        // Senders only: each station sent exactly one frame, so ties break alphabetically.
        XCTAssertEqual(result.topTalkers.map { $0.label }, ["K9ALP", "N3CHR"])
    }

    func testTimeframeIntervalPadsSeriesAndHeatmap() {
        let now = Date(timeIntervalSince1970: 1_700_100_000) // 2023-11-15T02:00:00Z
        let interval = DateInterval(
            start: now.addingTimeInterval(-(2 * 24 * 60 * 60)),
            end: now
        )
        let packets = [
            makePacket(timestamp: interval.start.addingTimeInterval(5 * 3600), from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: interval.end.addingTimeInterval(-2 * 3600), from: "N3CHR", to: "W4DEL")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .hour,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3),
            timeframeInterval: interval
        )

        XCTAssertEqual(result.series.packetsPerBucket.count, 48)
        XCTAssertEqual(result.heatmap.yLabels.count, 3)
        XCTAssertEqual(result.heatmap.matrix.flatMap { $0 }.reduce(0, +), 2)
    }

    func testTopListsExcludeNonCallsignIdentifiers() {
        let base = Date(timeIntervalSince1970: 1_700_060_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "BEACON", via: ["WIDE1"]),
            makePacket(timestamp: base.addingTimeInterval(60), from: "ID", to: "W5BRV", via: ["RELAY"]),
            makePacket(timestamp: base.addingTimeInterval(120), from: "N3CHR", to: "W5BRV", via: ["K8DIG"])
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: true, histogramBinCount: 4, topLimit: 10)
        )

        XCTAssertFalse(result.topTalkers.map(\.label).contains("BEACON"))
        XCTAssertFalse(result.topTalkers.map(\.label).contains("ID"))
        XCTAssertFalse(result.topDestinations.map(\.label).contains("BEACON"))
        XCTAssertFalse(result.topDigipeaters.map(\.label).contains("WIDE1"))
        XCTAssertFalse(result.topDigipeaters.map(\.label).contains("RELAY"))
        XCTAssertTrue(result.topDigipeaters.map(\.label).contains("K8DIG"))
    }

    func testTopTalkersRankSendersOnly() {
        let base = Date(timeIntervalSince1970: 1_700_070_000)
        // W5BRV receives three frames but sends none; it must not appear as a talker.
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(30), from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(60), from: "N3CHR", to: "W5BRV")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 5)
        )

        XCTAssertEqual(result.topTalkers.map(\.label), ["K9ALP", "N3CHR"])
        XCTAssertEqual(result.topTalkers.map(\.count), [2, 1])
        XCTAssertFalse(result.topTalkers.map(\.label).contains("W5BRV"))
        XCTAssertEqual(result.topDestinations.first?.label, "W5BRV")
    }

    func testTopDigipeatersIgnoreUnrepeatedPathEntries() {
        let base = Date(timeIntervalSince1970: 1_700_080_000)
        let packets = [
            // K8DIG actually repeated (H bit set); K7REQ was requested but never acted.
            Packet(
                timestamp: base,
                from: AX25Address(call: "K9ALP"),
                to: AX25Address(call: "W5BRV"),
                via: [
                    AX25Address(call: "K8DIG", repeated: true),
                    AX25Address(call: "K7REQ", repeated: false)
                ],
                frameType: .ui,
                info: Data(repeating: 0x41, count: 10)
            )
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: true, histogramBinCount: 4, topLimit: 5)
        )

        XCTAssertEqual(result.topDigipeaters.map(\.label), ["K8DIG"])
    }

    func testUniqueStationsExcludeUnrepeatedVia() {
        let base = Date(timeIntervalSince1970: 1_700_090_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV", via: ["K7REQ"], viaRepeated: false)
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: true, histogramBinCount: 4, topLimit: 5)
        )

        // Only the two endpoints were actually observed on air.
        XCTAssertEqual(result.summary.uniqueStations, 2)
    }

    func testStationIdentityModeGroupsSSIDs() {
        let base = Date(timeIntervalSince1970: 1_700_095_000)
        let packets = [
            makePacket(timestamp: base, from: "K0NTS-1", to: "W1AAA"),
            makePacket(timestamp: base.addingTimeInterval(10), from: "K0NTS-10", to: "W1AAA"),
            makePacket(timestamp: base.addingTimeInterval(20), from: "K0NTS-1", to: "W1AAA")
        ]

        // Station mode: SSIDs collapse to the base callsign, matching the graph
        // and the health panel — one "K0NTS" talker, two unique stations.
        let station = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(
                includeViaDigipeaters: false,
                histogramBinCount: 4,
                topLimit: 5,
                stationIdentityMode: .station
            )
        )
        XCTAssertEqual(station.summary.uniqueStations, 2)
        XCTAssertEqual(station.topTalkers.map(\.label), ["K0NTS"])
        XCTAssertEqual(station.topTalkers.first?.count, 3)

        // SSID mode: each SSID is its own station.
        let ssid = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(
                includeViaDigipeaters: false,
                histogramBinCount: 4,
                topLimit: 5,
                stationIdentityMode: .ssid
            )
        )
        XCTAssertEqual(ssid.summary.uniqueStations, 3)
        XCTAssertEqual(ssid.topTalkers.map(\.label), ["K0NTS-1", "K0NTS-10"])
    }

    func testTopTalkersIncludeTacticalAliases() {
        // A NET/ROM node ident that transmits is a talker; service names stay out.
        let base = Date(timeIntervalSince1970: 1_700_096_000)
        let packets = [
            makePacket(timestamp: base, from: "DRLNOD", to: "K0EPI"),
            makePacket(timestamp: base.addingTimeInterval(5), from: "DRLNOD", to: "K0EPI"),
            makePacket(timestamp: base.addingTimeInterval(10), from: "K0EPI", to: "DRLNOD"),
            makePacket(timestamp: base.addingTimeInterval(15), from: "BEACON", to: "K0EPI")
        ]

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 5)
        )

        XCTAssertEqual(result.topTalkers.map(\.label), ["DRLNOD", "K0EPI"])
        XCTAssertTrue(result.topDestinations.map(\.label).contains("DRLNOD"))
        XCTAssertFalse(result.topTalkers.map(\.label).contains("BEACON"))
    }

    func testFrameTypeAndRejectSeriesSumToPacketCounts() {
        let base = Date(timeIntervalSince1970: 1_700_097_000)
        var packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV"),                       // UI
            makePacket(timestamp: base.addingTimeInterval(5), from: "K9ALP", to: "W5BRV")  // UI
        ]
        // I frame
        packets.append(Packet(
            timestamp: base.addingTimeInterval(10),
            from: AX25Address(call: "K9ALP"),
            to: AX25Address(call: "W5BRV"),
            frameType: .i,
            control: 0x00,
            info: Data(repeating: 0x41, count: 5)
        ))
        // REJ supervisory frame (mod-8: sType bits = 2 -> control 0x09)
        packets.append(Packet(
            timestamp: base.addingTimeInterval(15),
            from: AX25Address(call: "W5BRV"),
            to: AX25Address(call: "K9ALP"),
            frameType: .s,
            control: 0x09,
            info: Data()
        ))
        // RR supervisory frame (sType 0) — not a reject
        packets.append(Packet(
            timestamp: base.addingTimeInterval(20),
            from: AX25Address(call: "W5BRV"),
            to: AX25Address(call: "K9ALP"),
            frameType: .s,
            control: 0x01,
            info: Data()
        ))

        let result = AnalyticsAggregator.aggregate(
            packets: packets,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(includeViaDigipeaters: false, histogramBinCount: 4, topLimit: 3)
        )

        let ui = result.series.uiFramesPerBucket.map(\.value).reduce(0, +)
        let iFrames = result.series.iFramesPerBucket.map(\.value).reduce(0, +)
        let other = result.series.otherFramesPerBucket.map(\.value).reduce(0, +)
        let rejects = result.series.rejectFramesPerBucket.map(\.value).reduce(0, +)

        XCTAssertEqual(ui, 2)
        XCTAssertEqual(iFrames, 1)
        XCTAssertEqual(other, 2, "S frames land in Other")
        XCTAssertEqual(ui + iFrames + other, result.summary.totalPackets,
                       "Frame-type series must sum to the packet series")
        XCTAssertEqual(rejects, 1, "Only REJ/SREJ count as retransmit requests")
    }

    func testChannelUtilizationModel() {
        // Zero traffic is zero airtime.
        XCTAssertEqual(AnalyticsStyle.Channel.utilizationPercent(packets: 0, payloadBytes: 0, bucketSeconds: 60), 0)

        // 10 frames of 128-byte payload in a 60 s bucket at 1200 baud:
        // 10 × 0.3 s overhead + 10 × (128 + 32) × 8 / 1200 ≈ 3 + 10.67 ≈ 13.7 s → 23%.
        let moderate = AnalyticsStyle.Channel.utilizationPercent(packets: 10, payloadBytes: 1280, bucketSeconds: 60)
        XCTAssertEqual(moderate, 23)

        // Saturation clamps at 100%.
        XCTAssertEqual(AnalyticsStyle.Channel.utilizationPercent(packets: 500, payloadBytes: 64_000, bucketSeconds: 60), 100)
    }

    private func makePacket(
        timestamp: Date,
        from: String,
        to: String,
        via: [String] = [],
        viaRepeated: Bool = true,
        infoBytes: Int = 10
    ) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0, repeated: viaRepeated) },
            frameType: .ui,
            info: Data(repeating: 0x41, count: infoBytes)
        )
    }
}
