//
//  OneLinkPerAddressPairTests.swift
//  AXTermTests
//
//  AX.25 identifies a link by both addresses. B (ID-50) answers as K0EPI-3
//  and, for its node, as EPINDB. Sessions are keyed by the remote station,
//  so with a link up K0EPI-2 <-> EPINDB, A's SABM to K0EPI-3 landed on that
//  link and B answered UA from EPINDB. A took it as an unexpected UA on its
//  EPINDB link and re-established it, and every retry did it again (smoke
//  run 2026-10-03-1, issue 89).
//
//  A frame to one of our addresses that is not the one our link with that
//  peer uses belongs to a link we do not hold: the disconnected state
//  answers a SABM, a DISC, or any command with P set with DM, from the
//  address the frame was sent to, and the other link is left alone.
//

import XCTest
@testable import AXTerm

@MainActor
final class OneLinkPerAddressPairTests: XCTestCase {

    private let caller = AX25Address(call: "K0EPI", ssid: 2)
    private let station = AX25Address(call: "K0EPI", ssid: 3)
    private let node = AX25Address(call: "EPINDB", ssid: 0)

    private func nodeLinkUp() throws -> (AX25SessionManager, AX25Session) {
        let manager = AX25SessionManager(localCallsign: station, clock: AX25VirtualClock())
        manager.setServiceAddress(node, for: "netromNodeL2")
        let ua = try XCTUnwrap(manager.handleInboundSABM(from: caller, to: node, path: DigiPath(), radio: .primary))
        XCTAssertEqual(ua.source.display, "EPINDB")
        let session = try XCTUnwrap(manager.existingSession(for: caller, path: DigiPath(), radio: .primary))
        XCTAssertEqual(session.state, .connected)
        return (manager, session)
    }

    func testFramesToTheLinksOwnAddressAreItsOwn() throws {
        let (manager, _) = try nodeLinkUp()
        XCTAssertNil(manager.answerForUnheldLink(from: caller, to: node, path: DigiPath(), radio: .primary,
                                                 kind: .sabm, isCommand: true, pf: true))
    }

    func testASABMToTheOtherAddressIsRefusedFromThatAddress() throws {
        let (manager, session) = try nodeLinkUp()
        let answer = try XCTUnwrap(manager.answerForUnheldLink(
            from: caller, to: station, path: DigiPath(), radio: .primary,
            kind: .sabm, isCommand: true, pf: true))
        let dm = try XCTUnwrap(answer.response)
        XCTAssertEqual(dm.source.display, "K0EPI-3", "answered from the address the SABM was sent to")
        XCTAssertEqual(dm.destination.display, "K0EPI-2")
        XCTAssertEqual(dm.displayInfo, "DM")
        XCTAssertEqual(session.state, .connected, "the EPINDB link is left alone")
    }

    func testACommandWithThePollBitIsAnsweredDMAndOneWithoutIsIgnored() throws {
        let (manager, _) = try nodeLinkUp()
        let polled = try XCTUnwrap(manager.answerForUnheldLink(
            from: caller, to: station, path: DigiPath(), radio: .primary,
            kind: .supervisoryOrInformation, isCommand: true, pf: true))
        XCTAssertEqual(polled.response?.displayInfo, "DM")
        let quiet = try XCTUnwrap(manager.answerForUnheldLink(
            from: caller, to: station, path: DigiPath(), radio: .primary,
            kind: .supervisoryOrInformation, isCommand: true, pf: false))
        XCTAssertNil(quiet.response, "taken, so the other link never sees it, and not answered")
        let response = try XCTUnwrap(manager.answerForUnheldLink(
            from: caller, to: station, path: DigiPath(), radio: .primary,
            kind: .response, isCommand: false, pf: true))
        XCTAssertNil(response.response, "a response is never answered")
    }

    func testWithNoLinkToThatPeerNothingIsIntercepted() {
        let manager = AX25SessionManager(localCallsign: station, clock: AX25VirtualClock())
        manager.setServiceAddress(node, for: "netromNodeL2")
        XCTAssertNil(manager.answerForUnheldLink(from: caller, to: station, path: DigiPath(), radio: .primary,
                                                 kind: .sabm, isCommand: true, pf: true))
    }
}
