//
//  SessionCoordinatorIdentityWiringTests.swift
//  AXTermTests
//
//  Regression cover for the 2026-08-25 iOS field failure: the iOS shell built
//  a SessionCoordinator but never handed it the station identity, so connects
//  went out as `src=NOCALL`. W0ARP-10 answered `UA F=1` — the gateway had the
//  link up — but the frames were addressed to a callsign the operator does not
//  hold, and the session sat in `connecting` until N2 exhausted.
//
//  These tests pin the identity half of the wiring. The transport half
//  (`subscribeToPackets`) needs a live PacketEngine and is covered by the
//  transmission integration tests.
//

import XCTest
@testable import AXTerm

@MainActor
final class SessionCoordinatorIdentityWiringTests: XCTestCase {

    /// The unconfigured default. Named here so the test fails loudly if the
    /// placeholder ever changes without this cover being revisited.
    private let placeholder = AX25Address(call: "NOCALL", ssid: 0)

    // MARK: - The failure being pinned

    func testFreshCoordinatorTransmitsAsPlaceholderUntilConfigured() {
        let coordinator = SessionCoordinator()

        // This is the bug's precondition, asserted rather than assumed: a
        // coordinator nobody configured will identify as NOCALL on the air.
        XCTAssertEqual(coordinator.sessionManager.localCallsign, placeholder,
                       "A coordinator that was never given a callsign must be detectably unconfigured")
    }

    func testApplyingCallsignReachesTheSessionManager() {
        let coordinator = SessionCoordinator()

        coordinator.applyLocalCallsign("K0EPI-7")

        // The session manager is what stamps the source address onto outbound
        // frames, so this — not the published string — is the property that
        // decides what goes on the air.
        XCTAssertEqual(coordinator.sessionManager.localCallsign,
                       AX25Address(call: "K0EPI", ssid: 7))
    }

    // MARK: - SSID and normalisation

    func testCallsignWithoutSSIDLandsAsSSIDZero() {
        let coordinator = SessionCoordinator()

        coordinator.applyLocalCallsign("K0EPI")

        XCTAssertEqual(coordinator.sessionManager.localCallsign,
                       AX25Address(call: "K0EPI", ssid: 0))
    }

    func testLowercaseCallsignIsUppercasedForTheAir() {
        let coordinator = SessionCoordinator()

        coordinator.applyLocalCallsign("k0epi-9")

        // AX.25 addresses are shifted ASCII uppercase; a lowercase settings
        // value must not reach the encoder as-is.
        XCTAssertEqual(coordinator.sessionManager.localCallsign,
                       AX25Address(call: "K0EPI", ssid: 9))
    }

    func testEmptyCallsignFallsBackToThePlaceholderRatherThanAnEmptyAddress() {
        let coordinator = SessionCoordinator()
        coordinator.applyLocalCallsign("K0EPI-7")

        coordinator.applyLocalCallsign("")

        // An empty address would encode as spaces and be undiagnosable on a
        // capture; the placeholder is at least recognisable as unconfigured.
        XCTAssertEqual(coordinator.sessionManager.localCallsign, placeholder)
    }

    // MARK: - Repeated view initialisation

    func testReapplyingTheSameCallsignIsANoOp() {
        let coordinator = SessionCoordinator()
        coordinator.applyLocalCallsign("K0EPI-7")
        let peer = AX25Address(call: "W0ARP", ssid: 10)
        _ = coordinator.sessionManager.session(for: peer)
        XCTAssertEqual(coordinator.sessionManager.sessions.count, 1)

        // The iOS root view re-inits freely. An assignment on every pass would
        // republish inside a view update, and — because a callsign change
        // purges sessions — would silently drop a live link.
        coordinator.applyLocalCallsign("K0EPI-7")

        XCTAssertEqual(coordinator.sessionManager.sessions.count, 1,
                       "Re-applying an unchanged callsign must not purge live sessions")
    }

    func testChangingTheCallsignStillPurgesSessions() {
        let coordinator = SessionCoordinator()
        coordinator.applyLocalCallsign("K0EPI-7")
        _ = coordinator.sessionManager.session(for: AX25Address(call: "W0ARP", ssid: 10))
        XCTAssertEqual(coordinator.sessionManager.sessions.count, 1)

        coordinator.applyLocalCallsign("K0EPI-9")

        // The guard above must not have cost us the purge: sessions opened
        // under the old identity are not addressable under the new one.
        XCTAssertTrue(coordinator.sessionManager.sessions.isEmpty,
                      "A real callsign change must still purge sessions bound to the old identity")
    }
}
