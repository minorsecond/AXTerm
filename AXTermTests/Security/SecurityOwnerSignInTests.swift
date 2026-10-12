//
//  SecurityOwnerSignInTests.swift
//  AXTermTests
//
//  Security suite (Docs/SecurityTesting.md), part 1: signing in as the
//  owner. Anyone can transmit under the operator's callsign, so the
//  callsign proves nothing; only the code or the paired key does. These
//  tests attack both from the air: guessing, replaying, borrowing a
//  sign-in made for another station or caller, and malformed input.
//

import CryptoKit
import XCTest
@testable import AXTerm

// MARK: - The six-digit code

final class SecurityOwnerCodeTests: XCTestCase {

    private let secret = Data("12345678901234567890".utf8)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// SEC-1. Three wrong codes lock codes out, and the right code is
    /// refused while locked out.
    func testThreeWrongCodesLockOutEvenTheRightOne() {
        var checker = OwnerCode.Checker(secret: secret)
        for _ in 0..<3 { XCTAssertEqual(checker.check("000000", at: start), .wrong) }
        XCTAssertEqual(checker.check(OwnerCode.code(secret: secret, at: start), at: start), .lockedOut)
    }

    /// SEC-1. A patient guesser at the fastest pace the lockout allows,
    /// for a year: each guess can match every code in the window (two
    /// minutes late to one step early, six codes), so the odds are six in a
    /// million per guess. The lockout must hold a year of guessing under
    /// 0.15% (0.1% until the window grew to two minutes, 2026-10-12).
    func testAYearOfGuessingStaysUnderOneAndAHalfInAThousand() {
        var checker = OwnerCode.Checker(secret: secret)
        var now = start
        let end = start.addingTimeInterval(365 * 86_400)
        var guesses = 0
        while now < end {
            // Every guess the lockout lets through counts, right or wrong:
            // the odds are in how many there are.
            if checker.check("999999", at: now) != .lockedOut { guesses += 1 }
            now = now.addingTimeInterval(60)
        }
        let window = Double(OwnerCode.Checker.lateSteps + OwnerCode.Checker.earlySteps + 1)
        let odds = Double(guesses) * window / 1_000_000
        XCTAssertLessThan(odds, 0.0015, "\(guesses) guesses in a year")
    }

    /// SEC-1. A right code ends the escalation: the operator is not paying
    /// for an attacker's guesses after signing in.
    func testSigningInResetsTheLockout() {
        var checker = OwnerCode.Checker(secret: secret)
        for _ in 0..<3 { _ = checker.check("000000", at: start) }
        let later = start.addingTimeInterval(OwnerCode.Checker.lockout + 1)
        XCTAssertEqual(checker.check(OwnerCode.code(secret: secret, at: later), at: later), .accepted)
        for _ in 0..<3 { _ = checker.check("000000", at: later) }
        let unlocked = later.addingTimeInterval(OwnerCode.Checker.lockout + 1)
        XCTAssertNotEqual(checker.check(OwnerCode.code(secret: secret, at: unlocked), at: unlocked), .lockedOut,
                          "back to the first lockout's length")
    }

    /// SEC-2. A code heard on the air works once.
    func testAHeardCodeCannotBeReplayed() {
        var checker = OwnerCode.Checker(secret: secret)
        let code = OwnerCode.code(secret: secret, at: start)
        XCTAssertEqual(checker.check(code, at: start), .accepted)
        XCTAssertEqual(checker.check(code, at: start.addingTimeInterval(5)), .used)
        XCTAssertEqual(checker.check(code, at: start.addingTimeInterval(35)), .used)
    }

    /// SEC-2. An older code cannot be used after a newer one.
    func testAnOlderCodeCannotFollowANewerOne() {
        var checker = OwnerCode.Checker(secret: secret)
        let old = OwnerCode.code(secret: secret, at: start)
        let new = OwnerCode.code(secret: secret, at: start.addingTimeInterval(30))
        XCTAssertEqual(checker.check(new, at: start.addingTimeInterval(30)), .accepted)
        XCTAssertEqual(checker.check(old, at: start.addingTimeInterval(31)), .used)
    }

    /// SEC-3. A code is good for two minutes after it appears, so it can
    /// cross several digipeaters with retries, and for one step early, for
    /// a station clock running slow. Anything older or newer is wrong.
    func testACodeIsGoodForTwoMinutesAndNoLonger() {
        // `start` is the first moment of a step.
        let shown = OwnerCode.code(secret: secret, at: start)
        var late = OwnerCode.Checker(secret: secret)
        XCTAssertEqual(late.check(shown, at: start.addingTimeInterval(149)), .accepted,
                       "read as it appeared, it reaches the station 2.5 minutes later")
        var lastMoment = OwnerCode.Checker(secret: secret)
        XCTAssertEqual(lastMoment.check(OwnerCode.code(secret: secret, at: start.addingTimeInterval(29)),
                                        at: start.addingTimeInterval(29 + 120)), .accepted,
                       "read just before it changed, it still has two minutes")
        var tooLate = OwnerCode.Checker(secret: secret)
        XCTAssertEqual(tooLate.check(shown, at: start.addingTimeInterval(150)), .wrong)
        var early = OwnerCode.Checker(secret: secret)
        XCTAssertEqual(early.check(OwnerCode.code(secret: secret, at: start.addingTimeInterval(30)), at: start), .accepted)
        var tooEarly = OwnerCode.Checker(secret: secret)
        XCTAssertEqual(tooEarly.check(OwnerCode.code(secret: secret, at: start.addingTimeInterval(60)), at: start), .wrong)
    }

    /// SEC-4. Only six ASCII digits are a code. Look-alike digits, signs,
    /// spaces inside, padding, and NUL are wrong, never accepted.
    func testOnlySixASCIIDigitsAreACode() {
        let right = OwnerCode.code(secret: secret, at: start)
        let fullwidth = String(right.unicodeScalars.map { Character(UnicodeScalar($0.value - 0x30 + 0xFF10)!) })
        let arabic = String(right.unicodeScalars.map { Character(UnicodeScalar($0.value - 0x30 + 0x0660)!) })
        let mangled = [fullwidth, arabic, "+" + right.dropFirst(), "-" + right.dropFirst(),
                       right.prefix(3) + " " + right.dropFirst(3), right + "0", String(right.dropLast()),
                       right + "\u{0}", "", "abcdef", String(repeating: right, count: 1000)]
        for typed in mangled {
            var checker = OwnerCode.Checker(secret: secret)
            XCTAssertNotEqual(checker.check(String(typed), at: start), .accepted, typed.debugDescription)
        }
        var checker = OwnerCode.Checker(secret: secret)
        XCTAssertEqual(checker.check("  \(right)  ", at: start), .accepted, "spaces around are fine")
    }
}

// MARK: - Who may try at all

final class SecurityOwnerCallsignTests: XCTestCase {

    /// SEC-5. Only the operator's base callsign, at any SSID, is offered
    /// OWNER. Look-alikes and supersets are not.
    func testOnlyTheOperatorsCallsignMayTry() {
        for caller in ["K0EPI-3", "K0EPI", "K0EPI-15", "k0epi-3"] {
            XCTAssertTrue(BBSShell.isOwnerCallsign(caller, station: "K0EPI-4"), caller)
        }
        for caller in ["K0EP1-3", "K0EPIX-3", "XK0EPI-3", "K0EP-3", "W0ARP-1", "", "K0EPI/P"] {
            XCTAssertFalse(BBSShell.isOwnerCallsign(caller, station: "K0EPI-4"), caller)
        }
    }

    /// SEC-5. To anyone else the owner's commands do not exist: OWNER, ST
    /// and the control words are unknown, and help does not list them.
    func testToAnyoneElseOwnerCommandsDoNotExist() {
        let now = Date()
        var shell = BBSShell(caller: "W0ARP-1", sysop: "K0EPI-4", pageRows: 0)
        shell.ownerControls = OwnerControlCommand.radioPreset
        shell.ownerRadios = ControlRadio.warblerPreset
        for line in ["OWNER 123456", "OWNER KEY", "OWNER MAC AAAA", "ST", "PWR 705", "PWR 705 10", "!AAAAAA PWR 705 10"] {
            XCTAssertTrue(shell.handle(line: line, mailbox: BBSShell.Mailbox(), now: now).lines.first?.hasPrefix("?") ?? false,
                          line)
        }
        let help = shell.handle(line: "H", mailbox: BBSShell.Mailbox(), now: now).lines
        XCTAssertFalse(help.contains { $0.hasPrefix("OWNER") || $0.hasPrefix("PWR") || $0.hasPrefix("Radios") })
    }
}

// MARK: - The paired key

final class SecurityOwnerKeyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let device = P256.KeyAgreement.PrivateKey()

    private func console(caller: String = "K0EPI-3", station: String = "K0EPI-4") -> OwnerConsole {
        var console = OwnerConsole(caller: caller, station: station)
        console.ownerKeys = [OwnerKey.PairedDevice(name: "iPhone", publicKey: OwnerKey.encode(device.publicKey))]
        return console
    }

    private func challenge(_ console: inout OwnerConsole) throws -> String {
        let line = try XCTUnwrap(console.command("OWNER", "KEY", checked: false, status: [], now: now)?.lines.first)
        return try XCTUnwrap(OwnerKey.challenge(inLine: line))
    }

    private func answer(_ oneTime: String, station: String = "K0EPI-4", caller: String = "K0EPI-3",
                        key: P256.KeyAgreement.PrivateKey? = nil) throws -> String {
        let session = try XCTUnwrap(OwnerKey.sessionKey(mine: key ?? device, theirs: oneTime, station: station, caller: caller))
        return OwnerKey.check(key: session, counter: 0, command: "", length: OwnerKey.signInCheckBytes)
    }

    @discardableResult
    private func signIn(_ console: inout OwnerConsole, _ mac: String) -> OwnerConsole.Reply? {
        console.command("OWNER", "MAC \(mac)", checked: false, status: [], now: now)
    }

    /// SEC-6. A sign-in heard on the air is no good on the next challenge.
    func testASignInCannotBeReplayedOnANewChallenge() throws {
        var first = console()
        let mac = try answer(try challenge(&first))
        signIn(&first, mac)
        XCTAssertTrue(first.isOwner)
        var second = console()
        _ = try challenge(&second)
        signIn(&second, mac)
        XCTAssertFalse(second.isOwner)
    }

    /// SEC-6. A challenge takes one answer: a wrong one spends it, so each
    /// guess costs the guesser a new challenge.
    func testAChallengeTakesOneAnswer() throws {
        var sut = console()
        let oneTime = try challenge(&sut)
        signIn(&sut, "AAAAAAAAAAAAAAAAAAAAAA")
        signIn(&sut, try answer(oneTime))
        XCTAssertFalse(sut.isOwner)
    }

    /// SEC-7. A sign-in made for another station or another caller fails.
    func testASignInIsBoundToBothCallsigns() throws {
        var sut = console()
        let oneTime = try challenge(&sut)
        signIn(&sut, try answer(oneTime, station: "K0EPI-7"))
        XCTAssertFalse(sut.isOwner, "made for the node, tried at the mailbox")
        var other = console()
        signIn(&other, try answer(try challenge(&other), caller: "K0EPI-9"))
        XCTAssertFalse(other.isOwner, "made by another SSID")
    }

    /// SEC-8. An unpaired key fails, whatever else is right.
    func testAnUnpairedKeyFails() throws {
        var sut = console()
        signIn(&sut, try answer(try challenge(&sut), key: P256.KeyAgreement.PrivateKey()))
        XCTAssertFalse(sut.isOwner)
    }

    /// SEC-9. Truncated, padded, re-cased and garbage answers fail and
    /// never crash.
    func testMalformedAnswersFail() throws {
        for garbage in ["", "A", String(repeating: "A", count: 21), String(repeating: "A", count: 4096),
                        "!!!!!!!!!!!!!!!!!!!!!!", "\u{0}\u{0}\u{0}", "😀😀😀😀😀😀😀😀😀😀😀"] {
            var sut = console()
            _ = try challenge(&sut)
            signIn(&sut, garbage)
            XCTAssertFalse(sut.isOwner, garbage.debugDescription)
        }
        var sut = console()
        let right = try answer(try challenge(&sut))
        signIn(&sut, right.lowercased() == right ? right.uppercased() : right.lowercased())
        XCTAssertFalse(sut.isOwner, "base64 is case-sensitive")
    }

    /// SEC-10. A challenge left too long is spent.
    func testAStaleChallengeIsRefused() throws {
        var sut = console()
        let mac = try answer(try challenge(&sut))
        _ = sut.command("OWNER", "MAC \(mac)", checked: false, status: [],
                        now: now.addingTimeInterval(OwnerKey.challengeLifetime + 1))
        XCTAssertFalse(sut.isOwner)
    }

    /// SEC-11. Garbage where a public key belongs never crashes and never
    /// derives a key: a pairing entry, or a mailbox's one-time key.
    func testGarbageKeysAreRefused() {
        // Not points on P-256: wrong lengths, a bad prefix byte, an x past
        // the field prime, and text that is not base64.
        for garbage in ["", "AAAA", "BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                        "A/////////////////////////////////////////8=",
                        String(repeating: "/", count: 44), "not base64 at all", "BBBB" + String(repeating: "A", count: 84)] {
            XCTAssertNil(OwnerKey.sessionKey(mine: device, theirs: garbage, station: "K0EPI-4", caller: "K0EPI-3"),
                         garbage)
        }
        var sut = OwnerConsole(caller: "K0EPI-3", station: "K0EPI-4")
        sut.ownerKeys = [OwnerKey.PairedDevice(name: "broken", publicKey: "garbage")]
        _ = sut.command("OWNER", "KEY", checked: false, status: [], now: now)
        _ = sut.command("OWNER", "MAC AAAAAAAAAAAAAAAAAAAAAA", checked: false, status: [], now: now)
        XCTAssertFalse(sut.isOwner)
    }

    /// SEC-12. Comparing an answer takes the same time however much of it
    /// is right, so timing says nothing about a guess.
    func testComparingIsConstantTimeInShape() {
        XCTAssertFalse(OwnerKey.matches("AAAAAB", "AAAAAA"))
        XCTAssertFalse(OwnerKey.matches("AAAAA", "AAAAAA"))
        XCTAssertFalse(OwnerKey.matches("", "AAAAAA"))
        XCTAssertTrue(OwnerKey.matches("AAAAAA", "AAAAAA"))
    }
}
