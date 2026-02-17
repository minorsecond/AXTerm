//
//  SettingsObservationTests.swift
//  AXTermTests
//
//  Tests for the connection logic suspension mechanism:
//  - isConnectionLogicSuspended captures snapshot on suspend
//  - Resume compares snapshot and reconnects only if transport fields changed
//  - Mobilinkd-only changes while suspended must NOT trigger reconnect
//

import XCTest
@testable import AXTerm

@MainActor
final class SettingsObservationTests: XCTestCase {

    private func makeEngine() -> (PacketEngine, AppSettingsStore) {
        let suiteName = "AXTermTests.SettingsObs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettingsStore(defaults: defaults)
        let engine = PacketEngine(settings: settings)
        return (engine, settings)
    }

    // MARK: - Suspension captures snapshot

    func testSuspendCapturesSnapshot() {
        let (engine, settings) = makeEngine()
        settings.host = "192.168.1.1"
        settings.port = 8001

        engine.isConnectionLogicSuspended = true

        // Suspension should have captured the snapshot internally.
        // We can't inspect the private snapshot, but we can verify the
        // round-trip: resume with no changes should not reconnect.
        // The engine status should stay .disconnected.
        engine.isConnectionLogicSuspended = false

        XCTAssertEqual(engine.status, .disconnected,
            "Resume with no changes should not trigger reconnect")
    }

    // MARK: - Resume with no changes skips reconnect

    func testResumeWithNoChangesDoesNotReconnect() {
        let (engine, settings) = makeEngine()
        settings.transportType = "network"
        settings.host = "localhost"
        settings.port = 8001

        let statusBefore = engine.status

        engine.isConnectionLogicSuspended = true
        // No changes
        engine.isConnectionLogicSuspended = false

        XCTAssertEqual(engine.status, statusBefore,
            "Resuming without settings changes must not change engine status")
    }

    // MARK: - Resume with transport change triggers reconnect

    func testResumeWithTransportChangeTriggersReconnect() {
        let (engine, settings) = makeEngine()
        settings.transportType = "network"

        engine.isConnectionLogicSuspended = true
        settings.host = "192.168.3.218"  // Transport-level change
        engine.isConnectionLogicSuspended = false

        // The engine should have called connectUsingSettings()
        // which sets status to .connecting for network transport
        XCTAssertEqual(engine.status, .connecting,
            "Resume after transport change should trigger reconnect")
    }

    func testResumeWithSerialPathChangeTriggersReconnect() {
        let (engine, settings) = makeEngine()
        settings.transportType = "serial"
        settings.serialDevicePath = "/dev/cu.usbmodem1234"

        engine.isConnectionLogicSuspended = true
        settings.serialDevicePath = "/dev/cu.usbmodem5678"  // Transport change
        engine.isConnectionLogicSuspended = false

        // Serial transport should attempt reconnect (status changes from disconnected)
        // Since the device doesn't exist, it may fail, but it should try
        XCTAssertNotEqual(engine.status, .disconnected,
            "Resume after serial path change should trigger reconnect attempt")
    }

    // MARK: - Resume with Mobilinkd-only changes does NOT reconnect

    func testResumeWithMobilinkdEnabledChangeDoesNotReconnect() {
        let (engine, settings) = makeEngine()
        settings.transportType = "serial"
        settings.serialDevicePath = "/dev/cu.usbmodem1234"

        engine.isConnectionLogicSuspended = true
        settings.mobilinkdEnabled = !settings.mobilinkdEnabled
        engine.isConnectionLogicSuspended = false

        XCTAssertEqual(engine.status, .disconnected,
            "Mobilinkd enabled toggle must not trigger reconnect on resume")
    }

    func testResumeWithMobilinkdGainChangeDoesNotReconnect() {
        let (engine, settings) = makeEngine()
        settings.mobilinkdEnabled = true

        engine.isConnectionLogicSuspended = true
        settings.mobilinkdInputGain = 3
        settings.mobilinkdOutputGain = 200
        engine.isConnectionLogicSuspended = false

        XCTAssertEqual(engine.status, .disconnected,
            "Mobilinkd gain changes must not trigger reconnect on resume")
    }

    func testResumeWithMobilinkdModemTypeChangeDoesNotReconnect() {
        let (engine, settings) = makeEngine()
        settings.mobilinkdEnabled = true

        engine.isConnectionLogicSuspended = true
        settings.mobilinkdModemType = 5
        engine.isConnectionLogicSuspended = false

        XCTAssertEqual(engine.status, .disconnected,
            "Mobilinkd modem type change must not trigger reconnect on resume")
    }

    func testResumeWithAllMobilinkdFieldsChangedDoesNotReconnect() {
        let (engine, settings) = makeEngine()
        settings.mobilinkdEnabled = true
        settings.mobilinkdModemType = 1
        settings.mobilinkdOutputGain = 128
        settings.mobilinkdInputGain = 4

        engine.isConnectionLogicSuspended = true
        // Change every Mobilinkd field
        settings.mobilinkdEnabled = false
        settings.mobilinkdModemType = 9
        settings.mobilinkdOutputGain = 255
        settings.mobilinkdInputGain = 0
        engine.isConnectionLogicSuspended = false

        XCTAssertEqual(engine.status, .disconnected,
            "Changing ALL Mobilinkd fields must not trigger reconnect on resume")
    }

    // MARK: - Suspension blocks settings-change auto-reconnect

    func testSettingsChangeWhileSuspendedDoesNotAutoReconnect() async throws {
        let (engine, settings) = makeEngine()
        settings.transportType = "network"
        settings.host = "localhost"
        settings.port = 8001

        engine.isConnectionLogicSuspended = true

        // Change a transport setting while suspended
        settings.host = "192.168.1.100"

        // Wait for debounce (500ms) + buffer
        try await Task.sleep(nanoseconds: 700_000_000)

        // Engine should NOT have auto-reconnected because suspension is active
        XCTAssertEqual(engine.status, .disconnected,
            "Settings change while suspended must not trigger auto-reconnect")
    }

    // MARK: - Multiple suspend/resume cycles

    func testMultipleSuspendResumeCyclesStable() {
        let (engine, settings) = makeEngine()

        for _ in 0..<5 {
            engine.isConnectionLogicSuspended = true
            engine.isConnectionLogicSuspended = false
        }

        XCTAssertEqual(engine.status, .disconnected,
            "Repeated suspend/resume with no changes should leave engine disconnected")
    }
}
