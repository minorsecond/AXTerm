//
//  BLELinkReuseTests.swift
//  AXTermTests
//
//  Tests that connectBLE() reuses existing BLE links when the UUID matches,
//  mirroring the serial link reuse pattern.
//

import XCTest
@testable import AXTerm

@MainActor
final class BLELinkReuseTests: XCTestCase {

    private func makeEngine() -> PacketEngine {
        let suiteName = "AXTermTests.BLEReuse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettingsStore(defaults: defaults)
        return PacketEngine(settings: settings)
    }

    func testConnectBLESameUUIDDoesNotTeardown() {
        let engine = makeEngine()
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        let config1 = BLEConfig(
            peripheralUUID: uuid,
            peripheralName: "TNC4",
            autoReconnect: false,
            mobilinkdConfig: nil
        )

        // First connection
        engine.connectBLE(config: config1)
        let statusAfterFirst = engine.status

        // Second connection with same UUID but different name
        let config2 = BLEConfig(
            peripheralUUID: uuid,
            peripheralName: "TNC4-Updated",
            autoReconnect: false,
            mobilinkdConfig: nil
        )
        engine.connectBLE(config: config2)
        let statusAfterSecond = engine.status

        // Status should not have been reset to .connecting by the second call
        // because the BLE link was reused (updateConfig path)
        // The first call sets .connecting, the second should leave it alone
        // (or at most update config without disconnect+reconnect)
        XCTAssertEqual(statusAfterFirst, statusAfterSecond,
            "Same-UUID connectBLE should reuse link, not teardown and re-set status")
    }

    func testConnectBLEDifferentUUIDTriggersDisconnect() {
        let engine = makeEngine()
        let config1 = BLEConfig(
            peripheralUUID: "AAAA-AAAA-AAAA-AAAA",
            peripheralName: "TNC4-A",
            autoReconnect: false
        )

        engine.connectBLE(config: config1)

        let config2 = BLEConfig(
            peripheralUUID: "BBBB-BBBB-BBBB-BBBB",
            peripheralName: "TNC4-B",
            autoReconnect: false
        )

        engine.connectBLE(config: config2)

        // With a different UUID, it should have done a full disconnect + new link
        // Status should be .connecting (new BLE link being set up)
        XCTAssertEqual(engine.status, .connecting,
            "Different-UUID connectBLE should create a new link")
    }
}
