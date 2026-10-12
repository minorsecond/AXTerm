//
//  NodeIdleTimeoutTests.swift
//  AXTermTests
//
//  The node hangs up on a caller who has typed nothing for a while, as a
//  BPQ node's IDLETIME does (operator, 2026-10-12: the iPad sat connected
//  to EPINOD for three hours with nobody there). Fifteen minutes unless the
//  operator sets otherwise, or never. Only the caller's typing counts: the
//  link's own polls do not reach the node.
//

import XCTest
@testable import AXTerm

@MainActor
final class NodeIdleTimeoutTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var said = ""
    private var hungUp = false

    private func node(idle: TimeInterval?) -> NetRomNodeHost {
        let host = NetRomNodeHost()
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm") }
        host.idleTimeout = idle
        host.now = { [unowned self] in self.clock }
        clock = t0
        host.attachAX25Caller(key: "S1", callsign: "K0EPI-3", dialed: "EPINOD",
                              send: { [unowned self] in self.said += String(decoding: $0, as: UTF8.self) },
                              hangUp: { [unowned self] in self.hungUp = true })
        said = ""
        return host
    }

    func testTheSettingStartsAtFifteenMinutesAndIsKept() {
        let defaults = TestDefaults.make("node-idle-setting")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).netRomNodeIdleMinutes, 15)
        AppSettingsStore(defaults: defaults).netRomNodeIdleMinutes = 0
        XCTAssertEqual(AppSettingsStore(defaults: defaults).netRomNodeIdleMinutes, 0, "never")
        AppSettingsStore(defaults: defaults).netRomNodeIdleMinutes = 30
        XCTAssertEqual(AppSettingsStore(defaults: defaults).netRomNodeIdleMinutes, 30)
    }

    func testTheCoordinatorGivesTheNodeTheSetting() {
        let settings = AppSettingsStore(defaults: TestDefaults.make("node-idle-apply"))
        let coordinator = SessionCoordinator()
        settings.netRomNodeIdleMinutes = 10
        coordinator.applyNetRomNodeSettings(settings)
        XCTAssertEqual(coordinator.netRomNodeHost.idleTimeout, 600)
        settings.netRomNodeIdleMinutes = 0
        coordinator.applyNetRomNodeSettings(settings)
        XCTAssertNil(coordinator.netRomNodeHost.idleTimeout)
    }

    func testAnIdleCallerIsToldAndHungUpOn() {
        let host = node(idle: 900)
        clock = t0.addingTimeInterval(899)
        host.hangUpIdleCallers()
        XCTAssertFalse(hungUp)
        clock = t0.addingTimeInterval(900)
        host.hangUpIdleCallers()
        XCTAssertTrue(said.contains("no activity"), said)
        XCTAssertTrue(hungUp)
    }

    func testTypingKeepsTheCallerOn() {
        let host = node(idle: 900)
        clock = t0.addingTimeInterval(600)
        host.ax25CallerReceived(key: "S1", data: Data("i\r".utf8))
        clock = t0.addingTimeInterval(1_200)
        host.hangUpIdleCallers()
        XCTAssertFalse(hungUp, "ten minutes since the last line")
        clock = t0.addingTimeInterval(1_500)
        host.hangUpIdleCallers()
        XCTAssertTrue(hungUp)
    }

    func testSetToNeverNobodyIsHungUpOn() {
        let host = node(idle: nil)
        clock = t0.addingTimeInterval(86_400)
        host.hangUpIdleCallers()
        XCTAssertFalse(hungUp)
    }
}
