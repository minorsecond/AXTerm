//
//  AnalyticsEngineTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-18.
//

import XCTest
@testable import AXTerm

final class AnalyticsEngineTests: XCTestCase {
    func testComputeSummaryCountsAndTopLists() {
        let packet1 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "n0call", ssid: 1),
            to: AX25Address(call: "dest"),
            via: [AX25Address(call: "dig1")],
            frameType: .ui,
            info: Data([0x41, 0x42])
        )
        let packet2 = Packet(
            timestamp: Date(),
            from: nil,
            to: AX25Address(call: "dest"),
            via: [],
            frameType: .i,
            info: Data()
        )
        let packet3 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "n0call", ssid: 1),
            to: nil,
            via: [AX25Address(call: "dig2")],
            frameType: .ui,
            info: Data([0x00])
        )

        let summary = AnalyticsEngine.computeSummary(packets: [packet1, packet2, packet3])

        XCTAssertEqual(summary.packetCount, 3)
        XCTAssertEqual(summary.uniqueStationsCount, 4)
        XCTAssertEqual(summary.totalPayloadBytes, 3)
        XCTAssertEqual(summary.infoTextRatio, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(summary.frameTypeCounts[.ui], 2)
        XCTAssertEqual(summary.frameTypeCounts[.i], 1)

        XCTAssertEqual(summary.topTalkersByFrom, [StationCount(station: "N0CALL-1", count: 2)])
        XCTAssertEqual(summary.topDestinationsByTo, [StationCount(station: "DEST", count: 2)])
    }

    func testUniqueStationsExcludeViaWhenConfigured() {
        let packet = Packet(
            timestamp: Date(),
            from: AX25Address(call: "call"),
            to: AX25Address(call: "dest"),
            via: [AX25Address(call: "dig1"), AX25Address(call: "dig2")],
            frameType: .ui,
            info: Data()
        )

        let summary = AnalyticsEngine.computeSummary(
            packets: [packet],
            includeViaInUniqueStations: false
        )

        XCTAssertEqual(summary.uniqueStationsCount, 2)
    }

    func testComputeSummaryWithEmptyPackets() {
        let summary = AnalyticsEngine.computeSummary(packets: [])

        XCTAssertEqual(summary.packetCount, 0)
        XCTAssertEqual(summary.uniqueStationsCount, 0)
        XCTAssertEqual(summary.totalPayloadBytes, 0)
        XCTAssertEqual(summary.infoTextRatio, 0)
        XCTAssertTrue(summary.topTalkersByFrom.isEmpty)
        XCTAssertTrue(summary.topDestinationsByTo.isEmpty)
    }

    func testAllUnknownStationsExcludedFromTopLists() {
        let packet = Packet(
            timestamp: Date(),
            from: nil,
            to: nil,
            via: [],
            frameType: .unknown,
            info: Data()
        )

        let summary = AnalyticsEngine.computeSummary(packets: [packet])

        XCTAssertEqual(summary.packetCount, 1)
        XCTAssertEqual(summary.uniqueStationsCount, 0)
        XCTAssertTrue(summary.topTalkersByFrom.isEmpty)
        XCTAssertTrue(summary.topDestinationsByTo.isEmpty)
    }
}
