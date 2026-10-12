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
//  Links are keyed by both addresses since 2026-10-12, so A's SABM to
//  K0EPI-3 is its own link beside the EPINDB one, answered UA from K0EPI-3.
//  Any other frame to one of our addresses on which we hold no link with
//  that peer belongs to a link we do not hold: the disconnected state
//  answers a DISC, or any command with P set, with DM from the address the
//  frame was sent to, and the other link is left alone.
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

    /// The SABM of issue 89 opens its own link now, answered from the
    /// address it was sent to, and the EPINDB link is left alone. It used
    /// to be refused with DM, when a link was keyed by the peer alone.
    func testASABMToTheOtherAddressOpensItsOwnLink() throws {
        let (manager, session) = try nodeLinkUp()
        XCTAssertNil(manager.answerForUnheldLink(from: caller, to: station, path: DigiPath(), radio: .primary,
                                                 kind: .sabm, isCommand: true, pf: true))
        let ua = try XCTUnwrap(manager.handleInboundSABM(from: caller, to: station, path: DigiPath(), radio: .primary))
        XCTAssertEqual(ua.displayInfo, "UA")
        XCTAssertEqual(ua.source.display, "K0EPI-3", "answered from the address the SABM was sent to")
        XCTAssertEqual(session.state, .connected, "the EPINDB link is left alone")
        XCTAssertEqual(manager.existingSession(for: caller, path: DigiPath(), radio: .primary, local: station)?.state,
                       .connected)
    }

    /// With a link on each address, a frame to either is its own link's.
    func testAFrameToAnAddressWithItsOwnLinkIsThatLinks() throws {
        let (manager, _) = try nodeLinkUp()
        _ = manager.handleInboundSABM(from: caller, to: station, path: DigiPath(), radio: .primary)
        XCTAssertNil(manager.answerForUnheldLink(from: caller, to: station, path: DigiPath(), radio: .primary,
                                                 kind: .supervisoryOrInformation, isCommand: true, pf: true))
        XCTAssertNil(manager.answerForUnheldLink(from: caller, to: node, path: DigiPath(), radio: .primary,
                                                 kind: .response, isCommand: false, pf: true))
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
