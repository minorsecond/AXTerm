//
//  EventLoggerTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/2/26.
//

import XCTest
@testable import AXTerm

@MainActor
final class EventLoggerTests: XCTestCase {
    func testDatabaseLoggerWritesEvent() async {
        let store = MockEventLogStore()
        let settings = makeSettings()
        let logger = DatabaseEventLogger(store: store, settings: settings)

        logger.log(level: .info, category: .ui, message: "Copied diagnostics", metadata: ["source": "test"])

        await waitForStore(store)
        XCTAssertEqual(store.appendedEntries.count, 1)
        XCTAssertEqual(store.appendedEntries.first?.message, "Copied diagnostics")
    }

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests-EventLogger-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.set(true, forKey: AppSettingsStore.persistKey)
        return AppSettingsStore(defaults: defaults)
    }

    /// Wait for the logger to reach its store, and fail here if it never does.
    ///
    /// Returning quietly on timeout leaves the assertion below to report
    /// "expected 1, got 0", which reads as the logger writing the wrong thing
    /// rather than as the wait running out.
    private func waitForStore(_ store: MockEventLogStore,
                              file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10 {
            if !store.appendedEntries.isEmpty || !store.pruneCalls.isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the event log store was never written to", file: file, line: line)
    }
}
