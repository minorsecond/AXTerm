//
//  BBSOwnerControlServiceTests.swift
//  AXTermTests
//
//  Control commands end to end at the mailbox: what runs, where it may run,
//  and the fail-safe. 97.213 allows a station to be controlled over a radio
//  link that is an auxiliary station (2 m and up, outside 144.0-144.5,
//  145.8-146.0, 219-220, 222.00-222.15, 431-433 and 435-438 MHz), and asks
//  that it stop within 3 minutes if the control link fails. So a command
//  that changes how the station transmits runs only on a direct link on
//  such a frequency, and what it changed is put back when the link fails or
//  nothing is heard from the operator for two and a half minutes. Ending
//  the call cleanly keeps the change.
//

import CryptoKit
import GRDB
import XCTest
@testable import AXTerm

final class TelecommandLinkTests: XCTestCase {

    func testTwoMetersOutsideTheExcludedSegmentsIsAllowed() {
        XCTAssertNil(TelecommandLink.refusal(frequencyHz: 145_650_000, digipeated: false))
        XCTAssertNil(TelecommandLink.refusal(frequencyHz: 446_000_000, digipeated: false))
    }

    func testTheExcludedSegmentsAreRefused() {
        for hz in [144_390_000, 145_900_000, 219_500_000, 222_100_000, 432_100_000, 436_000_000] {
            XCTAssertNotNil(TelecommandLink.refusal(frequencyHz: hz, digipeated: false), "\(hz)")
        }
    }

    func testHFIsRefused() {
        XCTAssertEqual(TelecommandLink.refusal(frequencyHz: 14_105_000, digipeated: false),
                       "this link is on 14.105 MHz, where 97.201 does not allow a control link.")
    }

    func testAnUnknownFrequencyIsRefused() {
        XCTAssertEqual(TelecommandLink.refusal(frequencyHz: nil, digipeated: false),
                       "AXTerm cannot tell which frequency this link is on.")
    }

    func testADigipeatedLinkIsRefused() {
        XCTAssertEqual(TelecommandLink.refusal(frequencyHz: 145_650_000, digipeated: true),
                       "it needs a direct link, not one through a digipeater.")
    }
}

@MainActor
final class BBSOwnerControlServiceTests: XCTestCase {

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

    private var store: SQLiteBBSMessageStore!
    private var settings: BBSSettings!
    private var coordinator: SessionCoordinator!
    private var service: BBSService!
    private var caller: BBSSimulatedCaller!
    private let rig = FakeRig()
    private let device = P256.KeyAgreement.PrivateKey()
    private let secret = Data("12345678901234567890".utf8)
    private let mailboxAddress = AX25Address(call: "K0EPI", ssid: 4)
    private var counter: UInt64 = 1
    private var sessionKey: SymmetricKey!

    private let freq = OwnerControlCommand(name: "FREQ", help: "tune the 705",
                                           argument: .number(min: 144e6, max: 148e6),
                                           action: .rigctl(host: "localhost", port: 4533, set: "F {arg}", read: "f"),
                                           changesTransmission: true)
    private let power = OwnerControlCommand(name: "PWR", help: "the 705's power", argument: .none,
                                            action: .rigctl(host: "localhost", port: 4533, set: "l RFPOWER", read: nil),
                                            changesTransmission: false)

    override func setUp() async throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)
        settings = BBSSettings(defaults: TestDefaults.make("bbs-owner-control-tests"))
        settings.onAir = true
        settings.callsign = "K0EPI-4"
        settings.ownerCommandsEnabled = true
        settings.ownerDevices = [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))]
        settings.ownerControlCommands = [freq, power]
        coordinator = SessionCoordinator()
    }

    override func tearDown() async throws {
        service?.shutdown(reason: "test over")
        service?.detach()
    }

    private func connect(frequencyHz: Int? = 145_650_000, silence: Duration = .seconds(150)) async {
        let simulated = BBSSimulatedCaller(manager: coordinator.sessionManager, address: AX25Address(call: "K0EPI", ssid: 3),
                                           mailbox: mailboxAddress)
        caller = simulated
        coordinator.sessionManager.onSendFrame = { [weak simulated] in simulated?.outbox.append($0) }
        service = BBSService(store: store, settings: settings, coordinator: coordinator,
                             sendFrames: { [weak simulated] in simulated?.outbox.append(contentsOf: $0) },
                             stationCallsign: { "K0EPI" }, isWinlinkP2PArmed: { false },
                             winlinkP2PCallsign: { "" }, linkBytesPerSecond: { 1_000_000 })
        service.ownerSecret = { [secret] in secret }
        service.controlRunner = OwnerControlRunner(rigctl: rig, scripts: NoScripts())
        service.linkFrequencyHz = { _ in frequencyHz }
        service.controlSilenceLimit = silence
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

    private func signInByKey() async throws {
        let reply = await command("OWNER KEY")
        let line = try XCTUnwrap(reply.split(separator: "\r").map(String.init).first { $0.hasPrefix(OwnerKey.challengePrefix) })
        let oneTime = try XCTUnwrap(OwnerKey.challenge(inLine: line))
        sessionKey = try XCTUnwrap(OwnerKey.sessionKey(mine: device, theirs: oneTime, station: "K0EPI-4", caller: "K0EPI-3"))
        let signedIn = await command("OWNER MAC " + OwnerKey.check(key: sessionKey, counter: 0, command: "", length: 16))
        XCTAssertTrue(signedIn.contains("Signed in as the owner"), signedIn)
        counter = 1
    }

    private func checked(_ text: String) async -> String {
        let line = "!" + OwnerKey.check(key: sessionKey, counter: counter, command: text, length: 4) + " " + text
        counter += 1
        return await command(line)
    }

    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    /// What it said, then the prompt, once the command has run.
    func testAReadingCommandAnswersAndThenThePrompt() async throws {
        await connect()
        _ = await command("OWNER \(OwnerCode.code(secret: secret, at: Date()))")
        let reply = await command("PWR")
        XCTAssertTrue(reply.contains("PWR: 0.500000\r>\r"), reply)
        XCTAssertTrue(service.transcript.contains { $0.text.contains("ran PWR") })
    }

    func testATransmittingCommandRunsOnAnAllowedDirectLink() async throws {
        await connect()
        try await signInByKey()
        let reply = await checked("FREQ 145650000")
        XCTAssertTrue(reply.contains("FREQ: done."), reply)
        XCTAssertEqual(rig.sent, ["f", "F 145650000"])
    }

    func testATransmittingCommandIsRefusedOnHF() async throws {
        await connect(frequencyHz: 14_105_000)
        try await signInByKey()
        let reply = await checked("FREQ 145650000")
        XCTAssertTrue(reply.contains("FREQ: this link is on 14.105 MHz, where 97.201 does not allow a control link."),
                      reply)
        XCTAssertEqual(rig.sent, [])
    }

    /// The link fails: what the command changed is put back.
    func testAChangeIsPutBackWhenTheLinkFails() async throws {
        await connect()
        try await signInByKey()
        _ = await checked("FREQ 145650000")
        coordinator.sessionManager.handleInboundFRMR(from: caller.address, path: DigiPath(), radio: .primary)
        await settle()
        XCTAssertEqual(rig.sent.last, "F 146520000")
        XCTAssertTrue(service.transcript.contains { $0.text.contains("put back: F 146520000") },
                      "\(service.transcript.map(\.text))")
        // The call has ended by now; the restore still goes in its log.
        let actions = try XCTUnwrap(store.recentCalls(limit: 1).first?.actions)
        XCTAssertEqual(actions.suffix(2), ["fail-safe: the link failed", "put back: F 146520000"])
    }

    /// Nothing heard from the operator for the limit: put back, and said.
    func testAChangeIsPutBackWhenTheLinkGoesQuiet() async throws {
        await connect(silence: .milliseconds(400))
        try await signInByKey()
        _ = await checked("FREQ 145650000")
        _ = await caller.pump(timeout: 3) { self.caller.text.contains("Nothing heard from you") }
        await settle()
        XCTAssertEqual(rig.sent.last, "F 146520000")
        XCTAssertTrue(caller.text.contains("Nothing heard from you: put back FREQ."), caller.text)
        // In the call log with the commands, as the docs promise; it used to
        // reach only the transcript on screen (2026-10-12).
        let actions = try XCTUnwrap(store.recentCalls(limit: 1).first?.actions)
        XCTAssertEqual(actions.suffix(2), ["fail-safe: nothing heard from the operator", "put back: F 146520000"])
    }

    /// Something heard from the operator keeps the change in place.
    func testTypingKeepsItInPlace() async throws {
        await connect(silence: .milliseconds(600))
        try await signInByKey()
        _ = await checked("FREQ 145650000")
        await settle(0.4)
        _ = await command("V")
        await settle(0.4)
        XCTAssertEqual(rig.sent, ["f", "F 145650000"])
    }

    /// Ending the call on purpose keeps the change.
    func testACleanDisconnectKeepsTheChange() async throws {
        await connect(silence: .milliseconds(400))
        try await signInByKey()
        _ = await checked("FREQ 145650000")
        caller.disconnect()
        await settle(0.8)
        XCTAssertEqual(rig.sent, ["f", "F 145650000"])
    }
}
