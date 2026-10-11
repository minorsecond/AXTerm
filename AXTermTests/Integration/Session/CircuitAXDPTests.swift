//
//  CircuitAXDPTests.swift
//  AXTermTests
//
//  AXDP over a native NET/ROM circuit (Docs/RemoteAccessPlan.md, part 1,
//  step 3). NET/ROM repairs a loss on the hop where it happened and AXDP
//  confirms the whole file end to end: the robust way from the road to
//  home. Home runs its node; a circuit lands at the node prompt as it
//  always has, and when what arrives first is AXDP rather than typing, the
//  circuit becomes a conversation with the caller: AXDP and plain text,
//  like a direct link, with the caller named by the circuit's user field.
//

import XCTest
@testable import AXTerm

@MainActor
final class CircuitAXDPTests: XCTestCase {

    private var caller: TransferStation!
    private var home: TransferStation!

    override func setUp() async throws {
        caller = TransferStation(callsign: "K0AAA-1")
        home = TransferStation(callsign: "K0BBB-2")
        for station in [caller!, home!] {
            station.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
            station.coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
            station.coordinator.peerMemory = AXDPPeerMemory(defaults: TestDefaults.make("Circuit-\(station.callsign)"))
            station.coordinator.testTextProbeFallbackDelay = 60
        }
        home.settings.netRomAcceptInbound = true
        home.coordinator.applyNetRomNodeSettings(home.settings)
        caller.coordinator.netRomDriver.nextHopResolver = { $0.uppercased() == "K0BBB-2" ? "K0BBB-2" : nil }
        caller.connectLink(to: home)
        home.connectLink(to: caller)
    }

    override func tearDown() async throws {
        caller?.tearDown()
        home?.tearDown()
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller = nil
        home = nil
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

    private func openCircuit() async throws -> NetRomCircuitID {
        guard case .success(let id) = caller.coordinator.netRomDriver.openCircuit(to: home.address) else {
            XCTFail("no circuit")
            throw XCTSkip("no circuit")
        }
        try await waitUntil("the circuit connects") {
            self.caller.coordinator.netRomDriver.circuit(for: id)?.state == .connected
        }
        return id
    }

    /// The far end of an outbound circuit is a conversation like any other.
    func testAnOpenCircuitIsAWayToReachItsStation() async throws {
        let id = try await openCircuit()
        XCTAssertEqual(caller.coordinator.circuit(toPeer: home.address), id)
        // Send File offers it once, over the circuit its AXDP takes.
        XCTAssertEqual(caller.coordinator.transferDestinations,
                       [TransferDestination(callsign: "K0BBB-2", path: "", via: .netRom)])
    }

    func testTheCapabilityCheckGoesOverTheCircuit() async throws {
        caller.coordinator.peerMemory.record(.axterm, for: home.address.display)
        _ = try await openCircuit()
        try await waitUntil("the caller knows home runs AXTerm") {
            self.caller.coordinator.capabilityStatus(for: self.home.address.display) == .confirmed
        }
        try await waitUntil("home knows the caller runs AXTerm") {
            self.home.coordinator.capabilityStatus(for: self.caller.address.display) == .confirmed
        }
    }

    /// A station with no AXTerm sign is a node to type at, and gets no AXDP.
    func testNoSignNoAXDP() async throws {
        var axdpFrames = 0
        caller.coordinator.onFrameHandedToRadio = { if $0.payload.range(of: AXDP.magic) != nil { axdpFrames += 1 } }
        _ = try await openCircuit()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(axdpFrames, 0)
    }

    func testAFileGoesHomeOverTheCircuitByAXDP() async throws {
        caller.coordinator.peerMemory.record(.axterm, for: home.address.display)
        _ = try await openCircuit()
        try await waitUntil("the caller knows home runs AXTerm") {
            self.caller.coordinator.capabilityStatus(for: self.home.address.display) == .confirmed
        }
        var plainAXDPFrames = 0, circuitFrames = 0
        caller.coordinator.onFrameHandedToRadio = { frame in
            if frame.pid == NetRomWire.pid { circuitFrames += 1 }
            if frame.pid == 0xF0, AXDP.hasMagic(frame.payload) { plainAXDPFrames += 1 }
        }
        let data = Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 7) })
        XCTAssertNil(caller.coordinator.startTransfer(to: home.callsign, fileName: "home.bin", data: data,
                                                     transferProtocol: .axdp, compressionSettings: .disabled))
        try await waitUntil("home is offered the file") {
            !self.home.coordinator.pendingIncomingTransfers.isEmpty
        }
        let offer = try XCTUnwrap(home.coordinator.pendingIncomingTransfers.first)
        XCTAssertEqual(offer.sourceCallsign.uppercased(), caller.callsign.uppercased())
        home.coordinator.acceptIncomingTransfer(offer.id)
        try await waitUntil("the file arrives", timeout: 90) {
            self.home.transfer(named: "home.bin")?.status == .completed
        }
        XCTAssertEqual(home.savedData(home.transfer(named: "home.bin")), data)
        XCTAssertGreaterThan(circuitFrames, 0, "over the circuit")
        XCTAssertEqual(plainAXDPFrames, 0, "and not beside it on the radio link")
    }
}
