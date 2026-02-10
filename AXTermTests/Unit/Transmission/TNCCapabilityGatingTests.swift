//
//  TNCCapabilityGatingTests.swift
//  AXTermTests
//
//  Tests for TNC capability model, gating logic, and persistence.
//

import XCTest
@testable import AXTerm

@MainActor
final class TNCCapabilityGatingTests: XCTestCase {

    // MARK: - TNCMode Tests

    func testTNCModeRawValues() {
        XCTAssertEqual(TNCMode.kiss.rawValue, "kiss")
        XCTAssertEqual(TNCMode.host.rawValue, "host")
        XCTAssertEqual(TNCMode.unknown.rawValue, "unknown")
    }

    // MARK: - TNCCapabilities Defaults

    func testDefaultCapabilitiesAreKISSWithLinkTuning() {
        let caps = TNCCapabilities()
        XCTAssertEqual(caps.mode, .kiss)
        XCTAssertTrue(caps.supportsLinkTuning)
        XCTAssertFalse(caps.supportsModemTuning)
        XCTAssertFalse(caps.supportsCustomCommands)
    }

    func testHostModeDoesNotSupportLinkTuning() {
        var caps = TNCCapabilities()
        caps.mode = .host
        caps.supportsLinkTuning = false
        XCTAssertEqual(caps.mode, .host)
        XCTAssertFalse(caps.supportsLinkTuning)
    }

    func testUnknownModeDoesNotSupportLinkTuning() {
        var caps = TNCCapabilities()
        caps.mode = .unknown
        caps.supportsLinkTuning = false
        XCTAssertEqual(caps.mode, .unknown)
        XCTAssertFalse(caps.supportsLinkTuning)
    }

    // MARK: - Codable Round-Trip

    func testTNCCapabilitiesCodableRoundTrip() throws {
        var original = TNCCapabilities()
        original.mode = .host
        original.supportsLinkTuning = false
        original.supportsModemTuning = true
        original.supportsCustomCommands = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TNCCapabilities.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testTNCCapabilitiesDefaultCodableRoundTrip() throws {
        let original = TNCCapabilities()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TNCCapabilities.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - AppSettingsStore Persistence

    func testSettingsStoreDefaultTNCCapabilities() {
        let suiteName = "TNCCapabilityGatingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.tncCapabilities.mode, .kiss)
        XCTAssertTrue(store.tncCapabilities.supportsLinkTuning)
    }

    func testSettingsStorePersistsTNCCapabilities() {
        let suiteName = "TNCCapabilityGatingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        // Write
        let store1 = AppSettingsStore(defaults: defaults)
        var caps = TNCCapabilities()
        caps.mode = .host
        caps.supportsLinkTuning = false
        store1.tncCapabilities = caps

        // Read back in a new store instance
        let store2 = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store2.tncCapabilities.mode, .host)
        XCTAssertFalse(store2.tncCapabilities.supportsLinkTuning)
    }

    // MARK: - Capability Gating in SessionCoordinator

    @MainActor
    func testSyncUsesDefaultsWhenLinkTuningNotSupported() async {
        let defaults = UserDefaults(suiteName: "TNCCapabilityGatingTests-\(UUID().uuidString)")!

        let settings = AppSettingsStore(defaults: defaults)
        var caps = TNCCapabilities()
        caps.mode = .host
        caps.supportsLinkTuning = false
        settings.tncCapabilities = caps

        let coordinator = SessionCoordinator()
        coordinator.appSettings = settings
        coordinator.adaptiveTransmissionEnabled = true

        // Set non-default adaptive values
        var adaptive = coordinator.globalAdaptiveSettings
        adaptive.windowSize.mode = .manual
        adaptive.windowSize.manualValue = 7
        adaptive.paclen.mode = .manual
        adaptive.paclen.manualValue = 256
        adaptive.maxRetries.mode = .manual
        adaptive.maxRetries.manualValue = 20
        coordinator.globalAdaptiveSettings = adaptive

        coordinator.syncSessionManagerConfigFromAdaptive()

        // Should use AX25SessionConfig() defaults, NOT the manual values
        let config = coordinator.sessionManager.defaultConfig
        XCTAssertEqual(config.windowSize, 4, "Window size should be protocol default when TNC manages link")
        XCTAssertEqual(config.paclen, 128, "PACLEN should be protocol default when TNC manages link")
        XCTAssertEqual(config.maxRetries, 10, "Max retries should be protocol default when TNC manages link")
    }

    @MainActor
    func testSyncAppliesUserValuesWhenLinkTuningSupported() async {
        let defaults = UserDefaults(suiteName: "TNCCapabilityGatingTests-\(UUID().uuidString)")!

        let settings = AppSettingsStore(defaults: defaults)
        // Default: KISS mode, supportsLinkTuning = true
        XCTAssertTrue(settings.tncCapabilities.supportsLinkTuning)

        let coordinator = SessionCoordinator()
        coordinator.appSettings = settings
        coordinator.adaptiveTransmissionEnabled = true

        var adaptive = coordinator.globalAdaptiveSettings
        adaptive.windowSize.mode = .manual
        adaptive.windowSize.manualValue = 7
        adaptive.paclen.mode = .manual
        adaptive.paclen.manualValue = 200
        adaptive.maxRetries.mode = .manual
        adaptive.maxRetries.manualValue = 5
        coordinator.globalAdaptiveSettings = adaptive

        coordinator.syncSessionManagerConfigFromAdaptive()

        let config = coordinator.sessionManager.defaultConfig
        XCTAssertEqual(config.windowSize, 7, "Manual window size should be applied when TNC supports link tuning")
        XCTAssertEqual(config.paclen, 200, "Manual PACLEN should be applied when TNC supports link tuning")
        XCTAssertEqual(config.maxRetries, 5, "Manual max retries should be applied when TNC supports link tuning")
    }

    @MainActor
    func testSyncUsesDefaultsWhenAdaptiveDisabledButLinkTuningSupported() async {
        let defaults = UserDefaults(suiteName: "TNCCapabilityGatingTests-\(UUID().uuidString)")!

        let settings = AppSettingsStore(defaults: defaults)
        let coordinator = SessionCoordinator()
        coordinator.appSettings = settings
        coordinator.adaptiveTransmissionEnabled = false

        coordinator.syncSessionManagerConfigFromAdaptive()

        let config = coordinator.sessionManager.defaultConfig
        XCTAssertEqual(config.windowSize, 4)
        XCTAssertEqual(config.paclen, 128)
        XCTAssertEqual(config.maxRetries, 10)
    }

    // MARK: - Equatable

    func testTNCCapabilitiesEquatable() {
        let a = TNCCapabilities()
        var b = TNCCapabilities()
        XCTAssertEqual(a, b)

        b.mode = .host
        XCTAssertNotEqual(a, b)
    }
}
