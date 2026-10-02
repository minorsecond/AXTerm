//
//  NetRomNodeHostWiringTests.swift
//  AXTermTests
//
//  The node host learns who it is and what it may say from the coordinator,
//  not from a view. Until 2026-10-02 only the Mac's ContentView set the
//  host's providers, so on iOS a caller to the node alias was greeted as
//  NODE:N0CALL and saw an empty INFO with the mailbox unavailable, even
//  though the iOS settings let the operator turn the node on.
//
//  These tests build a coordinator and settings the way either app shell
//  does and never touch a view.
//

import XCTest
@testable import AXTerm

@MainActor
final class NetRomNodeHostWiringTests: XCTestCase {

    private var written: [Data] = []

    private var callerText: String {
        String(decoding: Data(written.flatMap { $0 }), as: UTF8.self)
    }

    private func makeSettings(_ label: String) -> AppSettingsStore {
        let settings = AppSettingsStore(defaults: TestDefaults.make(label))
        settings.myCallsign = "K0EPI"
        settings.netRomNodeAlias = "epinod"
        return settings
    }

    private func attachCaller(to coordinator: SessionCoordinator) {
        coordinator.netRomNodeHost.attachAX25Caller(
            key: "S1", callsign: "W0ARP-1",
            send: { [weak self] data in self?.written.append(data) },
            hangUp: {})
    }

    private func type(_ line: String, to coordinator: SessionCoordinator) {
        coordinator.netRomNodeHost.ax25CallerReceived(
            key: "S1", data: Data((line + "\r").utf8))
    }

    func testNodeGreetsWithTheConfiguredAliasAndPrimaryCallsign() {
        let settings = makeSettings("node-host-greeting")
        let coordinator = SessionCoordinator()
        coordinator.appSettings = settings

        attachCaller(to: coordinator)

        let call = settings.primaryCallsign.uppercased()
        XCTAssertFalse(call.isEmpty)
        XCTAssertTrue(callerText.contains("Node EPINOD:\(call)"),
                      "greeting was: \(callerText)")
        XCTAssertFalse(callerText.contains("N0CALL"))
    }

    func testGreetingFollowsASettingsChangeWithoutRewiring() {
        let settings = makeSettings("node-host-greeting-change")
        let coordinator = SessionCoordinator()
        coordinator.appSettings = settings

        settings.netRomNodeAlias = "COSCO"
        attachCaller(to: coordinator)

        XCTAssertTrue(callerText.contains("Node COSCO:"), "greeting was: \(callerText)")
    }

    func testInfoAndBBSComeFromTheMailboxTheCoordinatorWasGiven() {
        let settings = makeSettings("node-host-mailbox")
        let bbsSettings = BBSSettings(defaults: TestDefaults.make("node-host-mailbox-bbs"))
        bbsSettings.stationInfo = "Grid EM29, on the air evenings."
        bbsSettings.onAir = true
        let coordinator = SessionCoordinator()
        coordinator.appSettings = settings
        let mailbox = BBSService(
            store: nil, settings: bbsSettings, coordinator: coordinator,
            sendFrames: { _ in }, stationCallsign: { settings.primaryCallsign },
            isWinlinkP2PArmed: { false }, winlinkP2PCallsign: { "" })

        attachCaller(to: coordinator)
        type("INFO", to: coordinator)
        XCTAssertTrue(callerText.contains("Grid EM29, on the air evenings."),
                      "INFO was: \(callerText)")

        written = []
        type("BBS", to: coordinator)
        XCTAssertFalse(callerText.contains("The mailbox is not on the air."),
                       "BBS was: \(callerText)")
        withExtendedLifetime(mailbox) {}
    }
}
