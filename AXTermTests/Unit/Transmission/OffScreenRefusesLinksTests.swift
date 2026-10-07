//
//  OffScreenRefusesLinksTests.swift
//  AXTermTests
//
//  The iPad heard nothing from its Bluetooth TNC while AXTerm was in the
//  background, so its goodbye was one-sided: the DISC went out, A (705)
//  answered UA, and the iPad never heard it (smoke run 2026-10-03-1, 13.4,
//  issue 115). The iOS app now declares the bluetooth-central background
//  mode, which also lets iOS wake it for frames after the goodbye. A call
//  arriving then would open a link the app cannot keep, so while the app
//  is off screen a SABM is refused with DM, as on an APRS channel.
//

import XCTest
@testable import AXTerm

@MainActor
final class OffScreenRefusesLinksTests: XCTestCase {
    private let me = AX25Address(call: "K0EPI", ssid: 3)
    private let caller = AX25Address(call: "K0EPI", ssid: 2)

    private func coordinator() -> SessionCoordinator {
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = me.display
        coordinator.appSettings = AppSettingsStore(defaults: TestDefaults.make("OffScreenRefusesLinks"))
        return coordinator
    }

    func testACallWhileOffScreenIsRefusedWithDM() throws {
        let coordinator = coordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.isOffScreen = true
        let answer = try XCTUnwrap(coordinator.sessionManager.handleInboundSABM(
            from: caller, to: me, path: DigiPath(), radio: .primary))
        XCTAssertEqual(answer.displayInfo, "DM")
        XCTAssertNil(coordinator.sessionManager.connectedSession(withPeer: caller))
    }

    func testACallOnScreenIsAnswered() throws {
        let coordinator = coordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.isOffScreen = false
        let answer = try XCTUnwrap(coordinator.sessionManager.handleInboundSABM(
            from: caller, to: me, path: DigiPath(), radio: .primary))
        XCTAssertEqual(answer.displayInfo, "UA")
    }

    func testTheIOSAppDeclaresBluetoothBackgroundMode() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AXTerm/iOS/AXTerm-iOS-Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        XCTAssertTrue(modes.contains("bluetooth-central"))
    }
}
