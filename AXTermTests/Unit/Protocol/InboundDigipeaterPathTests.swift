//
//  InboundDigipeaterPathTests.swift
//  AXTermTests
//
//  A frame that reached us through digipeaters is answered through the
//  same digipeaters in reverse order. A station calling via D2,D1 sits
//  beside D2; our answer has to go to D1 first, then D2. Linux does this in
//  ax25_digi_invert (net/ax25/ax25_addr.c) for every inbound link, and the
//  TNC-2 family answers the same way.
//
//  Until 2026-10-01 the coordinator handed the session layer the path in
//  the order it was heard, and the session answered along it unchanged.
//  With one digipeater the two orders are the same, so it never showed;
//  with two the UA, every RR and every I-frame went to the wrong
//  digipeater first and the caller never heard us.
//

import XCTest
@testable import AXTerm

@MainActor
final class InboundDigipeaterPathTests: XCTestCase {

    private let peer = AX25Address(call: "W1PEER", ssid: 0)
    private let local = AX25Address(call: "N0AXT", ssid: 1)

    private func repeated(_ calls: [String]) -> [AX25Address] {
        calls.map { AX25Address(call: $0, repeated: true) }
    }

    func testTheReplyPathIsTheHeardPathReversedWithTheHBitsCleared() {
        let path = DigiPath.replyPath(heardVia: repeated(["DIGI2", "DIGI1"]))
        XCTAssertEqual(path.display, "DIGI1,DIGI2")
        XCTAssertTrue(path.digis.allSatisfy { !$0.repeated }, "our frame has not been repeated yet")
        XCTAssertTrue(DigiPath.replyPath(heardVia: []).isEmpty)
    }

    /// The peer calls via DIGI2,DIGI1. The session it opens must answer via
    /// DIGI1,DIGI2, and every reply the session builds uses that path.
    func testAnInboundCallThroughTwoDigipeatersIsAnsweredInReverse() throws {
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "N0AXT-1"
        let sabm = Packet(from: peer, to: local, via: repeated(["DIGI2", "DIGI1"]),
                          frameType: .u, control: 0x3F)
        coordinator.handleIncomingPacket(sabm)

        let session = try XCTUnwrap(coordinator.sessionManager.connectedSession(withPeer: peer, radio: .primary))
        XCTAssertEqual(session.path.display, "DIGI1,DIGI2")
    }

    /// Our own call via DIGI1,DIGI2 is answered via DIGI2,DIGI1. Those
    /// answers belong to the session we opened, found by its own path.
    func testAnswersToOurCallMatchTheSessionPathExactly() throws {
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "N0AXT-1"
        let path = DigiPath.from(["DIGI1", "DIGI2"])
        _ = coordinator.sessionManager.connect(to: peer, path: path)

        let ua = Packet(from: peer, to: local, via: repeated(["DIGI2", "DIGI1"]),
                        frameType: .u, control: 0x73)
        coordinator.handleIncomingPacket(ua)

        let session = try XCTUnwrap(coordinator.sessionManager.existingSession(for: peer, path: path))
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(coordinator.sessionManager.sessions.count, 1, "no second session for the reversed path")
    }

    /// Smoke run 2026-10-03-1, issue 56: W0ARP-7 is heard directly as well as
    /// through DRLNOD, so each of its frames arrives twice, first with DRLNOD
    /// not yet repeated. A frame is ours only once every digipeater has
    /// repeated it; the first copy belongs to DRLNOD and must change nothing.
    func testTheUnrepeatedCopyOfACallIsIgnored() {
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "N0AXT-1"
        let inTransit = Packet(from: peer, to: local, via: [AX25Address(call: "DRLNOD", repeated: false)],
                               frameType: .u, control: 0x3F)
        coordinator.handleIncomingPacket(inTransit)
        XCTAssertTrue(coordinator.sessionManager.sessions.isEmpty, "the digipeater has not repeated it yet")

        coordinator.handleIncomingPacket(Packet(from: peer, to: local, via: repeated(["DRLNOD"]),
                                                frameType: .u, control: 0x3F))
        XCTAssertNotNil(coordinator.sessionManager.connectedSession(withPeer: peer, radio: .primary))
    }

    func testTheUnrepeatedCopyOfAnAnswerIsIgnored() throws {
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "N0AXT-1"
        let path = DigiPath.from(["DRLNOD"])
        _ = coordinator.sessionManager.connect(to: peer, path: path)
        let session = try XCTUnwrap(coordinator.sessionManager.existingSession(for: peer, path: path))

        coordinator.handleIncomingPacket(Packet(from: peer, to: local,
                                                via: [AX25Address(call: "DRLNOD", repeated: false)],
                                                frameType: .u, control: 0x73))
        XCTAssertEqual(session.state, .connecting, "the UA is still with DRLNOD")

        coordinator.handleIncomingPacket(Packet(from: peer, to: local, via: repeated(["DRLNOD"]),
                                                frameType: .u, control: 0x73))
        XCTAssertEqual(session.state, .connected)
    }
}
