//
//  AnalyticsDashboardViewModelDeinitTests.swift
//  AXTermTests
//
//  Regression guard: deallocating AnalyticsDashboardViewModel synchronously
//  from a @MainActor synchronous context used to abort the process
//  ("malloc: pointer being freed was not allocated", SIGABRT) via
//  TelemetryRateLimiter's implicitly isolated deinit —
//  swift_task_deinitOnExecutorImpl's task-local teardown double-freed.
//  With SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, any helper class stored by
//  the view model must opt out of isolation (or have a nonisolated deinit) so
//  a synchronous release never routes through the executor machinery.
//
//  This test is deliberately SYNCHRONOUS: async tests never hit the crash,
//  which is how the rest of the view-model suite avoided it.
//

import XCTest
@testable import AXTerm

@MainActor
final class AnalyticsDashboardViewModelDeinitTests: XCTestCase {
    func testSynchronousDeallocationDoesNotCrash() {
        Telemetry.setBackend(NoOpTelemetryBackend())
        let suiteName = "AXTermTests-VMDeinit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let settings = AppSettingsStore(defaults: defaults)

        autoreleasepool {
            var viewModel: AnalyticsDashboardViewModel? = AnalyticsDashboardViewModel(
                settingsStore: settings,
                calendar: Calendar(identifier: .gregorian),
                packetDebounce: 0,
                graphDebounce: 0,
                packetScheduler: .main
            )
            XCTAssertNotNil(viewModel)
            viewModel = nil // synchronous release on the main actor — must not abort
        }

        XCTAssertTrue(true, "Synchronous deallocation completed without SIGABRT")
        CallsignValidator.configureIgnoredServiceEndpoints([])
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}
