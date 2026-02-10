//
//  SQLitePacketStoreTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import XCTest
import GRDB
@testable import AXTerm

final class SQLitePacketStoreTests: XCTestCase {
    func testRoundTripOrderingAndPinned() throws {
        let store = try makeStore()
        let endpoint = try makeEndpoint()
        let first = Packet(
            timestamp: Date(timeIntervalSince1970: 10),
            from: AX25Address(call: "CALL1"),
            to: AX25Address(call: "DEST"),
            frameType: .ui,
            control: 0x03,
            info: Data([0x41]),
            rawAx25: Data([0x01]),
            kissEndpoint: endpoint
        )
        let second = Packet(
            timestamp: Date(timeIntervalSince1970: 20),
            from: AX25Address(call: "CALL2"),
            to: AX25Address(call: "DEST"),
            frameType: .i,
            control: 0x00,
            info: Data([0x42]),
            rawAx25: Data([0x02]),
            kissEndpoint: endpoint
        )
        try store.save(first)
        try store.save(second)
        try store.setPinned(packetId: second.id, pinned: true)

        let recent = try store.loadRecent(limit: 10)
        XCTAssertEqual(recent.map(\.id), [second.id, first.id])
        XCTAssertEqual(recent.first?.pinned, true)
    }

    func testPruneRemovesOldest() throws {
        let store = try makeStore()
        let endpoint = try makeEndpoint()
        let packets = (0..<6).map { index in
            Packet(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                from: AX25Address(call: "CALL\(index)"),
                to: AX25Address(call: "DEST"),
                frameType: .u,
                control: 0x13,
                info: Data([UInt8(index)]),
                rawAx25: Data([UInt8(index)]),
                kissEndpoint: endpoint
            )
        }
        for packet in packets {
            try store.save(packet)
        }
        try store.pruneIfNeeded(retentionLimit: 3)
        let remaining = try store.loadRecent(limit: 10)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertFalse(remaining.contains(where: { $0.id == packets[0].id }))
        XCTAssertTrue(remaining.contains(where: { $0.id == packets[5].id }))
    }

    func testPersistsAllFrameTypes() throws {
        let store = try makeStore()
        let endpoint = try makeEndpoint()
        let frames: [FrameType] = [.ui, .i, .s, .u]
        for frame in frames {
            let packet = Packet(
                timestamp: Date(),
                from: AX25Address(call: "CALL"),
                to: AX25Address(call: "DEST"),
                frameType: frame,
                control: 0x03,
                info: Data([0x41]),
                rawAx25: Data([0x01]),
                kissEndpoint: endpoint
            )
            try store.save(packet)
        }

        let records = try store.loadRecent(limit: 10)
        let types = Set(records.map(\.frameType))
        XCTAssertEqual(types, Set(frames.map(\.rawValue)))
    }

    func testPersistsBlobPayloadsAndEndpoint() throws {
        let store = try makeStore()
        let endpoint = try makeEndpoint()
        let infoBytes = Data([0x00, 0x41, 0xFF])
        let rawBytes = Data([0x01, 0x02, 0x03, 0x04])
        let packet = Packet(
            timestamp: Date(timeIntervalSince1970: 100),
            from: AX25Address(call: "CALL"),
            to: AX25Address(call: "DEST"),
            frameType: .ui,
            control: 0x03,
            info: infoBytes,
            rawAx25: rawBytes,
            kissEndpoint: endpoint
        )

        try store.save(packet)
        let record = try store.loadRecent(limit: 1).first

        XCTAssertEqual(record?.infoBytes, infoBytes)
        XCTAssertEqual(record?.rawAx25Bytes, rawBytes)
        XCTAssertEqual(record?.kissHost, endpoint.host)
        XCTAssertEqual(record?.kissPort, Int(endpoint.port))
    }

    func testAggregateAnalyticsPadsTimeframeAndCountsAllRows() throws {
        let store = try makeStore()
        let endpoint = try makeEndpoint()
        let calendar = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_707_000_000)
        let timeframe = DateInterval(start: now.addingTimeInterval(-7 * 24 * 3600), end: now)

        let packetA = Packet(
            timestamp: timeframe.start.addingTimeInterval(2 * 3600),
            from: AX25Address(call: "A1"),
            to: AX25Address(call: "B1"),
            via: [AX25Address(call: "D1")],
            frameType: .ui,
            control: 0x03,
            info: Data(repeating: 0x41, count: 20),
            rawAx25: Data([0x01]),
            kissEndpoint: endpoint
        )
        let packetB = Packet(
            timestamp: timeframe.end.addingTimeInterval(-3 * 3600),
            from: AX25Address(call: "C1"),
            to: AX25Address(call: "D1"),
            frameType: .i,
            control: 0x00,
            info: Data(repeating: 0x42, count: 40),
            rawAx25: Data([0x02]),
            kissEndpoint: endpoint
        )
        try store.save(packetA)
        try store.save(packetB)

        let result = try store.aggregateAnalytics(
            in: timeframe,
            bucket: .hour,
            calendar: calendar,
            options: AnalyticsAggregator.Options(
                includeViaDigipeaters: true,
                histogramBinCount: 4,
                topLimit: 5
            )
        )

        XCTAssertEqual(result.summary.totalPackets, 2)
        XCTAssertEqual(result.summary.totalPayloadBytes, 60)
        XCTAssertEqual(result.summary.uiFrames, 1)
        XCTAssertEqual(result.summary.iFrames, 1)
        XCTAssertEqual(result.summary.uniqueStations, 4)
        XCTAssertEqual(result.series.packetsPerBucket.count, 169)
        XCTAssertEqual(result.heatmap.yLabels.count, 8)
        XCTAssertEqual(result.heatmap.matrix.flatMap { $0 }.reduce(0, +), 2)
    }

    func testAggregateAnalyticsReadsBeyondInMemoryCapSizes() throws {
        let store = try makeStore()
        let endpoint = try makeEndpoint()
        let calendar = utcCalendar()
        let base = Date(timeIntervalSince1970: 1_707_100_000)
        let total = 6_200

        for index in 0..<total {
            let packet = Packet(
                timestamp: base.addingTimeInterval(Double(index)),
                from: AX25Address(call: "SRC"),
                to: AX25Address(call: "K9DST"),
                frameType: .ui,
                control: 0x03,
                info: Data([0x41]),
                rawAx25: Data([0x01]),
                kissEndpoint: endpoint
            )
            try store.save(packet)
        }

        let timeframe = DateInterval(start: base, end: base.addingTimeInterval(Double(total) + 1))
        let result = try store.aggregateAnalytics(
            in: timeframe,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(
                includeViaDigipeaters: false,
                histogramBinCount: 4,
                topLimit: 5
            )
        )

        XCTAssertEqual(result.summary.totalPackets, total)
        XCTAssertEqual(result.summary.totalPayloadBytes, total)
        XCTAssertEqual(result.topTalkers.first?.label, "K9DST")
        XCTAssertEqual(result.topTalkers.first?.count, total)
    }

    func testAggregateAnalyticsExcludesNonCallsignIdentifiersFromTopLists() throws {
        let store = try makeStore()
        let endpoint = try makeEndpoint()
        let calendar = utcCalendar()
        let base = Date(timeIntervalSince1970: 1_707_300_000)

        let packets = [
            Packet(
                timestamp: base,
                from: AX25Address(call: "K1ABC"),
                to: AX25Address(call: "BEACON"),
                via: [AX25Address(call: "WIDE1", ssid: 1)],
                frameType: .ui,
                control: 0x03,
                info: Data([0x41]),
                rawAx25: Data([0x01]),
                kissEndpoint: endpoint
            ),
            Packet(
                timestamp: base.addingTimeInterval(60),
                from: AX25Address(call: "ID"),
                to: AX25Address(call: "N2DEF"),
                via: [AX25Address(call: "RELAY")],
                frameType: .ui,
                control: 0x03,
                info: Data([0x42]),
                rawAx25: Data([0x02]),
                kissEndpoint: endpoint
            ),
            Packet(
                timestamp: base.addingTimeInterval(120),
                from: AX25Address(call: "K1ABC"),
                to: AX25Address(call: "N2DEF"),
                via: [AX25Address(call: "K8DIG")],
                frameType: .ui,
                control: 0x03,
                info: Data([0x43]),
                rawAx25: Data([0x03]),
                kissEndpoint: endpoint
            )
        ]
        for packet in packets {
            try store.save(packet)
        }

        let timeframe = DateInterval(start: base.addingTimeInterval(-10), end: base.addingTimeInterval(180))
        let result = try store.aggregateAnalytics(
            in: timeframe,
            bucket: .minute,
            calendar: calendar,
            options: AnalyticsAggregator.Options(
                includeViaDigipeaters: true,
                histogramBinCount: 4,
                topLimit: 10
            )
        )

        XCTAssertEqual(result.summary.totalPackets, 3)
        XCTAssertFalse(result.topTalkers.map(\.label).contains("BEACON"))
        XCTAssertFalse(result.topTalkers.map(\.label).contains("ID"))
        XCTAssertFalse(result.topDestinations.map(\.label).contains("BEACON"))
        XCTAssertFalse(result.topDigipeaters.map(\.label).contains("WIDE1-1"))
        XCTAssertFalse(result.topDigipeaters.map(\.label).contains("RELAY"))
        XCTAssertTrue(result.topDigipeaters.map(\.label).contains("K8DIG"))
    }

    func testLoadPacketsInTimeframeReturnsRangeOnly() throws {
        let store = try makeStore()
        let endpoint = try makeEndpoint()
        let base = Date(timeIntervalSince1970: 1_707_200_000)
        let packets = (0..<4).map { offset in
            Packet(
                timestamp: base.addingTimeInterval(Double(offset) * 60),
                from: AX25Address(call: "SRC\(offset)"),
                to: AX25Address(call: "DST"),
                frameType: .ui,
                control: 0x03,
                info: Data([0x41]),
                rawAx25: Data([0x01]),
                kissEndpoint: endpoint
            )
        }
        for packet in packets {
            try store.save(packet)
        }

        let timeframe = DateInterval(
            start: base.addingTimeInterval(30),
            end: base.addingTimeInterval(150)
        )
        let ranged = try store.loadPackets(in: timeframe)

        XCTAssertEqual(ranged.count, 2)
        XCTAssertEqual(ranged.first?.id, packets[1].id)
        XCTAssertEqual(ranged.last?.id, packets[2].id)
    }

    private func makeStore() throws -> SQLitePacketStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLitePacketStore(dbQueue: queue)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func makeEndpoint() throws -> KISSEndpoint {
        guard let endpoint = KISSEndpoint(host: "localhost", port: 8001) else {
            XCTFail("Expected valid KISS endpoint")
            throw TestError.invalidEndpoint
        }
        return endpoint
    }

    private enum TestError: Error {
        case invalidEndpoint
    }
}
