//
//  OwnerKeyTests.swift
//  AXTermTests
//
//  Owner commands from another AXTerm (Docs/RemoteAccessPlan.md, "Signing
//  in"). The device keeps a P-256 key-agreement key; home keeps the public
//  keys of the devices paired with it. OWNER KEY gets a one-time public key
//  from home, both ends derive the same session key from it (ECDH), and the
//  device proves it holds its key with one full 128-bit check. After that
//  each owner command carries a 32-bit check over a counter both ends keep
//  and the command's text: 8 characters on the air, where a signature took
//  150. Three wrong checks end the sign-in, so a forger gets three tries at
//  1 in 4.3 billion. Everything stays readable: the checks hide nothing.
//

import CryptoKit
import XCTest
@testable import AXTerm

final class OwnerKeyTests: XCTestCase {

    private let station = "K0EPI-4"
    private let caller = "K0EPI-3"

    /// Home, with the one-time key, and the device, with its own, arrive at
    /// the same session key without it going on the air.
    func testBothEndsDeriveTheSameSessionKey() throws {
        let device = P256.KeyAgreement.PrivateKey()
        let oneTime = P256.KeyAgreement.PrivateKey()
        let home = try XCTUnwrap(OwnerKey.sessionKey(mine: oneTime, theirs: OwnerKey.encode(device.publicKey),
                                                     station: station, caller: caller))
        let away = try XCTUnwrap(OwnerKey.sessionKey(mine: device, theirs: OwnerKey.encode(oneTime.publicKey),
                                                     station: station, caller: caller))
        XCTAssertEqual(OwnerKey.check(key: home, counter: 0, command: "", length: 16),
                       OwnerKey.check(key: away, counter: 0, command: "", length: 16))
    }

    /// The session key belongs to one station and one caller.
    func testTheSessionKeyIsBoundToBothCallsigns() throws {
        let device = P256.KeyAgreement.PrivateKey()
        let oneTime = P256.KeyAgreement.PrivateKey()
        let devicePublic = OwnerKey.encode(device.publicKey)
        let base = try XCTUnwrap(OwnerKey.sessionKey(mine: oneTime, theirs: devicePublic, station: station, caller: caller))
        let otherStation = try XCTUnwrap(OwnerKey.sessionKey(mine: oneTime, theirs: devicePublic,
                                                             station: "K0EPI-7", caller: caller))
        let otherCaller = try XCTUnwrap(OwnerKey.sessionKey(mine: oneTime, theirs: devicePublic,
                                                            station: station, caller: "K0EPI-9"))
        let mark = { (key: SymmetricKey) in OwnerKey.check(key: key, counter: 0, command: "", length: 16) }
        XCTAssertNotEqual(mark(base), mark(otherStation))
        XCTAssertNotEqual(mark(base), mark(otherCaller))
    }

    /// A command's check is 6 characters, the sign-in's 22, and each
    /// depends on the counter and the command.
    func testChecksAreShortAndCoverCounterAndCommand() {
        let key = SymmetricKey(size: .bits256)
        let st0 = OwnerKey.check(key: key, counter: 0, command: "ST", length: 4)
        XCTAssertEqual(st0.count, 6)
        XCTAssertEqual(OwnerKey.check(key: key, counter: 0, command: "", length: 16).count, 22)
        XCTAssertNotEqual(st0, OwnerKey.check(key: key, counter: 1, command: "ST", length: 4))
        XCTAssertNotEqual(st0, OwnerKey.check(key: key, counter: 0, command: "L", length: 4))
    }

    func testGarbageIsRefused() {
        XCTAssertNil(OwnerKey.decode("nope"))
        XCTAssertNil(OwnerKey.sessionKey(mine: P256.KeyAgreement.PrivateKey(), theirs: "nope",
                                         station: station, caller: caller))
    }

    func testTheChallengeLineParses() {
        XCTAssertEqual(OwnerKey.challenge(inLine: "Owner challenge: 4F2A9C11"), "4F2A9C11")
        XCTAssertNil(OwnerKey.challenge(inLine: "Owner challenge:"))
        XCTAssertNil(OwnerKey.challenge(inLine: "Welcome"))
    }
}

/// The mailbox's side.
final class BBSShellOwnerKeyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let device = P256.KeyAgreement.PrivateKey()

    private func shell(caller: String = "K0EPI-3", paired: Bool = true,
                       checkOwnerCode: ((String, Date) -> OwnerCode.Verdict)? = nil) -> BBSShell {
        let devices = paired ? [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))] : []
        return BBSShell(caller: caller, sysop: "K0EPI-4", pageRows: 0,
                        checkOwnerCode: checkOwnerCode,
                        ownerKeys: devices.isEmpty ? nil : devices)
    }

    /// What the device does with the challenge line: the session key, and
    /// the sign-in line.
    private func answer(_ challengeLine: String, caller: String = "K0EPI-3") throws -> (SymmetricKey, String) {
        let oneTime = try XCTUnwrap(OwnerKey.challenge(inLine: challengeLine))
        let key = try XCTUnwrap(OwnerKey.sessionKey(mine: device, theirs: oneTime, station: "K0EPI-4", caller: caller))
        return (key, "OWNER MAC " + OwnerKey.check(key: key, counter: 0, command: "", length: 16))
    }

    private func command(_ text: String, _ counter: UInt64, _ key: SymmetricKey) -> String {
        "!" + OwnerKey.check(key: key, counter: counter, command: text, length: 4) + " " + text
    }

    /// Signs in and returns the session key.
    private func signIn(_ sut: inout BBSShell, box: BBSShell.Mailbox) throws -> SymmetricKey {
        let challenge = try XCTUnwrap(sut.handle(line: "OWNER KEY", mailbox: box, now: now).lines.first)
        let (key, line) = try answer(challenge)
        _ = sut.handle(line: line, mailbox: box, now: now)
        return key
    }

    private var box: BBSShell.Mailbox {
        var box = BBSShell.Mailbox()
        box.ownerStatus = ["Mail for you: 2 unread"]
        return box
    }

    func testTheKeyExchangeSignsIn() throws {
        var sut = shell()
        let challenge = try XCTUnwrap(sut.handle(line: "OWNER KEY", mailbox: box, now: now).lines.first)
        XCTAssertTrue(challenge.hasPrefix(OwnerKey.challengePrefix))
        let out = sut.handle(line: try answer(challenge).1, mailbox: box, now: now)
        XCTAssertTrue(sut.isOwner)
        XCTAssertEqual(out.effects, [.ownerSignIn(accepted: true)])
        XCTAssertEqual(out.lines, ["Signed in as the owner until you disconnect. Owner commands carry a check.",
                                   "Owner commands: ST"])
    }

    /// Each owner command carries 8 characters: "!", the 6-character
    /// check and a space.
    func testEachOwnerCommandCarriesAShortCheck() throws {
        var sut = shell()
        let key = try signIn(&sut, box: box)
        let first = command("ST", 1, key)
        XCTAssertEqual(first.count, "ST".count + 8)
        XCTAssertEqual(sut.handle(line: first, mailbox: box, now: now).lines, ["Mail for you: 2 unread"])
        XCTAssertEqual(sut.handle(line: command("ST", 2, key), mailbox: box, now: now).lines,
                       ["Mail for you: 2 unread"])
    }

    /// A command heard on the air cannot be sent again: the counter has
    /// moved on.
    func testACommandCannotBeReplayed() throws {
        var sut = shell()
        let key = try signIn(&sut, box: box)
        let line = command("ST", 1, key)
        _ = sut.handle(line: line, mailbox: box, now: now)
        let again = sut.handle(line: line, mailbox: box, now: now)
        XCTAssertEqual(again.lines, ["That check is not right."])
        XCTAssertEqual(again.effects, [.ownerSignIn(accepted: false)])
    }

    /// A check is for the command it was made over.
    func testACheckCannotCarryAnotherCommand() throws {
        var sut = shell()
        let key = try signIn(&sut, box: box)
        let moved = command("H", 1, key).replacingOccurrences(of: " H", with: " ST")
        XCTAssertEqual(sut.handle(line: moved, mailbox: box, now: now).lines, ["That check is not right."])
    }

    /// Three wrong checks end the sign-in: a forger gets three tries, and
    /// the operator signs in again with a fresh exchange.
    func testThreeWrongChecksEndTheSignIn() throws {
        var sut = shell()
        let key = try signIn(&sut, box: box)
        _ = sut.handle(line: "!AAAAAA ST", mailbox: box, now: now)
        _ = sut.handle(line: "!AAAAAB ST", mailbox: box, now: now)
        let third = sut.handle(line: "!AAAAAC ST", mailbox: box, now: now)
        XCTAssertEqual(third.lines, ["Too many wrong checks. Sign in again: OWNER KEY."])
        XCTAssertFalse(sut.isOwner)
        XCTAssertFalse(sut.handle(line: command("ST", 1, key), mailbox: box, now: now).lines
            .contains("Mail for you: 2 unread"))
    }

    /// Someone can put frames into the session under the operator's
    /// callsign. Signed in by key, an owner command without its check is
    /// refused, so the sign-in cannot be borrowed.
    func testAnOwnerCommandWithoutItsCheckIsRefused() throws {
        var sut = shell()
        _ = try signIn(&sut, box: box)
        XCTAssertEqual(sut.handle(line: "ST", mailbox: box, now: now).lines,
                       ["Owner commands from a paired device carry a check; AXTerm adds it for you."])
    }

    /// The caller's callsign is in the session key.
    func testASignInMadeForAnotherCallerIsRefused() throws {
        var sut = shell(caller: "K0EPI-3")
        let challenge = try XCTUnwrap(sut.handle(line: "OWNER KEY", mailbox: box, now: now).lines.first)
        let out = sut.handle(line: try answer(challenge, caller: "K0EPI-7").1, mailbox: box, now: now)
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.lines, ["That sign-in is not from a paired device."])
        XCTAssertEqual(out.effects, [.ownerSignIn(accepted: false)])
    }

    /// Each sign-in needs its own challenge: an answer heard on the air
    /// cannot sign in again.
    func testASignInCannotBeReplayed() throws {
        var sut = shell()
        let challenge = try XCTUnwrap(sut.handle(line: "OWNER KEY", mailbox: box, now: now).lines.first)
        let line = try answer(challenge).1
        var other = shell()
        _ = other.handle(line: "OWNER KEY", mailbox: box, now: now)
        _ = other.handle(line: line, mailbox: box, now: now)
        XCTAssertFalse(other.isOwner)
    }

    /// A challenge is good for five minutes.
    func testAChallengeExpires() throws {
        var sut = shell()
        let challenge = try XCTUnwrap(sut.handle(line: "OWNER KEY", mailbox: box, now: now).lines.first)
        let out = sut.handle(line: try answer(challenge).1, mailbox: box,
                             now: now.addingTimeInterval(OwnerKey.challengeLifetime + 1))
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.lines, ["That challenge has run out. Ask for a new one: OWNER KEY."])
    }

    func testASignInNeedsAChallengeFirst() {
        var sut = shell()
        let out = sut.handle(line: "OWNER MAC AAAAAAAAAAAAAAAAAAAAAA", mailbox: box, now: now)
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.lines, ["Ask for a challenge first: OWNER KEY."])
    }

    /// Anyone can send wrong codes as the owner's callsign and lock codes
    /// out for 15 minutes. A paired device's key cannot be guessed, so the
    /// code lockout does not stop it: the owner can always get in.
    func testAKeySignsInWhileCodesAreLockedOut() throws {
        var sut = shell(checkOwnerCode: { _, _ in .lockedOut })
        XCTAssertEqual(sut.handle(line: "OWNER 123456", mailbox: box, now: now).lines,
                       ["Too many wrong codes. Try again in 15 minutes."])
        _ = try signIn(&sut, box: box)
        XCTAssertTrue(sut.isOwner)
    }

    /// Signed in with a code, from a plain terminal, owner commands that
    /// only read are typed as they are.
    func testACodeSignInRunsReadingCommandsUnchecked() {
        var sut = shell(paired: false, checkOwnerCode: { _, _ in .accepted })
        _ = sut.handle(line: "OWNER 123456", mailbox: box, now: now)
        XCTAssertEqual(sut.handle(line: "ST", mailbox: box, now: now).lines, ["Mail for you: 2 unread"])
    }

    /// With codes on and no device paired, OWNER KEY says so. It used to
    /// go to the code checker as the code "KEY": a wrong code, or the
    /// lockout message once codes were locked out.
    func testOwnerKeyWithNoDevicePairedIsNotACode() {
        var checked = false
        var sut = BBSShell(caller: "K0EPI-3", sysop: "K0EPI-4", pageRows: 0,
                           checkOwnerCode: { _, _ in checked = true; return .lockedOut })
        let out = sut.handle(line: "OWNER KEY", mailbox: BBSShell.Mailbox(), now: now)
        XCTAssertFalse(checked, "KEY is not a code")
        XCTAssertEqual(out.lines, ["No device is paired with this station. Pair one in its owner settings at home."])
        XCTAssertEqual(out.effects, [])
    }

    /// Without paired devices, OWNER KEY is unknown like any command.
    func testNoPairedDevicesMeansUnknown() {
        var sut = shell(paired: false)
        XCTAssertTrue(sut.handle(line: "OWNER KEY", mailbox: BBSShell.Mailbox(), now: now).lines.first?
            .hasPrefix("? OWNER") ?? false)
    }
}

/// The terminal's side: after Sign In as Owner sends OWNER KEY, the
/// mailbox's challenge is answered with the sign-in check; after that, each
/// owner command the operator types gets its check before it goes out. The
/// operator types ST and nothing else.
final class OwnerSignInResponderTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)
    private var derive: OwnerSignInResponder.Derive { { [key] _, _, _ in key } }

    private func signedIn() -> OwnerSignInResponder {
        var responder = OwnerSignInResponder()
        responder.begin(peer: "K0EPI-4")
        _ = responder.reply(toLine: "Owner challenge: X", from: "K0EPI-4", caller: "K0EPI-3", derive: derive)
        return responder
    }

    func testTheChallengeIsAnsweredOnce() {
        var responder = OwnerSignInResponder()
        responder.begin(peer: "k0epi-4")
        XCTAssertEqual(responder.reply(toLine: "Owner challenge: X", from: "K0EPI-4", caller: "K0EPI-3", derive: derive),
                       "OWNER MAC " + OwnerKey.check(key: key, counter: 0, command: "", length: 16))
        XCTAssertNil(responder.reply(toLine: "Owner challenge: X", from: "K0EPI-4", caller: "K0EPI-3", derive: derive))
    }

    /// A challenge nobody asked for, or from another station, is not answered.
    func testOnlyWhatWasAskedIsAnswered() {
        var responder = OwnerSignInResponder()
        XCTAssertNil(responder.reply(toLine: "Owner challenge: X", from: "K0EPI-4", caller: "K0EPI-3", derive: derive))
        responder.begin(peer: "K0EPI-4")
        XCTAssertNil(responder.reply(toLine: "Owner challenge: X", from: "W0ARP-1", caller: "K0EPI-3", derive: derive))
        XCTAssertNil(responder.reply(toLine: "Welcome", from: "K0EPI-4", caller: "K0EPI-3", derive: derive))
        XCTAssertNotNil(responder.reply(toLine: "Owner challenge: X", from: "K0EPI-4", caller: "K0EPI-3", derive: derive))
    }

    /// Owner commands get their check, the counter moving on each time.
    func testOwnerCommandsGetTheirCheck() {
        var responder = signedIn()
        XCTAssertEqual(responder.signed(line: "st", to: "K0EPI-4"),
                       "!" + OwnerKey.check(key: key, counter: 1, command: "st", length: 4) + " st")
        XCTAssertEqual(responder.signed(line: "ST", to: "K0EPI-4"),
                       "!" + OwnerKey.check(key: key, counter: 2, command: "ST", length: 4) + " ST")
    }

    /// Everything else goes as typed, and nothing is checked for a station
    /// never signed in to.
    func testOtherLinesGoAsTyped() {
        var fresh = OwnerSignInResponder()
        XCTAssertNil(fresh.signed(line: "ST", to: "K0EPI-4"))
        var responder = signedIn()
        XCTAssertNil(responder.signed(line: "L", to: "K0EPI-4"))
        XCTAssertNil(responder.signed(line: "ST", to: "W0ARP-1"))
    }

    /// The disconnect forgets the sign-in.
    func testEndingTheSessionForgetsIt() {
        var responder = signedIn()
        responder.end(peer: "K0EPI-4")
        XCTAssertNil(responder.signed(line: "ST", to: "K0EPI-4"))
    }

    /// Home tells the device the sign-in is over: it stops adding checks.
    func testASignOutFromHomeIsHeard() {
        var responder = signedIn()
        _ = responder.reply(toLine: "Too many wrong checks. Sign in again: OWNER KEY.", from: "K0EPI-4",
                            caller: "K0EPI-3", derive: derive)
        XCTAssertNil(responder.signed(line: "ST", to: "K0EPI-4"))
    }

    /// The real thing end to end: a device key, the mailbox, and a command.
    func testTheRealExchangeSignsInAndRunsACommand() throws {
        let device = P256.KeyAgreement.PrivateKey()
        var shell = BBSShell(caller: "K0EPI-3", sysop: "K0EPI-4", pageRows: 0,
                             ownerKeys: [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))])
        var box = BBSShell.Mailbox()
        box.ownerStatus = ["Mail for you: 2 unread"]
        var responder = OwnerSignInResponder()
        let realDerive: OwnerSignInResponder.Derive = { oneTime, station, caller in
            OwnerKey.sessionKey(mine: device, theirs: oneTime, station: station, caller: caller)
        }
        responder.begin(peer: "K0EPI-4")
        let challenge = shell.handle(line: "OWNER KEY", mailbox: box, now: Date()).lines[0]
        let signIn = try XCTUnwrap(responder.reply(toLine: challenge, from: "K0EPI-4", caller: "K0EPI-3",
                                                   derive: realDerive))
        _ = shell.handle(line: signIn, mailbox: box, now: Date())
        XCTAssertTrue(shell.isOwner)
        let st = try XCTUnwrap(responder.signed(line: "ST", to: "K0EPI-4"))
        XCTAssertEqual(shell.handle(line: st, mailbox: box, now: Date()).lines, ["Mail for you: 2 unread"])
    }
}
