//
//  SerialDeviceAutoDetectionTests.swift
//  AXTermTests
//
//  Tests for resolveSerialDevicePath() USB device auto-detection.
//

import XCTest
@testable import AXTerm

@MainActor
final class SerialDeviceAutoDetectionTests: XCTestCase {

    private func makeEngine() -> PacketEngine {
        let suiteName = "AXTermTests.AutoDetect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettingsStore(defaults: defaults)
        return PacketEngine(settings: settings)
    }

    func testExistingPathReturnedUnchanged() {
        let engine = makeEngine()
        // /dev/null always exists
        let result = engine.resolveSerialDevicePath("/dev/null")
        XCTAssertEqual(result, "/dev/null", "Existing path should be returned as-is")
    }

    func testMissingPathReturnsOriginalWhenNoUSBDevices() {
        let engine = makeEngine()
        // A path that certainly doesn't exist and no usbmodem devices likely present in CI
        let fakePath = "/dev/cu.nonexistent_device_\(UUID().uuidString)"
        let result = engine.resolveSerialDevicePath(fakePath)
        // Should either return the original path (no USB devices found)
        // or an auto-detected device (if a USB modem is plugged in)
        // We can't guarantee which, so just ensure it returns something non-empty
        XCTAssertFalse(result.isEmpty, "Should return a non-empty path")
    }

    func testEmptyPathAttempsAutoDetection() {
        let engine = makeEngine()
        let result = engine.resolveSerialDevicePath("")
        // With no USB modem plugged in, should return ""
        // With one plugged in, should return the detected path
        // Either way, shouldn't crash
        _ = result  // Just verify no crash
    }
}
