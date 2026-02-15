//
//  ConnectionConfigSnapshotTests.swift
//  AXTermTests
//
//  Tests for ConnectionConfigSnapshot equality and change detection.
//

import XCTest
@testable import AXTerm

@MainActor
final class ConnectionConfigSnapshotTests: XCTestCase {

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests.Snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettingsStore(defaults: defaults)
    }

    // MARK: - Equality when unchanged

    func testSnapshotEqualWhenSettingsUnchanged() {
        let settings = makeSettings()
        let a = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        let b = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertEqual(a, b, "Snapshots from the same unchanged settings should be equal")
    }

    // MARK: - Detect each type of change

    func testSnapshotDetectsTransportTypeChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.transportType = KISSTransportType.serial.rawValue
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsSerialPathChange() {
        let settings = makeSettings()
        settings.transportType = KISSTransportType.serial.rawValue
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.serialDevicePath = "/dev/cu.usbmodem9999"
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsBaudRateChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.serialBaudRate = 9600
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsBLEUUIDChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.blePeripheralUUID = "NEW-UUID-1234"
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsHostChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.host = "192.168.1.100"
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsPortChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.port = 9999
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsMobilinkdEnabledChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.mobilinkdEnabled = !settings.mobilinkdEnabled
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsMobilinkdModemTypeChange() {
        let settings = makeSettings()
        settings.mobilinkdEnabled = true
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.mobilinkdModemType = 5
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsMobilinkdOutputGainChange() {
        let settings = makeSettings()
        settings.mobilinkdEnabled = true
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.mobilinkdOutputGain = 200
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsMobilinkdInputGainChange() {
        let settings = makeSettings()
        settings.mobilinkdEnabled = true
        settings.mobilinkdInputGain = 2
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.mobilinkdInputGain = 4
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }
}
