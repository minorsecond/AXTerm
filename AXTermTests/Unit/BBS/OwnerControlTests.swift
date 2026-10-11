//
//  OwnerControlTests.swift
//  AXTermTests
//
//  Owner control commands the operator defines at home (operator,
//  2026-10-11: "an api ... so owners can set up control commands", such as
//  driving the IC-705 through Warbler). Each has a name, a help line, a rule
//  for its argument, and an action: a Hamlib rigctl command or a script in
//  AXTerm's Application Scripts folder. One that changes how the station
//  transmits must say how to put the change back, for the 3-minute
//  fail-safe 97.213(b) asks for.
//

import CryptoKit
import XCTest
@testable import AXTerm

final class OwnerControlTests: XCTestCase {

    private func freq() -> OwnerControlCommand {
        OwnerControlCommand(name: "FREQ", help: "tune the 705", argument: .number(min: 144_000_000, max: 148_000_000),
                            action: .rigctl(host: "localhost", port: 4533, set: "F {arg}", read: "f"),
                            changesTransmission: true)
    }

    // MARK: - Arguments

    func testANumberMustBeInRange() {
        let rule = OwnerControlCommand.ArgumentRule.number(min: 0, max: 1)
        XCTAssertEqual(rule.accept("0.5"), .success("0.5"))
        XCTAssertEqual(rule.accept("1"), .success("1"))
        XCTAssertEqual(rule.accept("1.5"), .failure(.outOfRange("0", "1")))
        XCTAssertEqual(rule.accept("-0.1"), .failure(.outOfRange("0", "1")))
    }

    /// Only digits, one point and a leading minus: nothing that could
    /// reach rigctl or a script as anything but a number.
    func testANumberIsOnlyANumber() {
        let rule = OwnerControlCommand.ArgumentRule.number(min: 0, max: 1e12)
        for text in ["", "1e9", "0x10", "12 3", "5;F 1", "1\nT 1", "nan", "inf", "1.2.3", "+1"] {
            XCTAssertEqual(rule.accept(text), .failure(.notANumber), text)
        }
        XCTAssertEqual(rule.accept("145650000"), .success("145650000"))
    }

    /// One of a list, in any case, given back as the list spells it.
    func testAChoiceIsOneOfTheList() {
        let rule = OwnerControlCommand.ArgumentRule.choice(["FM", "USB", "LSB"])
        XCTAssertEqual(rule.accept("usb"), .success("USB"))
        XCTAssertEqual(rule.accept("AM"), .failure(.notAChoice(["FM", "USB", "LSB"])))
    }

    func testNoArgumentMeansNone() {
        let rule = OwnerControlCommand.ArgumentRule.none
        XCTAssertEqual(rule.accept(""), .success(""))
        XCTAssertEqual(rule.accept("x"), .failure(.unexpected))
    }

    // MARK: - Definitions

    func testAGoodDefinitionPasses() {
        XCTAssertNil(freq().problem(among: []))
    }

    /// A name is the word typed: letters and digits, up to 8, not one of
    /// the mailbox's own commands and not used twice.
    func testTheNameIsAWordOfItsOwn() {
        var command = freq()
        command.name = "L"
        XCTAssertEqual(command.problem(among: []), "L is one of the mailbox's own commands.")
        command.name = "FREQ 2"
        XCTAssertEqual(command.problem(among: []), "A name is 1 to 8 letters and digits.")
        command.name = "TOOLONGNAME"
        XCTAssertEqual(command.problem(among: []), "A name is 1 to 8 letters and digits.")
        command.name = "FREQ"
        var other = freq()
        other.id = UUID()
        XCTAssertEqual(command.problem(among: [other]), "There is already a command called FREQ.")
    }

    /// The fail-safe has to be able to put a transmitting change back.
    func testATransmittingCommandSaysHowToPutItBack() {
        var command = freq()
        command.action = .rigctl(host: "localhost", port: 4533, set: "F {arg}", read: nil)
        XCTAssertEqual(command.problem(among: []),
                       "It changes how the station transmits, so it needs a way to put that back.")
        command.action = .script(name: "power.sh", restore: nil)
        XCTAssertEqual(command.problem(among: []),
                       "It changes how the station transmits, so it needs a way to put that back.")
        command.changesTransmission = false
        XCTAssertNil(command.problem(among: []))
    }

    /// A script is a file name in the scripts folder, never a path.
    func testAScriptIsAFileInTheFolder() {
        var command = freq()
        command.changesTransmission = false
        command.action = .script(name: "../bin/sh", restore: nil)
        XCTAssertEqual(command.problem(among: []), "A script is a file name in AXTerm's scripts folder.")
    }

    /// A rigctl command is one line.
    func testARigctlCommandIsOneLine() {
        var command = freq()
        command.action = .rigctl(host: "localhost", port: 4533, set: "F {arg}\nT 1", read: "f")
        XCTAssertEqual(command.problem(among: []), "A rigctl command is one line.")
    }

    func testTheRigctlLineTakesTheArgument() {
        XCTAssertEqual(OwnerControlCommand.fill("F {arg}", with: "145650000"), "F 145650000")
        XCTAssertEqual(OwnerControlCommand.fill("f", with: ""), "f")
    }

    @MainActor
    func testDefinitionsSurviveARestart() throws {
        let defaults = TestDefaults.make("owner-control-settings")
        let settings = BBSSettings(defaults: defaults)
        settings.ownerControlCommands = [freq()]
        XCTAssertEqual(BBSSettings(defaults: defaults).ownerControlCommands, settings.ownerControlCommands)
    }
}

/// The mailbox running them.
final class BBSShellOwnerControlTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let device = P256.KeyAgreement.PrivateKey()
    private let freq = OwnerControlCommand(name: "FREQ", help: "tune the 705",
                                           argument: .number(min: 144_000_000, max: 148_000_000),
                                           action: .rigctl(host: "localhost", port: 4533, set: "F {arg}", read: "f"),
                                           changesTransmission: true)
    private let where_ = OwnerControlCommand(name: "WHERE", help: "the 705's frequency", argument: .none,
                                             action: .rigctl(host: "localhost", port: 4533, set: "f", read: nil),
                                             changesTransmission: false)

    private func shell(caller: String = "K0EPI-3", code: Bool = false) -> BBSShell {
        var sut = BBSShell(caller: caller, sysop: "K0EPI-4", pageRows: 0,
                           checkOwnerCode: code ? { _, _ in .accepted } : nil,
                           ownerKeys: [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))])
        sut.ownerControls = [freq, where_]
        return sut
    }

    private let box = BBSShell.Mailbox()

    /// Signs in by key; the session key and what the mailbox said.
    private func signIn(_ sut: inout BBSShell) throws -> (SymmetricKey, [String]) {
        let challenge = try XCTUnwrap(sut.handle(line: "OWNER KEY", mailbox: box, now: now).lines.first)
        let oneTime = try XCTUnwrap(OwnerKey.challenge(inLine: challenge))
        let key = try XCTUnwrap(OwnerKey.sessionKey(mine: device, theirs: oneTime, station: "K0EPI-4", caller: "K0EPI-3"))
        let lines = sut.handle(line: "OWNER MAC " + OwnerKey.check(key: key, counter: 0, command: "", length: 16),
                               mailbox: box, now: now).lines
        return (key, lines)
    }

    private func checked(_ text: String, _ counter: UInt64, _ key: SymmetricKey) -> String {
        "!" + OwnerKey.check(key: key, counter: counter, command: text, length: 4) + " " + text
    }

    func testAControlCommandNeedsASignIn() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "FREQ 145650000", mailbox: box, now: now).lines,
                       ["Sign in first: OWNER and the six-digit code from your authenticator app."])
    }

    func testACheckedControlCommandRuns() throws {
        var sut = shell()
        let (key, _) = try signIn(&sut)
        let out = sut.handle(line: checked("FREQ 145650000", 1, key), mailbox: box, now: now)
        XCTAssertEqual(out.effects, [.runControl(freq, argument: "145650000")])
        XCTAssertEqual(out.lines, [])
    }

    func testAnUncheckedControlCommandIsRefused() throws {
        var sut = shell()
        _ = try signIn(&sut)
        let out = sut.handle(line: "FREQ 145650000", mailbox: box, now: now)
        XCTAssertEqual(out.effects, [])
        XCTAssertEqual(out.lines, ["Owner commands from a paired device carry a check; AXTerm adds it for you."])
    }

    /// The sign-in names the owner commands, so the device knows which
    /// lines to add checks to without being told at its end.
    func testTheSignInNamesTheOwnerCommands() throws {
        var sut = shell()
        let (_, lines) = try signIn(&sut)
        XCTAssertEqual(lines.last, "Owner commands: ST FREQ WHERE")
    }

    /// A code is not tied to the command it comes with, so from a plain
    /// terminal only commands that read run.
    func testACodeSignInRunsOnlyReadingCommands() {
        var sut = shell(code: true)
        _ = sut.handle(line: "OWNER 123456", mailbox: box, now: now)
        XCTAssertEqual(sut.handle(line: "WHERE", mailbox: box, now: now).effects, [.runControl(where_, argument: "")])
        let tune = sut.handle(line: "FREQ 145650000", mailbox: box, now: now)
        XCTAssertEqual(tune.effects, [])
        XCTAssertEqual(tune.lines, ["FREQ changes how the station transmits: sign in with a paired AXTerm's key."])
    }

    func testABadArgumentSaysWhatFits() throws {
        var sut = shell()
        let (key, _) = try signIn(&sut)
        XCTAssertEqual(sut.handle(line: checked("FREQ 7074000", 1, key), mailbox: box, now: now).lines,
                       ["FREQ takes a number from 144000000 to 148000000."])
        XCTAssertEqual(sut.handle(line: checked("WHERE x", 2, key), mailbox: box, now: now).lines,
                       ["WHERE takes nothing after it."])
    }

    /// To anyone else they do not exist.
    func testAnotherCallerSeesUnknownCommands() {
        var sut = BBSShell(caller: "W0ARP-1", sysop: "K0EPI-4", pageRows: 0)
        sut.ownerControls = [freq]
        XCTAssertTrue(sut.handle(line: "FREQ 145650000", mailbox: box, now: now).lines.first?.hasPrefix("? FREQ") ?? false)
    }

    func testHelpListsThem() {
        var sut = shell(code: true)
        let help = sut.handle(line: "H", mailbox: box, now: now).lines
        XCTAssertTrue(help.contains("FREQ       tune the 705"), "\(help)")
        XCTAssertTrue(help.allSatisfy { $0.count < 80 })
    }

    /// A line with a check that arrives while a message is being written is
    /// kept without its check, and the counter stays in step.
    func testACheckedLineInAMessageKeepsTheCounterInStep() throws {
        var sut = shell()
        let (key, _) = try signIn(&sut)
        _ = sut.handle(line: "S K0EPI", mailbox: box, now: now)
        _ = sut.handle(line: "subject", mailbox: box, now: now)
        _ = sut.handle(line: checked("FREQ is on 2 m", 1, key), mailbox: box, now: now)
        let end = sut.handle(line: "/EX", mailbox: box, now: now)
        guard case .store(let message)? = end.effects.first else { return XCTFail("\(end)") }
        XCTAssertEqual(message.body, "FREQ is on 2 m")
        XCTAssertEqual(sut.handle(line: checked("WHERE", 2, key), mailbox: box, now: now).effects,
                       [.runControl(where_, argument: "")])
    }
}

/// The device learns the owner commands from the sign-in.
final class OwnerSignInResponderControlTests: XCTestCase {

    func testItChecksTheCommandsTheMailboxNamed() {
        let key = SymmetricKey(size: .bits256)
        var responder = OwnerSignInResponder()
        responder.begin(peer: "K0EPI-4")
        _ = responder.reply(toLine: "Owner challenge: X", from: "K0EPI-4", caller: "K0EPI-3", derive: { _, _, _ in key })
        XCTAssertNil(responder.signed(line: "FREQ 145650000", to: "K0EPI-4"))
        _ = responder.reply(toLine: "Owner commands: ST FREQ", from: "K0EPI-4", caller: "K0EPI-3", derive: { _, _, _ in key })
        XCTAssertEqual(responder.signed(line: "FREQ 145650000", to: "K0EPI-4"),
                       "!" + OwnerKey.check(key: key, counter: 1, command: "FREQ 145650000", length: 4) + " FREQ 145650000")
    }
}

/// Running them: rigctl and scripts, what the operator is told, and what
/// the fail-safe will run to put a change back.
final class OwnerControlRunnerTests: XCTestCase {

    private final class FakeRig: RigctlTransport, @unchecked Sendable {
        var replies: [String: [String]] = [:]
        var sent: [String] = []
        var unreachable = false
        func exchange(host: String, port: Int, line: String) async throws -> [String] {
            if unreachable { throw URLError(.cannotConnectToHost) }
            sent.append(line)
            return replies[line] ?? ["RPRT 0"]
        }
    }

    private final class FakeScripts: ScriptRunning, @unchecked Sendable {
        var ran: [(String, [String])] = []
        var output = ["done here"]
        func run(script: String, arguments: [String]) async throws -> [String] {
            ran.append((script, arguments))
            return output
        }
    }

    private let freq = OwnerControlCommand(name: "FREQ", help: "", argument: .number(min: 144e6, max: 148e6),
                                           action: .rigctl(host: "localhost", port: 4533, set: "F {arg}", read: "f"),
                                           changesTransmission: true)

    func testASetReadsFirstSoItCanBePutBack() async {
        let rig = FakeRig()
        rig.replies["f"] = ["146520000"]
        let result = await OwnerControlRunner(rigctl: rig, scripts: FakeScripts()).run(freq, argument: "145650000")
        XCTAssertEqual(rig.sent, ["f", "F 145650000"])
        XCTAssertEqual(result.lines, ["FREQ: done."])
        XCTAssertEqual(result.restore, .rigctl(host: "localhost", port: 4533, line: "F 146520000"))
    }

    func testTheRadioSayingNoIsPassedOn() async {
        let rig = FakeRig()
        rig.replies["f"] = ["146520000"]
        rig.replies["F 145650000"] = ["RPRT -11"]
        let result = await OwnerControlRunner(rigctl: rig, scripts: FakeScripts()).run(freq, argument: "145650000")
        XCTAssertEqual(result.lines, ["FREQ: the radio said RPRT -11."])
        XCTAssertNil(result.restore)
    }

    /// Without the value to go back to, a transmitting change is not made.
    func testNoChangeWithoutAWayBack() async {
        let rig = FakeRig()
        rig.replies["f"] = ["RPRT -1"]
        let result = await OwnerControlRunner(rigctl: rig, scripts: FakeScripts()).run(freq, argument: "145650000")
        XCTAssertEqual(rig.sent, ["f"])
        XCTAssertEqual(result.lines, ["FREQ: could not read what it is now, so nothing was changed."])
        XCTAssertNil(result.restore)
    }

    func testAReadingCommandGivesTheReply() async {
        let rig = FakeRig()
        rig.replies["l RFPOWER"] = ["0.500000"]
        let power = OwnerControlCommand(name: "PWR", help: "", argument: .none,
                                        action: .rigctl(host: "localhost", port: 4533, set: "l RFPOWER", read: nil),
                                        changesTransmission: false)
        let result = await OwnerControlRunner(rigctl: rig, scripts: FakeScripts()).run(power, argument: "")
        XCTAssertEqual(result.lines, ["PWR: 0.500000"])
        XCTAssertNil(result.restore)
    }

    func testAnUnreachableRigSaysSo() async {
        let rig = FakeRig()
        rig.unreachable = true
        let result = await OwnerControlRunner(rigctl: rig, scripts: FakeScripts()).run(freq, argument: "145650000")
        XCTAssertEqual(result.lines, ["FREQ: cannot reach localhost:4533."])
        XCTAssertNil(result.restore)
    }

    /// A script gets the argument, and a transmitting one leaves its
    /// restore script for the fail-safe.
    func testAScriptGetsTheArgument() async {
        let scripts = FakeScripts()
        let beacon = OwnerControlCommand(name: "BCN", help: "", argument: .choice(["ON", "OFF"]),
                                         action: .script(name: "beacon.sh", restore: "beacon-off.sh"),
                                         changesTransmission: true)
        let result = await OwnerControlRunner(rigctl: FakeRig(), scripts: scripts).run(beacon, argument: "ON")
        XCTAssertEqual(scripts.ran.map(\.0), ["beacon.sh"])
        XCTAssertEqual(scripts.ran.first?.1, ["ON"])
        XCTAssertEqual(result.lines, ["BCN: done here"])
        XCTAssertEqual(result.restore, .script(name: "beacon-off.sh"))
    }

    /// Long output is cut to a few short lines.
    func testOutputIsKeptShort() async {
        let scripts = FakeScripts()
        scripts.output = Array(repeating: String(repeating: "x", count: 200), count: 50)
        let show = OwnerControlCommand(name: "SHOW", help: "", argument: .none,
                                       action: .script(name: "show.sh", restore: nil), changesTransmission: false)
        let result = await OwnerControlRunner(rigctl: FakeRig(), scripts: scripts).run(show, argument: "")
        XCTAssertLessThanOrEqual(result.lines.count, OwnerControlRunner.maxLines + 1)
        XCTAssertTrue(result.lines.allSatisfy { $0.count < 80 })
    }

    /// Keying the transmitter is not a control command: nothing could
    /// promise to let go of it.
    func testAControlCommandCannotKeyTheRadio() {
        for set in ["T 1", "set_ptt 1", "\\set_ptt 1"] {
            let command = OwnerControlCommand(name: "KEY1", help: "", argument: .none,
                                              action: .rigctl(host: "localhost", port: 4533, set: set, read: "t"),
                                              changesTransmission: true)
            XCTAssertEqual(command.problem(among: []), "AXTerm does not key the transmitter from a control command.", set)
        }
    }
}

/// The settings form: what the operator types becomes a command, or a
/// sentence saying what to fix.
final class OwnerControlDraftTests: XCTestCase {

    private func freqDraft() -> OwnerControlDraft {
        var draft = OwnerControlDraft()
        draft.name = "freq"
        draft.help = "tune the 705"
        draft.argumentKind = .number
        draft.minText = "144000000"
        draft.maxText = "148000000"
        draft.actionKind = .rigctl
        draft.setText = "F {arg}"
        draft.readText = "f"
        draft.changesTransmission = true
        return draft
    }

    /// Warbler's IC-705 is the default rigctl target.
    func testANewDraftPointsAtWarblersIC705() {
        let draft = OwnerControlDraft()
        XCTAssertEqual(draft.host, "localhost")
        XCTAssertEqual(draft.portText, "4533")
    }

    func testAGoodDraftBecomesACommand() throws {
        let command = try freqDraft().build(among: []).get()
        XCTAssertEqual(command.name, "FREQ")
        XCTAssertEqual(command.argument, .number(min: 144_000_000, max: 148_000_000))
        XCTAssertEqual(command.action, .rigctl(host: "localhost", port: 4533, set: "F {arg}", read: "f"))
        XCTAssertTrue(command.changesTransmission)
    }

    func testBadNumbersSaySo() {
        var draft = freqDraft()
        draft.maxText = "lots"
        XCTAssertEqual(draft.build(among: []).failureText, "The lowest and highest are numbers, lowest first.")
        draft.maxText = "1"
        XCTAssertEqual(draft.build(among: []).failureText, "The lowest and highest are numbers, lowest first.")
    }

    func testChoicesAreSplitOnSpacesAndCommas() throws {
        var draft = freqDraft()
        draft.argumentKind = .choice
        draft.choicesText = "FM, usb  LSB"
        XCTAssertEqual(try draft.build(among: []).get().argument, .choice(["FM", "USB", "LSB"]))
        draft.choicesText = " , "
        XCTAssertEqual(draft.build(among: []).failureText, "List at least one choice.")
    }

    func testThePortIsAPort() {
        var draft = freqDraft()
        draft.portText = "70000"
        XCTAssertEqual(draft.build(among: []).failureText, "The port is a number from 1 to 65535.")
    }

    func testAnEmptyReadMeansNone() throws {
        var draft = freqDraft()
        draft.changesTransmission = false
        draft.readText = "  "
        XCTAssertEqual(try draft.build(among: []).get().action,
                       .rigctl(host: "localhost", port: 4533, set: "F {arg}", read: nil))
    }

    func testTheDefinitionsOwnRulesStillApply() {
        var draft = freqDraft()
        draft.readText = ""
        XCTAssertEqual(draft.build(among: []).failureText,
                       "It changes how the station transmits, so it needs a way to put that back.")
    }

    func testAScriptDraft() throws {
        var draft = freqDraft()
        draft.actionKind = .script
        draft.scriptName = "beacon.sh"
        draft.restoreName = "beacon-off.sh"
        XCTAssertEqual(try draft.build(among: []).get().action, .script(name: "beacon.sh", restore: "beacon-off.sh"))
        draft.scriptName = ""
        XCTAssertEqual(draft.build(among: []).failureText, "Name the script to run.")
    }

    /// Editing starts from the command as it is.
    func testADraftFromACommandBuildsTheSameCommand() throws {
        let command = try freqDraft().build(among: []).get()
        XCTAssertEqual(try OwnerControlDraft(command).build(among: []).get(), command)
    }
}

private extension Result where Failure == OwnerControlDraft.Problem {
    var failureText: String? {
        if case .failure(let problem) = self { return problem.text }
        return nil
    }
}
