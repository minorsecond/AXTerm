//
//  TerminationTeardownTests.swift
//  AXTermTests
//
//  Quitting the app must not strand peers with zombie sessions. Field capture
//  2026-08-22: quitting mid-session left KB5YZB-7's node retransmitting old
//  session data and T1-polling a link that no longer existed on our side.
//

import XCTest
@testable import AXTerm

@MainActor
final class TerminationTeardownTests: XCTestCase {

    private func makeCoordinator(localCallsign: String) -> SessionCoordinator {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = localCallsign

        let coordinator = SessionCoordinator()
        coordinator.localCallsign = localCallsign
        return coordinator
    }

    func testPrepareForTerminationSendsDISCForLiveSessions() {
        let coordinator = makeCoordinator(localCallsign: "K0EPI-7")
        let manager = coordinator.sessionManager
        let peer = AX25Address(call: "KB5YZB", ssid: 7)
        let idlePeer = AX25Address(call: "N0HI", ssid: 7)

        // One connected session, one still connecting, one already closed.
        let connected = manager.session(for: peer, path: DigiPath(), channel: 0)
        _ = connected.stateMachine.handle(event: .connectRequest)
        _ = connected.stateMachine.handle(event: .receivedUA)
        XCTAssertEqual(connected.state, .connected)

        let connecting = manager.session(for: idlePeer, path: DigiPath(), channel: 0)
        _ = connecting.stateMachine.handle(event: .connectRequest)
        XCTAssertEqual(connecting.state, .connecting)

        let closed = manager.session(for: AX25Address(call: "W0ARP", ssid: 7), path: DigiPath(), channel: 0)
        XCTAssertEqual(closed.state, .disconnected)

        let sent = coordinator.prepareForTermination()

        XCTAssertEqual(sent, 2, "both live sessions get a DISC; the closed one does not")
        XCTAssertEqual(connected.state, .disconnecting,
                       "the peer is told the link is going down, not just abandoned")
        XCTAssertEqual(connecting.state, .disconnecting)
    }

    func testPrepareForTerminationIsQuietWithNoLiveSessions() {
        let coordinator = makeCoordinator(localCallsign: "K0EPI-7")
        XCTAssertEqual(coordinator.prepareForTermination(), 0,
                       "no sessions -> nothing on the air, quit proceeds immediately")
    }
}
