import XCTest
@testable import AXTerm

/// How AXTerm finds out whether a connected station runs AXTerm.
///
/// Retest 2026-10-10, finding 6: about one station in a thousand runs
/// AXTerm, so the check must cost next to nothing. Constitution retest
/// 2026-10-11, findings 1 and 5: every station is checked once and the
/// answer kept, and a station that shows an AXTerm sign is asked inside the
/// connection, where AX.25 resends a lost frame. The iPad's one UI probe to
/// K0EPI-4 was answered, the answer collided with the iPad's own RR, and
/// the iPad marked the mailbox "not AXDP" for a day.
final class AXDPProbePolicyTests: XCTestCase {

    func testAStationThatSaysAXTermIsAskedInsideTheConnection() {
        XCTAssertEqual(AXDPProbePolicy.check(afterData: Data("AXTerm personal mailbox - K0EPI-4\r".utf8),
                                             remembered: nil), .inSession)
    }

    func testAStationRememberedAsAXTermIsAskedInsideTheConnection() {
        XCTAssertEqual(AXDPProbePolicy.check(afterData: Data("Welcome\r".utf8), remembered: .axterm), .inSession)
        XCTAssertEqual(AXDPProbePolicy.check(afterData: nil, remembered: .axterm), .inSession)
    }

    /// One lost reply must not hide an AXTerm station: what it says now
    /// outranks a "no" kept from before.
    func testASignOutranksARememberedNo() {
        XCTAssertEqual(AXDPProbePolicy.check(afterData: Data("AXTerm personal mailbox\r".utf8),
                                             remembered: .notAXDP), .inSession)
    }

    /// Everyone else gets one six-byte UI probe, which only AXTerm reads.
    func testAStationWithNoSignGetsOneProbe() {
        XCTAssertEqual(AXDPProbePolicy.check(afterData: Data("[BPQ-6.0.24.1]\rEPINOD:K0EPI-7} \r".utf8),
                                             remembered: nil), .probe)
        XCTAssertEqual(AXDPProbePolicy.check(afterData: nil, remembered: nil), .probe, "a caller that says nothing")
    }

    func testARememberedNoIsNotAskedAgain() {
        XCTAssertEqual(AXDPProbePolicy.check(afterData: Data("[BPQ-6.0.24.1]\r".utf8), remembered: .notAXDP),
                       .none)
        XCTAssertEqual(AXDPProbePolicy.check(afterData: nil, remembered: .notAXDP), .none)
    }

    // MARK: Signs heard on the channel, with nothing sent (finding 1)

    func testAnAPRSBeaconToAXTermsTocallIsASign() {
        let beacon = Packet(from: AX25Address(call: "N0XYZ", ssid: 9), to: AX25Address(call: "APZAXT", ssid: 0),
                            frameType: .ui, pid: 0xF0, info: Data("!3944.35N/10459.42W-".utf8))
        XCTAssertEqual(AXTermSign.station(in: beacon), "N0XYZ-9")
        let direwolf = Packet(from: AX25Address(call: "N0XYZ", ssid: 9), to: AX25Address(call: "APDW16", ssid: 0),
                              frameType: .ui, pid: 0xF0, info: Data("!3944.35N/10459.42W-".utf8))
        XCTAssertNil(AXTermSign.station(in: direwolf))
    }

    func testAXDPHeardInAUIFrameIsASign() {
        let ping = AXDP.Message(type: .ping, sessionId: 0, messageId: 1,
                                capabilities: AXDPCapability.defaultLocal()).encode()
        let heard = Packet(from: AX25Address(call: "N0XYZ", ssid: 1), to: AX25Address(call: "N0ABC", ssid: 2),
                           frameType: .ui, pid: 0xF0, info: ping)
        XCTAssertEqual(AXTermSign.station(in: heard), "N0XYZ-1")
        let text = Packet(from: AX25Address(call: "N0XYZ", ssid: 1), to: AX25Address(call: "N0ABC", ssid: 2),
                          frameType: .ui, pid: 0xF0, info: Data("hello\r".utf8))
        XCTAssertNil(AXTermSign.station(in: text))
    }

    /// A node bridging two AXTerm stations carries their AXDP in its own
    /// I-frames; that does not make the node AXTerm (RelayAXDPTests).
    func testAXDPInAnIFrameIsNotASign() {
        let chat = AXDP.Message(type: .chat, sessionId: 0, messageId: 1, payload: Data("hi".utf8)).encode()
        let carried = Packet(from: AX25Address(call: "K0NOD", ssid: 1), to: AX25Address(call: "N0ABC", ssid: 2),
                             frameType: .i, pid: 0xF0, info: chat)
        XCTAssertNil(AXTermSign.station(in: carried))
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

    /// Either answer lasts a month (finding 1): asking every station once
    /// a day would be most of the probes for nothing.
    func testVerdictsLastAMonthEitherWay() {
        let memory = AXDPPeerMemory(defaults: TestDefaults.make("AXDPPeerMemoryExpiry"))
        let now = Date(timeIntervalSince1970: 1_791_700_000)
        memory.record(.notAXDP, for: "N0NODE-7", at: now)
        memory.record(.axterm, for: "K0EPI-4", at: now)
        for call in ["N0NODE-7", "K0EPI-4"] {
            XCTAssertNotNil(memory.verdict(for: call, now: now.addingTimeInterval(20 * 86_400)), call)
            XCTAssertNil(memory.verdict(for: call, now: now.addingTimeInterval(31 * 86_400)), call)
        }
    }

    /// An AXTerm station's capabilities are kept with the verdict, so next
    /// time it starts confirmed with nothing sent.
    func testCapabilitiesAreKeptWithTheVerdict() throws {
        let defaults = TestDefaults.make("AXDPPeerMemoryCapabilities")
        let capabilities = AXDPCapability.defaultLocal()
        AXDPPeerMemory(defaults: defaults).record(.axterm, for: "K0EPI-4", capabilities: capabilities)
        let later = AXDPPeerMemory(defaults: defaults)
        XCTAssertEqual(later.verdict(for: "K0EPI-4"), .axterm)
        XCTAssertEqual(later.capabilities(for: "K0EPI-4"), capabilities)
        XCTAssertNil(later.capabilities(for: "N0NODE-7"))
    }

    /// A passive sign (APRS beacon to APZAXT, AXDP heard) records AXTerm
    /// without capabilities, and does not wipe ones already known.
    func testASignWithoutCapabilitiesKeepsTheOnesKnown() {
        let memory = AXDPPeerMemory(defaults: TestDefaults.make("AXDPPeerMemoryKeep"))
        let capabilities = AXDPCapability.defaultLocal()
        memory.record(.axterm, for: "K0EPI-4", capabilities: capabilities)
        memory.record(.axterm, for: "K0EPI-4")
        XCTAssertEqual(memory.capabilities(for: "K0EPI-4"), capabilities)
        memory.record(.notAXDP, for: "K0EPI-4")
        XCTAssertNil(memory.capabilities(for: "K0EPI-4"))
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

    /// A node that is not AXTerm gets one UI probe, and its silence is
    /// kept, so the next connection sends nothing.
    func testANodeThatIsNotAXTermIsProbedOnceAndRemembered() async throws {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.peerMemory = AXDPPeerMemory(defaults: TestDefaults.make("AXDPProbeNode"))
        var probes = 0
        coordinator.onFrameHandedToRadio = { if $0.displayInfo == "AXDP probe" { probes += 1 } }
        let peer = AX25Address(call: "N0NODE", ssid: 7)
        let session = connectedAsCaller(to: peer, coordinator: coordinator)
        coordinator.sessionManager.onDataDeliveredForReassembly?(session, Data("[BPQ-6.0.24.1]\r".utf8))
        // It goes on the next turn, with the acknowledgment it owes.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probes, 1)

        coordinator.runCapabilityProbeTimers(now: Date().addingTimeInterval(120))
        XCTAssertEqual(probes, 1, "no retry")
        XCTAssertEqual(coordinator.peerMemory.verdict(for: peer.display), .notAXDP)
    }

    /// Check Again, from the Send File sheet's "No answer" badge: asks once
    /// more, whatever is remembered.
    func testCheckAgainAsksDespiteARememberedNo() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.peerMemory = AXDPPeerMemory(defaults: TestDefaults.make("AXDPCheckAgain"))
        let peer = AX25Address(call: "K0EPI", ssid: 4)
        coordinator.peerMemory.record(.notAXDP, for: peer.display)
        var probes = 0
        coordinator.onFrameHandedToRadio = { if $0.displayInfo == "AXDP probe" { probes += 1 } }
        _ = connectedAsCaller(to: peer, coordinator: coordinator)
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .notSupported)

        coordinator.checkAXDPAgain(for: peer.display)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .pending)
        XCTAssertNil(coordinator.peerMemory.verdict(for: peer.display), "the old answer is gone")
    }

    /// What the XID exchange showed goes into the peer memory: an answer
    /// to the marker is AXTerm, anything else is not, and a "no" never
    /// overwrites a station already known as AXTerm.
    func testTheXIDMarkerFillsTheMemory() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.peerMemory = AXDPPeerMemory(defaults: TestDefaults.make("AXDPXIDMarker"))
        coordinator.sessionManager.onXIDShowedAXTerm?("K0EPI-3", true)
        coordinator.sessionManager.onXIDShowedAXTerm?("N0NODE-7", false)
        coordinator.sessionManager.onXIDShowedAXTerm?("K0EPI-3", false)
        XCTAssertEqual(coordinator.peerMemory.verdict(for: "K0EPI-3"), .axterm)
        XCTAssertEqual(coordinator.peerMemory.verdict(for: "N0NODE-7"), .notAXDP)
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
