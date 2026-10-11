import XCTest
@testable import AXTerm

/// The AXDP probe goes only where it can be answered (retest 2026-10-10,
/// finding 6). About one station in a thousand runs AXTerm, and every
/// connected station used to get the text probe and two retries, with the
/// "no AXDP" verdict forgotten at each launch.
final class AXDPProbePolicyTests: XCTestCase {

    func testAGreetingThatSaysAXTermIsProbed() {
        XCTAssertTrue(AXDPProbePolicy.probesAfterFirstData(Data("AXTerm personal mailbox - K0EPI-4\r".utf8),
                                                           remembered: nil))
        XCTAssertFalse(AXDPProbePolicy.probesAfterFirstData(Data("[BPQ-6.0.24.1]\rEPINOD:K0EPI-7} \r".utf8),
                                                            remembered: nil))
    }

    func testWhatIsRememberedDecides() {
        let bpq = Data("Welcome to the node\r".utf8)
        XCTAssertTrue(AXDPProbePolicy.probesAfterFirstData(bpq, remembered: .axterm))
        XCTAssertFalse(AXDPProbePolicy.probesAfterFirstData(Data("AXTerm\r".utf8), remembered: .notAXDP),
                       "no answer last time: not again for a day")
    }

    /// The fallback timer, for a station that sends nothing: only one known
    /// to run AXTerm.
    func testTheFallbackOnlyProbesAKnownAXTermStation() {
        XCTAssertTrue(AXDPProbePolicy.probesWithoutData(remembered: .axterm))
        XCTAssertFalse(AXDPProbePolicy.probesWithoutData(remembered: nil))
        XCTAssertFalse(AXDPProbePolicy.probesWithoutData(remembered: .notAXDP))
    }

    func testOneProbeNoRetries() {
        XCTAssertEqual(AXDPCapabilityProbe.maxAttempts, 1)
    }

    // MARK: Memory across launches

    func testTheMemoryOutlivesALaunch() {
        let defaults = TestDefaults.make("AXDPPeerMemory")
        let now = Date(timeIntervalSince1970: 1_791_700_000)
        AXDPPeerMemory(defaults: defaults).record(.axterm, for: "k0epi-4", at: now)
        AXDPPeerMemory(defaults: defaults).record(.notAXDP, for: "N0NODE-7", at: now)

        let later = AXDPPeerMemory(defaults: defaults)
        XCTAssertEqual(later.verdict(for: "K0EPI-4", now: now.addingTimeInterval(3600)), .axterm)
        XCTAssertEqual(later.verdict(for: "N0NODE-7", now: now.addingTimeInterval(3600)), .notAXDP)
    }

    /// "No AXDP" lasts a day: a station's software can change. "AXTerm"
    /// lasts a month.
    func testVerdictsExpire() {
        let memory = AXDPPeerMemory(defaults: TestDefaults.make("AXDPPeerMemoryExpiry"))
        let now = Date(timeIntervalSince1970: 1_791_700_000)
        memory.record(.notAXDP, for: "N0NODE-7", at: now)
        memory.record(.axterm, for: "K0EPI-4", at: now)
        XCTAssertNil(memory.verdict(for: "N0NODE-7", now: now.addingTimeInterval(86_400 + 1)))
        XCTAssertEqual(memory.verdict(for: "K0EPI-4", now: now.addingTimeInterval(20 * 86_400)), .axterm)
        XCTAssertNil(memory.verdict(for: "K0EPI-4", now: now.addingTimeInterval(31 * 86_400)))
    }
}

/// End to end in the coordinator.
@MainActor
final class AXDPProbeTargetingTests: XCTestCase {

    private func connectedAsCaller(to peer: AX25Address, coordinator: SessionCoordinator) -> AX25Session {
        coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
        coordinator.sessionManager.localCallsign = AX25Address(call: "K0EPI", ssid: 3)
        let session = coordinator.sessionManager.session(for: peer)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        coordinator.sessionManager.onSessionStateChanged?(session, .connecting, .connected)
        return session
    }

    func testANodeThatIsNotAXTermIsNeverProbed() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        var probes = 0
        coordinator.onFrameHandedToRadio = { if $0.displayInfo == "AXDP probe" { probes += 1 } }
        let peer = AX25Address(call: "N0NODE", ssid: 7)
        let session = connectedAsCaller(to: peer, coordinator: coordinator)
        coordinator.sessionManager.onDataDeliveredForReassembly?(session, Data("[BPQ-6.0.24.1]\r".utf8))
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .unknown)
    }

    func testAnAXTermMailboxIsProbedOnceAndForgottenWhenSilent() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.peerMemory = AXDPPeerMemory(defaults: TestDefaults.make("AXDPProbeTargeting"))
        var probes = 0
        coordinator.onFrameHandedToRadio = { if $0.displayInfo == "AXDP probe" { probes += 1 } }
        let peer = AX25Address(call: "K0EPI", ssid: 4)
        let session = connectedAsCaller(to: peer, coordinator: coordinator)
        coordinator.sessionManager.onDataDeliveredForReassembly?(session,
                                                                 Data("AXTerm personal mailbox - K0EPI-4\r".utf8))
        XCTAssertEqual(probes, 1)

        coordinator.runCapabilityProbeTimers(now: Date().addingTimeInterval(120))
        XCTAssertEqual(probes, 1, "no retry")
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .notSupported)
        XCTAssertEqual(coordinator.peerMemory.verdict(for: peer.display), .notAXDP, "remembered across launches")
    }

    /// AXDP heard from a station marks it as AXTerm for next time.
    func testAXDPHeardIsRemembered() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.peerMemory = AXDPPeerMemory(defaults: TestDefaults.make("AXDPProbeRemember"))
        coordinator.markImplicitlyConfirmedAXDP(for: "K0EPI-3")
        XCTAssertEqual(coordinator.peerMemory.verdict(for: "K0EPI-3"), .axterm)
    }
}
