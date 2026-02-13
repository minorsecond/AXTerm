//
//  KISSLinkBLETests.swift
//  AXTermTests
//
//  Unit tests for BLE transport configuration and constants.
//

import CoreBluetooth
import XCTest
@testable import AXTerm

final class KISSLinkBLETests: XCTestCase {

    // MARK: - BLEConfig Tests

    func testBLEConfigDefaults() {
        let config = BLEConfig(peripheralUUID: "12345678-1234-1234-1234-123456789ABC")
        XCTAssertEqual(config.peripheralUUID, "12345678-1234-1234-1234-123456789ABC")
        XCTAssertEqual(config.peripheralName, "")
        XCTAssertTrue(config.autoReconnect)
    }

    func testBLEConfigCustomValues() {
        let config = BLEConfig(
            peripheralUUID: "AABBCCDD-1111-2222-3333-444455556666",
            peripheralName: "Mobilinkd TNC4",
            autoReconnect: false
        )
        XCTAssertEqual(config.peripheralUUID, "AABBCCDD-1111-2222-3333-444455556666")
        XCTAssertEqual(config.peripheralName, "Mobilinkd TNC4")
        XCTAssertFalse(config.autoReconnect)
    }

    func testBLEConfigEquality() {
        let a = BLEConfig(peripheralUUID: "A", peripheralName: "X", autoReconnect: true)
        let b = BLEConfig(peripheralUUID: "A", peripheralName: "X", autoReconnect: true)
        let c = BLEConfig(peripheralUUID: "B", peripheralName: "X", autoReconnect: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Service UUID Tests

    func testMobilinkdServiceUUID() {
        let uuid = BLEServiceUUIDs.mobilinkd
        XCTAssertEqual(uuid, CBUUID(string: "00000001-BA2A-46C9-AE49-01B0961F68BB"))
    }

    func testNordicUARTServiceUUID() {
        let uuid = BLEServiceUUIDs.nordicUART
        XCTAssertEqual(uuid, CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"))
    }

    func testAllServicesContainsBothUUIDs() {
        XCTAssertEqual(BLEServiceUUIDs.knownTNCServices.count, 2)
        XCTAssertTrue(BLEServiceUUIDs.knownTNCServices.contains(BLEServiceUUIDs.mobilinkd))
        XCTAssertTrue(BLEServiceUUIDs.knownTNCServices.contains(BLEServiceUUIDs.nordicUART))
    }

    // MARK: - Characteristic UUID Tests

    func testMobilinkdCharacteristicUUIDs() {
        XCTAssertEqual(
            BLECharacteristicUUIDs.mobilinkdTX,
            CBUUID(string: "00000002-BA2A-46C9-AE49-01B0961F68BB")
        )
        XCTAssertEqual(
            BLECharacteristicUUIDs.mobilinkdRX,
            CBUUID(string: "00000003-BA2A-46C9-AE49-01B0961F68BB")
        )
    }

    func testNordicUARTCharacteristicUUIDs() {
        XCTAssertEqual(
            BLECharacteristicUUIDs.nordicUARTTX,
            CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        )
        XCTAssertEqual(
            BLECharacteristicUUIDs.nordicUARTRX,
            CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        )
    }

    // MARK: - BLEDiscoveredDevice Tests

    func testDiscoveredDeviceDisplayName() {
        let withName = BLEDiscoveredDevice(id: UUID(), name: "TNC4", rssi: -65, serviceUUIDs: [])
        XCTAssertEqual(withName.displayName, "TNC4")

        let withoutName = BLEDiscoveredDevice(id: UUID(), name: "", rssi: -80, serviceUUIDs: [])
        XCTAssertTrue(withoutName.displayName.hasPrefix("Unknown ("))
    }

    func testDiscoveredDeviceEquality() {
        let id = UUID()
        let a = BLEDiscoveredDevice(id: id, name: "TNC", rssi: -60, serviceUUIDs: [])
        let b = BLEDiscoveredDevice(id: id, name: "TNC", rssi: -60, serviceUUIDs: [])
        XCTAssertEqual(a, b)
    }

    func testDiscoveredDeviceIsKnownTNC() {
        let knownTNC = BLEDiscoveredDevice(id: UUID(), name: "TNC4", rssi: -65, serviceUUIDs: [BLEServiceUUIDs.mobilinkd])
        XCTAssertTrue(knownTNC.isKnownTNC)

        let unknownDevice = BLEDiscoveredDevice(id: UUID(), name: "Speaker", rssi: -70, serviceUUIDs: [CBUUID(string: "AAAA")])
        XCTAssertFalse(unknownDevice.isKnownTNC)

        let noServices = BLEDiscoveredDevice(id: UUID(), name: "X", rssi: -50, serviceUUIDs: [])
        XCTAssertFalse(noServices.isKnownTNC)
    }

    // MARK: - KISSLinkBLE State Tests

    func testInitialState() {
        let config = BLEConfig(peripheralUUID: "00000000-0000-0000-0000-000000000000")
        let link = KISSLinkBLE(config: config)
        XCTAssertEqual(link.state, .disconnected)
        XCTAssertEqual(link.totalBytesIn, 0)
        XCTAssertEqual(link.totalBytesOut, 0)
    }

    func testEndpointDescriptionWithName() {
        let config = BLEConfig(peripheralUUID: "AABBCCDD-1234-5678-9ABC-DEF012345678", peripheralName: "TNC4")
        let link = KISSLinkBLE(config: config)
        XCTAssertEqual(link.endpointDescription, "BLE TNC4")
    }

    func testEndpointDescriptionWithoutName() {
        let config = BLEConfig(peripheralUUID: "AABBCCDD-1234-5678-9ABC-DEF012345678", peripheralName: "")
        let link = KISSLinkBLE(config: config)
        XCTAssertEqual(link.endpointDescription, "BLE AABBCCDD")
    }

    // MARK: - KISSLink Protocol Conformance

    func testConformsToKISSLink() {
        let config = BLEConfig(peripheralUUID: "00000000-0000-0000-0000-000000000000")
        let link = KISSLinkBLE(config: config)
        // Verify KISSLink protocol conformance by assigning to protocol type
        let _: KISSLink = link
        XCTAssertNil(link.delegate)
    }

    // MARK: - BLE Error Tests

    func testBLEErrorDescriptions() {
        XCTAssertNotNil(KISSBLEError.bluetoothUnavailable("off").errorDescription)
        XCTAssertNotNil(KISSBLEError.peripheralNotFound("uuid").errorDescription)
        XCTAssertNotNil(KISSBLEError.serviceNotFound("uuid").errorDescription)
        XCTAssertNotNil(KISSBLEError.characteristicNotFound("uuid").errorDescription)
        XCTAssertNotNil(KISSBLEError.writeFailed("reason").errorDescription)
        XCTAssertNotNil(KISSBLEError.notConnected.errorDescription)
    }

    // MARK: - Settings Integration Tests

    func testAppSettingsBLETransport() {
        let defaults = UserDefaults(suiteName: "KISSLinkBLETests_\(UUID().uuidString)")!
        let settings = AppSettingsStore(defaults: defaults)

        settings.transportType = "ble"
        XCTAssertTrue(settings.isBLETransport)
        XCTAssertFalse(settings.isSerialTransport)

        settings.blePeripheralUUID = "AABBCCDD-1234-5678-9ABC-DEF012345678"
        settings.blePeripheralName = "Test TNC"
        settings.bleAutoReconnect = false

        XCTAssertEqual(settings.blePeripheralUUID, "AABBCCDD-1234-5678-9ABC-DEF012345678")
        XCTAssertEqual(settings.blePeripheralName, "Test TNC")
        XCTAssertFalse(settings.bleAutoReconnect)

        defaults.removePersistentDomain(forName: "KISSLinkBLETests_\(UUID().uuidString)")
    }

    func testAppSettingsBLEDefaults() {
        let defaults = UserDefaults(suiteName: "KISSLinkBLEDefaultsTests_\(UUID().uuidString)")!
        let settings = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(settings.blePeripheralUUID, "")
        XCTAssertEqual(settings.blePeripheralName, "")
        XCTAssertTrue(settings.bleAutoReconnect)
        XCTAssertFalse(settings.isBLETransport)  // Default transport is "network"
    }
}
