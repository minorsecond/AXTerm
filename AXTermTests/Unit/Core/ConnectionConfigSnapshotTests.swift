//
//  ConnectionConfigSnapshotTests.swift
//  AXTermTests
//
//  Tests for ConnectionConfigSnapshot equality and change detection.
//  Snapshot captures transport-level settings ONLY — Mobilinkd config
//  changes must NOT trigger reconnection (they disrupt the TNC4 demodulator).
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

    // MARK: - Transport field changes trigger inequality

    func testSnapshotDetectsTransportTypeChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.kind = .serial }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsSerialPathChange() {
        let settings = makeSettings()
        settings.updateRadio(settings.primaryRadio!.id) { $0.kind = .serial }
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.serialDevicePath = "/dev/cu.usbmodem9999" }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsBaudRateChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.kind = .serial; $0.serialBaudRate = 9600 }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsBLEUUIDChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.kind = .ble; $0.blePeripheralUUID = "NEW-UUID-1234" }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsHostChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.host = "192.168.1.100" }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    func testSnapshotDetectsPortChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.port = 9999 }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertNotEqual(before, after)
    }

    // MARK: - Mobilinkd field changes must NOT trigger inequality
    // These fields are excluded from the snapshot to prevent settings panel
    // close from triggering a reconnect that disrupts the TNC4 demodulator.

    func testSnapshotIgnoresMobilinkdEnabledChange() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdEnabled = !$0.mobilinkdEnabled }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertEqual(before, after,
            "Mobilinkd enabled toggle must not trigger reconnect")
    }

    func testSnapshotIgnoresMobilinkdModemTypeChange() {
        let settings = makeSettings()
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdEnabled = true }
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdModemType = 5 }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertEqual(before, after,
            "Modem type change must not trigger reconnect")
    }

    func testSnapshotIgnoresMobilinkdOutputGainChange() {
        let settings = makeSettings()
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdEnabled = true }
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdOutputGain = 200 }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertEqual(before, after,
            "Output gain change must not trigger reconnect")
    }

    func testSnapshotIgnoresMobilinkdInputGainChange() {
        let settings = makeSettings()
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdEnabled = true }
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdInputGain = 2 }
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdInputGain = 4 }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertEqual(before, after,
            "Input gain change must not trigger reconnect")
    }

    // MARK: - Combined changes

    func testSnapshotIgnoresMobilinkdWhenTransportAlsoChanges() {
        let settings = makeSettings()
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        // Change both transport and Mobilinkd fields
        settings.updateRadio(settings.primaryRadio!.id) { $0.kind = .serial; $0.serialDevicePath = "/dev/cu.usbmodem1234" }
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdInputGain = 3 }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        // Should be unequal because of the transport field change
        XCTAssertNotEqual(before, after,
            "Transport change should still be detected even with Mobilinkd changes")
    }

    func testSnapshotOnlyMobilinkdFieldsChangedStaysEqual() {
        let settings = makeSettings()
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdEnabled = true }
        let before = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        // Change ALL Mobilinkd fields
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdEnabled = false }
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdModemType = 9 }
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdOutputGain = 255 }
        settings.updateRadio(settings.primaryRadio!.id) { $0.mobilinkdInputGain = 0 }
        let after = PacketEngine.ConnectionConfigSnapshot(settings: settings)
        XCTAssertEqual(before, after,
            "Changing only Mobilinkd fields must keep snapshots equal")
    }
}
