//
//  ZeroDisruptionInitTests.swift
//  AXTermTests
//
//  Tests verifying the zero-disruption KISS init strategy:
//  - No commands are sent on connect (TNC4 auto-starts demodulator)
//  - EEPROM holds calibrated settings — disrupting them breaks RX
//  - Only transport-level config changes (device path, baud rate) trigger reconnect
//  - Mobilinkd gain/modem settings are stored but never cause reconnect
//

import XCTest
@testable import AXTerm

// MARK: - Serial Zero-Disruption Tests

final class ZeroDisruptionSerialTests: XCTestCase {

    // MARK: - Initial State

    func testSerialLinkStartsDisconnected() {
        let config = SerialConfig(devicePath: "/dev/null", baudRate: 115200)
        let link = KISSLinkSerial(config: config)
        XCTAssertEqual(link.state, .disconnected)
    }

    func testSerialLinkStartsDisconnectedWithMobilinkdConfig() {
        let config = SerialConfig(
            devicePath: "/dev/null",
            baudRate: 115200,
            mobilinkdConfig: MobilinkdConfig(
                modemType: .afsk1200,
                outputGain: 128,
                inputGain: 4,
                isBatteryMonitoringEnabled: false
            )
        )
        let link = KISSLinkSerial(config: config)
        XCTAssertEqual(link.state, .disconnected)
    }

    // MARK: - Close Idempotency

    func testCloseOnDisconnectedLinkIsIdempotent() {
        let config = SerialConfig(devicePath: "/dev/null", baudRate: 115200)
        let link = KISSLinkSerial(config: config)
        // Close multiple times — should not crash or change state
        link.close()
        link.close()
        link.close()
        XCTAssertEqual(link.state, .disconnected)
    }

    // MARK: - updateConfig: Transport Changes vs Mobilinkd Changes

    func testUpdateConfigStoresNewConfig() async throws {
        let config = SerialConfig(
            devicePath: "/dev/null",
            baudRate: 115200,
            mobilinkdConfig: MobilinkdConfig()
        )
        let link = KISSLinkSerial(config: config)

        let newConfig = SerialConfig(
            devicePath: "/dev/null",
            baudRate: 9600,
            mobilinkdConfig: MobilinkdConfig(modemType: .afsk1200, outputGain: 200, inputGain: 2, isBatteryMonitoringEnabled: true)
        )
        link.updateConfig(newConfig)

        // Allow serial queue to process
        try await Task.sleep(nanoseconds: 100_000_000)

        // Link was disconnected, so no reconnect should happen
        XCTAssertEqual(link.state, .disconnected,
            "updateConfig on disconnected link should not trigger reconnect")
    }

    func testUpdateConfigDisconnectedLinkNoReconnectOnTransportChange() async throws {
        let config = SerialConfig(devicePath: "/dev/null", baudRate: 115200)
        let link = KISSLinkSerial(config: config)

        // Change device path (transport-level) while disconnected
        let newConfig = SerialConfig(devicePath: "/dev/cu.usbmodem999", baudRate: 9600)
        link.updateConfig(newConfig)

        try await Task.sleep(nanoseconds: 100_000_000)

        // Should still be disconnected — no reconnect when not connected
        XCTAssertEqual(link.state, .disconnected,
            "Transport config change on disconnected link must not trigger open")
    }

    func testUpdateConfigDisconnectedLinkNoReconnectOnMobilinkdChange() async throws {
        let config = SerialConfig(
            devicePath: "/dev/null",
            baudRate: 115200,
            mobilinkdConfig: MobilinkdConfig()
        )
        let link = KISSLinkSerial(config: config)

        // Change only Mobilinkd config while disconnected
        let newConfig = SerialConfig(
            devicePath: "/dev/null",
            baudRate: 115200,
            mobilinkdConfig: MobilinkdConfig(modemType: .afsk1200, outputGain: 255, inputGain: 0, isBatteryMonitoringEnabled: true)
        )
        link.updateConfig(newConfig)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(link.state, .disconnected,
            "Mobilinkd-only config change on disconnected link must not trigger open")
    }

    // MARK: - SerialConfig Equality

    func testSerialConfigEqualityIncludesMobilinkd() {
        let a = SerialConfig(
            devicePath: "/dev/cu.test",
            baudRate: 115200,
            mobilinkdConfig: MobilinkdConfig(modemType: .afsk1200, outputGain: 128, inputGain: 4, isBatteryMonitoringEnabled: false)
        )
        let b = SerialConfig(
            devicePath: "/dev/cu.test",
            baudRate: 115200,
            mobilinkdConfig: MobilinkdConfig(modemType: .afsk1200, outputGain: 128, inputGain: 4, isBatteryMonitoringEnabled: false)
        )
        XCTAssertEqual(a, b)
    }

    func testSerialConfigInequalityOnPath() {
        let a = SerialConfig(devicePath: "/dev/cu.a", baudRate: 115200)
        let b = SerialConfig(devicePath: "/dev/cu.b", baudRate: 115200)
        XCTAssertNotEqual(a, b)
    }

    func testSerialConfigInequalityOnBaudRate() {
        let a = SerialConfig(devicePath: "/dev/cu.test", baudRate: 115200)
        let b = SerialConfig(devicePath: "/dev/cu.test", baudRate: 9600)
        XCTAssertNotEqual(a, b)
    }

    func testSerialConfigInequalityOnMobilinkdConfig() {
        let a = SerialConfig(devicePath: "/dev/cu.test", baudRate: 115200, mobilinkdConfig: nil)
        let b = SerialConfig(
            devicePath: "/dev/cu.test",
            baudRate: 115200,
            mobilinkdConfig: MobilinkdConfig()
        )
        XCTAssertNotEqual(a, b,
            "SerialConfig should distinguish nil vs present MobilinkdConfig")
    }

    // MARK: - Serial Error Descriptions

    func testSerialErrorDescriptions() {
        XCTAssertNotNil(KISSSerialError.deviceNotFound("/dev/cu.test").errorDescription)
        XCTAssertNotNil(KISSSerialError.openFailed("/dev/cu.test", ENOENT).errorDescription)
        XCTAssertNotNil(KISSSerialError.configurationFailed("bad baud").errorDescription)
        XCTAssertNotNil(KISSSerialError.writeFailed("timeout").errorDescription)
        XCTAssertNotNil(KISSSerialError.notOpen.errorDescription)
        XCTAssertNotNil(KISSSerialError.openTimeout("/dev/cu.test").errorDescription)
    }

    // MARK: - Endpoint Description

    func testSerialEndpointDescription() {
        let config = SerialConfig(devicePath: "/dev/cu.usbmodem14201", baudRate: 115200)
        let link = KISSLinkSerial(config: config)
        XCTAssertTrue(link.endpointDescription.contains("usbmodem14201"),
            "Endpoint description should include device path")
    }
}

// MARK: - BLE Zero-Disruption Tests

final class ZeroDisruptionBLETests: XCTestCase {

    // MARK: - Initial State

    func testBLELinkStartsDisconnected() {
        let config = BLEConfig(peripheralUUID: "00000000-0000-0000-0000-000000000000")
        let link = KISSLinkBLE(config: config)
        XCTAssertEqual(link.state, .disconnected)
    }

    func testBLELinkStartsDisconnectedWithMobilinkdConfig() {
        let config = BLEConfig(
            peripheralUUID: "00000000-0000-0000-0000-000000000000",
            peripheralName: "TNC4",
            mobilinkdConfig: MobilinkdConfig(
                modemType: .afsk1200,
                outputGain: 128,
                inputGain: 4,
                isBatteryMonitoringEnabled: false
            )
        )
        let link = KISSLinkBLE(config: config)
        XCTAssertEqual(link.state, .disconnected)
    }

    // MARK: - Close Idempotency

    func testBLECloseOnDisconnectedLinkIsIdempotent() {
        let config = BLEConfig(peripheralUUID: "00000000-0000-0000-0000-000000000000")
        let link = KISSLinkBLE(config: config)
        link.close()
        link.close()
        link.close()
        XCTAssertEqual(link.state, .disconnected)
    }

    // MARK: - BLE Config Equality with Mobilinkd

    func testBLEConfigEqualityIncludesMobilinkd() {
        let a = BLEConfig(
            peripheralUUID: "AAAA",
            peripheralName: "TNC4",
            mobilinkdConfig: MobilinkdConfig(modemType: .afsk1200, outputGain: 128, inputGain: 4, isBatteryMonitoringEnabled: false)
        )
        let b = BLEConfig(
            peripheralUUID: "AAAA",
            peripheralName: "TNC4",
            mobilinkdConfig: MobilinkdConfig(modemType: .afsk1200, outputGain: 128, inputGain: 4, isBatteryMonitoringEnabled: false)
        )
        XCTAssertEqual(a, b)
    }

    func testBLEConfigInequalityOnMobilinkdConfig() {
        let a = BLEConfig(peripheralUUID: "AAAA", peripheralName: "TNC4", mobilinkdConfig: nil)
        let b = BLEConfig(
            peripheralUUID: "AAAA",
            peripheralName: "TNC4",
            mobilinkdConfig: MobilinkdConfig()
        )
        XCTAssertNotEqual(a, b,
            "BLEConfig should distinguish nil vs present MobilinkdConfig")
    }

    // MARK: - BLE Error Descriptions

    func testBLEErrorDescriptionsAreNonNil() {
        XCTAssertNotNil(KISSBLEError.bluetoothUnavailable("powered off").errorDescription)
        XCTAssertNotNil(KISSBLEError.peripheralNotFound("uuid").errorDescription)
        XCTAssertNotNil(KISSBLEError.serviceNotFound("uuid").errorDescription)
        XCTAssertNotNil(KISSBLEError.characteristicNotFound("uuid").errorDescription)
        XCTAssertNotNil(KISSBLEError.writeFailed("reason").errorDescription)
        XCTAssertNotNil(KISSBLEError.notConnected.errorDescription)
    }
}

// MARK: - Loopback Zero-Disruption Verification

@MainActor
final class ZeroDisruptionLoopbackTests: XCTestCase {

    /// Verify that opening a KISSLink does NOT send any data.
    /// The loopback link records all sent data — opening should produce zero bytes.
    func testOpenSendsNoData() async throws {
        let link = KISSLinkLoopback()
        link.loopbackEnabled = false  // Record only, don't echo back

        link.open()
        XCTAssertEqual(link.state, .connected)

        // Allow any async init to complete
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(link.sentData.count, 0,
            "Zero-disruption: opening a KISS link must not send any init commands")
    }

    /// Verify that opening with delegate connected produces a .connected state change
    /// but no received data (no loopback of init commands).
    func testOpenProducesStateChangeButNoData() async throws {
        let link = KISSLinkLoopback()
        let delegate = ZDTestDelegate()
        link.delegate = delegate
        link.loopbackEnabled = false

        link.open()

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(delegate.stateChanges, [.connected],
            "Opening should produce exactly one state change to .connected")
        XCTAssertEqual(delegate.receivedData.count, 0,
            "No data should be received on open (zero-disruption)")
    }

    /// Verify that data flows normally after open (the link is usable).
    func testDataFlowsAfterOpen() async throws {
        let link = KISSLinkLoopback()
        let delegate = ZDTestDelegate()
        link.delegate = delegate

        link.open()

        let testData = Data([0xC0, 0x00, 0x42, 0xC0])
        var sendError: Error?
        link.send(testData) { error in sendError = error }

        XCTAssertNil(sendError)
        XCTAssertEqual(delegate.receivedData.count, 1)
        XCTAssertEqual(delegate.receivedData[0], testData)
    }
}

// MARK: - Test Helpers

@MainActor
private class ZDTestDelegate: KISSLinkDelegate {
    var receivedData: [Data] = []
    var stateChanges: [KISSLinkState] = []
    var errors: [String] = []

    func linkDidReceive(_ data: Data) { receivedData.append(data) }
    func linkDidChangeState(_ state: KISSLinkState) { stateChanges.append(state) }
    func linkDidError(_ message: String) { errors.append(message) }
}
