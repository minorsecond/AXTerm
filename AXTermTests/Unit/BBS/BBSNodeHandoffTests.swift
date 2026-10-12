//
//  BBSNodeHandoffTests.swift
//  AXTermTests
//
//  BBS at the node over a direct AX.25 link hands the link to the full
//  mailbox (operator, 2026-10-12): transfers and control commands work
//  there, the node's sign-in comes along, and B gives the link back to the
//  node instead of hanging up. A NET/ROM circuit keeps the lines-only
//  mailbox, since only the node can carry its bytes.
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class BBSNodeHandoffTests: XCTestCase {

    private var coordinator: SessionCoordinator!
    private var service: BBSService!
    private var caller: BBSSimulatedCaller!
    private let nodeAddress = AX25Address(call: "EPINOD", ssid: 0)

    override func setUp() async throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let settings = BBSSettings(defaults: TestDefaults.make("bbs-node-handoff"))
        settings.onAir = true
        settings.callsign = "K0EPI-4"
        settings.ownerCommandsEnabled = true
        coordinator = SessionCoordinator()
        let simulated = BBSSimulatedCaller(manager: coordinator.sessionManager, address: AX25Address(call: "K0EPI", ssid: 3),
                                           mailbox: nodeAddress)
        caller = simulated
        coordinator.sessionManager.onSendFrame = { [weak simulated] in simulated?.outbox.append($0) }
        service = BBSService(store: SQLiteBBSMessageStore(dbQueue: queue), settings: settings,
                             coordinator: coordinator,
                             sendFrames: { [weak simulated] in simulated?.outbox.append(contentsOf: $0) },
                             stationCallsign: { "K0EPI" }, isWinlinkP2PArmed: { false },
                             winlinkP2PCallsign: { "" }, linkBytesPerSecond: { 1_000_000 })
        service.ownerSecret = { Data("12345678901234567890".utf8) }
        service.attach()
    }

    override func tearDown() async throws {
        service?.shutdown(reason: "test over")
        service?.detach()
    }

    /// The node's console, signed in at the node.
    private func signedIn() -> OwnerConsole {
        var console = OwnerConsole(caller: "K0EPI-3", station: "EPINOD", ownerCallsign: "K0EPI-4",
                                   checkOwnerCode: { _, _ in .accepted })
        _ = console.command("OWNER", "123456", checked: false, status: [], now: Date())
        XCTAssertTrue(console.isOwner)
        return console
    }

    private func nodeSession() throws -> AX25Session {
        caller.connect()
        return try XCTUnwrap(coordinator.sessionManager.sessions.values.first {
            $0.remoteAddress.display == "K0EPI-3" && $0.state == .connected
        })
    }

    func testTheMailboxTakesTheLinkWithTheSignIn() async throws {
        let session = try nodeSession()
        XCTAssertTrue(service.adoptFromNode(session, owner: signedIn()) { _ in })
        _ = await caller.pump { self.caller.text.contains("not met you before") }
        caller.type("A")
        _ = await caller.pump { self.caller.text.hasSuffix(">\r") }
        caller.clearReceived()
        caller.type("ST")
        _ = await caller.pump { self.caller.text.contains("Mail for you") }
        XCTAssertTrue(caller.text.contains("Mail for you"), "signed in at the node, signed in here: \(caller.text)")
    }

    /// B goes back to the node, still signed in, and the link stays up.
    func testByeGivesTheLinkBackToTheNode() async throws {
        let session = try nodeSession()
        var returned: OwnerConsole?
        XCTAssertTrue(service.adoptFromNode(session, owner: signedIn()) { returned = $0 })
        _ = await caller.pump { self.caller.text.contains("personal mailbox") }
        caller.outbox.removeAll()
        caller.type("A")
        caller.type("B")
        _ = await caller.pump { returned != nil }
        XCTAssertEqual(returned?.isOwner, true)
        XCTAssertEqual(session.state, .connected, "no DISC: the caller is back at the node")
        XCTAssertFalse(caller.outbox.contains { $0.displayInfo == "DISC" }, "no DISC sent")
        XCTAssertNil(service.live, "the mailbox is free for the next caller")
    }

    /// The mailbox takes one caller at a time; the node keeps the lines-only
    /// mailbox for anyone who comes while it is busy.
    func testABusyMailboxSaysNo() throws {
        let session = try nodeSession()
        XCTAssertTrue(service.adoptFromNode(session, owner: signedIn()) { _ in })
        XCTAssertFalse(service.adoptFromNode(session, owner: signedIn()) { _ in })
    }
}

@MainActor
final class NetRomNodeHostHandoffTests: XCTestCase {

    private var host: NetRomNodeHost!
    private var written: [Data] = []

    override func setUp() async throws {
        host = NetRomNodeHost()
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm 1.0") }
        host.snapshotProvider = {
            var snapshot = NetRomNodeShell.Snapshot()
            snapshot.bbsAvailable = true
            return snapshot
        }
        written = []
    }

    private var text: String { String(decoding: Data(written.flatMap { $0 }), as: UTF8.self) }

    private func attach(owner: OwnerConsole? = nil, returning: Bool = false) {
        host.attachAX25Caller(key: "S1", callsign: "K0EPI-3", dialed: "EPINOD", radio: .primary,
                              owner: owner, returning: returning,
                              send: { [weak self] in self?.written.append($0) }, hangUp: {})
    }

    func testBBSOverAnAX25LinkHandsItToTheMailbox() {
        var handed: (key: String, owner: OwnerConsole)?
        host.adoptAX25ForMailbox = { key, owner in handed = (key, owner); return true }
        host.bbsSessionFactory = { _ in XCTFail("the lines-only mailbox is for circuits now"); return nil }
        attach()
        host.ax25CallerReceived(key: "S1", data: Data("BBS\r".utf8))
        XCTAssertEqual(handed?.key, "S1")
        written = []
        host.ax25CallerReceived(key: "S1", data: Data("ROUTES\r".utf8))
        XCTAssertEqual(text, "", "the link is the mailbox's now")
    }

    func testABusyMailboxFallsBackToLinesOnly() {
        host.adoptAX25ForMailbox = { _, _ in false }
        var asked = false
        host.bbsSessionFactory = { _ in asked = true; return nil }
        attach()
        host.ax25CallerReceived(key: "S1", data: Data("BBS\r".utf8))
        XCTAssertTrue(asked)
    }

    /// Back from the mailbox: a short word, the prompt, and the sign-in.
    func testComingBackFromTheMailbox() {
        var console = OwnerConsole(caller: "K0EPI-3", station: "EPINOD", ownerCallsign: "K0EPI-7",
                                   checkOwnerCode: { _, _ in .accepted })
        _ = console.command("OWNER", "123456", checked: false, status: [], now: Date())
        attach(owner: console, returning: true)
        XCTAssertEqual(text, "Back at the node.\rEPINOD:K0EPI-7} ")
        written = []
        host.ax25CallerReceived(key: "S1", data: Data("ST\r".utf8))
        XCTAssertTrue(text.hasPrefix("Nothing to report."), "still signed in: \(text)")
    }
}

/// The whole way through, with the real coordinator: connect to the node's
/// alias, sign in there, BBS into the full mailbox, still signed in, and B
/// back to the node on the same link.
@MainActor
final class NodeToMailboxEndToEndTests: XCTestCase {

    private var coordinator: SessionCoordinator!
    private var service: BBSService!
    private var caller: BBSSimulatedCaller!
    private let secret = Data("12345678901234567890".utf8)

    override func setUp() async throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let app = AppSettingsStore(defaults: TestDefaults.make("node-mailbox-e2e-app"))
        app.myCallsign = "K0EPI"
        app.netRomNodeAlias = "EPINOD"
        app.netRomAcceptInbound = true
        let bbs = BBSSettings(defaults: TestDefaults.make("node-mailbox-e2e-bbs"))
        bbs.onAir = true
        bbs.callsign = "K0EPI-4"
        bbs.ownerCommandsEnabled = true
        coordinator = SessionCoordinator()
        coordinator.appSettings = app
        coordinator.applyNetRomNodeSettings(app)
        let simulated = BBSSimulatedCaller(manager: coordinator.sessionManager, address: AX25Address(call: "K0EPI", ssid: 3),
                                           mailbox: AX25Address(call: "EPINOD", ssid: 0))
        caller = simulated
        coordinator.sessionManager.onSendFrame = { [weak simulated] in simulated?.outbox.append($0) }
        coordinator.onFrameHandedToRadio = { [weak simulated] in simulated?.outbox.append($0) }
        service = BBSService(store: SQLiteBBSMessageStore(dbQueue: queue), settings: bbs, coordinator: coordinator,
                             sendFrames: { [weak simulated] in simulated?.outbox.append(contentsOf: $0) },
                             stationCallsign: { "K0EPI" }, isWinlinkP2PArmed: { false },
                             winlinkP2PCallsign: { "" }, linkBytesPerSecond: { 1_000_000 })
        service.ownerSecret = { [secret] in secret }
        service.attach()
    }

    override func tearDown() async throws {
        service?.shutdown(reason: "test over")
        service?.detach()
    }

    private func until(_ text: String) async -> Bool {
        await caller.pump { self.caller.text.contains(text) }
    }

    func testFromTheNodeIntoTheMailboxAndBack() async throws {
        caller.connect()
        let greeted = await until("BBS CONNECT INFO NODES ROUTES MH BYE")
        XCTAssertTrue(greeted, caller.text)
        caller.type("OWNER \(OwnerCode.code(secret: secret, at: Date()))")
        let signedIn = await until("Signed in as the owner")
        XCTAssertTrue(signedIn, caller.text)

        caller.clearReceived()
        caller.type("BBS")
        let inMailbox = await until("not met you before")
        XCTAssertTrue(inMailbox, "the full mailbox greets a first-time caller: \(caller.text)")
        caller.type("A")
        _ = await caller.pump { self.caller.text.hasSuffix(">\r") }
        caller.clearReceived()
        caller.type("ST")
        let status = await until("Mail for you")
        XCTAssertTrue(status, "still signed in, in the mailbox: \(caller.text)")

        caller.clearReceived()
        caller.type("B")
        let back = await until("Back at the node.")
        XCTAssertTrue(back, caller.text)
        caller.clearReceived()
        caller.type("ST")
        let again = await until("Mail for you")
        XCTAssertTrue(again, "still signed in, back at the node: \(caller.text)")
        XCTAssertTrue(coordinator.sessionManager.sessions.values.contains {
            $0.remoteAddress.display == "K0EPI-3" && $0.state == .connected
        }, "one link all the way through")
    }
}

/// A connect to the node's own callsign is greeted at the caller's first
/// line, or when they have not typed after a moment: a neighbor node links
/// to the same callsign to carry NET/ROM and must not get the prompt's text.
@MainActor
final class NodeGreetingWaitTests: XCTestCase {

    private var host: NetRomNodeHost!
    private var written: [Data] = []
    private var timeouts: [() -> Void] = []

    override func setUp() async throws {
        host = NetRomNodeHost()
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm 1.0") }
        host.snapshotProvider = { NetRomNodeShell.Snapshot() }
        host.scheduleTimeout = { [weak self] _, work in self?.timeouts.append(work) }
        written = []
        timeouts = []
        host.attachAX25Caller(key: "S1", callsign: "W0XYZ-1", dialed: "K0EPI-7", greetsAtFirstLine: true,
                              send: { [weak self] in self?.written.append($0) }, hangUp: {})
    }

    private var text: String { String(decoding: Data(written.flatMap { $0 }), as: UTF8.self) }

    func testNothingIsSentUntilTheCallerTypes() {
        XCTAssertEqual(text, "")
        host.ax25CallerReceived(key: "S1", data: Data("ROUTES\r".utf8))
        XCTAssertTrue(text.hasPrefix("AXTerm 1.0 Node EPINOD:K0EPI-7"), text)
        XCTAssertTrue(text.contains("Routes"), "then the line is answered: \(text)")
    }

    func testACallerWhoWaitsIsGreetedAfterAMoment() {
        XCTAssertEqual(timeouts.count, 1)
        timeouts.first?()
        XCTAssertTrue(text.hasPrefix("AXTerm 1.0 Node EPINOD:K0EPI-7"), text)
    }

    func testANeighborsLinkIsLetGoWithoutAWord() {
        host.ax25CallerYielded(key: "S1")
        timeouts.first?()
        XCTAssertEqual(text, "")
    }
}
