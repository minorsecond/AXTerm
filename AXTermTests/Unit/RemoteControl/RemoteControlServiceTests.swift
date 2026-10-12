//
//  RemoteControlServiceTests.swift
//  AXTermTests
//
//  One remote-control service for the station, which the mailbox and the
//  node both use (operator, 2026-10-12): the same codes and keys at every
//  door, one lockout, one fail-safe per link, one log.
//

import XCTest
@testable import AXTerm

@MainActor
final class RemoteControlServiceTests: XCTestCase {

    private final class FakeRig: RigctlTransport, @unchecked Sendable {
        var sent: [String] = []
        func exchange(host: String, port: Int, line: String) async throws -> [String] {
            sent.append(line)
            return line == "f" ? ["146520000"] : ["RPRT 0"]
        }
    }

    private final class NoScripts: ScriptRunning, @unchecked Sendable {
        func run(script: String, arguments: [String]) async throws -> [String] { [] }
    }

    private let secret = Data("12345678901234567890".utf8)
    private let rig = FakeRig()
    private let freq = OwnerControlCommand(name: "FREQ", help: "", argument: .number(min: 144e6, max: 148e6),
                                           action: .rigctl(host: "localhost", port: 4533, set: "F {arg}", read: "f"),
                                           changesTransmission: true)

    private func service(_ label: String, silence: Duration = .seconds(150)) -> RemoteControlService {
        let defaults = TestDefaults.make(label)
        let settings = BBSSettings(defaults: defaults)
        settings.ownerCommandsEnabled = true
        let service = RemoteControlService(settings: settings, defaults: defaults)
        service.ownerSecret = { [secret] in secret }
        service.runner = OwnerControlRunner(rigctl: rig, scripts: NoScripts())
        service.linkFrequencyHz = { _ in 145_650_000 }
        service.silenceLimit = silence
        return service
    }

    private let direct = RemoteControlService.LinkFacts(radio: .primary, digipeated: false, relayed: false)

    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    // MARK: - One sign-in for every door

    /// Three wrong codes at the mailbox lock the node out too: switching
    /// doors gives no more guesses.
    func testTheLockoutCoversEveryDoor() throws {
        let sut = service("rc-lockout")
        let atMailbox = try XCTUnwrap(sut.codeCheck(for: "K0EPI-3", station: "K0EPI-4"))
        let atNode = try XCTUnwrap(sut.codeCheck(for: "K0EPI-3", station: "K0EPI-7"))
        let now = Date()
        for _ in 0..<3 { _ = atMailbox("000000", now) }
        XCTAssertEqual(atNode(OwnerCode.code(secret: secret, at: now), now), .lockedOut)
    }

    /// A code used at one door is used at the other.
    func testACodeWorksOnceAcrossDoors() throws {
        let sut = service("rc-once")
        let now = Date()
        let code = OwnerCode.code(secret: secret, at: now)
        XCTAssertEqual(try XCTUnwrap(sut.codeCheck(for: "K0EPI-3", station: "K0EPI-4"))(code, now), .accepted)
        XCTAssertEqual(try XCTUnwrap(sut.codeCheck(for: "K0EPI-3", station: "K0EPI-7"))(code, now), .used)
    }

    func testOnlyTheOperatorsCallsignIsOffered() {
        let sut = service("rc-callsign")
        XCTAssertNil(sut.codeCheck(for: "W0ARP-1", station: "K0EPI-4"))
        XCTAssertNotNil(sut.codeCheck(for: "K0EPI-9", station: "K0EPI-4"))
    }

    // MARK: - The fail-safe, per link

    func testAFailedLinkPutsItsChangesBack() async {
        let sut = service("rc-failed")
        var said: [String] = []
        sut.run(freq, argument: "145650000", link: "node:K0EPI-3", facts: direct, caller: "K0EPI-3", door: "node",
                write: { said += $0 }, prompt: nil)
        await settle()
        XCTAssertEqual(said, ["FREQ: done."])
        sut.linkEnded("node:K0EPI-3", failed: true)
        await settle()
        XCTAssertEqual(rig.sent.last, "F 146520000")
        XCTAssertTrue(sut.log.contains { $0.text == "put back: F 146520000" && $0.door == "node" },
                      "\(sut.log.map(\.text))")
    }

    func testHangingUpKeepsTheChange() async {
        let sut = service("rc-hangup")
        sut.run(freq, argument: "145650000", link: "bbs:K0EPI-3", facts: direct, caller: "K0EPI-3", door: "mailbox",
                write: { _ in }, prompt: nil)
        await settle()
        sut.linkEnded("bbs:K0EPI-3", failed: false)
        await settle()
        XCTAssertEqual(rig.sent, ["f", "F 145650000"])
    }

    func testSilencePutsItBackAndSaysSo() async {
        let sut = service("rc-silence", silence: .milliseconds(300))
        var said: [String] = []
        sut.run(freq, argument: "145650000", link: "bbs:K0EPI-3", facts: direct, caller: "K0EPI-3", door: "mailbox",
                write: { said += $0 }, prompt: nil)
        await settle(0.8)
        XCTAssertEqual(rig.sent.last, "F 146520000")
        XCTAssertTrue(said.contains("Nothing heard from you: put back FREQ."), "\(said)")
    }

    func testHearingTheOperatorKeepsIt() async {
        let sut = service("rc-heard", silence: .milliseconds(500))
        sut.run(freq, argument: "145650000", link: "bbs:K0EPI-3", facts: direct, caller: "K0EPI-3", door: "mailbox",
                write: { _ in }, prompt: nil)
        await settle(0.3)
        sut.heard("bbs:K0EPI-3")
        await settle(0.3)
        XCTAssertEqual(rig.sent, ["f", "F 145650000"])
    }

    /// Each link has its own: one ending puts back only its own changes.
    func testLinksAreKeptApart() async {
        let sut = service("rc-apart")
        sut.run(freq, argument: "145650000", link: "bbs:K0EPI-3", facts: direct, caller: "K0EPI-3", door: "mailbox",
                write: { _ in }, prompt: nil)
        await settle()
        sut.linkEnded("node:K0EPI-9", failed: true)
        await settle()
        XCTAssertEqual(rig.sent, ["f", "F 145650000"])
    }

    // MARK: - The control link

    /// A NET/ROM circuit is other stations relaying, not the control link.
    func testACircuitCannotChangeTheStation() async {
        let sut = service("rc-circuit")
        var said: [String] = []
        sut.run(freq, argument: "145650000", link: "node:K0EPI-3",
                facts: RemoteControlService.LinkFacts(radio: .primary, digipeated: false, relayed: true),
                caller: "K0EPI-3", door: "node", write: { said += $0 }, prompt: ">")
        await settle()
        XCTAssertEqual(said, ["FREQ: it needs a direct link, not one through a NET/ROM circuit.", ">"])
        XCTAssertEqual(rig.sent, [])
    }

    func testTheLogSurvivesARestart() async {
        let defaults = TestDefaults.make("rc-log")
        let settings = BBSSettings(defaults: defaults)
        let first = RemoteControlService(settings: settings, defaults: defaults)
        first.record("signed in as the owner", caller: "K0EPI-3", door: "node")
        let again = RemoteControlService(settings: settings, defaults: defaults)
        XCTAssertEqual(again.log.last?.text, "signed in as the owner")
        XCTAssertEqual(again.log.last?.door, "node")
    }

    /// The settings page reads the log without the service running there.
    func testTheSettingsPageCanReadTheLog() {
        let defaults = TestDefaults.make("rc-log-page")
        let service = RemoteControlService(settings: BBSSettings(defaults: defaults), defaults: defaults)
        service.record("ran PWR 705", caller: "K0EPI-3", door: "node")
        XCTAssertEqual(RemoteControlService.storedLog(defaults: defaults).map(\.text), ["ran PWR 705"])
    }
}

