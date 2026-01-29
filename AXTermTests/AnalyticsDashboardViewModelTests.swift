import XCTest
@testable import AXTerm

final class AnalyticsDashboardViewModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    func testChangingBucketTriggersSeriesRecompute() {
        let date1 = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let date2 = makeDate(year: 2026, month: 2, day: 18, hour: 7, minute: 5, second: 0)
        let packets = [
            makePacket(timestamp: date1, from: "alpha", to: "beta"),
            makePacket(timestamp: date2, from: "alpha", to: "beta")
        ]

        let viewModel = AnalyticsDashboardViewModel(
            calendar: calendar,
            bucket: .hour,
            includeViaDigipeaters: false,
            minEdgeCount: 1,
            maxNodes: 10,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )

        viewModel.updatePackets(packets)
        drainMainQueue()
        XCTAssertEqual(viewModel.series.packetsPerBucket.count, 2)

        viewModel.bucket = .day
        drainMainQueue()
        XCTAssertEqual(viewModel.series.packetsPerBucket.count, 1)
    }

    func testTogglingIncludeViaTriggersGraphRecompute() {
        let timestamp = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let packets = [
            makePacket(timestamp: timestamp, from: "alpha", to: "beta", via: ["dig1"])
        ]

        let viewModel = AnalyticsDashboardViewModel(
            calendar: calendar,
            bucket: .fiveMinutes,
            includeViaDigipeaters: false,
            minEdgeCount: 1,
            maxNodes: 10,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )

        viewModel.updatePackets(packets)
        drainMainQueue()
        XCTAssertEqual(viewModel.graphModel.edges.count, 1)

        viewModel.includeViaDigipeaters = true
        drainMainQueue()
        XCTAssertEqual(viewModel.graphModel.edges.count, 2)
    }

    func testMinEdgeCountFiltersEdges() {
        let timestamp = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let packets = [
            makePacket(timestamp: timestamp, from: "alpha", to: "beta"),
            makePacket(timestamp: timestamp.addingTimeInterval(1), from: "alpha", to: "beta"),
            makePacket(timestamp: timestamp.addingTimeInterval(2), from: "beta", to: "gamma")
        ]

        let viewModel = AnalyticsDashboardViewModel(
            calendar: calendar,
            bucket: .fiveMinutes,
            includeViaDigipeaters: false,
            minEdgeCount: 1,
            maxNodes: 10,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )

        viewModel.updatePackets(packets)
        drainMainQueue()
        XCTAssertEqual(viewModel.graphModel.edges.count, 2)

        viewModel.minEdgeCount = 2
        drainMainQueue()
        XCTAssertEqual(viewModel.graphModel.edges.count, 1)
        XCTAssertEqual(viewModel.graphModel.edges.first?.sourceID, "ALPHA")
    }

    func testSelectionUpdatesDoNotCrash() {
        let viewModel = AnalyticsDashboardViewModel(
            calendar: calendar,
            bucket: .fiveMinutes,
            includeViaDigipeaters: false,
            minEdgeCount: 1,
            maxNodes: 10,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )

        viewModel.handleNodeClick("alpha", isShift: false)
        XCTAssertEqual(viewModel.selectedNodeID, "alpha")
        XCTAssertEqual(viewModel.selectedNodeIDs, ["alpha"])

        viewModel.updateHover(for: "alpha")
        XCTAssertEqual(viewModel.hoveredNodeID, "alpha")

        viewModel.handleBackgroundClick()
        XCTAssertNil(viewModel.selectedNodeID)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
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
