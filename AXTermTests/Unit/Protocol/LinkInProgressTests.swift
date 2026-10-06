//
//  LinkInProgressTests.swift
//  AXTermTests
//
//  A UA or DM from a station we hold a link with belongs to the link, not
//  to a ping probe that happens to be waiting on the same station. The ping
//  prober was asked "is there a session?" with a check that counts only
//  connected links, so a UA answering our SABM (connecting) or our DISC
//  (disconnecting) could be taken as a probe answer and never reach the
//  link, which then went on retrying DISC (smoke run 2026-10-03-1, issue 90,
//  seen in the iPhone simulator at 18:29:39Z).
//

import XCTest
@testable import AXTerm

@MainActor
final class LinkInProgressTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)

    private func manager() -> AX25SessionManager {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 0),
                                         clock: AX25VirtualClock())
        manager.defaultConfig = AX25SessionConfig(initialRto: 3.0)
        return manager
    }

    func testEveryLiveStateCounts() throws {
        let manager = manager()
        XCTAssertFalse(manager.hasLinkInProgress(withPeer: peer))

        _ = try XCTUnwrap(manager.connect(to: peer))
        XCTAssertTrue(manager.hasLinkInProgress(withPeer: peer), "connecting: the UA to our SABM is the link's")

        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertTrue(manager.hasLinkInProgress(withPeer: peer))

        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        _ = try XCTUnwrap(manager.disconnect(session: session))
        XCTAssertEqual(session.state, .disconnecting)
        XCTAssertTrue(manager.hasLinkInProgress(withPeer: peer), "disconnecting: the UA to our DISC is the link's")

        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertFalse(manager.hasLinkInProgress(withPeer: peer), "ended")
    }

    /// A response heard with its C bit set decodes as "repeated"; it is
    /// still the same station.
    func testTheAddressFlagsDoNotMatter() throws {
        let manager = manager()
        _ = try XCTUnwrap(manager.connect(to: peer))
        XCTAssertTrue(manager.hasLinkInProgress(withPeer: AX25Address(call: "K0EPI", ssid: 3, repeated: true)))
    }
}
