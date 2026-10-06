//
//  UpperLayerDisconnectOrderTests.swift
//  AXTermTests
//
//  A disconnect the layer above asks for while a received frame is being
//  delivered goes out after that frame's own answer.
//
//  Smoke run 2026-10-03-1, issue 72: A (705) sent FQ as I(6,3) P. B (ID-50)'s
//  Winlink exchange asked for the disconnect the moment FQ was delivered,
//  and B transmitted DISC P and then RR(7) F, answering the poll on a link
//  it had already started to release. In the AX.25 2.2 SDL the enquiry
//  response is part of handling the I-frame, and a DL-DISCONNECT request
//  from layer 3 is a later event, so the order is RR F, then DISC.
//

import XCTest
@testable import AXTerm

@MainActor
final class UpperLayerDisconnectOrderTests: XCTestCase {

    private let local = AX25Address(call: "K0AAA", ssid: 1)
    private let peer = AX25Address(call: "K0BBB", ssid: 2)

    func testADisconnectAskedForDuringADeliveryFollowsThePollAnswer() {
        let manager = AX25SessionManager(localCallsign: local, clock: AX25VirtualClock())
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)

        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        manager.onDataReceived = { [weak manager] session, _ in
            // The layer above hears FQ and ends the link at once.
            if let disc = manager?.disconnect(session: session) { sent.append(disc) }
        }

        if let response = manager.handleInboundIFrame(
            from: peer, path: DigiPath(), radio: .primary,
            ns: 0, nr: 0, pf: true, payload: Data("FQ\r".utf8)) {
            sent.append(response)
        }

        XCTAssertEqual(sent.compactMap(\.displayInfo), ["RR(1)", "DISC"],
                       "the poll is answered before the link is released")
        XCTAssertEqual(session.state, .disconnecting)
    }

    /// Asked for outside a delivery, a disconnect is as before: the DISC
    /// comes back to the caller at once.
    func testADisconnectAskedForOtherwiseIsImmediate() {
        let manager = AX25SessionManager(localCallsign: local, clock: AX25VirtualClock())
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(manager.disconnect(session: session)?.displayInfo, "DISC")
    }
}
