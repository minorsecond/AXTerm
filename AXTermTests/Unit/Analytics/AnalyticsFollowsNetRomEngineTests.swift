//
//  AnalyticsFollowsNetRomEngineTests.swift
//  AXTermTests
//
//  The station builds its NET/ROM engine once it has a callsign and
//  replaces it when the callsign changes. The analytics model kept the one
//  it was handed at window creation: nil, or the old engine, so the graph's
//  NET/ROM view read stale tables and never heard their updates. Found
//  through the edge tooltip, which read no link estimates at all on
//  A (705) (smoke run 2026-10-03-1, issue 95).
//

import Combine
import XCTest
@testable import AXTerm

@MainActor
final class AnalyticsFollowsNetRomEngineTests: XCTestCase {

    private func settle() async {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    func testTheModelFollowsAReplacedEngine() async {
        let engines = CurrentValueSubject<NetRomIntegration?, Never>(nil)
        let viewModel = AnalyticsDashboardViewModel(
            settingsStore: AppSettingsStore(defaults: TestDefaults.make("AnalyticsFollowsNetRomEngine")),
            netRomIntegrationUpdates: engines.eraseToAnyPublisher(),
            packetDebounce: 0, graphDebounce: 0, packetScheduler: .main)
        viewModel.autoUpdateEnabled = true
        await settle()
        XCTAssertNil(viewModel.currentNetRomIntegration, "no engine yet: the callsign has not arrived")

        let first = NetRomIntegration(localCallsign: "K0EPI-2", mode: .hybrid)
        engines.send(first)
        await settle()
        XCTAssertTrue(viewModel.currentNetRomIntegration === first)
        first.purgeStaleData(currentDate: Date())
        await settle()
        XCTAssertEqual(viewModel.netRomUpdateCount, 1, "the engine that arrived after launch is heard")

        let second = NetRomIntegration(localCallsign: "K0EPI-5", mode: .hybrid)
        engines.send(second)
        await settle()
        XCTAssertTrue(viewModel.currentNetRomIntegration === second)
        first.purgeStaleData(currentDate: Date())
        await settle()
        XCTAssertEqual(viewModel.netRomUpdateCount, 1, "the replaced engine is no longer heard")
        second.purgeStaleData(currentDate: Date())
        await settle()
        XCTAssertEqual(viewModel.netRomUpdateCount, 2, "the replacement is")
    }
}
