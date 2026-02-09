//
//  AppSettingsStoreTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import XCTest
import Combine
@testable import AXTerm

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "AXTermTests.AppSettingsStore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite \(suiteName)")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        body(defaults)
    }

    func testHostValidationDefaultsToLocalhost() {
        XCTAssertEqual(AppSettingsStore.sanitizeHost("   "), AppSettingsStore.defaultHost)
        XCTAssertEqual(AppSettingsStore.sanitizeHost("kiss.local"), "kiss.local")
    }

    func testPortValidationClampsToRange() {
        XCTAssertEqual(AppSettingsStore.sanitizePort(0), 1)
        XCTAssertEqual(AppSettingsStore.sanitizePort(99999), 65535)
        XCTAssertEqual(AppSettingsStore.sanitizePort(8001), 8001)
    }

    func testRetentionValidationClamps() {
        XCTAssertEqual(AppSettingsStore.sanitizeRetention(10), AppSettingsStore.minRetention)
        XCTAssertEqual(AppSettingsStore.sanitizeRetention(20_000_000), AppSettingsStore.maxRetention)
        XCTAssertEqual(AppSettingsStore.sanitizeRetention(50_000), 50_000)
    }

    func testLogRetentionValidationClamps() {
        XCTAssertEqual(AppSettingsStore.sanitizeLogRetention(10), AppSettingsStore.minLogRetention)
        XCTAssertEqual(AppSettingsStore.sanitizeLogRetention(3_000_000), AppSettingsStore.maxLogRetention)
        XCTAssertEqual(AppSettingsStore.sanitizeLogRetention(10_000), 10_000)
    }

    func testWatchListSanitizesAndDedupes() {
        let input = [" n0call ", "N0CALL", "DEST-1", ""]
        let result = AppSettingsStore.sanitizeWatchList(input, normalize: CallsignValidator.normalize)
        XCTAssertEqual(result, ["N0CALL", "DEST-1"])
    }

    func testMyCallsignPersistsUppercased() {
        withIsolatedDefaults { defaults in
            let store = AppSettingsStore(defaults: defaults)
            store.myCallsign = "n0call-7"
            XCTAssertEqual(store.myCallsign, "N0CALL-7")
        }
    }

    // MARK: - runInMenuBar Regression Tests

    /// Verifies runInMenuBar reads default value when key is absent.
    func testRunInMenuBarDefaultsToFalse() {
        withIsolatedDefaults { defaults in
            let store = AppSettingsStore(defaults: defaults)
            XCTAssertEqual(store.runInMenuBar, AppSettingsStore.defaultRunInMenuBar)
        }
    }

    /// Verifies runInMenuBar writes to UserDefaults.
    func testRunInMenuBarPersistsToDefaults() {
        withIsolatedDefaults { defaults in
            let store = AppSettingsStore(defaults: defaults)

            store.runInMenuBar = true
            XCTAssertTrue(defaults.bool(forKey: AppSettingsStore.runInMenuBarKey))

            store.runInMenuBar = false
            XCTAssertFalse(defaults.bool(forKey: AppSettingsStore.runInMenuBarKey))
        }
    }

    /// Verifies runInMenuBar reads persisted value on init.
    func testRunInMenuBarReadsPersistedValue() {
        withIsolatedDefaults { defaults in
            defaults.set(true, forKey: AppSettingsStore.runInMenuBarKey)

            let store = AppSettingsStore(defaults: defaults)
            XCTAssertTrue(store.runInMenuBar)
        }
    }

    /// Verifies that reading runInMenuBar does not trigger objectWillChange.
    /// This is critical: MenuBarExtra(isInserted:) reads during scene updates,
    /// and triggering Combine publishes during reads causes infinite loops.
    func testRunInMenuBarReadDoesNotPublish() {
        withIsolatedDefaults { defaults in
            let store = AppSettingsStore(defaults: defaults)

            var publishCount = 0
            let cancellable = store.objectWillChange.sink { _ in
                publishCount += 1
            }

            // Read the value multiple times
            _ = store.runInMenuBar
            _ = store.runInMenuBar
            _ = store.runInMenuBar

            XCTAssertEqual(publishCount, 0, "Reading runInMenuBar must not trigger objectWillChange")
            cancellable.cancel()
        }
    }
}
