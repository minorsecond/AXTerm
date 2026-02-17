//
//  TNC4BluetoothSerialConnectionTests.swift
//  AXTermTests
//
//  Live integration checks for Mobilinkd TNC4 over Bluetooth classic serial
//  (/dev/cu.*) via KISSLinkSerial.
//

import XCTest
@testable import AXTerm

@MainActor
private final class BluetoothSerialTestDelegate: KISSLinkDelegate {
    var states: [KISSLinkState] = []
    var errors: [String] = []

    func linkDidReceive(_ data: Data) {}

    func linkDidChangeState(_ state: KISSLinkState) {
        states.append(state)
    }

    func linkDidError(_ message: String) {
        errors.append(message)
    }
}

@MainActor
final class TNC4BluetoothSerialConnectionTests: XCTestCase {
    private let bluetoothSerialPath = "/dev/cu.TNC4Mobilinkd"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.fileExists(atPath: "/tmp/axterm_rf_tests_enabled") else {
            throw XCTSkip("RF tests disabled — use run_rf_tests.sh to enable")
        }
        guard FileManager.default.fileExists(atPath: bluetoothSerialPath) else {
            throw XCTSkip("Bluetooth serial device not present at \(bluetoothSerialPath)")
        }
    }

    func testKISSLinkSerialOpensMobilinkdBluetoothSerialPath() async throws {
        let config = SerialConfig(
            devicePath: bluetoothSerialPath,
            baudRate: 115200,
            autoReconnect: false,
            mobilinkdConfig: MobilinkdConfig(
                modemType: .afsk1200,
                outputGain: 11,
                inputGain: 0,
                isBatteryMonitoringEnabled: true
            )
        )

        let link = KISSLinkSerial(config: config)
        let delegate = BluetoothSerialTestDelegate()
        link.delegate = delegate

        link.open()

        let deadline = Date().addingTimeInterval(20.0)
        while Date() < deadline {
            if link.state == .connected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertEqual(link.state, .connected, "Bluetooth classic serial link should reach connected state")
        XCTAssertTrue(delegate.states.contains(.connected), "Delegate should receive connected state")

        link.close()

        let closeDeadline = Date().addingTimeInterval(3.0)
        while Date() < closeDeadline {
            if link.state == .disconnected { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(link.state, .disconnected)
    }
}
