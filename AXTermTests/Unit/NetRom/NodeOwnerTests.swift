//
//  NodeOwnerTests.swift
//  AXTermTests
//
//  The node as a second door to the station's remote control (operator,
//  2026-10-12): it lists what it offers, the operator signs in and runs
//  control commands there as at the mailbox, and a sign-in carries into
//  the mailbox reached through it and back. A NET/ROM circuit is not a
//  direct control link, so it may read but not change the station.
//

import CryptoKit
import XCTest
@testable import AXTerm

final class NetRomNodeShellOwnerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private let whereCommand = OwnerControlCommand(name: "WHERE", help: "the 705's frequency", argument: .none,
                                                   action: .rigctl(host: "localhost", port: 4533, set: "f", read: nil),
                                                   changesTransmission: false)

    private func shell(caller: String = "K0EPI-3") -> NetRomNodeShell {
        var shell = NetRomNodeShell(nodeAlias: "EPINOD", nodeCall: "K0EPI-7", version: "AXTerm 1.0", caller: caller)
        if BBSShell.isOwnerCallsign(caller, station: "K0EPI-7") {
            shell.owner.checkOwnerCode = { _, _ in .accepted }
        }
        shell.owner.controls = [whereCommand]
        return shell
    }

    private var snapshot: NetRomNodeShell.Snapshot {
        var snapshot = NetRomNodeShell.Snapshot()
        snapshot.bbsAvailable = true
        snapshot.ownerStatus = ["Mail for you: 1 unread"]
        return snapshot
    }

    /// BPQ-style: the choices up front, not only after a wrong guess.
    func testTheGreetingListsWhatTheNodeOffers() {
        XCTAssertEqual(shell().greeting(snapshot: snapshot).lines,
                       ["AXTerm 1.0 Node EPINOD:K0EPI-7", "BBS CONNECT INFO NODES ROUTES MH TALK BYE  (? for help)"])
        var off = snapshot
        off.bbsAvailable = false
        XCTAssertEqual(shell().greeting(snapshot: off).lines.last, "CONNECT INFO NODES ROUTES MH TALK BYE  (? for help)")
    }

    func testTheOwnerSignsInAtTheNode() {
        var sut = shell()
        let signIn = sut.handle(line: "OWNER 123456", snapshot: snapshot, now: now)
        XCTAssertEqual(signIn.effects, [.ownerSignIn(accepted: true)])
        XCTAssertEqual(signIn.prompt, "EPINOD:K0EPI-7} ")
        XCTAssertEqual(sut.handle(line: "ST", snapshot: snapshot, now: now).lines, ["Mail for you: 1 unread"])
    }

    /// The command runs, and the host writes the prompt after its answer.
    func testAControlCommandRunsAtTheNode() {
        var sut = shell()
        _ = sut.handle(line: "OWNER 123456", snapshot: snapshot, now: now)
        let out = sut.handle(line: "WHERE", snapshot: snapshot, now: now)
        XCTAssertEqual(out.effects, [.runControl(whereCommand, argument: "")])
        XCTAssertNil(out.prompt)
    }

    func testAnotherCallerHasNoOwnerCommands() {
        var sut = shell(caller: "W0ARP-1")
        XCTAssertTrue(sut.handle(line: "OWNER 123456", snapshot: snapshot, now: now).lines.first?
            .hasPrefix("? OWNER") ?? false)
    }

    func testHelpShowsTheOwnersCommandsToTheOwnerOnly() {
        var mine = shell()
        XCTAssertTrue(mine.handle(line: "?", snapshot: snapshot, now: now).lines.contains("WHERE      the 705's frequency"))
        var theirs = shell(caller: "W0ARP-1")
        XCTAssertFalse(theirs.handle(line: "?", snapshot: snapshot, now: now).lines.contains { $0.hasPrefix("OWNER") })
    }
}

@MainActor
final class NetRomNodeHostOwnerTests: XCTestCase {

    private final class FakeRig: RigctlTransport, @unchecked Sendable {
        var sent: [String] = []
        func exchange(host: String, port: Int, line: String) async throws -> [String] {
            sent.append(line)
            switch line {
            case "f": return ["146520000"]
            case "l RFPOWER": return ["0.500000"]
            default: return ["RPRT 0"]
            }
        }
    }

    private final class NoScripts: ScriptRunning, @unchecked Sendable {
        func run(script: String, arguments: [String]) async throws -> [String] { [] }
    }

    /// A mailbox that keeps the console it is handed and gives it back.
    nonisolated final class OwnerAwareMailbox: NodeMailboxSession {
        nonisolated(unsafe) var sawOwner: [Bool] = []
        nonisolated(unsafe) var closeOnNext = false
        @MainActor func greeting() -> (lines: [String], prompt: String?) { (["Mailbox open."], "BBS> ") }
        @MainActor func handle(line: String, owner: inout OwnerConsole) -> NodeMailboxReply {
            sawOwner.append(owner.isOwner)
            return closeOnNext ? NodeMailboxReply(lines: ["73."], prompt: nil, closed: true)
                               : NodeMailboxReply(lines: ["ok"], prompt: "BBS> ", closed: false)
        }
    }

    private let secret = Data("12345678901234567890".utf8)
    private let device = P256.KeyAgreement.PrivateKey()
    private let rig = FakeRig()
    private var host: NetRomNodeHost!
    private var control: RemoteControlService!
    private var written: [Data] = []

    override func setUp() async throws {
        let defaults = TestDefaults.make("node-owner")
        let settings = BBSSettings(defaults: defaults)
        settings.ownerCommandsEnabled = true
        settings.ownerDevices = [OwnerKey.PairedDevice(name: "iPhone", publicKey: OwnerKey.encode(device.publicKey))]
        settings.ownerControlCommands = OwnerControlCommand.radioPreset
        settings.controlRadios = ControlRadio.warblerPreset
        control = RemoteControlService(settings: settings, defaults: defaults)
        control.ownerSecret = { [secret] in secret }
        control.runner = OwnerControlRunner(rigctl: rig, scripts: NoScripts())
        control.linkFrequencyHz = { _ in 145_650_000 }
        host = NetRomNodeHost()
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm 1.0") }
        host.snapshotProvider = {
            var snapshot = NetRomNodeShell.Snapshot()
            snapshot.bbsAvailable = true
            snapshot.ownerStatus = ["Mail for you: 0 unread"]
            return snapshot
        }
        host.remoteControlProvider = { [weak self] in self?.control }
        written = []
    }

    private func attach(digipeated: Bool = false) {
        host.attachAX25Caller(key: "S1", callsign: "K0EPI-3", dialed: "EPINOD", radio: .primary,
                              digipeated: digipeated,
                              send: { [weak self] in self?.written.append($0) }, hangUp: {})
    }

    private var text: String { String(decoding: Data(written.flatMap { $0 }), as: UTF8.self) }

    private func type(_ line: String) {
        host.ax25CallerReceived(key: "S1", data: Data((line + "\r").utf8))
    }

    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    /// Signs in by key, as the iPhone does, and returns the session key.
    private func signInByKey() throws -> SymmetricKey {
        written = []
        type("OWNER KEY")
        let line = try XCTUnwrap(text.split(separator: "\r").map(String.init).first { $0.hasPrefix(OwnerKey.challengePrefix) })
        let oneTime = try XCTUnwrap(OwnerKey.challenge(inLine: line))
        // The device signs for the station it dialed: the node's alias here.
        let key = try XCTUnwrap(OwnerKey.sessionKey(mine: device, theirs: oneTime, station: "EPINOD", caller: "K0EPI-3"))
        type("OWNER MAC " + OwnerKey.check(key: key, counter: 0, command: "", length: 16))
        XCTAssertTrue(text.contains("Signed in as the owner"), text)
        return key
    }

    func testTheGreetingListsWhatTheNodeOffers() {
        attach()
        XCTAssertTrue(text.contains("BBS CONNECT INFO NODES ROUTES MH TALK BYE"), text)
    }

    func testAReadingCommandAnswersAtTheNode() async {
        attach()
        type("OWNER \(OwnerCode.code(secret: secret, at: Date()))")
        written = []
        type("PWR 705")
        await settle()
        XCTAssertTrue(text.contains("PWR 705: 5.0 W\rEPINOD:K0EPI-7} "), text)
        XCTAssertTrue(control.log.contains { $0.door == "node" && $0.text == "ran PWR 705" })
    }

    func testSettingPowerAtTheNodeOverADirectLink() async throws {
        attach()
        let key = try signInByKey()
        written = []
        type("!" + OwnerKey.check(key: key, counter: 1, command: "PWR 710 50", length: 4) + " PWR 710 50")
        await settle()
        XCTAssertTrue(text.contains("PWR 710: done, 50 W."), text)
        XCTAssertEqual(rig.sent.last, "L RFPOWER 0.502500")
    }

    /// The node's AX.25 link fails: what was changed goes back.
    func testAFailedLinkPutsTheChangeBack() async throws {
        attach()
        let key = try signInByKey()
        type("!" + OwnerKey.check(key: key, counter: 1, command: "PWR 710 50", length: 4) + " PWR 710 50")
        await settle()
        host.ax25CallerClosed(key: "S1", failed: true)
        await settle()
        XCTAssertEqual(rig.sent.last, "L RFPOWER 0.500000")
    }

    func testADigipeatedLinkCannotChangeTheStation() async throws {
        attach(digipeated: true)
        let key = try signInByKey()
        written = []
        type("!" + OwnerKey.check(key: key, counter: 1, command: "PWR 710 50", length: 4) + " PWR 710 50")
        await settle()
        XCTAssertTrue(text.contains("PWR 710: it needs a direct link, not one through a digipeater."), text)
    }

    /// Signed in at the node, the caller is signed in at the mailbox, and
    /// still at the node when they come back.
    func testTheSignInCarriesIntoTheMailboxAndBack() {
        let mailbox = OwnerAwareMailbox()
        host.bbsSessionFactory = { _ in mailbox }
        attach()
        type("OWNER \(OwnerCode.code(secret: secret, at: Date()))")
        type("BBS")
        type("L")
        XCTAssertEqual(mailbox.sawOwner, [true])
        mailbox.closeOnNext = true
        type("B")
        written = []
        type("ST")
        XCTAssertTrue(text.contains("Mail for you: 0 unread"), text)
    }
}
