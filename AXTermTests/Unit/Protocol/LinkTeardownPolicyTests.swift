//
//  LinkTeardownPolicyTests.swift
//  AXTermTests
//
//  Regression net for the 2026-08-28 half-open-session trap: a link torn
//  down without a DISC leaves BPQ at the far end holding the session, and
//  the next SABM becomes a reset of it — past the greeting, so the node
//  never sends the banner the prompt relay waits on. These tests pin down
//  both the policy (when a teardown must go on the air) and the transport
//  behaviors the policy leans on (DISC actually emitted, completion on
//  UA/DM, giving up on a dead path, silence for half-open links).
//

import XCTest
@testable import AXTerm

@MainActor
final class LinkTeardownPolicyTests: XCTestCase {

    // MARK: - Policy decisions

    /// Only a connected session provably has far-end state to release.
    func testOnlyConnectedSessionsAreReleasedOnAir() {
        XCTAssertEqual(LinkTeardownPolicy.action(for: .connected), .sendDISC)
        XCTAssertEqual(LinkTeardownPolicy.action(for: .connecting), .dropLocally)
        XCTAssertEqual(LinkTeardownPolicy.action(for: .disconnected), .dropLocally)
        XCTAssertEqual(LinkTeardownPolicy.action(for: .disconnecting), .dropLocally)
        XCTAssertEqual(LinkTeardownPolicy.action(for: .error), .dropLocally)
    }

    // MARK: - The on-air branch, end to end through the session manager

    /// Graceful teardown of a connected session must produce a DISC frame
    /// addressed to the peer and move the session to `.disconnecting` —
    /// not silently wipe local state the way forceDisconnect does.
    func testTeardownOfConnectedSessionPutsDISCOnAir() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "ME", ssid: 7))
        let peer = AX25Address(call: "NODE", ssid: 0)
        let path = DigiPath()

        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(LinkTeardownPolicy.action(for: session.state), .sendDISC)

        let disc = manager.disconnect(session: session)
        XCTAssertNotNil(disc, "connected teardown must transmit")
        XCTAssertEqual(disc?.displayInfo, "DISC")
        XCTAssertEqual(disc?.destination.display, peer.display)
        XCTAssertEqual(session.state, .disconnecting)
    }

    /// The peer's UA completes the release, and the *next* connect gets a
    /// fresh frame — the "next attempt starts clean" guarantee that the
    /// silent teardown broke in the field.
    func testUACompletesTeardownAndFreshConnectFollows() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "ME", ssid: 7))
        let peer = AX25Address(call: "NODE", ssid: 0)
        let path = DigiPath()

        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)
        _ = manager.disconnect(session: session)
        XCTAssertEqual(session.state, .disconnecting)

        manager.handleInboundUA(from: peer, path: path, channel: 0)
        XCTAssertEqual(session.state, .disconnected)

        XCTAssertNotNil(
            manager.connect(to: peer, path: path, channel: 0),
            "a completed teardown must not block the next connect")
    }

    /// A peer that answers the DISC with DM (already forgot the session)
    /// also completes the release — either answer ends it, per §6.3.4.
    func testDMAlsoCompletesTeardown() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        _ = sm.handle(event: .disconnectRequest)
        XCTAssertEqual(sm.state, .disconnecting)

        let actions = sm.handle(event: .receivedDM)
        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertTrue(actions.contains(.stopT1))
        XCTAssertTrue(actions.contains(.notifyDisconnected))
    }

    /// On a path that died mid-session the DISC is retried on T1 and then
    /// abandoned — the release must never wedge a session in
    /// `.disconnecting` forever, or the next connect stays blocked.
    func testDISCRetriesOnT1ThenGivesUp() {
        let config = AX25SessionConfig(maxRetries: 3)
        var sm = AX25StateMachine(config: config)
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        _ = sm.handle(event: .disconnectRequest)
        XCTAssertEqual(sm.state, .disconnecting)

        for attempt in 1...config.maxRetries {
            let actions = sm.handle(event: .t1Timeout)
            XCTAssertEqual(sm.state, .disconnecting, "retry \(attempt) keeps releasing")
            XCTAssertTrue(actions.contains(.sendDISC), "retry \(attempt) retransmits DISC")
        }

        let final = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.state, .disconnected, "retries exhausted — stop keying the transmitter")
        XCTAssertTrue(final.contains(.stopT1))
        XCTAssertFalse(final.contains(.sendDISC))
    }

    // MARK: - The local-only branch

    /// A half-open link (SABM sent, no UA) has nothing on the far side to
    /// release; teardown must transmit nothing at all, or a dead path gets
    /// minutes of DISC retries against silence.
    func testTeardownOfHalfOpenSessionTransmitsNothing() {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "ME", ssid: 7))
        let peer = AX25Address(call: "NODE", ssid: 0)
        let path = DigiPath()

        _ = manager.connect(to: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertEqual(LinkTeardownPolicy.action(for: session.state), .dropLocally)

        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        let actions = sm.handle(event: .forceDisconnect)
        XCTAssertEqual(sm.state, .disconnected)
        XCTAssertFalse(actions.contains(.sendDISC), "half-open teardown stays off the air")
        XCTAssertFalse(actions.contains(.sendDM))

        manager.forceDisconnect(session: session)
        XCTAssertEqual(session.state, .disconnected)
    }
}
