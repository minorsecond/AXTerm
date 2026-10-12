//
//  LinkByBothAddressesTests.swift
//  AXTermTests
//
//  AX.25 identifies a link by the pair of addresses. AXTerm keyed its links
//  by the other station alone (with path and radio), so it could hold only
//  one link to a station: a second call to another of our addresses was
//  refused, and a frame to one of our addresses could land on the link of
//  another. A station that runs its node on its own callsign, as operators
//  expect of a node (operator, 2026-10-12), holds links to the same
//  neighbor from both: the node's for NET/ROM, the operator's for typing.
//
//  These tests hold two links to one station, from the station's address
//  and from another of ours, and send each kind of frame to each.
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class LinkByBothAddressesTests: XCTestCase {

    private let station = AX25Address(call: "K0EPI", ssid: 2)
    private let mailbox = AX25Address(call: "K0EPI", ssid: 4)
    private let node = AX25Address(call: "K0EPI", ssid: 7)
    private let peer = AX25Address(call: "W0ARP", ssid: 7)

    private func manager() -> AX25SessionManager {
        let manager = AX25SessionManager(localCallsign: station, clock: AX25VirtualClock())
        manager.setServiceAddress(mailbox, for: "bbs")
        manager.setServiceAddress(node, for: "node")
        return manager
    }

    /// A link from the station's address (we call) and one to the mailbox
    /// (they call), both up.
    private func twoLinks(_ manager: AX25SessionManager) throws -> (ours: AX25Session, theirs: AX25Session) {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundUA(from: peer, to: station, path: DigiPath(), radio: .primary)
        let answer = try XCTUnwrap(manager.handleInboundSABM(from: peer, to: mailbox, path: DigiPath(), radio: .primary))
        XCTAssertEqual(answer.displayInfo, "UA")
        XCTAssertEqual(answer.source.display, "K0EPI-4", "answered from the address called")
        let ours = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary, local: station))
        let theirs = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary, local: mailbox))
        return (ours, theirs)
    }

    // MARK: - Two links

    /// A call to the mailbox while the station has a link to the caller is
    /// a second link, not a refusal.
    func testASecondLinkFromAnotherOfOurAddressesIsAnswered() throws {
        let manager = manager()
        let (ours, theirs) = try twoLinks(manager)
        XCTAssertFalse(ours === theirs)
        XCTAssertEqual(ours.state, .connected)
        XCTAssertEqual(theirs.state, .connected)
        XCTAssertEqual(ours.localAddress.display, "K0EPI-2")
        XCTAssertEqual(theirs.localAddress.display, "K0EPI-4")
        XCTAssertNotEqual(ours.key, theirs.key)
    }

    func testAnIFrameGoesToTheLinkItIsAddressedTo() throws {
        let manager = manager()
        let (ours, theirs) = try twoLinks(manager)
        var toOurs = Data(), toTheirs = Data()
        _ = manager.claimDelivery(for: ours.key, handler: { _, data in toOurs.append(data) })
        _ = manager.claimDelivery(for: theirs.key, handler: { _, data in toTheirs.append(data) })

        _ = manager.handleInboundIFrame(from: peer, to: mailbox, path: DigiPath(), radio: .primary,
                                        ns: 0, nr: 0, payload: Data("for the mailbox\r".utf8))
        _ = manager.handleInboundIFrame(from: peer, to: station, path: DigiPath(), radio: .primary,
                                        ns: 0, nr: 0, payload: Data("for the operator\r".utf8))

        XCTAssertEqual(String(decoding: toTheirs, as: UTF8.self), "for the mailbox\r")
        XCTAssertEqual(String(decoding: toOurs, as: UTF8.self), "for the operator\r")
    }

    /// An acknowledgment frees the frames of the link it is addressed to.
    func testAnRRAcknowledgesOnlyTheLinkItIsAddressedTo() throws {
        let manager = manager()
        let (ours, theirs) = try twoLinks(manager)
        _ = manager.sendData(Data("one\r".utf8), to: peer, path: DigiPath(), radio: .primary, from: station)
        _ = manager.sendData(Data("two\r".utf8), to: peer, path: DigiPath(), radio: .primary, from: mailbox)
        XCTAssertEqual(ours.stateMachine.sequenceState.vs, 1)
        XCTAssertEqual(theirs.stateMachine.sequenceState.vs, 1)

        _ = manager.handleInboundRRFrames(from: peer, to: mailbox, path: DigiPath(), radio: .primary,
                                          nr: 1, pf: false, isCommand: false)

        XCTAssertEqual(theirs.stateMachine.sequenceState.va, 1)
        XCTAssertEqual(ours.stateMachine.sequenceState.va, 0, "the operator's frame is still outstanding")
    }

    func testADISCEndsOnlyTheLinkItIsAddressedTo() throws {
        let manager = manager()
        let (ours, theirs) = try twoLinks(manager)
        let answer = try XCTUnwrap(manager.handleInboundDISC(from: peer, to: mailbox, path: DigiPath(), radio: .primary))
        XCTAssertEqual(answer.displayInfo, "UA")
        XCTAssertEqual(answer.source.display, "K0EPI-4")
        XCTAssertEqual(theirs.state, .disconnected)
        XCTAssertEqual(ours.state, .connected)
    }

    func testADMEndsOnlyTheLinkItIsAddressedTo() throws {
        let manager = manager()
        let (ours, theirs) = try twoLinks(manager)
        manager.handleInboundDM(from: peer, to: mailbox, path: DigiPath(), radio: .primary)
        XCTAssertNotEqual(theirs.state, .connected)
        XCTAssertEqual(ours.state, .connected)
    }

    // MARK: - Calling from an address

    /// The node calls a neighbor from its own callsign while the operator
    /// calls the same station from theirs; each UA answers its own call.
    func testEachUAAnswersTheCallItIsAddressedTo() throws {
        let manager = manager()
        let fromStation = try XCTUnwrap(manager.connect(to: peer, path: DigiPath(), radio: .primary))
        let fromNode = try XCTUnwrap(manager.connect(to: peer, path: DigiPath(), radio: .primary, from: node))
        XCTAssertEqual(fromStation.source.display, "K0EPI-2")
        XCTAssertEqual(fromNode.source.display, "K0EPI-7")
        let operatorLink = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary, local: station))
        let nodeLink = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary, local: node))

        _ = manager.handleInboundUA(from: peer, to: node, path: DigiPath(), radio: .primary)

        XCTAssertEqual(nodeLink.state, .connected)
        XCTAssertEqual(operatorLink.state, .connecting)
    }

    func testSendingFromAnAddressUsesThatLink() throws {
        let manager = manager()
        let frames = manager.sendData(Data("datagram".utf8), to: peer, path: DigiPath(), radio: .primary, from: node)
        XCTAssertEqual(frames.first?.source.display, "K0EPI-7", "the SABM that opens the node's link")
        let link = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary, local: node))
        XCTAssertEqual(link.localAddress.display, "K0EPI-7")
    }

    // MARK: - Everything that names no address works as before

    /// With two links up, an address-free send is the operator's, from the
    /// station's address.
    func testWithoutAnAddressTheStationsLinkIsUsed() throws {
        let manager = manager()
        _ = try twoLinks(manager)
        let frames = manager.sendData(Data("typed\r".utf8), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(frames.first?.source.display, "K0EPI-2")
    }

    /// One link, on any address, is found without naming the address, as
    /// every caller that holds a session already does.
    func testALoneLinkIsFoundWithoutItsAddress() throws {
        let manager = manager()
        _ = manager.handleInboundSABM(from: peer, to: mailbox, path: DigiPath(), radio: .primary)
        let link = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        XCTAssertEqual(link.localAddress.display, "K0EPI-4")
        let frames = manager.sendData(Data("hello\r".utf8), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(frames.first?.source.display, "K0EPI-4")
    }

    /// A frame that names none of our links' addresses still finds the one
    /// link to its sender, as before (the caller's TNC may address an alias
    /// we answer on).
    func testAFrameToAnUnheldAddressFallsBackToTheOneLink() throws {
        let manager = manager()
        _ = manager.handleInboundSABM(from: peer, to: mailbox, path: DigiPath(), radio: .primary)
        let link = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        var delivered = Data()
        _ = manager.claimDelivery(for: link.key, handler: { _, data in delivered.append(data) })
        _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                        ns: 0, nr: 0, payload: Data("x\r".utf8))
        XCTAssertEqual(String(decoding: delivered, as: UTF8.self), "x\r")
    }
}

/// The same through the coordinator, which reads frames off the air and
/// must hand each to the manager with the address it was sent to.
@MainActor
final class CoordinatorLinkAddressTests: XCTestCase {

    private let station = AX25Address(call: "K0EPI", ssid: 2)
    private let node = AX25Address(call: "K0EPI", ssid: 7)
    private let peer = AX25Address(call: "W0ARP", ssid: 7)

    private func coordinator() -> SessionCoordinator {
        let coordinator = SessionCoordinator()
        coordinator.sessionManager.localCallsign = station
        coordinator.sessionManager.setServiceAddress(node, for: "node")
        return coordinator
    }

    private func hear(_ frame: OutboundFrame, at coordinator: SessionCoordinator) throws {
        let bytes = frame.encodeAX25()
        guard case .success(let decoded) = AX25.checkFrame(ax25: bytes) else { return XCTFail("frame did not decode") }
        coordinator.handleIncomingPacket(Packet(from: decoded.from, to: decoded.to, via: decoded.via,
                                                frameType: decoded.frameType, control: decoded.control,
                                                controlByte1: decoded.controlByte1, pid: decoded.pid,
                                                info: decoded.info, rawAx25: bytes, radioID: .primary))
    }

    /// Both our addresses call the same station; each UA answers its own.
    private func twoCalls(_ coordinator: SessionCoordinator) throws -> (operatorLink: AX25Session, nodeLink: AX25Session) {
        let manager = coordinator.sessionManager
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary, from: node)
        return (try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary, local: station)),
                try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary, local: node)))
    }

    func testAUAOffTheAirAnswersTheCallItIsAddressedTo() throws {
        let coordinator = coordinator()
        let (operatorLink, nodeLink) = try twoCalls(coordinator)
        try hear(AX25FrameBuilder.buildUA(from: peer, to: node), at: coordinator)
        XCTAssertEqual(nodeLink.state, .connected)
        XCTAssertEqual(operatorLink.state, .connecting)
    }

    func testADMOffTheAirRefusesOnlyTheCallItIsAddressedTo() throws {
        let coordinator = coordinator()
        let (operatorLink, nodeLink) = try twoCalls(coordinator)
        try hear(AX25FrameBuilder.buildDM(from: peer, to: node), at: coordinator)
        XCTAssertNotEqual(nodeLink.state, .connecting)
        XCTAssertEqual(operatorLink.state, .connecting)
    }
}

/// The services write on their own links: with the caller also holding a
/// link to the station's address, what the mailbox says goes out from the
/// mailbox's address on the mailbox's link.
@MainActor
final class ServicesWriteOnTheirOwnLinkTests: XCTestCase {

    func testTheMailboxWritesOnItsOwnLink() async throws {
        let queue = try GRDB.DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let settings = BBSSettings(defaults: TestDefaults.make("own-link-bbs"))
        settings.onAir = true
        settings.callsign = "K0EPI-4"
        let coordinator = SessionCoordinator()
        let manager = coordinator.sessionManager
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 2)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        let service = BBSService(store: SQLiteBBSMessageStore(dbQueue: queue), settings: settings,
                                 coordinator: coordinator, sendFrames: { sent.append(contentsOf: $0) },
                                 stationCallsign: { "K0EPI" }, isWinlinkP2PArmed: { false },
                                 winlinkP2PCallsign: { "" }, linkBytesPerSecond: { 1_000_000 })
        service.attach()
        defer { service.shutdown(reason: "test over"); service.detach() }
        let caller = AX25Address(call: "K0EPI", ssid: 3)
        // The operator's own link to the caller, from K0EPI-2.
        _ = manager.connect(to: caller, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundUA(from: caller, to: manager.localCallsign, path: DigiPath(), radio: .primary)
        sent = []
        // The caller calls the mailbox.
        manager.answerInboundSABM(from: caller, to: AX25Address(call: "K0EPI", ssid: 4), path: DigiPath(),
                                  radio: .primary) { sent.append($0) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let greeting = sent.filter { $0.frameType == "i" || $0.displayInfo?.hasPrefix("BBS") == true }
        XCTAssertFalse(greeting.isEmpty, "the mailbox greeted: \(sent.map { $0.displayInfo ?? "" })")
        XCTAssertTrue(greeting.allSatisfy { $0.source.display == "K0EPI-4" },
                      "\(greeting.map { $0.source.display })")
    }
}
