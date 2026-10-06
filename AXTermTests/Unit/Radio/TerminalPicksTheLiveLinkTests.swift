//
//  TerminalPicksTheLiveLinkTests.swift
//  AXTermTests
//
//  In the main app (two radios, the first one disabled and disconnected) a
//  line typed on a live link to K0EPI-3 over the 705 sat at "Queued": the
//  terminal looked the session up on the primary radio, found a session to
//  K0EPI-3 there that never connected, and queued the line on it (smoke run
//  2026-10-03-1, test 10.4, issue 100).
//

import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class TerminalPicksTheLiveLinkTests: XCTestCase {

    func testTheTerminalUsesTheLiveLinkOverADeadSessionOnThePrimary() throws {
        let settings = AppSettingsStore(defaults: TestDefaults.make("TerminalPicksTheLiveLink"))
        settings.myCallsign = "K0EPI"
        let primary = settings.radios[0].id
        let second = settings.addRadio().id
        let engine = PacketEngine(settings: settings)
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = settings.primaryCallsign
        coordinator.appSettings = settings
        defer { withExtendedLifetime((engine, coordinator)) {} }
        let manager = coordinator.sessionManager
        let peer = AX25Address(call: "K0EPI", ssid: 3)
        let me = AX25Address(call: "K0EPI", ssid: 2)

        // Left on the primary by an attempt that never got out.
        let dead = manager.session(for: peer, path: DigiPath(), radio: primary)
        XCTAssertNotEqual(dead.state, .connected)
        // The real link, on the second radio.
        XCTAssertEqual(manager.handleInboundSABM(from: peer, to: me, path: DigiPath(), radio: second)?.displayInfo, "UA")

        let terminal = ObservableTerminalTxViewModel(client: engine, settings: settings,
                                                     sourceCall: settings.primaryCallsign,
                                                     sessionManager: manager)
        terminal.destinationCall.wrappedValue = "K0EPI-3"
        terminal.refreshCurrentSession()

        let current = try XCTUnwrap(terminal.currentSession)
        XCTAssertEqual(current.radio, second, "the live link, not the session on the primary that never connected")
        XCTAssertEqual(current.state, .connected)
    }
}
