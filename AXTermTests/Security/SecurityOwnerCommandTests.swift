//
//  SecurityOwnerCommandTests.swift
//  AXTermTests
//
//  Security suite (Docs/SecurityTesting.md), part 2: once signed in.
//  AX.25 does not authenticate frames, so anyone can put frames into the
//  operator's session under their callsign. These tests try to borrow a
//  sign-in, forge and replay checks, move a check onto another command,
//  and smuggle a second command or keying into a control command.
//

import CryptoKit
import XCTest
@testable import AXTerm

// MARK: - Borrowing a sign-in

final class SecuritySessionHijackTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let device = P256.KeyAgreement.PrivateKey()
    private var box: BBSShell.Mailbox {
        var box = BBSShell.Mailbox()
        box.ownerStatus = ["Mail for you: 2 unread"]
        return box
    }

    private func signedIn() throws -> (OwnerConsole, SymmetricKey) {
        var console = OwnerConsole(caller: "K0EPI-3", station: "K0EPI-4")
        console.ownerKeys = [OwnerKey.PairedDevice(name: "iPhone", publicKey: OwnerKey.encode(device.publicKey))]
        console.controls = OwnerControlCommand.radioPreset
        console.radios = ControlRadio.warblerPreset
        let line = try XCTUnwrap(console.command("OWNER", "KEY", checked: false, status: [], now: now)?.lines.first)
        let key = try XCTUnwrap(OwnerKey.sessionKey(mine: device, theirs: try XCTUnwrap(OwnerKey.challenge(inLine: line)),
                                                    station: "K0EPI-4", caller: "K0EPI-3"))
        _ = console.command("OWNER", "MAC " + OwnerKey.check(key: key, counter: 0, command: "", length: 16),
                            checked: false, status: [], now: now)
        XCTAssertTrue(console.isOwner)
        return (console, key)
    }

    private func checked(_ text: String, _ counter: UInt64, _ key: SymmetricKey) -> String {
        "!" + OwnerKey.check(key: key, counter: counter, command: text, length: 4) + " " + text
    }

    /// Whether a control command was run. A refused check is logged as an
    /// attempt, so "nothing happened" means no command ran.
    private func ran(_ reply: OwnerConsole.Reply?) -> Bool {
        reply?.effects.contains { if case .runControl = $0 { return true }; return false } ?? false
    }

    /// Runs one line the way a prompt does.
    private func run(_ line: String, _ console: inout OwnerConsole) -> OwnerConsole.Reply? {
        switch console.route(line, atCommandLine: true) {
        case .reply(let reply): return reply
        case .line(let text, let checked):
            let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
            return console.command(parts.first?.uppercased() ?? "", parts.count > 1 ? parts[1] : "",
                                   checked: checked, status: box.ownerStatus, now: now)
        }
    }

    /// SEC-13. A frame injected into the signed-in session without a check
    /// runs no owner command.
    func testAnInjectedOwnerCommandWithoutACheckIsRefused() throws {
        var (console, _) = try signedIn()
        for line in ["ST", "PWR 705 10", "PWR 710 100", "QRG 705"] {
            let reply = run(line, &console)
            XCTAssertFalse(ran(reply), line)
            XCTAssertEqual(reply?.lines.first, "Owner commands from a paired device carry a check; AXTerm adds it for you.", line)
        }
    }

    /// SEC-14. Forged checks: three and the sign-in is over, and the right
    /// check is no good after.
    func testForgedChecksEndTheSignIn() throws {
        var (console, key) = try signedIn()
        for forged in ["!AAAAAA PWR 705 10", "!zzzzzz PWR 705 10", "!////// PWR 705 10"] { _ = run(forged, &console) }
        XCTAssertFalse(console.isOwner)
        XCTAssertFalse(ran(run(checked("PWR 705 10", 1, key), &console)))
    }

    /// SEC-15. A check heard on the air cannot be sent again.
    func testAHeardCheckCannotBeReplayed() throws {
        var (console, key) = try signedIn()
        let line = checked("PWR 705 5", 1, key)
        XCTAssertTrue(ran(run(line, &console)))
        XCTAssertFalse(ran(run(line, &console)))
    }

    /// SEC-16. A check is for its own command: moved onto another, or with
    /// the argument changed, it fails.
    func testACheckCannotBeMovedOntoAnotherCommand() throws {
        var (console, key) = try signedIn()
        let good = OwnerKey.check(key: key, counter: 1, command: "PWR 705 5", length: 4)
        // A trailing space is not another command: the command is trimmed
        // before it is checked, and the counter still spends the check.
        for forged in ["!\(good) PWR 705 10", "!\(good) PWR 710 5", "!\(good) PWR 705 5;T 1"] {
            var copy = console
            XCTAssertFalse(ran(run(forged, &copy)), forged)
        }
    }

    /// SEC-17. A check made in one session is no good in another.
    func testAChecksSessionKeyIsItsOwn() throws {
        var (first, firstKey) = try signedIn()
        var (second, _) = try signedIn()
        _ = first
        XCTAssertFalse(ran(run(checked("PWR 705 5", 1, firstKey), &second)))
        XCTAssertTrue(ran(run(checked("PWR 705 5", 1, firstKey), &first)))
    }

    /// SEC-18. A code sign-in never changes the station: codes are not tied
    /// to the command they come with.
    func testACodeSignInCannotChangeTheStation() {
        var console = OwnerConsole(caller: "K0EPI-3", station: "K0EPI-4", checkOwnerCode: { _, _ in .accepted })
        console.controls = OwnerControlCommand.radioPreset
        console.radios = ControlRadio.warblerPreset
        _ = console.command("OWNER", "123456", checked: false, status: [], now: now)
        XCTAssertTrue(console.isOwner)
        for line in ["PWR 705 10", "PWR 710 100"] {
            XCTAssertFalse(ran(run(line, &console)), line)
        }
    }
}

// MARK: - Smuggling something into a control command

final class SecurityControlInjectionTests: XCTestCase {

    /// SEC-19. A number argument is only a number: nothing that could reach
    /// rigctld or a script as a second command, a flag or a format.
    func testANumberArgumentIsOnlyANumber() {
        let rule = OwnerControlCommand.ArgumentRule.number(min: 0, max: 1e12)
        let hostile = ["5\nT 1", "5\rT 1", "5;T 1", "5 T 1", "5\tT 1", "5\u{0}", "５", "٥", "1e3", "0x5", "inf",
                       "nan", "+5", "--5", "5-", ".", "", " ", "$(reboot)", "`id`", "5|sh", "5&&x", "%n",
                       String(repeating: "9", count: 40), "0." + String(repeating: "1", count: 40)]
        for text in hostile {
            if case .success = rule.accept(text) { XCTFail("accepted \(text.debugDescription)") }
        }
    }

    /// SEC-19. A choice is exactly one of the list.
    func testAChoiceIsExactlyOneOfTheList() {
        let rule = OwnerControlCommand.ArgumentRule.choice(["FM", "USB"])
        for text in ["F", "FMX", "FM\nT 1", "FM;T 1", "FM T 1", "", "fm\u{0}"] {
            if case .success = rule.accept(text) { XCTFail("accepted \(text.debugDescription)") }
        }
        XCTAssertEqual(rule.accept(" fm "), .success("FM"))
    }

    /// SEC-20. Radio power takes the radio's range in watts and nothing
    /// else.
    func testRadioPowerTakesOnlyTheRadiosRange() {
        var console = OwnerConsole(caller: "K0EPI-3", station: "K0EPI-4", checkOwnerCode: { _, _ in .accepted })
        console.controls = OwnerControlCommand.radioPreset
        console.radios = ControlRadio.warblerPreset
        _ = console.command("OWNER", "123456", checked: false, status: [], now: Date())
        for args in ["705 5;T 1", "705 5 T 1", "705 5w5", "705 -5", "705 0", "705 10.0001", "705 1e1", "705 75",
                     "710 4.9", "710 101", "705 5\nT 1", "705 ５"] {
            let reply = console.command("PWR", args, checked: true, status: [], now: Date())
            XCTAssertTrue(reply?.effects.isEmpty ?? true, args.debugDescription)
        }
    }

    private func definition(set: String, read: String? = "t", transmits: Bool = true) -> OwnerControlCommand {
        OwnerControlCommand(name: "X", help: "", argument: .none,
                            action: .rigctl(host: "localhost", port: 4533, set: set, read: read),
                            changesTransmission: transmits)
    }

    /// SEC-21. No control command may key the transmitter or send it raw
    /// commands: PTT, CW, DTMF, voice memories, and raw CAT, in any
    /// spelling rigctld accepts.
    func testNoControlCommandCanKeyTheTransmitter() {
        let keying = ["T 1", "T\t1", "  T 1", "set_ptt 1", "\\set_ptt 1", "SET_PTT 1", "b CQ", "send_morse CQ",
                      "\\send_morse CQ", "w TX1;", "send_cmd TX1;", "W TX1; 3", "\\send_cmd_rx TX1;",
                      "\\send_dtmf 123", "\\send_voice_mem 1"]
        for line in keying {
            XCTAssertNotNil(definition(set: line).problem(among: []), line.debugDescription)
            XCTAssertNotNil(definition(set: "f", read: line, transmits: false).problem(among: []),
                            "as the read line: \(line.debugDescription)")
        }
        XCTAssertNil(definition(set: "t", read: nil, transmits: false).problem(among: []), "reading PTT is fine")
    }

    /// SEC-22. A script is a file in the scripts folder, never a path.
    func testAScriptCannotLeaveItsFolder() {
        for name in ["../x.sh", "/bin/sh", ".hidden.sh", "a/b.sh", "..", "x.sh\nrm", "~/x.sh"] {
            let command = OwnerControlCommand(name: "X", help: "", argument: .none,
                                              action: .script(name: name, restore: nil), changesTransmission: false)
            XCTAssertNotNil(command.problem(among: []), name.debugDescription)
            let restore = OwnerControlCommand(name: "X", help: "", argument: .none,
                                              action: .script(name: "ok.sh", restore: name), changesTransmission: true)
            XCTAssertNotNil(restore.problem(among: []), "as the restore: \(name.debugDescription)")
        }
    }

    /// SEC-23. What a radio or script says goes on the air as plain lines:
    /// no control characters or terminal escapes, short, and few.
    func testOutputIsCleanedBeforeItGoesOnTheAir() {
        let hostile = ["\u{1B}[2J\u{1B}[31mred", "bell\u{7}", "nul\u{0}here", "back\u{8}space",
                       String(repeating: "x", count: 500), "\u{202E}gnp.exe"]
        let lines = OwnerControlRunner.shorten(hostile + Array(repeating: "more", count: 50), for: "X")
        XCTAssertLessThanOrEqual(lines.count, OwnerControlRunner.maxLines + 1)
        for line in lines {
            XCTAssertLessThan(line.count, 80, line)
            XCTAssertFalse(line.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
                           line.debugDescription)
        }
    }
}
