//
//  AppSettingsStoreTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import XCTest
@testable import AXTerm

final class AppSettingsStoreTests: XCTestCase {
    func testHostValidationDefaultsToLocalhost() {
        XCTAssertEqual(AppSettingsStore.sanitizeHost("   "), AppSettingsStore.defaultHost)
        XCTAssertEqual(AppSettingsStore.sanitizeHost("kiss.local"), "kiss.local")
    }

    func testPortValidationClampsToRange() {
        XCTAssertEqual(AppSettingsStore.sanitizePort("0"), "1")
        XCTAssertEqual(AppSettingsStore.sanitizePort("99999"), "65535")
        XCTAssertEqual(AppSettingsStore.sanitizePort("8001"), "8001")
        XCTAssertEqual(AppSettingsStore.sanitizePort("abc"), "\(AppSettingsStore.defaultPort)")
    }

    func testRetentionValidationClamps() {
        XCTAssertEqual(AppSettingsStore.sanitizeRetention(10), AppSettingsStore.minRetention)
        XCTAssertEqual(AppSettingsStore.sanitizeRetention(600_000), AppSettingsStore.maxRetention)
        XCTAssertEqual(AppSettingsStore.sanitizeRetention(50_000), 50_000)
    }

    func testLogRetentionValidationClamps() {
        XCTAssertEqual(AppSettingsStore.sanitizeLogRetention(10), AppSettingsStore.minLogRetention)
        XCTAssertEqual(AppSettingsStore.sanitizeLogRetention(600_000), AppSettingsStore.maxLogRetention)
        XCTAssertEqual(AppSettingsStore.sanitizeLogRetention(10_000), 10_000)
    }
}
