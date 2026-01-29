//
//  ObservabilityTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-01-29.
//

import XCTest
@testable import AXTerm

final class ObservabilityTests: XCTestCase {
    func testResolveDSN_prefersEnvironmentOverInfoPlist() {
        let dsn = SentryConfiguration.resolveDSN(
            environmentValue: "  https://examplePublicKey@o0.ingest.sentry.io/0  ",
            infoPlistValue: "https://ignored@o0.ingest.sentry.io/1"
        )
        XCTAssertEqual(dsn, "https://examplePublicKey@o0.ingest.sentry.io/0")
    }

    func testResolveDSN_emptyValuesReturnNil() {
        XCTAssertNil(SentryConfiguration.resolveDSN(environmentValue: "   ", infoPlistValue: "https://x@y/1"))
        XCTAssertNil(SentryConfiguration.resolveDSN(environmentValue: nil, infoPlistValue: "   "))
        XCTAssertNil(SentryConfiguration.resolveDSN(environmentValue: "   ", infoPlistValue: "   "))
    }

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
}

