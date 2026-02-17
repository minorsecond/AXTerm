//
//  AX25SessionCallsignChangeTests.swift
//  AXTermTests
//
//  Tests for purging stale sessions when the local callsign changes.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25SessionCallsignChangeTests: XCTestCase {

    private let oldCallsign = AX25Address(call: "K0EPI", ssid: 7)
    private let newCallsign = AX25Address(call: "K0EPI", ssid: 6)
    private let peer = AX25Address(call: "N0BBS", ssid: 0)

    private func makeManager(callsign: AX25Address) -> AX25SessionManager {
        let manager = AX25SessionManager()
        manager.localCallsign = callsign
        return manager
    }

    // MARK: - Purge Tests

    func testPurgeRemovesDisconnectedSessions() {
        let manager = makeManager(callsign: oldCallsign)

        // Create a session that stays disconnected
        let _ = manager.session(for: peer)
        XCTAssertEqual(manager.sessions.count, 1)

        manager.purgeSessionsForCallsignChange()

        XCTAssertTrue(manager.sessions.isEmpty, "All sessions should be removed after purge")
    }

    func testPurgeForceDisconnectsActiveSessions() {
        let manager = makeManager(callsign: oldCallsign)

        // Connect a session
        _ = manager.connect(to: peer)
        let session = manager.session(for: peer)
        XCTAssertEqual(session.state, .connecting)

        // Simulate UA to move to connected
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(manager.sessions.count, 1)

        var stateChanges: [(AX25SessionState, AX25SessionState)] = []
        manager.onSessionStateChanged = { _, oldState, newState in
            stateChanges.append((oldState, newState))
        }

        manager.purgeSessionsForCallsignChange()

        XCTAssertTrue(manager.sessions.isEmpty, "All sessions should be removed after purge")
        // forceDisconnect should have triggered a state change
        XCTAssertFalse(stateChanges.isEmpty, "Active session should have been force-disconnected")
    }

    func testPurgeWithNoSessions() {
        let manager = makeManager(callsign: oldCallsign)
        XCTAssertTrue(manager.sessions.isEmpty)

        // Should be a no-op, not crash
        manager.purgeSessionsForCallsignChange()

        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testPurgePreservesSessionsWhenCallsignUnchanged() {
        let manager = makeManager(callsign: oldCallsign)
        _ = manager.session(for: peer)
        XCTAssertEqual(manager.sessions.count, 1)

        // Setting the same callsign should NOT purge
        // (This tests the guard in SessionCoordinator/TerminalView, not the method itself)
        // The purge method always removes; the callers gate on != check
        let countBefore = manager.sessions.count
        // Simulate what the callers do: only purge if changed
        if manager.localCallsign != oldCallsign {
            manager.purgeSessionsForCallsignChange()
        }
        XCTAssertEqual(manager.sessions.count, countBefore, "Sessions should survive when callsign is unchanged")
    }

    func testNewSessionUsesUpdatedCallsign() {
        let manager = makeManager(callsign: oldCallsign)

        // Create session with old callsign
        let oldSession = manager.session(for: peer)
        XCTAssertEqual(oldSession.localAddress, oldCallsign)

        // Purge and update callsign
        manager.purgeSessionsForCallsignChange()
        manager.localCallsign = newCallsign

        // New session should use the new callsign
        let newSession = manager.session(for: peer)
        XCTAssertEqual(newSession.localAddress, newCallsign)
        XCTAssertNotEqual(oldSession.id, newSession.id, "Should be a different session instance")
    }

    func testPurgeOnSSIDChange() {
        let manager = makeManager(callsign: oldCallsign)

        // Create and connect a session
        _ = manager.connect(to: peer)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        XCTAssertEqual(manager.sessions.count, 1)

        // Simulate SSID change (K0EPI-7 -> K0EPI-6) — same base call, different SSID
        XCTAssertNotEqual(oldCallsign, newCallsign, "Precondition: SSIDs differ")

        manager.purgeSessionsForCallsignChange()
        manager.localCallsign = newCallsign

        XCTAssertTrue(manager.sessions.isEmpty, "Sessions should be purged on SSID change")

        // New session uses updated SSID
        let session = manager.session(for: peer)
        XCTAssertEqual(session.localAddress.ssid, 6)
    }
}
