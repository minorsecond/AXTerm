//
//  T1ResendPollsLastTests.swift
//  AXTermTests
//
//  After a T1 expiry A (705) resent every outstanding I-frame with P on the
//  first and the rest a few milliseconds behind it. The iPhone answered the
//  poll with RR F as soon as the first arrived, before the second; its ack
//  for the second was not heard, so T1 ran out again and A went back one
//  frame per round (smoke run 2026-10-03-1, F2, issue 108). The resend now
//  polls on its last frame, as a normal burst does, so the F response
//  accounts for everything resent.
//

import XCTest
@testable import AXTerm

@MainActor
final class T1ResendPollsLastTests: XCTestCase {
    private let me = AX25Address(call: "K0EPI", ssid: 2)
    private let peer = AX25Address(call: "K0EPI", ssid: 3)

    private func pollBit(_ frame: OutboundFrame) -> Bool {
        (frame.controlByte ?? 0) & 0x10 != 0
    }

    func testAResendBurstPollsOnItsLastFrame() throws {
        let manager = AX25SessionManager(localCallsign: me, clock: AX25VirtualClock())
        manager.negotiateV22 = false
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        _ = manager.sendData(Data("one\r".utf8), to: peer, path: DigiPath(), radio: .primary)
        _ = manager.sendData(Data("two\r".utf8), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.outstandingCount, 2)

        let resent = manager.handleT1Timeout(session: session).filter { $0.frameType == "i" }

        XCTAssertEqual(resent.count, 2)
        XCTAssertFalse(pollBit(resent[0]), "the first resent frame does not poll")
        XCTAssertTrue(pollBit(resent[1]), "the last resent frame carries the poll")
        XCTAssertTrue(manager.handleT1Timeout(session: session).filter { $0.frameType == "s" && $0.isCommand == true }.isEmpty,
                      "the resent I-frame is the poll; no separate RR command")
    }
}
