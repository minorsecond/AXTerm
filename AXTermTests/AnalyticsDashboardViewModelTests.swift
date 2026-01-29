//
//  AnalyticsDashboardViewModelTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-21.
//

import XCTest
@testable import AXTerm

final class AnalyticsDashboardViewModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testChangingBucketTriggersSeriesRecompute() {
        let date1 = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let date2 = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 5, second: 0)
        let packets = [
            makePacket(timestamp: date1, from: "alpha", to: "beta"),
            makePacket(timestamp: date2, from: "alpha", to: "beta")
        ]

        let viewModel = AnalyticsDashboardViewModel(
            calendar: calendar,
            bucket: .fiveMinutes,
            includeViaDigipeaters: false,
            minEdgeCount: 1,
            packetDebounce: .zero,
            packetScheduler: .main
        )

        viewModel.updatePackets(packets)
        XCTAssertEqual(viewModel.series.packetsPerBucket.count, 2)

        viewModel.bucket = .hour
        XCTAssertEqual(viewModel.series.packetsPerBucket.count, 1)
    }

    func testTogglingIncludeViaTriggersEdgeRecompute() {
        let timestamp = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let packets = [
            makePacket(timestamp: timestamp, from: "alpha", to: "beta", via: ["dig1"])
        ]

        let viewModel = AnalyticsDashboardViewModel(
            calendar: calendar,
            bucket: .fiveMinutes,
            includeViaDigipeaters: false,
            minEdgeCount: 1,
            packetDebounce: .zero,
            packetScheduler: .main
        )

        viewModel.updatePackets(packets)
        XCTAssertEqual(viewModel.edges.count, 1)

        viewModel.includeViaDigipeaters = true
        XCTAssertEqual(viewModel.edges.count, 2)
    }

    func testMinEdgeCountFiltersEdges() {
        let timestamp = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let packets = [
            makePacket(timestamp: timestamp, from: "alpha", to: "beta"),
            makePacket(timestamp: timestamp, from: "alpha", to: "beta"),
            makePacket(timestamp: timestamp, from: "beta", to: "gamma")
        ]

        let viewModel = AnalyticsDashboardViewModel(
            calendar: calendar,
            bucket: .fiveMinutes,
            includeViaDigipeaters: false,
            minEdgeCount: 1,
            packetDebounce: .zero,
            packetScheduler: .main
        )

        viewModel.updatePackets(packets)
        XCTAssertEqual(viewModel.edges.count, 2)

        viewModel.minEdgeCount = 2
        XCTAssertEqual(viewModel.edges.count, 1)
        XCTAssertEqual(viewModel.edges.first?.source, "alpha")
    }

    func testSelectionUpdatesDoNotCrash() {
        let viewModel = AnalyticsDashboardViewModel(
            calendar: calendar,
            bucket: .fiveMinutes,
            includeViaDigipeaters: false,
            minEdgeCount: 1,
            packetDebounce: .zero,
            packetScheduler: .main
        )

        viewModel.handleNodeClick("alpha", isShift: false)
        XCTAssertEqual(viewModel.selectedNodeID, "alpha")
        XCTAssertEqual(viewModel.selectedNodeIDs, ["alpha"])

        viewModel.updateHover(for: "alpha", isHovering: true)
        XCTAssertEqual(viewModel.hoveredNodeID, "alpha")

        viewModel.handleNodeDoubleClick("alpha", isShift: false)
        XCTAssertNotNil(viewModel.stationInspector)

        viewModel.updateHover(for: "alpha", isHovering: false)
        XCTAssertNil(viewModel.hoveredNodeID)

        viewModel.handleBackgroundClick()
        XCTAssertNil(viewModel.selectedNodeID)
    }
}

private extension AnalyticsDashboardViewModelTests {
    func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )) ?? Date(timeIntervalSince1970: 0)
    }

    func makePacket(
        timestamp: Date,
        from: String? = nil,
        to: String? = nil,
        via: [String] = []
    ) -> Packet {
        Packet(
            timestamp: timestamp,
            from: from.map { AX25Address(call: $0) },
            to: to.map { AX25Address(call: $0) },
            via: via.map { AX25Address(call: $0) },
            frameType: .ui
        )
    }
}
