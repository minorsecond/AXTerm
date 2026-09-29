//
//  HiddenNodeBreakdownTests.swift
//  AXTermTests
//
//  The "Hidden by filters: N" badge must count actual stations hidden from the
//  current data, exactly once each. The old computation summed four overlapping
//  buckets, labeled the max-nodes truncation counter "Min Edge / Max Nodes"
//  (the min-edge slider hides edges, never nodes), and counted every
//  ignore-list entry whether or not that station appeared in the timeframe —
//  so the badge read nonzero on an empty band.
//

import XCTest
@testable import AXTerm

@MainActor
final class HiddenNodeBreakdownTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        Telemetry.setBackend(NoOpTelemetryBackend())
        suiteName = "AXTermTests-HiddenBreakdown-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() {
        CallsignValidator.configureIgnoredServiceEndpoints([])
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func makeSettings() -> AppSettingsStore {
        let settings = AppSettingsStore(defaults: defaults)
        settings.analyticsTimeframe = "custom"
        settings.analyticsBucket = "fiveMinutes"
        settings.analyticsIncludeVia = true
        settings.analyticsMinEdgeCount = 1
        settings.analyticsMaxNodes = 50
        return settings
    }

    private func makeViewModel(settings: AppSettingsStore) -> AnalyticsDashboardViewModel {
        let viewModel = AnalyticsDashboardViewModel(
            settingsStore: settings,
            calendar: calendar,
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )
        viewModel.graphViewMode = .all
        return viewModel
    }

    private func makePacket(timestamp: Date, from: String, to: String) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            frameType: .ui,
            info: Data(repeating: 0x41, count: 10)
        )
    }

    private func waitFor(_ condition: @escaping () -> Bool) async {
        let timeout = Date().addingTimeInterval(2.0)
        while Date() < timeout {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Issue 3: an ignore-list entry only counts as hidden when that station is
    /// actually present in the timeframe. An empty band shows zero hidden nodes.
    func testIgnoreListEntriesAbsentFromTimeframeDoNotCount() async {
        let settings = makeSettings()
        settings.addIgnoredServiceEndpoint("K9SVC")

        let viewModel = makeViewModel(settings: settings)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        viewModel.customRangeStart = timestamp.addingTimeInterval(-60)
        viewModel.customRangeEnd = timestamp.addingTimeInterval(600)
        viewModel.setActive(true)
        viewModel.updatePackets([])
        await waitFor { viewModel.hasLoadedGraph }

        let empty = viewModel.hiddenNodeBreakdown(simulatedEndpoints: [], temporarilyUnignored: [])
        XCTAssertEqual(empty.totalCount, 0, "Empty band: nothing is hidden, badge must read 0")

        // Now the ignored station actually shows up on air.
        viewModel.updatePackets([
            makePacket(timestamp: timestamp, from: "W1AAA", to: "K2BBB"),
            makePacket(timestamp: timestamp.addingTimeInterval(1), from: "K2BBB", to: "W1AAA"),
            makePacket(timestamp: timestamp.addingTimeInterval(2), from: "K9SVC", to: "W1AAA")
        ])
        viewModel.manualRefresh()
        await waitFor {
            viewModel.hiddenNodeBreakdown(simulatedEndpoints: [], temporarilyUnignored: []).ignoredPresent.contains("K9SVC")
        }

        let present = viewModel.hiddenNodeBreakdown(simulatedEndpoints: [], temporarilyUnignored: [])
        XCTAssertEqual(present.ignoredPresent, ["K9SVC"], "Ignored station on air counts as hidden")
    }

    /// Issue 2: structural hiding must be counted from the data, not from a
    /// single builder counter. Note the classified graph derives *nodes* from all
    /// stations seen in packets — the min-edge slider hides edges, never nodes —
    /// so the structural bucket is the max-nodes cap plus stations with no
    /// drawable link, computed as valid-present-stations minus drawn nodes.
    func testMaxNodesCapCountsHiddenStations() async {
        let settings = makeSettings()
        let viewModel = makeViewModel(settings: settings)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        viewModel.customRangeStart = timestamp.addingTimeInterval(-60)
        viewModel.customRangeEnd = timestamp.addingTimeInterval(600)
        viewModel.setActive(true)

        // 30 valid stations in a ring, one frame each.
        let prefixes = ["W", "K", "N"]
        let calls = (0..<30).map { "\(prefixes[$0 / 10])\($0 % 10)AAA" }
        let packets = calls.indices.map { index in
            makePacket(
                timestamp: timestamp.addingTimeInterval(Double(index)),
                from: calls[index],
                to: calls[(index + 1) % calls.count]
            )
        }
        viewModel.updatePackets(packets)
        await waitFor { viewModel.viewState.classifiedGraphModel.nodes.count == 30 }

        let unlimited = viewModel.hiddenNodeBreakdown(simulatedEndpoints: [], temporarilyUnignored: [])
        XCTAssertEqual(unlimited.structuralCount, 0, "All 30 stations drawn; nothing structurally hidden")

        // Cap the graph below the station count (normalizer floor is 25).
        viewModel.maxNodes = 25
        await waitFor { viewModel.viewState.classifiedGraphModel.nodes.count == 25 }
        XCTAssertEqual(viewModel.viewState.classifiedGraphModel.nodes.count, 25,
                       "Precondition: max-nodes cap truncates the graph")

        let capped = viewModel.hiddenNodeBreakdown(simulatedEndpoints: [], temporarilyUnignored: [])
        XCTAssertEqual(capped.structuralCount, 5,
                       "Stations dropped by the max-nodes cap must appear in the structural count")
        XCTAssertEqual(capped.totalCount, 5)
    }

    /// Issue 1: causes must not double-count. An ignored station is invalid for
    /// the graph, so it can never also be counted as structurally hidden.
    func testCausesAreDisjointAndTotalIsDeduplicated() async {
        let settings = makeSettings()
        settings.addIgnoredServiceEndpoint("N3CCC")

        let viewModel = makeViewModel(settings: settings)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        viewModel.customRangeStart = timestamp.addingTimeInterval(-60)
        viewModel.customRangeEnd = timestamp.addingTimeInterval(600)
        viewModel.setActive(true)

        viewModel.updatePackets([
            makePacket(timestamp: timestamp, from: "W1AAA", to: "K2BBB"),
            makePacket(timestamp: timestamp.addingTimeInterval(1), from: "K2BBB", to: "W1AAA"),
            makePacket(timestamp: timestamp.addingTimeInterval(2), from: "W1AAA", to: "K2BBB"),
            makePacket(timestamp: timestamp.addingTimeInterval(3), from: "K2BBB", to: "W1AAA"),
            makePacket(timestamp: timestamp.addingTimeInterval(4), from: "N3CCC", to: "W1AAA")
        ])
        await waitFor { viewModel.viewState.graphModel.nodes.count == 2 }

        let breakdown = viewModel.hiddenNodeBreakdown(simulatedEndpoints: [], temporarilyUnignored: [])
        XCTAssertEqual(breakdown.ignoredPresent, ["N3CCC"])
        XCTAssertFalse(breakdown.structuralHiddenKeys.contains("N3CCC"),
                       "An ignored station must not also count as structurally hidden")
        XCTAssertEqual(
            breakdown.totalCount,
            breakdown.structuralCount + breakdown.focusHiddenIDs.count
                + breakdown.simulatedPresent.count + breakdown.ignoredPresent.count,
            "Total is the sum of disjoint parts"
        )
        XCTAssertEqual(breakdown.totalCount, 1, "Only N3CCC is hidden, counted exactly once")
    }

    /// A simulated removal counts only when the station is present in the data.
    func testSimulatedRemovalCountsOnlyPresentStations() async {
        let settings = makeSettings()
        // Simulation adds the endpoint to the ignore list; mirror that here.
        settings.addIgnoredServiceEndpoint("W1AAA")

        let viewModel = makeViewModel(settings: settings)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        viewModel.customRangeStart = timestamp.addingTimeInterval(-60)
        viewModel.customRangeEnd = timestamp.addingTimeInterval(600)
        viewModel.setActive(true)
        viewModel.updatePackets([
            makePacket(timestamp: timestamp, from: "W1AAA", to: "K2BBB")
        ])
        await waitFor { viewModel.hasLoadedGraph }
        await waitFor {
            !viewModel.hiddenNodeBreakdown(simulatedEndpoints: ["W1AAA"], temporarilyUnignored: []).simulatedPresent.isEmpty
        }

        let breakdown = viewModel.hiddenNodeBreakdown(
            simulatedEndpoints: ["W1AAA", "K9ABS"],
            temporarilyUnignored: []
        )
        XCTAssertEqual(breakdown.simulatedPresent, ["W1AAA"],
                       "A simulated endpoint that never appears on air is not a hidden node")
        XCTAssertFalse(breakdown.ignoredPresent.contains("W1AAA"),
                       "Simulated stations are not double-counted as ignored")
    }
}
