//
//  CapabilityExchangeFramesTests.swift
//  AXTermTests
//
//  Home retest 2026-10-10, finding 6. The capability exchange took four
//  frames: the caller's text probe, a PONG, the caller's PING, and a PONG.
//  The operator saw "AXDP probe, PONG, PING" in the terminal and found the
//  order odd. The answering station now replies to the probe with a PING
//  carrying its capabilities, the caller answers with a PONG carrying its
//  own, and both know each other in three frames.
//

import XCTest
@testable import AXTerm

@MainActor
final class CapabilityExchangeFramesTests: XCTestCase {

    private var caller: TransferStation!
    private var answerer: TransferStation!

    override func tearDown() async throws {
        caller?.tearDown()
        answerer?.tearDown()
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller = nil
        answerer = nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static let capabilityFrames: Set<String> = ["AXDP probe", "AXDP PING", "AXDP PONG"]

    /// The answer to a text probe is a PING with our capabilities.
    func testATextProbeIsAnsweredWithAPing() throws {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        coordinator.sessionManager.localCallsign = AX25Address(call: "K0EPI", ssid: 2)
        var sent: [OutboundFrame] = []
        coordinator.onFrameHandedToRadio = { sent.append($0) }

        let probe = try XCTUnwrap(SessionCoordinator.axdpTextProbe.data(using: .ascii))
        coordinator.handleInboundTextProbe(from: AX25Address(call: "K0EPI", ssid: 3), path: DigiPath(), payload: probe)

        let reply = try XCTUnwrap(sent.last)
        XCTAssertEqual(reply.displayInfo, "AXDP PING")
        guard case .message(let message, _) = AXDP.Message.frame(reply.payload) else {
            return XCTFail("the reply is not an AXDP message")
        }
        XCTAssertEqual(message.type, .ping)
        XCTAssertNotNil(message.capabilities)
    }

    /// A caller whose probe is answered with a PING replies with one PONG and
    /// is done: no PING of its own, now or when a stray PONG turns up.
    func testAProbeAnsweredWithAPingIsAnsweredWithOnePong() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
        coordinator.sessionManager.localCallsign = AX25Address(call: "K0EPI", ssid: 3)
        let peer = AX25Address(call: "K0EPI", ssid: 2)
        let session = coordinator.sessionManager.session(for: peer)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        coordinator.sessionManager.onSessionStateChanged?(session, .connecting, .connected)
        coordinator.sessionManager.onDataDeliveredForReassembly?(session, Data("Welcome to AXTerm\r".utf8))
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .pending)

        var events: [CapabilityDebugEventType] = []
        coordinator.onCapabilityEvent = { events.append($0.type) }
        let ping = AXDP.Message(type: .ping, sessionId: 0, messageId: 1, capabilities: AXDPCapability.defaultLocal())
        coordinator.handleCapabilityMessage(ping, from: peer, path: DigiPath())

        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .confirmed)
        XCTAssertFalse(coordinator.isCapabilityDiscoveryPending(for: peer.display))
        XCTAssertEqual(events.filter { $0 == .pongSent }.count, 1)

        let pong = AXDP.Message(type: .pong, sessionId: 0, messageId: 1, capabilities: AXDPCapability.defaultLocal())
        coordinator.handleCapabilityMessage(pong, from: peer, path: DigiPath())
        XCTAssertFalse(events.contains(.pingSent), "\(events)")
    }

    /// End to end: both stations know each other after three frames.
    func testTheExchangeTakesThreeFrames() async throws {
        caller = TransferStation(callsign: "K0AAA-1")
        answerer = TransferStation(callsign: "K0BBB-2")
        for station in [caller!, answerer!] {
            station.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
            station.coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
        }
        caller.coordinator.testTextProbeFallbackDelay = 0.1
        // The answering station sends no greeting and is not remembered, so
        // the caller sends the UI probe when the fallback runs out. A station
        // with an AXTerm sign is asked inside the connection instead
        // (InSessionCapabilityCheckTests).
        caller.coordinator.peerMemory = AXDPPeerMemory(defaults: TestDefaults.make("ThreeFrames-caller"))
        answerer.coordinator.testTextProbeFallbackDelay = 60
        var frames: [String] = []
        for station in [caller!, answerer!] {
            station.coordinator.onFrameHandedToRadio = { frame in
                if let info = frame.displayInfo, Self.capabilityFrames.contains(info) { frames.append(info) }
            }
        }
        caller.connectLink(to: answerer)
        answerer.connectLink(to: caller)
        if let sabm = caller.coordinator.sessionManager.connect(
            to: answerer.address, path: DigiPath(), radio: caller.coordinator.primaryRadioID) {
            caller.coordinator.sendFrame(sabm)
        }

        try await waitUntil("both stations know the other's capabilities") {
            self.caller.coordinator.packetEngine?.capabilityStore.capabilities(
                for: self.answerer.address.call, ssid: self.answerer.address.ssid) != nil
                && self.answerer.coordinator.packetEngine?.capabilityStore.capabilities(
                    for: self.caller.address.call, ssid: self.caller.address.ssid) != nil
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(frames, ["AXDP probe", "AXDP PING", "AXDP PONG"])
    }
}
