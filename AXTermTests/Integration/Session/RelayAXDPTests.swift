//
//  RelayAXDPTests.swift
//  AXTermTests
//
//  AXDP to the far end of a node relay (Docs/RemoteAccessPlan.md, part 1;
//  operator, 2026-10-11: as robust and fast as AX.25 and packet allow).
//
//  Three stations share one simplex channel: the caller, a node that
//  behaves like BPQ (answers, greets, bridges on C <call>, and calls the far
//  station from its own callsign), and home. AXTerm used to treat the
//  station at the other end of the radio link as the one it talks to, so
//  through a node every AXDP message was the node's. Now a conversation is
//  the far station plus the link that carries it, and an AXDP PING or PONG
//  carries its sender's callsign, so each end learns who is really there.
//

import XCTest
@testable import AXTerm

@MainActor
final class RelayAXDPTests: XCTestCase {

    private var caller: TransferStation!
    private var nodeStation: TransferStation!
    private var node: BridgeNode!
    private var home: TransferStation!

    override func setUp() async throws {
        caller = TransferStation(callsign: "K0AAA-1")
        nodeStation = TransferStation(callsign: "K0NOD-1")
        home = TransferStation(callsign: "K0BBB-2")
        node = BridgeNode(station: nodeStation, alias: "TSTNOD")
        for station in [caller!, home!] {
            station.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
            station.coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
            station.coordinator.peerMemory = AXDPPeerMemory(defaults: TestDefaults.make("Relay-\(station.callsign)"))
            station.coordinator.testTextProbeFallbackDelay = 60
        }
        let all = [caller!, nodeStation!, home!]
        for station in all { station.join(all) }
    }

    override func tearDown() async throws {
        for station in [caller, nodeStation, home] { station?.tearDown() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller = nil; nodeStation = nil; home = nil; node = nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)")
                throw XCTSkip(what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private var linkToNode: AX25Session? {
        caller.coordinator.sessionManager.connectedSession(withPeer: nodeStation.address)
    }

    private func type(_ text: String) {
        guard let session = linkToNode else { return }
        for frame in caller.coordinator.sessionManager.sendData(Data(text.utf8), to: session.remoteAddress,
                                                                path: session.path, radio: session.radio) {
            caller.coordinator.sendFrame(frame)
        }
    }

    /// Connects to the node and has it bridge to home, as an operator would.
    private func relayToHome() async throws -> AX25Session {
        if let sabm = caller.coordinator.sessionManager.connect(to: nodeStation.address, path: DigiPath(),
                                                               radio: caller.coordinator.primaryRadioID) {
            caller.coordinator.sendFrame(sabm)
        }
        try await waitUntil("the node greets") {
            String(decoding: self.caller.terminalText, as: UTF8.self).contains("BPQ-style test node")
        }
        type("C K0BBB-2\r")
        try await waitUntil("the node reports the far station") {
            String(decoding: self.caller.terminalText, as: UTF8.self).contains("Connected to K0BBB-2")
        }
        let session = try XCTUnwrap(linkToNode)
        caller.coordinator.registerRelay(to: home.address, via: session)
        return session
    }

    // MARK: - The conversation table

    func testTheFarStationIsReachedThroughTheNodesLink() async throws {
        let session = try await relayToHome()
        XCTAssertTrue(caller.coordinator.link(toPeer: home.address) === session)
        XCTAssertEqual(caller.coordinator.relayFarEnd(of: session), home.address)
        XCTAssertTrue(caller.coordinator.link(toPeer: nodeStation.address) === session, "the node itself too")
        // Send File offers the far station, by way of the node, not the node.
        XCTAssertEqual(caller.coordinator.transferDestinations,
                       [TransferDestination(callsign: "K0BBB-2", path: "", via: .node("K0NOD-1"))])
    }

    /// A station with an AXTerm sign is asked inside the relayed link, and
    /// both ends learn who the other really is: home files the caller under
    /// K0AAA-1, not the node it heard the bytes from.
    func testTheCapabilityCheckCrossesTheNodeAndNamesTheRealStations() async throws {
        caller.coordinator.peerMemory.record(.axterm, for: home.address.display)
        _ = try await relayToHome()
        try await waitUntil("the caller knows home runs AXTerm") {
            self.caller.coordinator.capabilityStatus(for: self.home.address.display) == .confirmed
        }
        try await waitUntil("home knows the caller runs AXTerm") {
            self.home.coordinator.capabilityStatus(for: self.caller.address.display) == .confirmed
        }
        XCTAssertNotEqual(home.coordinator.peerMemory.verdict(for: nodeStation.address.display), .axterm,
                          "the node is not AXTerm, and must never be sent AXDP for being in the middle")
        XCTAssertNotEqual(caller.coordinator.peerMemory.verdict(for: nodeStation.address.display), .axterm)
    }

    /// A far station with no AXTerm sign gets nothing: binary on a plain
    /// terminal is junk on someone's screen.
    func testAFarStationWithNoSignIsNotSentAXDP() async throws {
        var axdpFrames = 0
        caller.coordinator.onFrameHandedToRadio = { if AXDP.hasMagic($0.payload) { axdpFrames += 1 } }
        _ = try await relayToHome()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(axdpFrames, 0)
    }

    /// The whole point: a file by AXDP to home, through the node, intact.
    func testAFileGoesToHomeThroughTheNodeByAXDP() async throws {
        caller.coordinator.peerMemory.record(.axterm, for: home.address.display)
        _ = try await relayToHome()
        try await waitUntil("the caller knows home runs AXTerm") {
            self.caller.coordinator.capabilityStatus(for: self.home.address.display) == .confirmed
        }
        let data = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        XCTAssertNil(caller.coordinator.startTransfer(to: home.callsign, fileName: "photo.bin", data: data,
                                                     transferProtocol: .axdp, compressionSettings: .disabled))
        try await waitUntil("home is offered the file") {
            !self.home.coordinator.pendingIncomingTransfers.isEmpty
        }
        let offer = try XCTUnwrap(home.coordinator.pendingIncomingTransfers.first)
        XCTAssertEqual(offer.sourceCallsign.uppercased(), caller.callsign.uppercased(), "from the caller, not the node")
        home.coordinator.acceptIncomingTransfer(offer.id)
        try await waitUntil("the file arrives", timeout: 60) {
            self.home.transfer(named: "photo.bin")?.status == .completed
        }
        XCTAssertEqual(home.savedData(home.transfer(named: "photo.bin")), data)
    }

    /// The node's link going down ends the conversation through it.
    func testTheRelayEndsWithTheNodesLink() async throws {
        let session = try await relayToHome()
        if let disc = caller.coordinator.sessionManager.disconnect(session: session) {
            caller.coordinator.sendFrame(disc)
        }
        try await waitUntil("the link goes down") { self.linkToNode == nil }
        XCTAssertNil(caller.coordinator.link(toPeer: home.address))
    }
}
