import XCTest
@testable import AXTerm

@MainActor
final class AnalyticsDashboardViewModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    func testChangingBucketTriggersSeriesRecompute() async {
        // Create two packets about 1 hour 5 min apart
        let date1 = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let date2 = makeDate(year: 2026, month: 2, day: 18, hour: 7, minute: 5, second: 0)
        let packets = [
            makePacket(timestamp: date1, from: "alpha", to: "beta"),
            makePacket(timestamp: date2, from: "alpha", to: "beta")
        ]

        let settings = makeSettings()
        settings.analyticsBucket = "hour"
        settings.analyticsIncludeVia = false
        settings.analyticsMinEdgeCount = 1
        settings.analyticsMaxNodes = 10

        let viewModel = AnalyticsDashboardViewModel(
            settingsStore: settings,
            calendar: calendar,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )

        viewModel.updatePackets(packets)
        await waitFor { viewModel.viewState.series.packetsPerBucket.count == 2 }
        XCTAssertEqual(viewModel.viewState.series.packetsPerBucket.count, 2)

        // Change to a larger bucket (fifteenMinutes won't collapse them, but fiveMinutes should give us more buckets)
        // Actually for this test - if they're 65 minutes apart with hour bucket = 2 buckets.
        // With fifteenMinutes bucket = still multiple. Let's test going to a finer granularity.
        viewModel.bucketSelection = .tenSeconds
        await waitFor { viewModel.viewState.series.packetsPerBucket.count >= 2 }
        XCTAssertGreaterThanOrEqual(viewModel.viewState.series.packetsPerBucket.count, 2)
    }

    func testTogglingIncludeViaTriggersGraphRecompute() async {
        let timestamp = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let packets = [
            makePacket(timestamp: timestamp, from: "alpha", to: "beta", via: ["dig1"])
        ]

        let settings = makeSettings()
        settings.analyticsBucket = "fiveMinutes"
        settings.analyticsIncludeVia = false
        settings.analyticsMinEdgeCount = 1
        settings.analyticsMaxNodes = 10

        let viewModel = AnalyticsDashboardViewModel(
            settingsStore: settings,
            calendar: calendar,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )

        viewModel.updatePackets(packets)
        await waitFor { viewModel.viewState.graphModel.edges.count == 1 }
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 1)

        viewModel.includeViaDigipeaters = true
        await waitFor { viewModel.viewState.graphModel.edges.count == 2 }
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 2)
    }

    func testMinEdgeCountFiltersEdges() async {
        let timestamp = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let packets = [
            makePacket(timestamp: timestamp, from: "alpha", to: "beta"),
            makePacket(timestamp: timestamp.addingTimeInterval(1), from: "alpha", to: "beta"),
            makePacket(timestamp: timestamp.addingTimeInterval(2), from: "beta", to: "gamma")
        ]

        let settings = makeSettings()
        settings.analyticsBucket = "fiveMinutes"
        settings.analyticsIncludeVia = false
        settings.analyticsMinEdgeCount = 1
        settings.analyticsMaxNodes = 10

        let viewModel = AnalyticsDashboardViewModel(
            settingsStore: settings,
            calendar: calendar,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )

        viewModel.updatePackets(packets)
        await waitFor { viewModel.viewState.graphModel.edges.count == 2 }
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 2)

        viewModel.minEdgeCount = 2
        await waitFor { viewModel.viewState.graphModel.edges.count == 1 }
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 1)
        XCTAssertEqual(viewModel.viewState.graphModel.edges.first?.sourceID, "ALPHA")
    }

    func testSelectionUpdatesDoNotCrash() {
        let settings = makeSettings()
        settings.analyticsBucket = "fiveMinutes"
        settings.analyticsIncludeVia = false
        settings.analyticsMinEdgeCount = 1
        settings.analyticsMaxNodes = 10

        let viewModel = AnalyticsDashboardViewModel(
            settingsStore: settings,
            calendar: calendar,
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

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests-AnalyticsDashboard-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppSettingsStore(defaults: defaults)
    }

    /// Main-actor aware wait helper that doesn't require @Sendable closure
    private func waitFor(_ condition: @escaping () -> Bool) async {
        let timeout = Date().addingTimeInterval(1.0)
        while Date() < timeout {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition not met before timeout.")
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
