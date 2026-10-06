//
//  BBSNetRomStandAsideTests.swift
//  AXTermTests
//
//  The mailbox steps aside from a link that turns out to carry NET/ROM.
//
//  Answering on the node's callsign, the mailbox greets a neighbor node that
//  linked up to carry a circuit, the way the Winlink answerer did in smoke
//  run 2026-10-03-1, issue 73. The first PID 0xCF frame says the link is a
//  node's (AX.25 §3.3), so the mailbox lets go of it and never times it out.
//

import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class BBSNetRomStandAsideTests: XCTestCase {

    private let mailboxAddress = AX25Address(call: "K0EPI", ssid: 3)
    private let neighbor = AX25Address(call: "K0EPI", ssid: 2)

    func testTheMailboxLetsGoOfANodesLinkWithoutEndingIt() async throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLiteBBSMessageStore(dbQueue: queue)
        let settings = BBSSettings(defaults: TestDefaults.make("bbs-netrom-stand-aside"))
        settings.onAir = true
        settings.callsign = "K0EPI-3"
        let coordinator = SessionCoordinator()
        let caller = BBSSimulatedCaller(manager: coordinator.sessionManager,
                                        address: neighbor, mailbox: mailboxAddress)
        coordinator.sessionManager.onSendFrame = { [weak caller] in caller?.outbox.append($0) }
        let service = BBSService(
            store: store, settings: settings, coordinator: coordinator,
            sendFrames: { [weak caller] in caller?.outbox.append(contentsOf: $0) },
            stationCallsign: { "K0EPI" },
            isWinlinkP2PArmed: { false },
            winlinkP2PCallsign: { "" },
            linkBytesPerSecond: { 1_000_000 })
        service.attach()
        defer { service.shutdown(reason: "test over"); service.detach() }

        caller.connect()
        let greeted = await caller.pump { !caller.text.isEmpty }
        XCTAssertTrue(greeted, "the mailbox answered the link")
        XCTAssertNotNil(service.live)
        let session = try XCTUnwrap(coordinator.sessionManager.existingSession(for: neighbor))
        caller.outbox.removeAll()

        // The neighbor's CONREQ.
        _ = coordinator.sessionManager.handleInboundIFrame(
            from: neighbor, path: DigiPath(), radio: .primary,
            ns: 0, nr: 0, pf: false, payload: Data(repeating: 0, count: 20), pid: NetRomWire.pid)

        XCTAssertNil(service.live, "the mailbox is no longer on the call")
        XCTAssertFalse(coordinator.sessionManager.hasDeliveryClaim(for: session.key))
        XCTAssertEqual(session.state, .connected, "the link is the node's now")
        XCTAssertFalse(caller.outbox.contains { ($0.controlByte ?? 0) & ~0x10 == 0x43 },
                       "no DISC from the mailbox")
    }
}
