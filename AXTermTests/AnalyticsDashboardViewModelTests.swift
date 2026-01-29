import XCTest
@testable import AXTerm

final class AnalyticsDashboardViewModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    func testChangingBucketTriggersSeriesRecompute() async {
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
        await waitFor(condition: { viewModel.viewState.series.packetsPerBucket.count == 2 })
        XCTAssertEqual(viewModel.viewState.series.packetsPerBucket.count, 2)

        viewModel.bucket = .day
        await waitFor(condition: { viewModel.viewState.series.packetsPerBucket.count == 1 })
        XCTAssertEqual(viewModel.viewState.series.packetsPerBucket.count, 1)
    }

    func testTogglingIncludeViaTriggersGraphRecompute() async {
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
        await waitFor(condition: { viewModel.viewState.graphModel.edges.count == 1 })
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 1)

        viewModel.includeViaDigipeaters = true
        await waitFor(condition: { viewModel.viewState.graphModel.edges.count == 2 })
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 2)
    }

    func testMinEdgeCountFiltersEdges() async {
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
        await waitFor(condition: { viewModel.viewState.graphModel.edges.count == 2 })
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 2)

        viewModel.minEdgeCount = 2
        await waitFor(condition: { viewModel.viewState.graphModel.edges.count == 1 })
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 1)
        XCTAssertEqual(viewModel.viewState.graphModel.edges.first?.sourceID, "ALPHA")
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
        XCTAssertEqual(viewModel.viewState.selectedNodeID, "alpha")
        XCTAssertEqual(viewModel.viewState.selectedNodeIDs, ["alpha"])

        viewModel.updateHover(for: "alpha")
        XCTAssertEqual(viewModel.viewState.hoveredNodeID, "alpha")

        viewModel.handleBackgroundClick()
        XCTAssertNil(viewModel.viewState.selectedNodeID)
    }
}

private extension AnalyticsDashboardViewModelTests {
    func waitFor(condition: @escaping @Sendable () -> Bool) async {
        let timeout = Date().addingTimeInterval(1.0)
        while Date() < timeout {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition not met before timeout.")
    }

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
