//
//  FramesLeaveOnTheSessionsRadioTests.swift
//  AXTermTests
//
//  The main app has two radios: ham-pi (the primary) and the 705. A link to
//  K0EPI-3 over the 705 came up, but every I-frame it sent, and every
//  retransmission, went to the primary radio's transport, which was down:
//  "Send skipped: link is down ... radio=radio-primary", until N2 ended the
//  link. The opening XID did the same. buildIFrame and the XID were built
//  with no radio, so they carried the default. A test-mode station has one
//  radio whose id is the primary, which hid it (smoke run 2026-10-03-1,
//  test 10.4, issue 100).
//

import XCTest
@testable import AXTerm

@MainActor
final class FramesLeaveOnTheSessionsRadioTests: XCTestCase {
    private let me = AX25Address(call: "K0EPI", ssid: 2)
    private let peer = AX25Address(call: "K0EPI", ssid: 3)
    private let radio705 = RadioID(rawValue: "328B00EB-B9E0-4651-B1C8-F883122C8B0D")

    func testTheOpeningXIDLeavesOnTheSessionsRadio() throws {
        let manager = AX25SessionManager(localCallsign: me, clock: AX25VirtualClock())
        manager.negotiateV22 = true
        let opening = try XCTUnwrap(manager.connect(to: peer, path: DigiPath(), radio: radio705))
        XCTAssertEqual(opening.displayInfo, "XID")
        XCTAssertEqual(opening.radio, radio705)
    }

    func testIFramesAndRetransmissionsLeaveOnTheSessionsRadio() throws {
        let manager = AX25SessionManager(localCallsign: me, clock: AX25VirtualClock())
        manager.negotiateV22 = false
        let sabm = try XCTUnwrap(manager.connect(to: peer, path: DigiPath(), radio: radio705))
        XCTAssertEqual(sabm.radio, radio705)
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: radio705)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: radio705))
        XCTAssertEqual(session.state, .connected)

        let data = manager.sendData(Data("smoke 10.4\r".utf8), to: peer, path: DigiPath(), radio: radio705)
        XCTAssertFalse(data.isEmpty)
        for frame in data { XCTAssertEqual(frame.radio, radio705, "I-frame") }

        let resent = manager.handleT1Timeout(session: session)
        XCTAssertFalse(resent.isEmpty)
        for frame in resent { XCTAssertEqual(frame.radio, radio705, "after T1: \(frame.displayInfo ?? "")") }
    }

    /// Data typed before the link is up waits in the pending queue and is
    /// sent when it comes up: the same builder, the same radio.
    func testQueuedDataLeavesOnTheSessionsRadioWhenTheLinkComesUp() throws {
        let manager = AX25SessionManager(localCallsign: me, clock: AX25VirtualClock())
        manager.negotiateV22 = false
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        _ = manager.sendData(Data("early\r".utf8), to: peer, path: DigiPath(), radio: radio705)
        let drained = manager.handleInboundUA(from: peer, path: DigiPath(), radio: radio705)
        let iFrames = (drained + sent).filter { $0.frameType == "i" }
        XCTAssertFalse(iFrames.isEmpty)
        for frame in iFrames { XCTAssertEqual(frame.radio, radio705) }
    }
}
