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

/// The ready-made set for the IC-705 behind Warbler. The 705 carries the
/// operator's own link, so the set reads it and adjusts its power, and never
/// changes its frequency or mode: that would cut the link it came in on.
final class OwnerControlPresetTests: XCTestCase {

    private let preset = OwnerControlCommand.warblerIC705Preset

    func testEveryCommandIsAGoodDefinition() {
        for command in preset {
            XCTAssertNil(command.problem(among: preset), command.name)
        }
        XCTAssertEqual(preset.map(\.name), ["QRG", "MODE", "PWR", "SETPWR", "SIG", "VOLTS", "HFQRG"])
    }

    func testItNeverRetunesTheLinkRadio() {
        for command in preset {
            guard case .rigctl(_, let port, let set, _) = command.action else { return XCTFail(command.name) }
            let word = set.split(separator: " ").first.map(String.init) ?? ""
            XCTAssertFalse(["F", "M", "V", "set_freq", "set_mode", "set_vfo"].contains(word), command.name)
            if port == 4532 { XCTAssertFalse(command.changesTransmission, "the FT-710 is read, never changed") }
        }
    }

    /// Power can be turned down, never to nothing.
    func testPowerHasAFloor() {
        let setPower = preset.first { $0.name == "SETPWR" }
        XCTAssertEqual(setPower?.argument, .number(min: 0.5, max: 10), "watts since 2026-10-12")
        XCTAssertEqual(setPower?.changesTransmission, true)
    }

    /// Adding the set to commands already there skips names in use.
    func testAddingItKeepsWhatIsThere() {
        let mine = OwnerControlCommand(name: "PWR", help: "mine", argument: .none,
                                       action: .script(name: "p.sh", restore: nil), changesTransmission: false)
        let merged = OwnerControlCommand.adding(preset, to: [mine])
        XCTAssertEqual(merged.filter { $0.name == "PWR" }, [mine])
        XCTAssertEqual(merged.count, preset.count)
    }
}

/// Units. Hamlib gives power as a fraction of the radio's maximum, so 0.5
/// on the IC-705 is 5 W; the operator thinks in watts and read 0.5 as half
/// a watt (2026-10-12). A command can carry a scale: what is typed is
/// divided by it on the way to rigctl, and a number read back is
/// multiplied by it and shown with the unit.
final class OwnerControlUnitTests: XCTestCase {

    private final class FakeRig: RigctlTransport, @unchecked Sendable {
        var sent: [String] = []
        func exchange(host: String, port: Int, line: String) async throws -> [String] {
            sent.append(line)
            return line.hasPrefix("l ") ? ["0.498039"] : ["RPRT 0"]
        }
    }

    private final class NoScripts: ScriptRunning, @unchecked Sendable {
        func run(script: String, arguments: [String]) async throws -> [String] { [] }
    }

    private let setPower = OwnerControlCommand(name: "SETPWR", help: "", argument: .number(min: 0.5, max: 10),
                                               action: .rigctl(host: "localhost", port: 4533, set: "L RFPOWER {arg}",
                                                               read: "l RFPOWER"),
                                               changesTransmission: true, scale: 10, unit: "W")
    private let power = OwnerControlCommand(name: "PWR", help: "", argument: .none,
                                            action: .rigctl(host: "localhost", port: 4533, set: "l RFPOWER", read: nil),
                                            changesTransmission: false, scale: 10, unit: "W")

    func testWattsTypedAreSentAsHamlibsFraction() async {
        let rig = FakeRig()
        let result = await OwnerControlRunner(rigctl: rig, scripts: NoScripts()).run(setPower, argument: "5")
        XCTAssertEqual(rig.sent, ["l RFPOWER", "L RFPOWER 0.5"])
        XCTAssertEqual(result.lines, ["SETPWR: done, 5 W."])
        // The fail-safe puts back exactly what the radio said.
        XCTAssertEqual(result.restore, .rigctl(host: "localhost", port: 4533, line: "L RFPOWER 0.498039"))
    }

    func testAReadingIsShownInWatts() async {
        let result = await OwnerControlRunner(rigctl: FakeRig(), scripts: NoScripts()).run(power, argument: "")
        XCTAssertEqual(result.lines, ["PWR: 5.0 W"])
    }

    func testSmallValuesKeepTheirDigits() {
        XCTAssertEqual(OwnerControlCommand.scaled("0.5", by: 10), "0.05")
        XCTAssertEqual(OwnerControlCommand.scaled("7.3", by: 10), "0.73")
        XCTAssertEqual(OwnerControlCommand.scaled("145650000", by: 1), "145650000")
    }

    /// Commands saved before scales existed load as they were.
    func testOldDefinitionsLoadWithNoScale() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"PWR","help":"","argument":{"none":{}},"action":{"rigctl":{"host":"localhost","port":4533,"set":"l RFPOWER"}},"changesTransmission":false}"#
        let command = try JSONDecoder().decode(OwnerControlCommand.self, from: Data(old.utf8))
        XCTAssertEqual(command.scale, 1)
        XCTAssertEqual(command.unit, "")
    }

    /// The preset speaks watts.
    func testThePresetSpeaksWatts() {
        let preset = OwnerControlCommand.warblerIC705Preset
        let set = preset.first { $0.name == "SETPWR" }
        XCTAssertEqual(set?.argument, .number(min: 0.5, max: 10))
        XCTAssertEqual(set?.scale, 10)
        XCTAssertEqual(set?.unit, "W")
        XCTAssertEqual(preset.first { $0.name == "PWR" }?.scale, 10)
    }

    /// The set already added on A is the one that took fractions: loading
    /// moves it to watts, and leaves commands the operator changed alone.
    func testTheOldPresetIsMovedToWatts() {
        var mine = OwnerControlCommand.legacyIC705Power[0]
        mine.help = "my own words"
        let upgraded = OwnerControlCommand.upgradingPreset(OwnerControlCommand.legacyIC705Power + [mine])
        XCTAssertEqual(upgraded[0].argument, .number(min: 0.5, max: 10))
        XCTAssertEqual(upgraded[0].id, OwnerControlCommand.legacyIC705Power[0].id, "kept its identity")
        XCTAssertEqual(upgraded[1].scale, 10)
        XCTAssertEqual(upgraded[2], mine)
    }

    func testTheFormTakesAScaleAndUnit() throws {
        var draft = OwnerControlDraft(setPower)
        XCTAssertEqual(draft.scaleText, "10")
        XCTAssertEqual(draft.unit, "W")
        XCTAssertEqual(try draft.build(among: []).get(), setPower)
        draft.scaleText = "0"
        guard case .failure(let problem) = draft.build(among: []) else { return XCTFail("a scale of 0 was taken") }
        XCTAssertEqual(problem.text, "The scale is a number above 0.")
    }
}

/// Radios named once and one word per quantity (operator, 2026-10-12: "set
/// the 710 power to 50 watts, or the 705 power to 5 watts ... without
/// typing a long string", and "75 watts on the 705 is impossible"). PWR 705
/// reads; PWR 705 5 sets, inside the radio's own range, with the fail-safe.
final class OwnerControlRadioTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let device = P256.KeyAgreement.PrivateKey()
    private let box = BBSShell.Mailbox()
    private let radios = ControlRadio.warblerPreset

    private func shell(code: Bool = false) -> BBSShell {
        var sut = BBSShell(caller: "K0EPI-3", sysop: "K0EPI-4", pageRows: 0,
                           checkOwnerCode: code ? { _, _ in .accepted } : nil,
                           ownerKeys: [OwnerKey.PairedDevice(name: "iPhone", publicKey: OwnerKey.encode(device.publicKey))])
        sut.ownerControls = OwnerControlCommand.radioPreset
        sut.ownerRadios = radios
        return sut
    }

    private func signIn(_ sut: inout BBSShell) throws -> SymmetricKey {
        let challenge = try XCTUnwrap(sut.handle(line: "OWNER KEY", mailbox: box, now: now).lines.first)
        let oneTime = try XCTUnwrap(OwnerKey.challenge(inLine: challenge))
        let key = try XCTUnwrap(OwnerKey.sessionKey(mine: device, theirs: oneTime, station: "K0EPI-4", caller: "K0EPI-3"))
        _ = sut.handle(line: "OWNER MAC " + OwnerKey.check(key: key, counter: 0, command: "", length: 16),
                       mailbox: box, now: now)
        return key
    }

    private var counter: UInt64 = 1
    private func checked(_ sut: inout BBSShell, _ text: String, _ key: SymmetricKey) -> BBSShell.Output {
        defer { counter += 1 }
        let line = "!" + OwnerKey.check(key: key, counter: counter, command: text, length: 4) + " " + text
        return sut.handle(line: line, mailbox: box, now: now)
    }

    /// The command that reaches the runner, from what was typed.
    private func run(_ output: BBSShell.Output) -> (OwnerControlCommand, String)? {
        guard case .runControl(let command, let argument)? = output.effects.first else { return nil }
        return (command, argument)
    }

    func testThePresetNamesBothRadios() {
        XCTAssertEqual(radios.map(\.name), ["705", "710"])
        XCTAssertEqual(radios.map(\.port), [4533, 4532])
        let preset = OwnerControlCommand.radioPreset
        XCTAssertEqual(preset.map(\.name), ["QRG", "MODE", "PWR", "SIG", "VOLTS"])
        for command in preset { XCTAssertNil(command.problem(among: preset)) }
    }

    func testSettingThe710To50Watts() throws {
        var sut = shell()
        let key = try signIn(&sut)
        let (command, argument) = try XCTUnwrap(run(checked(&sut, "PWR 710 50", key)))
        XCTAssertEqual(command.name, "PWR 710")
        XCTAssertEqual(command.action, .rigctl(host: "localhost", port: 4532, set: "L RFPOWER {arg}", read: "l RFPOWER"))
        XCTAssertEqual(command.scale, 100)
        XCTAssertTrue(command.changesTransmission)
        XCTAssertEqual(argument, "50")
        XCTAssertEqual(command.steps, 100)
    }

    func testSettingThe705To5Watts() throws {
        var sut = shell()
        let key = try signIn(&sut)
        let (command, argument) = try XCTUnwrap(run(checked(&sut, "pwr 705 5w", key)))
        XCTAssertEqual(command.action, .rigctl(host: "localhost", port: 4533, set: "L RFPOWER {arg}", read: "l RFPOWER"))
        XCTAssertEqual(command.scale, 10)
        XCTAssertEqual(argument, "5", "a W after the number is fine")
    }

    /// Without a number it only reads, and a code sign-in may do that.
    func testWithoutANumberItReads() throws {
        var sut = shell(code: true)
        _ = sut.handle(line: "OWNER 123456", mailbox: box, now: now)
        let (command, argument) = try XCTUnwrap(run(sut.handle(line: "PWR 710", mailbox: box, now: now)))
        XCTAssertEqual(command.action, .rigctl(host: "localhost", port: 4532, set: "l RFPOWER", read: nil))
        XCTAssertFalse(command.changesTransmission)
        XCTAssertEqual(command.unit, "W")
        XCTAssertEqual(argument, "")
    }

    /// The radio's own range, so nothing impossible reaches it.
    func testAPowerTheRadioCannotGiveIsRefused() throws {
        var sut = shell()
        let key = try signIn(&sut)
        let out = checked(&sut, "PWR 705 75", key)
        XCTAssertNil(run(out))
        XCTAssertEqual(out.lines, ["PWR: the 705 takes 0.5 to 10 W."])
        XCTAssertEqual(checked(&sut, "PWR 710 2", key).lines, ["PWR: the 710 takes 5 to 100 W."])
        XCTAssertEqual(checked(&sut, "PWR 705 lots", key).lines, ["PWR: the 705 takes 0.5 to 10 W."])
    }

    func testAnUnknownRadioSaysWhichThereAre() throws {
        var sut = shell()
        let key = try signIn(&sut)
        XCTAssertEqual(checked(&sut, "PWR 711 5", key).lines, ["PWR: no radio called 711. Radios: 705, 710."])
        XCTAssertEqual(checked(&sut, "PWR", key).lines, ["PWR takes a radio, such as PWR 705, or PWR 705 5 to set it."])
    }

    /// Only power can be set; the others read.
    func testReadingQuantitiesTakeNoNumber() throws {
        var sut = shell()
        let key = try signIn(&sut)
        XCTAssertEqual(checked(&sut, "QRG 705 146520000", key).lines, ["QRG only reads: QRG 705."])
        let (command, _) = try XCTUnwrap(run(checked(&sut, "QRG 710", key)))
        XCTAssertEqual(command.action, .rigctl(host: "localhost", port: 4532, set: "f", read: nil))
    }

    /// A radio can be kept to reading from the road.
    func testARadioKeptToReadingIsNotChanged() throws {
        var sut = shell()
        var locked = radios
        locked[1].allowsChanges = false
        sut.ownerRadios = locked
        let key = try signIn(&sut)
        XCTAssertEqual(checked(&sut, "PWR 710 50", key).lines, ["PWR: the 710 is set to read only from the road."])
    }

    /// Setting needs the key: a code is not tied to its command.
    func testSettingNeedsTheKey() {
        var sut = shell(code: true)
        _ = sut.handle(line: "OWNER 123456", mailbox: box, now: now)
        XCTAssertEqual(sut.handle(line: "PWR 705 5", mailbox: box, now: now).lines,
                       ["PWR 705 5 changes how the station transmits: sign in with a paired AXTerm's key."])
    }

    func testHelpShowsHowToUseThem() {
        var sut = shell(code: true)
        let help = sut.handle(line: "H", mailbox: box, now: now).lines
        XCTAssertTrue(help.contains("PWR r [W]  a radio's power in watts; with W, set it"), "\(help)")
        XCTAssertTrue(help.contains("Radios: 705, 710"), "\(help)")
    }

    /// The first set saved on a station (QRG, SETPWR, HFQRG and the rest,
    /// each fixed to one radio) gives way to the radio set, with both radios
    /// named, as long as the operator had not changed it.
    func testTheOneRadioSetGivesWayToTheRadioSet() {
        let moved = OwnerControlCommand.movingToRadios(OwnerControlCommand.warblerIC705Preset, radios: [])
        XCTAssertEqual(moved.commands.map(\.name), ["QRG", "MODE", "PWR", "SIG", "VOLTS"])
        XCTAssertEqual(moved.radios.map(\.name), ["705", "710"])
        let mine = OwnerControlCommand(name: "BCN", help: "", argument: .none,
                                       action: .script(name: "b.sh", restore: nil), changesTransmission: false)
        let kept = OwnerControlCommand.movingToRadios([mine], radios: [])
        XCTAssertEqual(kept.commands, [mine])
        XCTAssertEqual(kept.radios, [])
    }

    func testRadiosSurviveARestart() {
        let defaults = TestDefaults.make("owner-control-radios")
        let settings = MainActor.assumeIsolated { BBSSettings(defaults: defaults) }
        MainActor.assumeIsolated { settings.controlRadios = radios }
        XCTAssertEqual(MainActor.assumeIsolated { BBSSettings(defaults: defaults).controlRadios }, radios)
    }
}

/// Power steps. The IC-705 keeps power as 0 to 255 and Warbler, like
/// Hamlib, truncates: 0.5 became step 127, 49.8%, which the 705 shows as
/// 49% (2026-10-12). AXTerm picks the nearest step to the watts asked for
/// and sends a value that lands on it whether the far end truncates or
/// rounds.
final class OwnerControlPowerStepTests: XCTestCase {

    private func lands(_ text: String, steps: Int) -> (truncated: Int, rounded: Int) {
        let value = Double(text)! * Double(steps)
        return (Int(value), Int(value.rounded()))
    }

    func testFiveWattsOnThe705IsFiftyPercent() {
        let sent = OwnerControlCommand.scaled("5", by: 10, steps: 255)
        XCTAssertEqual(lands(sent, steps: 255).truncated, 128)
        XCTAssertEqual(lands(sent, steps: 255).rounded, 128)
    }

    func testFiftyWattsOnThe710() {
        let sent = OwnerControlCommand.scaled("50", by: 100, steps: 100)
        XCTAssertEqual(lands(sent, steps: 100).truncated, 50)
        XCTAssertEqual(lands(sent, steps: 100).rounded, 50)
    }

    func testEveryStepLandsWhereItShould() {
        for watts in stride(from: 0.5, through: 10, by: 0.1) {
            let text = String(format: "%.1f", watts)
            let want = Int((watts / 10 * 255).rounded())
            let sent = OwnerControlCommand.scaled(text, by: 10, steps: 255)
            XCTAssertEqual(lands(sent, steps: 255).truncated, want, text)
            XCTAssertEqual(lands(sent, steps: 255).rounded, want, text)
        }
    }

    func testThePresetKnowsEachRadiosSteps() {
        XCTAssertEqual(ControlRadio.warblerPreset.map(\.powerSteps), [255, 100])
    }

    func testRadiosSavedBeforeStepsLoadWithout() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"705","host":"localhost","port":4533,"fullPowerWatts":10,"minWatts":0.5,"maxWatts":10,"allowsChanges":true}"#
        XCTAssertEqual(try JSONDecoder().decode(ControlRadio.self, from: Data(old.utf8)).powerSteps, 0)
    }
}
