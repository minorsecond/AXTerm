//
//  NodeCallsignTests.swift
//  AXTermTests
//
//  The node on its own callsign, as operators expect of a node (operator,
//  2026-10-12): with an SSID set for it, K0EPI-7 is the node everywhere. Its
//  NODES broadcasts leave from it, its links to neighbor nodes are made
//  from it, circuits are addressed to it, and a plain connect to it gets the
//  node prompt, as a connect to its alias does. The station's own callsign,
//  K0EPI-2, stays the operator's. Left unset, the node shares the station's
//  callsign as before.
//

import XCTest
@testable import AXTerm

@MainActor
final class NodeCallsignTests: XCTestCase {

    private let neighbor = AX25Address(call: "W0ARP", ssid: 7)
    private var sent: [OutboundFrame] = []

    private func station(nodeSSID: Int?) -> SessionCoordinator {
        let settings = AppSettingsStore(defaults: TestDefaults.make("node-callsign-\(nodeSSID.map(String.init) ?? "none")"))
        settings.myCallsign = "K0EPI"
        settings.netRomNodeAlias = "EPINOD"
        settings.netRomAcceptInbound = true
        settings.netRomNodeSSID = nodeSSID
        let coordinator = SessionCoordinator()
        coordinator.appSettings = settings
        coordinator.applyNetRomNodeSettings(settings)
        coordinator.onFrameHandedToRadio = { [weak self] in self?.sent.append($0) }
        coordinator.sessionManager.onSendFrame = { [weak self] in self?.sent.append($0) }
        return coordinator
    }

    private func spin(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    func testTheSettingIsKeptAndStartsUnset() {
        let defaults = TestDefaults.make("node-ssid-setting")
        let settings = AppSettingsStore(defaults: defaults)
        XCTAssertNil(settings.netRomNodeSSID)
        settings.netRomNodeSSID = 7
        XCTAssertEqual(AppSettingsStore(defaults: defaults).netRomNodeSSID, 7)
    }

    func testTheNodeIsItsOwnCallsignAtLayerThree() {
        let coordinator = station(nodeSSID: 7)
        XCTAssertEqual(coordinator.nodeCallsign.display, "K0EPI-7")
        XCTAssertEqual(coordinator.netRomDriver.localNode.display, "K0EPI-7")
        XCTAssertEqual(coordinator.netRomDriver.localUser.display, coordinator.localCallsign,
                       "the operator's own circuits still name the operator")
        XCTAssertTrue(coordinator.announcements().allSatisfy { $0.node.display == "K0EPI-7" })
        XCTAssertTrue(coordinator.sessionManager.answers(AX25Address(call: "K0EPI", ssid: 7)))
    }

    func testUnsetTheNodeSharesTheStationsCallsign() {
        let coordinator = station(nodeSSID: nil)
        XCTAssertEqual(coordinator.nodeCallsign.display, coordinator.localCallsign)
        XCTAssertEqual(coordinator.netRomDriver.localNode.display, coordinator.localCallsign)
    }

    /// The NODES broadcast says who the node is by the address it leaves
    /// from.
    func testNodesLeaveFromTheNodesCallsign() async {
        let coordinator = station(nodeSSID: 7)
        coordinator.netRomDriver.advertisesItself = true
        sent = []
        coordinator.netRomDriver.broadcastNodes()
        await spin(0.5)
        let nodes = sent.filter { $0.destination.call == "NODES" }
        XCTAssertFalse(nodes.isEmpty)
        XCTAssertTrue(nodes.allSatisfy { $0.source.display == "K0EPI-7" }, "\(nodes.map { $0.source.display })")
    }

    /// A circuit to a neighbor rides a link the node makes from its own
    /// callsign.
    func testLinksToNeighborNodesAreMadeFromTheNodesCallsign() {
        let coordinator = station(nodeSSID: 7)
        coordinator.netRomDriver.nextHopResolver = { [neighbor] _ in neighbor.display }
        sent = []
        _ = coordinator.netRomDriver.openCircuit(to: AX25Address(call: "KE0GB", ssid: 7))
        // The first frame that opens the link: an XID where AX.25 2.2
        // negotiation is on, a SABM otherwise.
        let sabm = sent.first { $0.displayInfo == "SABM" || $0.displayInfo == "XID" }
        XCTAssertEqual(sabm?.source.display, "K0EPI-7", "\(sent.map { "\($0.source.display)>\($0.destination.display) \($0.displayInfo ?? "")" })")
        XCTAssertEqual(sabm?.destination.display, "W0ARP-7")
    }

    /// A person who connects to the node's callsign gets the node prompt,
    /// at their first line.
    func testAConnectToTheNodesCallsignGetsTheNodePrompt() async throws {
        let coordinator = station(nodeSSID: 7)
        let user = AX25Address(call: "W0XYZ", ssid: 1)
        coordinator.sessionManager.answerInboundSABM(from: user, to: AX25Address(call: "K0EPI", ssid: 7),
                                                     path: DigiPath(), radio: .primary) { self.sent.append($0) }
        sent = []
        _ = coordinator.sessionManager.handleInboundIFrame(from: user, to: AX25Address(call: "K0EPI", ssid: 7),
                                                           path: DigiPath(), radio: .primary, ns: 0, nr: 0,
                                                           payload: Data("NODES\r".utf8))
        await spin()
        let text = sent.compactMap { $0.displayInfo }.joined(separator: " ")
        XCTAssertTrue(sent.contains { $0.source.display == "K0EPI-7" && ($0.displayInfo ?? "").hasPrefix("Node") }, text)
    }

    /// The greeting and prompt name the node as operators write it,
    /// ALIAS:NODECALL, with the node's own callsign (on air 2026-10-12: they
    /// said EPINOD:K0EPI-2 with the node on K0EPI-7).
    func testThePromptNamesTheNodesCallsign() async throws {
        XCTAssertEqual(station(nodeSSID: 7).nodeHostIdentity().call, "K0EPI-7")
        let coordinator = station(nodeSSID: 7)
        let user = AX25Address(call: "W0XYZ", ssid: 1)
        coordinator.sessionManager.answerInboundSABM(from: user, to: AX25Address(call: "K0EPI", ssid: 7),
                                                     path: DigiPath(), radio: .primary) { self.sent.append($0) }
        sent = []
        _ = coordinator.sessionManager.handleInboundIFrame(from: user, to: AX25Address(call: "K0EPI", ssid: 7),
                                                           path: DigiPath(), radio: .primary, ns: 0, nr: 0,
                                                           payload: Data("\r".utf8))
        await spin()
        let text = sent.map { String(decoding: $0.payload, as: UTF8.self) }.joined(separator: " ")
        XCTAssertTrue(text.contains("EPINOD:K0EPI-7"), text)
        XCTAssertFalse(text.contains("EPINOD:K0EPI-2"), text)
    }

    /// Left unset, the prompt names the station's primary callsign, as
    /// before.
    func testUnsetThePromptNamesTheStation() {
        let coordinator = station(nodeSSID: nil)
        XCTAssertEqual(coordinator.nodeHostIdentity().call, coordinator.appSettings?.primaryCallsign.uppercased())
    }

    /// A neighbor node links to the node's callsign to carry NET/ROM: it is
    /// never greeted with the prompt's text.
    func testANeighborNodesLinkIsNotGreeted() async throws {
        let coordinator = station(nodeSSID: 7)
        sent = []
        coordinator.sessionManager.answerInboundSABM(from: neighbor, to: AX25Address(call: "K0EPI", ssid: 7),
                                                     path: DigiPath(), radio: .primary) { self.sent.append($0) }
        let nodesInfo = NetRomNodesBroadcast.encode(originAlias: "ARPNOD", entries: []).first ?? Data()
        _ = coordinator.sessionManager.handleInboundIFrame(from: neighbor, to: AX25Address(call: "K0EPI", ssid: 7),
                                                           path: DigiPath(), radio: .primary, ns: 0, nr: 0,
                                                           payload: nodesInfo, pid: NetRomWire.pid)
        await spin(2.5)
        XCTAssertFalse(sent.contains { ($0.displayInfo ?? "").hasPrefix("Node") },
                       "\(sent.map { $0.displayInfo ?? "" })")
    }

    /// The station's own callsign is the operator's, not the node's.
    func testAConnectToTheStationIsNotTheNode() async {
        let coordinator = station(nodeSSID: 7)
        let user = AX25Address(call: "W0XYZ", ssid: 1)
        let station = CallsignNormalizer.toAddress(coordinator.localCallsign)
        coordinator.sessionManager.answerInboundSABM(from: user, to: station, path: DigiPath(),
                                                     radio: .primary) { self.sent.append($0) }
        sent = []
        _ = coordinator.sessionManager.handleInboundIFrame(from: user, to: station, path: DigiPath(), radio: .primary,
                                                           ns: 0, nr: 0, payload: Data("NODES\r".utf8))
        await spin()
        XCTAssertFalse(sent.contains { ($0.displayInfo ?? "").hasPrefix("Node") })
    }
}

/// The choices the Packet Node page offers for the node's callsign.
final class NodeCallsignChoicesTests: XCTestCase {

    func testEveryFreeSSIDIsOffered() {
        XCTAssertEqual(NodeCallsignChoices.ssids(taken: [2, 4]), [1, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
    }

    /// The node's current SSID stays on the list even when taken since.
    func testTheCurrentChoiceStays() {
        XCTAssertTrue(NodeCallsignChoices.ssids(taken: [7], current: 7).contains(7))
    }

    /// The mailbox's SSID is taken too: the picker offered K0EPI-4, the
    /// mailbox's address, for the node (2026-10-12).
    func testTheMailboxsSSIDIsTaken() {
        XCTAssertEqual(NodeCallsignChoices.taken(radios: ["K0EPI-2"], mailbox: "K0EPI-4", station: "K0EPI"), [2, 4])
        XCTAssertEqual(NodeCallsignChoices.taken(radios: ["K0EPI-2"], mailbox: "W0ARP-4", station: "K0EPI"), [2],
                       "a mailbox on another callsign takes nothing of ours")
        XCTAssertEqual(NodeCallsignChoices.taken(radios: ["K0EPI-2"], mailbox: nil, station: "K0EPI"), [2])
        XCTAssertFalse(NodeCallsignChoices.ssids(taken: [2, 4]).contains(4))
    }

    /// 7 is the one operators most often give a node.
    func testTheUsualOneIsSeven() {
        XCTAssertEqual(NodeCallsignChoices.suggested(taken: [2, 4]), 7)
        XCTAssertEqual(NodeCallsignChoices.suggested(taken: [7]), 8)
    }
}
