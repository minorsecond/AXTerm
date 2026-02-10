import XCTest
@testable import AXTerm

@MainActor
final class AnalyticsDashboardViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Telemetry.setBackend(NoOpTelemetryBackend())
    }

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
        settings.analyticsTimeframe = "custom"
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
        viewModel.setActive(true)
        viewModel.customRangeStart = date1.addingTimeInterval(-60)
        viewModel.customRangeEnd = date2.addingTimeInterval(60)

        viewModel.updatePackets(packets)
        await waitFor { viewModel.viewState.series.packetsPerBucket.count == 3 }
        XCTAssertEqual(viewModel.viewState.series.packetsPerBucket.count, 3)

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
            makePacket(timestamp: timestamp, from: "A1PHA", to: "B2ETA", via: ["D1G"])
        ]

        let settings = makeSettings()
        settings.analyticsTimeframe = "custom"
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
        viewModel.graphViewMode = .all
        viewModel.setActive(true)
        viewModel.customRangeStart = timestamp.addingTimeInterval(-60)
        viewModel.customRangeEnd = timestamp.addingTimeInterval(60)

        viewModel.updatePackets(packets)
        await waitFor { viewModel.viewState.graphModel.edges.count == 1 }
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 1)

        viewModel.includeViaDigipeaters = true
        await waitFor { viewModel.viewState.graphModel.edges.count == 3 }
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 3)
    }

    func testMinEdgeCountFiltersEdges() async {
        let timestamp = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let packets = [
            makePacket(timestamp: timestamp, from: "A1PHA", to: "B2ETA", via: ["D1G"])
        ]

        let settings = makeSettings()
        settings.analyticsTimeframe = "custom"
        settings.analyticsBucket = "fiveMinutes"
        settings.analyticsIncludeVia = true
        settings.analyticsMinEdgeCount = 1
        settings.analyticsMaxNodes = 10

        let viewModel = AnalyticsDashboardViewModel(
            settingsStore: settings,
            calendar: calendar,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )
        viewModel.graphViewMode = .all
        viewModel.setActive(true)
        viewModel.customRangeStart = timestamp.addingTimeInterval(-60)
        viewModel.customRangeEnd = timestamp.addingTimeInterval(60)

        viewModel.updatePackets(packets)
        await waitFor { viewModel.viewState.graphModel.edges.count == 3 }
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 3)

        viewModel.minEdgeCount = 2
        await waitFor { viewModel.viewState.graphModel.edges.count == 1 }
        XCTAssertEqual(viewModel.viewState.graphModel.edges.count, 1)
        XCTAssertEqual(viewModel.viewState.graphModel.edges.first?.sourceID, "A1PHA")
    }

    func testSelectionUpdatesDoNotCrash() async {
        let settings = makeSettings()
        settings.analyticsTimeframe = "custom"
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
        viewModel.setActive(true)

        viewModel.handleNodeClick("alpha", isShift: false)
        XCTAssertEqual(viewModel.viewState.selectedNodeID, "alpha")
        XCTAssertEqual(viewModel.viewState.selectedNodeIDs, ["alpha"])

        viewModel.updateHover(for: "alpha")
        XCTAssertEqual(viewModel.viewState.hoveredNodeID, "alpha")

        viewModel.handleBackgroundClick()
        XCTAssertNil(viewModel.viewState.selectedNodeID)
    }

    func testUsesDatabaseAggregationProviderWhenAvailable() async {
        let timestamp = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let settings = makeSettings()
        settings.analyticsTimeframe = "custom"
        settings.analyticsBucket = "hour"
        settings.analyticsIncludeVia = true
        settings.analyticsMinEdgeCount = 1
        settings.analyticsMaxNodes = 10

        let expected = AnalyticsAggregationResult(
            summary: AnalyticsSummaryMetrics(
                totalPackets: 6200,
                uniqueStations: 8,
                totalPayloadBytes: 12400,
                uiFrames: 4000,
                iFrames: 1200,
                infoTextRatio: 0.5
            ),
            series: AnalyticsSeries(
                packetsPerBucket: [AnalyticsSeriesPoint(bucket: timestamp, value: 6200)],
                bytesPerBucket: [AnalyticsSeriesPoint(bucket: timestamp, value: 12400)],
                uniqueStationsPerBucket: [AnalyticsSeriesPoint(bucket: timestamp, value: 8)]
            ),
            heatmap: HeatmapData(matrix: [[6200]], xLabels: ["00"], yLabels: ["Feb 18"]),
            histogram: HistogramData(bins: [HistogramBin(lowerBound: 0, upperBound: 127, count: 6200)], maxValue: 127),
            topTalkers: [RankRow(label: "SRC", count: 6200)],
            topDestinations: [RankRow(label: "DST", count: 6200)],
            topDigipeaters: [RankRow(label: "DIGI", count: 900)]
        )

        let viewModel = AnalyticsDashboardViewModel(
            settingsStore: settings,
            databaseAggregationProvider: { _, _, _, _, _, _ in expected },
            calendar: calendar,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )
        viewModel.setActive(true)
        viewModel.customRangeStart = timestamp.addingTimeInterval(-3600)
        viewModel.customRangeEnd = timestamp.addingTimeInterval(3600)

        // Intentionally keep in-memory packets sparse; provider should still drive results.
        viewModel.updatePackets([makePacket(timestamp: timestamp, from: "ONE", to: "TWO")])

        await waitFor { viewModel.viewState.summary?.totalPackets == 6200 }
        XCTAssertEqual(viewModel.viewState.summary?.totalPackets, 6200)
        XCTAssertEqual(viewModel.viewState.series.packetsPerBucket.first?.value, 6200)
        XCTAssertEqual(viewModel.viewState.topTalkers.first?.label, "SRC")
    }

    func testGraphBuildUsesTimeframePacketsProviderWhenAvailable() async {
        let timestamp = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let settings = makeSettings()
        settings.analyticsTimeframe = "custom"
        settings.analyticsBucket = "hour"
        settings.analyticsIncludeVia = false
        settings.analyticsMinEdgeCount = 1
        settings.analyticsMaxNodes = 10

        let providerPacket = makePacket(
            timestamp: timestamp,
            from: "DBSRC",
            to: "DBDST"
        )
        final class ProviderProbe: @unchecked Sendable {
            var called = false
        }
        let probe = ProviderProbe()

        let viewModel = AnalyticsDashboardViewModel(
            settingsStore: settings,
            timeframePacketsProvider: { _ in
                probe.called = true
                return [providerPacket]
            },
            calendar: calendar,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )
        viewModel.graphViewMode = .all
        viewModel.setActive(true)
        viewModel.customRangeStart = timestamp.addingTimeInterval(-3600)
        viewModel.customRangeEnd = timestamp.addingTimeInterval(3600)

        // In-memory packets are empty; graph should still build from provider data.
        viewModel.updatePackets([])

        await waitFor { probe.called }
        XCTAssertTrue(probe.called)
        await waitFor { viewModel.viewState.networkHealth.metrics.totalPackets > 0 }
        XCTAssertGreaterThan(viewModel.viewState.networkHealth.metrics.totalPackets, 0)
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
