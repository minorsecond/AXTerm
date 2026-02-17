//
//  PacketEngineIFrameConsoleFilteringTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

@MainActor
final class PacketEngineIFrameConsoleFilteringTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        SessionCoordinator.shared = nil
    }

    func testUserAddressedIFrameWithoutConnectedSessionIsShownInConsole() {
        let settings = makeSettings()
        settings.myCallsign = "TEST-7"
        let engine = PacketEngine(settings: settings)

        let packet = Packet(
            from: AX25Address(call: "PEER", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 7),
            frameType: .i,
            control: 0x00,
            pid: 0xF0,
            info: Data("hello without session".utf8)
        )

        engine.handleIncomingPacket(packet)

        XCTAssertTrue(
            engine.consoleLines.contains { $0.kind == .packet && $0.text.contains("hello without session") },
            "User-addressed I-frame must remain visible when no connected session exists."
        )
    }

    func testUserAddressedIFrameWithConnectedSessionIsSuppressedFromRawConsole() {
        let settings = makeSettings()
        settings.myCallsign = "TEST-7"
        let engine = PacketEngine(settings: settings)

        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "TEST-7"
        _ = coordinator.sessionManager.handleInboundSABM(
            from: AX25Address(call: "PEER", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 7),
            path: DigiPath(),
            channel: 0
        )

        let packet = Packet(
            from: AX25Address(call: "PEER", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 7),
            frameType: .i,
            control: 0x00,
            pid: 0xF0,
            info: Data("hello connected session".utf8)
        )

        engine.handleIncomingPacket(packet)

        XCTAssertFalse(
            engine.consoleLines.contains { $0.kind == .packet && $0.text.contains("hello connected session") },
            "When a connected session exists, raw user I-frame lines should be suppressed to avoid duplicates."
        )
    }

    func testUserAddressedIFrameWithNonConnectedSessionStillShowsInConsole() {
        let settings = makeSettings()
        settings.myCallsign = "TEST-7"
        let engine = PacketEngine(settings: settings)

        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "TEST-7"
        _ = coordinator.sessionManager.session(for: AX25Address(call: "PEER", ssid: 1), path: DigiPath())

        let packet = Packet(
            from: AX25Address(call: "PEER", ssid: 1),
            to: AX25Address(call: "TEST", ssid: 7),
            frameType: .i,
            control: 0x00,
            pid: 0xF0,
            info: Data("hello stale session".utf8)
        )

        engine.handleIncomingPacket(packet)

        XCTAssertTrue(
            engine.consoleLines.contains { $0.kind == .packet && $0.text.contains("hello stale session") },
            "Only active connected sessions should suppress raw I-frame console lines."
        )
    }

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppSettingsStore(defaults: defaults)
    }
}
