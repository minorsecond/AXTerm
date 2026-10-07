//
//  PacketSubscriptionKeepsFramesTests.swift
//  AXTermTests
//
//  Smoke run 2026-10-03-1, issue 104: the iPhone logged I-frames that never
//  reached its AX.25 session. The packet engine published them; the session
//  layer's subscriber never ran for them. The iPhone wired the coordinator
//  again on every settings change, and `subscribeToPackets` cancelled its
//  subscription and made a new one, losing a frame still queued for the
//  main queue. Wiring again with the same engine now keeps the subscription.
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class PacketSubscriptionKeepsFramesTests: XCTestCase {

    private let caller = AX25Address(call: "K0EPI", ssid: 2)
    private let local = AX25Address(call: "K0EPI", ssid: 3)

    func testWiringAgainDoesNotLoseAFrameOnItsWayToTheSession() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let settings = AppSettingsStore(defaults: TestDefaults.make("SubscriptionKeepsFrames"))
        let engine = PacketEngine(settings: settings, databaseWriter: queue)
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.localCallsign = "K0EPI-3"
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: engine)

        // A caller's SABM, published; delivery to the session layer waits for
        // the main queue.
        let sabm = Packet(from: caller, to: local, frameType: .u, control: 0x3F)
        engine.handleIncomingPacket(sabm)
        // The iPhone's settings change wires the coordinator again here.
        coordinator.subscribeToPackets(from: engine)

        let deadline = Date().addingTimeInterval(1)
        while coordinator.sessionManager.connectedSession(withPeer: caller) == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(coordinator.sessionManager.connectedSession(withPeer: caller),
                        "the SABM still reaches the session layer and opens the link")
    }
}
