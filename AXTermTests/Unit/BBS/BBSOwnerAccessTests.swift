//
//  BBSOwnerAccessTests.swift
//  AXTermTests
//
//  The mailbox end to end, with the operator calling from the road on their
//  own callsign (Docs/RemoteAccessPlan.md, "Signing in"): OWNER with the
//  code signs in and is logged at home, ST shows the station, and with
//  owner commands off, or without a secret, OWNER is an unknown command.
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class BBSOwnerAccessTests: XCTestCase {

    private var store: SQLiteBBSMessageStore!
    private var settings: BBSSettings!
    private var coordinator: SessionCoordinator!
    private var service: BBSService!
    private var caller: BBSSimulatedCaller!
    private let secret = Data("12345678901234567890".utf8)
    private let mailboxAddress = AX25Address(call: "K0EPI", ssid: 4)

    override func setUp() async throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)
        settings = BBSSettings(defaults: TestDefaults.make("bbs-owner-tests"))
        settings.onAir = true
        settings.callsign = "K0EPI-4"
        settings.ownerCommandsEnabled = true
        coordinator = SessionCoordinator()
    }

    override func tearDown() async throws {
        service?.shutdown(reason: "test over")
        service?.detach()
    }

    private func connect(as call: AX25Address) async {
        let simulated = BBSSimulatedCaller(manager: coordinator.sessionManager, address: call,
                                           mailbox: mailboxAddress)
        caller = simulated
        coordinator.sessionManager.onSendFrame = { [weak simulated] in simulated?.outbox.append($0) }
        service = BBSService(store: store, settings: settings, coordinator: coordinator,
                             sendFrames: { [weak simulated] in simulated?.outbox.append(contentsOf: $0) },
                             stationCallsign: { "K0EPI" }, isWinlinkP2PArmed: { false },
                             winlinkP2PCallsign: { "" }, linkBytesPerSecond: { 1_000_000 })
        service.ownerSecret = { [secret] in secret }
        service.attach()
        caller.connect()
        _ = await caller.pump { self.caller.text.contains("not met you before") }
        caller.type("A")
        _ = await caller.pump { self.caller.text.hasSuffix(">\r") }
        caller.clearReceived()
    }

    private func command(_ line: String) async -> String {
        caller.clearReceived()
        caller.type(line)
        _ = await caller.pump { self.caller.text.hasSuffix(">\r") }
        return caller.text
    }

    func testTheOwnerSignsInAndSeesTheStation() async {
        await connect(as: AX25Address(call: "K0EPI", ssid: 3))
        let signIn = await command("OWNER \(OwnerCode.code(secret: secret, at: Date()))")
        XCTAssertTrue(signIn.contains("Signed in as the owner"), signIn)
        XCTAssertTrue(service.transcript.contains { $0.text.contains("signed in as the owner") },
                      "\(service.transcript.map(\.text))")
        let status = await command("ST")
        XCTAssertTrue(status.contains("Mail for you: 0 unread"), status)
    }

    func testAWrongCodeIsLoggedAtHome() async {
        await connect(as: AX25Address(call: "K0EPI", ssid: 3))
        let reply = await command("OWNER 000000")
        XCTAssertTrue(reply.contains("That code is not right."), reply)
        XCTAssertTrue(service.transcript.contains { $0.text.contains("wrong owner code") })
    }

    func testAnotherCallsignCannotSignIn() async {
        await connect(as: AX25Address(call: "W0ARP", ssid: 1))
        let reply = await command("OWNER \(OwnerCode.code(secret: secret, at: Date()))")
        XCTAssertTrue(reply.hasPrefix("? OWNER"), reply)
    }

    func testOffMeansUnknown() async {
        settings.ownerCommandsEnabled = false
        await connect(as: AX25Address(call: "K0EPI", ssid: 3))
        let reply = await command("OWNER \(OwnerCode.code(secret: secret, at: Date()))")
        XCTAssertTrue(reply.hasPrefix("? OWNER"), reply)
    }

    /// Owner settings changed while a call is up reach that call. The
    /// operator turned code sign-in on, and later paired the iPad, with the
    /// iPad already connected; the call kept what it saw at connect and
    /// answered `? OWNER`, then took `OWNER KEY` for a wrong code (remote
    /// access test 2026-10-11, findings 8 and 10).
    func testOwnerSettingsChangedDuringACallApplyToIt() async {
        settings.ownerCommandsEnabled = false
        await connect(as: AX25Address(call: "K0EPI", ssid: 3))
        settings.ownerCommandsEnabled = true
        let signIn = await command("OWNER \(OwnerCode.code(secret: secret, at: Date()))")
        XCTAssertTrue(signIn.contains("Signed in as the owner"), signIn)
    }

    func testADevicePairedDuringACallCanSignIn() async {
        await connect(as: AX25Address(call: "K0EPI", ssid: 3))
        settings.ownerDevices = [OwnerKey.PairedDevice(name: "iPad", publicKey: "AAAA")]
        let reply = await command("OWNER KEY")
        XCTAssertTrue(reply.contains(OwnerKey.challengePrefix), reply)
    }
}

