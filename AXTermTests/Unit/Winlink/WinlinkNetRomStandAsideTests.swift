//
//  WinlinkNetRomStandAsideTests.swift
//  AXTermTests
//
//  A Winlink answerer that finds NET/ROM on its link steps aside and leaves
//  the link to the node.
//
//  Smoke run 2026-10-03-1, issue 73: B (ID-50)'s node and its Winlink
//  answerer share K0EPI-3. A (705) linked to K0EPI-3 to carry a NET/ROM
//  circuit; the answerer greeted, waited for a B2F handshake that was never
//  coming, timed out after 90 s and sent DISC, and the circuit riding the
//  link dropped. A link that carries PID 0xCF is a node's link (AX.25 §3.3,
//  the PID is the protocol demux), and the B2F answerer has no business on
//  it.
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class WinlinkNetRomStandAsideTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 2)
    private var sent: [OutboundFrame] = []

    private var sentDISC: Bool {
        sent.contains { ($0.controlByte ?? 0) & ~0x10 == 0x43 }
    }

    func testTheTransportStepsAsideWithoutEndingTheLink() async throws {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 3))
        manager.onSendFrame = { [unowned self] in self.sent.append($0) }
        _ = manager.handleInboundSABM(from: peer, to: manager.localCallsign, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer))
        let transport = WinlinkAX25Transport(
            sessionManager: manager,
            sendFrames: { [unowned self] in self.sent.append(contentsOf: $0) },
            destination: peer)
        var steppedAside: String?
        var received = Data()
        transport.onStandAside = { steppedAside = $0 }
        transport.onReceive = { received.append($0) }
        try await transport.open()
        transport.send(Data("[AXTerm-1.0-B2FHM$]\r".utf8))   // the answerer's greeting

        // The caller's first I-frame is a NET/ROM CONREQ, not a B2F line.
        let conreq = Data(repeating: 0x00, count: 20)
        _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                        ns: 0, nr: 0, pf: false, payload: conreq, pid: NetRomWire.pid)

        XCTAssertNotNil(steppedAside, "the answerer is told the link is not a Winlink call")
        XCTAssertFalse(sentDISC, "the link belongs to the node now; the answerer must not end it")
        XCTAssertEqual(session.state, .connected)
        XCTAssertFalse(manager.hasDeliveryClaim(for: session.key), "the claim on the link is released")

        // Text that follows on the link is the node's, not B2F.
        _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                        ns: 1, nr: 0, pf: false, payload: Data("N\r".utf8))
        XCTAssertTrue(received.isEmpty)
        transport.close()
        XCTAssertFalse(sentDISC, "closing a transport that stepped aside sends nothing")
    }

    func testTheRunnerEndsQuietlyWhenTheTransportStepsAside() async throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLiteWinlinkStore(dbQueue: queue)
        let runner = WinlinkSessionRunner(store: store)
        let transport = WinlinkSessionRunnerTests.FakeRMSTransport()
        transport.holdBanner = true
        let exchange = Task { @MainActor in
            await runner.runExchange(transport: transport, myCallsign: "K0EPI-3", password: nil,
                                     gatewayName: "K0EPI-2", transportName: "P2P",
                                     role: .answering, peer: "K0EPI-2")
        }
        while runner.phase != .exchanging { await Task.yield() }

        transport.onStandAside?("K0EPI-2 is using this link for NET/ROM")
        let idle = await runner.waitUntilIdle(timeout: 5)
        guard idle else { return XCTFail("the exchange must end when the answerer steps aside") }
        _ = await exchange.value

        XCTAssertEqual(runner.phase, .idle, "not a failed exchange: there was no Winlink call")
        XCTAssertTrue(try store.sessionLogs(limit: 5).isEmpty, "nothing to log as a Winlink session")
        XCTAssertTrue(runner.transcript.contains { $0.text.contains("NET/ROM") },
                      "the console says why the answerer stood down")
    }
}
