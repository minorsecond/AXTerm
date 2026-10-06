//
//  FreshLinkTests.swift
//  AXTermTests
//
//  A call that needs a fresh link gets one, or is told plainly why not.
//
//  AX.25 2.2 allows one link per pair of addresses, and a peer-to-peer
//  Winlink exchange (like a gateway's, or a node's banner) starts when the
//  link comes up: the called station speaks first. Smoke run 2026-10-03-1,
//  issue 80: after a NET/ROM circuit to K0EPI-3 closed, its AX.25 link stayed
//  up; A's Winlink call reused it and waited at "Signing in" for a greeting
//  that only a new link gets, and a terminal connect failed with "Unable to
//  build SABM frame". A leftover NET/ROM link with nothing riding it is now
//  released (DISC, UA) so the call can open a new one. A link carrying a
//  circuit, or a session someone is using, is left alone and the caller is
//  told why.
//

import XCTest
@testable import AXTerm

@MainActor
final class FreshLinkTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)

    /// A coordinator with a link the peer opened, optionally one that has
    /// carried a NET/ROM datagram.
    private func linked(carryingNetRom: Bool) -> (SessionCoordinator, AX25Session) {
        let coordinator = SessionCoordinator()
        let manager = coordinator.sessionManager
        _ = manager.handleInboundSABM(from: peer, to: manager.localCallsign, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
        if carryingNetRom {
            _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary, ns: 0, nr: 0,
                                            pf: false, payload: Data(repeating: 0, count: 20), pid: NetRomWire.pid)
            XCTAssertTrue(session.carriesNetRom)
        }
        return (coordinator, session)
    }

    func testNoLinkMeansGoAhead() async {
        let coordinator = SessionCoordinator()
        let outcome = await coordinator.makeWayForFreshLink(to: peer, radio: .primary, circuitsRiding: { _ in false })
        XCTAssertEqual(outcome, .clear)
    }

    func testAnIdleNetRomLinkIsReleasedForAFreshConnect() async {
        let (coordinator, session) = linked(carryingNetRom: true)
        let manager = coordinator.sessionManager
        // The peer answers the DISC with UA.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = manager.handleInboundUA(from: self.peer, path: DigiPath(), radio: .primary)
        }

        let outcome = await coordinator.makeWayForFreshLink(to: peer, radio: .primary, circuitsRiding: { _ in false })

        XCTAssertEqual(outcome, .released)
        XCTAssertTrue(session.state == .disconnected || session.state == .error, "\(session.state)")
    }

    func testALinkCarryingACircuitIsLeftUp() async {
        let (coordinator, session) = linked(carryingNetRom: true)

        let outcome = await coordinator.makeWayForFreshLink(to: peer, radio: .primary, circuitsRiding: { _ in true })

        guard case .carriesCircuit(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("K0EPI-3") && reason.contains("circuit"), reason)
        XCTAssertEqual(session.state, .connected)
    }

    /// A link that never carried NET/ROM is someone's session (a terminal
    /// conversation, a caller's session) and is not taken away.
    func testAnOrdinarySessionIsReportedInUse() async {
        let (coordinator, session) = linked(carryingNetRom: false)

        let outcome = await coordinator.makeWayForFreshLink(to: peer, radio: .primary, circuitsRiding: { _ in false })

        guard case .inUse(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("K0EPI-3"), reason)
        XCTAssertEqual(session.state, .connected)
    }

    // MARK: - The Winlink transport

    func testACallingTransportDoesNotReuseALinkItCannotReplace() async throws {
        let (coordinator, session) = linked(carryingNetRom: false)
        let transport = WinlinkAX25Transport(
            sessionManager: coordinator.sessionManager, sendFrames: { _ in }, destination: peer,
            makeWayForFreshLink: { "A session with K0EPI-3 is already open." })

        do {
            try await transport.open()
            XCTFail("the call reused a link whose greeting was long gone")
        } catch WinlinkTransportError.sessionBusy(let reason) {
            XCTAssertEqual(reason, "A session with K0EPI-3 is already open.")
        }
        XCTAssertEqual(session.state, .connected)
        XCTAssertFalse(coordinator.sessionManager.hasDeliveryClaim(for: session.key))
    }

    /// The whole call: the leftover link is released, a new one opened, and
    /// the station's greeting on it reaches the exchange. On the air the
    /// release dropped the exchange's claim on the link along with the old
    /// session, so the greeting went to the terminal and the call sat at
    /// "Signing in" (issue 80 retest, 14:06Z).
    func testTheGreetingOnTheFreshLinkReachesTheExchange() async throws {
        let (coordinator, session) = linked(carryingNetRom: true)
        let manager = coordinator.sessionManager
        let transport = WinlinkAX25Transport(
            sessionManager: manager, sendFrames: { _ in }, destination: peer, connectTimeout: 5,
            makeWayForFreshLink: {
                await coordinator.makeWayForFreshLink(to: self.peer, circuitsRiding: { _ in false }).refusal
            })
        var received = Data()
        transport.onReceive = { received.append($0) }
        // The peer answers our DISC, then our SABM.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = manager.handleInboundUA(from: self.peer, path: DigiPath(), radio: .primary)
            try? await Task.sleep(nanoseconds: 600_000_000)
            _ = manager.handleInboundUA(from: self.peer, path: DigiPath(), radio: .primary)
        }

        try await transport.open()
        let fresh = try XCTUnwrap(manager.connectedSession(withPeer: peer))
        XCTAssertNotIdentical(fresh, session, "a new link, not the leftover one")

        _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary, ns: 0, nr: 0,
                                        pf: false, payload: Data("[AXTerm-1.0-B2FHM$]\r".utf8))
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "[AXTerm-1.0-B2FHM$]\r",
                       "the greeting went somewhere other than the exchange")
    }

    /// The answering side runs on the link the caller just opened.
    func testAnAnsweringTransportUsesTheCallersLink() async throws {
        let (coordinator, session) = linked(carryingNetRom: false)
        let transport = WinlinkAX25Transport(
            sessionManager: coordinator.sessionManager, sendFrames: { _ in }, destination: peer,
            answering: true)

        try await transport.open()

        XCTAssertEqual(session.state, .connected)
        XCTAssertTrue(coordinator.sessionManager.hasDeliveryClaim(for: session.key))
    }
}
