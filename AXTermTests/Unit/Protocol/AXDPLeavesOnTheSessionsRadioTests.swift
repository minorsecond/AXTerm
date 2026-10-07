//
//  AXDPLeavesOnTheSessionsRadioTests.swift
//  AXTermTests
//
//  The iPad had two radios: an old KISS TCP radio (the primary, turned off)
//  and the TNC4 over Bluetooth. A (705) connected to it over the TNC4. When
//  AXDP was turned on, its PING found the link but was handed to `sendData`
//  with no radio, so it took the default, found no link on the primary, and
//  opened one there: an XID and SABMs on a radio that was off, with the PING
//  and the operator's lines queued behind them. A test-mode station has one
//  radio whose id is the primary, which hid it (smoke run 2026-10-03-1, test
//  13.4, issue 110).
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class AXDPLeavesOnTheSessionsRadioTests: XCTestCase {
    private let me = AX25Address(call: "K0EPI", ssid: 3)
    private let peer = AX25Address(call: "K0EPI", ssid: 2)
    private let tnc4 = RadioID(rawValue: "9C92D96B-D65F-4764-BD5C-7ABECD3B52FF")

    func testAnAXDPPayloadRidesTheLinkOnItsOwnRadio() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let settings = AppSettingsStore(defaults: TestDefaults.make("AXDPOnSessionsRadio"))
        let engine = PacketEngine(settings: settings, databaseWriter: queue)
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.localCallsign = me.display
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: engine)

        _ = coordinator.sessionManager.handleInboundSABM(from: peer, to: me, path: DigiPath(), radio: tnc4)
        let link = try XCTUnwrap(coordinator.sessionManager.connectedSession(withPeer: peer))
        XCTAssertEqual(link.radio, tnc4)

        let sent = coordinator.sendAXDPPayload(Data("AXT1 ping".utf8), to: peer, path: DigiPath(),
                                               displayInfo: "AXDP PING")

        XCTAssertTrue(sent)
        XCTAssertNil(coordinator.sessionManager.existingSession(for: peer, path: DigiPath(), radio: .primary),
                     "no second link is opened on the primary radio")
        XCTAssertEqual(coordinator.sessionManager.sessions.count, 1)
        XCTAssertEqual(link.vs, 1, "the payload went out as I0 on the TNC4's link")
    }
}
