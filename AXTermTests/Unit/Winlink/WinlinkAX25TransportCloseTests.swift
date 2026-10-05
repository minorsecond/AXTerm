//
//  WinlinkAX25TransportCloseTests.swift
//  AXTermTests
//
//  A B2F exchange ends with FQ and a disconnect. A disconnect discards the
//  I-frame queue (AX.25 2.2, Figure C4.4, DL-DISCONNECT request), so the
//  transport must let what it sent be acknowledged before it asks for one.
//  Smoke run 2026-10-03-1, issue 32(e): the FQ was cleared by the DISC
//  that followed it and never retransmitted.
//

import XCTest
@testable import AXTerm

@MainActor
final class WinlinkAX25TransportCloseTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)
    private var sent: [OutboundFrame] = []

    private func makeConnected() async throws -> (AX25SessionManager, AX25Session, WinlinkAX25Transport) {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 2))
        _ = manager.handleInboundSABM(from: peer, to: manager.localCallsign, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer))
        XCTAssertEqual(session.state, .connected)
        let transport = WinlinkAX25Transport(
            sessionManager: manager,
            sendFrames: { [unowned self] in self.sent.append(contentsOf: $0) },
            destination: peer)
        try await transport.open()
        return (manager, session, transport)
    }

    private var sentDISC: Bool {
        sent.contains { ($0.controlByte ?? 0) & ~0x10 == 0x43 }
    }

    func testCloseWaitsUntilWhatWasSentIsAcknowledged() async throws {
        let (manager, session, transport) = try await makeConnected()
        transport.send(Data("FQ\r".utf8))
        XCTAssertFalse(session.sendBuffer.isEmpty, "the FQ is out and unacknowledged")
        sent.removeAll()

        transport.close()
        XCTAssertFalse(sentDISC, "no DISC while the FQ is unacknowledged")
        XCTAssertEqual(session.state, .connected)

        sent.append(contentsOf: manager.handleInboundRRFrames(
            from: peer, path: DigiPath(), radio: .primary, nr: 1))
        XCTAssertTrue(sentDISC, "the DISC follows the ack")
        XCTAssertEqual(session.state, .disconnecting)
    }

    func testCloseWithNothingOutstandingDisconnectsAtOnce() async throws {
        let (_, session, transport) = try await makeConnected()
        transport.close()
        XCTAssertTrue(sentDISC)
        XCTAssertEqual(session.state, .disconnecting)
    }

    func testASecondCloseDisconnectsWithoutWaiting() async throws {
        let (_, session, transport) = try await makeConnected()
        transport.send(Data("FQ\r".utf8))
        sent.removeAll()
        transport.close()
        XCTAssertFalse(sentDISC)
        transport.close()
        XCTAssertTrue(sentDISC, "asked twice: the operator wants the link down now")
        XCTAssertEqual(session.state, .disconnecting)
    }

    func testThePeerDisconnectingWhileWeWaitEndsTheTransport() async throws {
        let (manager, _, transport) = try await makeConnected()
        var closedWith: String?? = .none
        transport.onClose = { closedWith = .some($0) }
        transport.send(Data("FQ\r".utf8))
        transport.close()
        _ = manager.handleInboundDISC(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(closedWith, .some(nil), "the peer's DISC is a clean end")
    }
}
