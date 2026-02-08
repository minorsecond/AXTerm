//
//  ObservabilityTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-01-29.
//

import XCTest
@testable import AXTerm

final class ObservabilityTests: XCTestCase {

    // MARK: - DSN Resolution Tests

    func testResolveDSN_prefersEnvironmentOverInfoPlist() {
        let dsn = SentryConfiguration.resolveDSN(
            environmentValue: "  https://examplePublicKey@o0.ingest.sentry.io/0  ",
            infoPlistValue: "https://ignored@o0.ingest.sentry.io/1"
        )
        XCTAssertEqual(dsn, "https://examplePublicKey@o0.ingest.sentry.io/0")
    }

    func testResolveDSN_fallsBackToInfoPlistWhenEnvEmpty() {
        let dsn = SentryConfiguration.resolveDSN(
            environmentValue: "   ",
            infoPlistValue: "https://plist@o0.ingest.sentry.io/1"
        )
        XCTAssertEqual(dsn, "https://plist@o0.ingest.sentry.io/1")
    }

    func testResolveDSN_emptyValuesReturnNil() {
        XCTAssertNil(SentryConfiguration.resolveDSN(environmentValue: "   ", infoPlistValue: "   "))
        XCTAssertNil(SentryConfiguration.resolveDSN(environmentValue: nil, infoPlistValue: "   "))
        XCTAssertNil(SentryConfiguration.resolveDSN(environmentValue: "   ", infoPlistValue: nil))
        XCTAssertNil(SentryConfiguration.resolveDSN(environmentValue: nil, infoPlistValue: nil))
    }

    // MARK: - Configuration Loading Tests

    func testSentryConfiguration_loadFromMockInfoPlist_allValuesPresent() {
        let mockPlist = MockInfoPlistReader([
            "SENTRY_DSN": "https://test@sentry.io/123",
            "SENTRY_ENVIRONMENT": "testing",
            "SENTRY_DEBUG": "YES",
            "SENTRY_TRACES_SAMPLE_RATE": "0.5",
            "SENTRY_PROFILES_SAMPLE_RATE": "0.25",
            "CFBundleShortVersionString": "2.0",
            "CFBundleVersion": "42",
            "CFBundleName": "TestApp"
        ])

        let config = SentryConfiguration.load(
            infoPlist: mockPlist,
            environmentVariables: [:],
            enabledByUser: true,
            sendPacketContents: false,
            sendConnectionDetails: true
        )

        XCTAssertEqual(config.dsn, "https://test@sentry.io/123")
        XCTAssertEqual(config.environment, "testing")
        XCTAssertTrue(config.debug)
        XCTAssertEqual(config.tracesSampleRate, 0.5, accuracy: 0.001)
        XCTAssertEqual(config.profilesSampleRate, 0.25, accuracy: 0.001)
        XCTAssertEqual(config.release, "TestApp@2.0+42")
        XCTAssertEqual(config.dist, "42")
        XCTAssertTrue(config.enabledByUser)
        XCTAssertFalse(config.sendPacketContents)
        XCTAssertTrue(config.sendConnectionDetails)
        XCTAssertTrue(config.shouldStart)
    }

    func testSentryConfiguration_loadFromMockInfoPlist_missingDSN_shouldNotStart() {
        let mockPlist = MockInfoPlistReader([
            "SENTRY_ENVIRONMENT": "testing",
            "SENTRY_DEBUG": "NO"
        ])

        let config = SentryConfiguration.load(
            infoPlist: mockPlist,
            environmentVariables: [:],
            enabledByUser: true
        )

        XCTAssertNil(config.dsn)
        XCTAssertFalse(config.shouldStart)
    }

    func testSentryConfiguration_loadFromMockInfoPlist_userDisabled_shouldNotStart() {
        let mockPlist = MockInfoPlistReader([
            "SENTRY_DSN": "https://test@sentry.io/123",
            "SENTRY_ENVIRONMENT": "production"
        ])

        let config = SentryConfiguration.load(
            infoPlist: mockPlist,
            environmentVariables: [:],
            enabledByUser: false
        )

        XCTAssertNotNil(config.dsn)
        XCTAssertFalse(config.shouldStart)
    }

    func testSentryConfiguration_sampleRatesClamped() {
        let mockPlist = MockInfoPlistReader([
            "SENTRY_DSN": "https://test@sentry.io/123",
            "SENTRY_TRACES_SAMPLE_RATE": "2.5",  // Above 1.0
            "SENTRY_PROFILES_SAMPLE_RATE": "-0.5"  // Below 0.0
        ])

        let config = SentryConfiguration.load(
            infoPlist: mockPlist,
            environmentVariables: [:],
            enabledByUser: true
        )

        XCTAssertEqual(config.tracesSampleRate, 1.0, accuracy: 0.001)
        XCTAssertEqual(config.profilesSampleRate, 0.0, accuracy: 0.001)
    }

    func testSentryConfiguration_boolParsing() {
        // Test various boolean representations
        let testCases: [(value: Any, expected: Bool)] = [
            ("YES", true),
            ("yes", true),
            ("TRUE", true),
            ("true", true),
            ("1", true),
            ("NO", false),
            ("no", false),
            ("FALSE", false),
            ("false", false),
            ("0", false),
            ("invalid", false)
        ]

        for (value, expected) in testCases {
            let mockPlist = MockInfoPlistReader(["SENTRY_DEBUG": value])
            XCTAssertEqual(mockPlist.bool(forKey: "SENTRY_DEBUG"), expected,
                           "Failed for value: \(value)")
        }
    }

    func testSentryConfiguration_environmentVariableTakesPrecedenceOverInfoPlist() {
        let mockPlist = MockInfoPlistReader([
            "SENTRY_DSN": "https://plist@sentry.io/1"
        ])

        let config = SentryConfiguration.load(
            infoPlist: mockPlist,
            environmentVariables: ["SENTRY_DSN": "https://env@sentry.io/2"],
            enabledByUser: true
        )

        XCTAssertEqual(config.dsn, "https://env@sentry.io/2")
    }

    // MARK: - Packet Payload Tests

    func testPacketSentryPayload_redactsContentsByDefault() {
        let packet = Packet(
            from: AX25Address(call: "N0CALL", ssid: 1),
            to: AX25Address(call: "DEST"),
            via: [AX25Address(call: "WIDE1", ssid: 1)],
            frameType: .ui,
            pid: 0xF0,
            info: "HELLO".data(using: .ascii) ?? Data(),
            rawAx25: Data([0x01, 0x02, 0x03])
        )

        let payload = PacketSentryPayload.make(packet: packet, sendPacketContents: false)
        XCTAssertNil(payload.infoText)
        XCTAssertNil(payload.rawHex)
        XCTAssertEqual(payload.from, "N0CALL-1")
        XCTAssertEqual(payload.to, "DEST")
        XCTAssertEqual(payload.viaCount, 1)
    }

    func testPacketSentryPayload_includesContentsWhenEnabled() {
        let packet = Packet(
            from: AX25Address(call: "N0CALL", ssid: 1),
            to: AX25Address(call: "DEST"),
            frameType: .ui,
            pid: 0xF0,
            info: "HELLO".data(using: .ascii) ?? Data(),
            rawAx25: Data([0x01, 0x02, 0x03])
        )

        let payload = PacketSentryPayload.make(packet: packet, sendPacketContents: true)
        XCTAssertNotNil(payload.infoText)
        XCTAssertNotNil(payload.rawHex)
    }

    func testPacketSentryPayload_toDictionary_containsRequiredKeys() {
        let packet = Packet(
            from: AX25Address(call: "TEST", ssid: 0),
            to: AX25Address(call: "APRS"),
            frameType: .ui,
            pid: 0xF0,
            info: Data(),
            rawAx25: Data([0x00])
        )

        let payload = PacketSentryPayload.make(packet: packet, sendPacketContents: false)
        let dict = payload.toDictionary()

        XCTAssertNotNil(dict["frameType"])
        XCTAssertNotNil(dict["byteCount"])
        XCTAssertNotNil(dict["from"])
        XCTAssertNotNil(dict["to"])
        XCTAssertNotNil(dict["viaCount"])
        XCTAssertNil(dict["infoText"]) // Redacted
        XCTAssertNil(dict["rawHex"])   // Redacted
    }

    // MARK: - MockInfoPlistReader Tests

    func testMockInfoPlistReader_stringRetrieval() {
        let mock = MockInfoPlistReader(["key": "value"])
        XCTAssertEqual(mock.string(forKey: "key"), "value")
        XCTAssertNil(mock.string(forKey: "missing"))
    }

    func testMockInfoPlistReader_doubleRetrieval() {
        let mock = MockInfoPlistReader([
            "doubleValue": 0.75,
            "stringDouble": "0.5",
            "invalidString": "not a number"
        ])

        XCTAssertEqual(mock.double(forKey: "doubleValue")!, 0.75, accuracy: 0.001)
        XCTAssertEqual(mock.double(forKey: "stringDouble")!, 0.5, accuracy: 0.001)
        XCTAssertNil(mock.double(forKey: "invalidString"))
        XCTAssertNil(mock.double(forKey: "missing"))
    }

    // MARK: - Router Tests

    @MainActor
    func testPacketInspectionRouter_requestAndConsume_isIdempotent() {
        let router = PacketInspectionRouter()
        let id = UUID()

        router.requestOpenPacket(id: id)
        XCTAssertEqual(router.requestedPacketID, id)
        XCTAssertTrue(router.shouldOpenMainWindow)

        router.consumePacketRequest()
        XCTAssertNil(router.requestedPacketID)
        XCTAssertTrue(router.shouldOpenMainWindow)

        router.consumeOpenWindowRequest()
        XCTAssertFalse(router.shouldOpenMainWindow)

        // Idempotent consumes should be safe.
        router.consumePacketRequest()
        router.consumeOpenWindowRequest()
        XCTAssertNil(router.requestedPacketID)
        XCTAssertFalse(router.shouldOpenMainWindow)
    }

    // MARK: - Settings Store Tests

    @MainActor
    func testAppSettingsStore_sanitizesViaDeferredUpdate() async {
        let suiteName = "AXTermTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = AppSettingsStore(defaults: defaults)

        store.port = "999999"
        XCTAssertEqual(store.port, "999999") // deferred

        await Task.yield()
        XCTAssertEqual(store.port, "65535")

        store.host = "   "
        XCTAssertEqual(store.host, "   ") // deferred

        await Task.yield()
        XCTAssertEqual(store.host, AppSettingsStore.defaultHost)
    }

    @MainActor
    func testAppSettingsStore_sentryDefaults() {
        let suiteName = "AXTermTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.sentryEnabled, AppSettingsStore.defaultSentryEnabled)
        XCTAssertEqual(store.sentrySendPacketContents, AppSettingsStore.defaultSentrySendPacketContents)
        XCTAssertEqual(store.sentrySendConnectionDetails, AppSettingsStore.defaultSentrySendConnectionDetails)
    }
}

