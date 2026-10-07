//
//  BLEDevicePickerTests.swift
//  AXTermTests
//
//  A connected TNC stops advertising, so the scan often misses the radio's
//  own device. The picker still shows it, by the name it was saved with.
//

import CoreBluetooth
import XCTest
@testable import AXTerm

@MainActor
final class BLEDevicePickerTests: XCTestCase {

    private let saved = UUID()

    private func device(_ id: UUID, _ name: String, rssi: Int = -60) -> BLEDiscoveredDevice {
        BLEDiscoveredDevice(id: id, name: name, rssi: rssi, serviceUUIDs: [])
    }

    /// By its name alone: the radio page says Connected right below, and
    /// "(connected)" made the menu truncate to "TNC4…nnected)" on a phone
    /// (smoke run 2026-10-03-1, issue 107).
    func testTheSavedDeviceIsListedWhenTheScanMissedIt() {
        let other = device(UUID(), "Other TNC")
        let rows = BLEDevicePicker.rows(scanned: [other], selectedID: saved.uuidString,
                                        savedName: "TNC4 Mobilinkd")
        XCTAssertEqual(rows.first, .init(id: saved.uuidString, label: "TNC4 Mobilinkd"))
        XCTAssertEqual(rows.count, 2)
    }

    func testANamelessSavedDeviceFallsBackToItsUUID() {
        let rows = BLEDevicePicker.rows(scanned: [], selectedID: saved.uuidString,
                                        savedName: "")
        XCTAssertEqual(rows, [.init(id: saved.uuidString, label: saved.uuidString)])
    }

    func testASeenDeviceIsNotListedTwice() {
        let rows = BLEDevicePicker.rows(scanned: [device(saved, "TNC4 Mobilinkd", rssi: -55)],
                                        selectedID: saved.uuidString,
                                        savedName: "TNC4 Mobilinkd")
        XCTAssertEqual(rows, [.init(id: saved.uuidString, label: "TNC4 Mobilinkd (-55 dBm)")])
    }

    func testNothingSavedAddsNothing() {
        XCTAssertEqual(BLEDevicePicker.rows(scanned: [], selectedID: "", savedName: ""), [])
    }
}
