//
//  OwnerKeyTests.swift
//  AXTermTests
//
//  Owner commands from another AXTerm, signed with a key pair
//  (Docs/RemoteAccessPlan.md, "Signing in"). The device keeps its private
//  key; home keeps the public keys of the devices paired with it. Every
//  owner command is signed together with its text, home's callsign, the
//  caller's callsign and a challenge home sent and uses once, so a recorded
//  signature cannot be replayed, moved to another station or caller, or
//  attached to another command. Everything on the air stays readable: the
//  challenge and signature are extra characters, not a cipher.
//

import CryptoKit
import XCTest
@testable import AXTerm

final class OwnerKeyTests: XCTestCase {

    private let station = "K0EPI-4"
    private let caller = "K0EPI-3"

    private func sign(_ challenge: String, _ command: String, station: String? = nil, caller: String? = nil,
                      with key: P256.Signing.PrivateKey) throws -> String {
        try OwnerKey.sign(challenge: challenge, station: station ?? self.station, caller: caller ?? self.caller,
                          command: command, with: key)
    }

    private func verify(_ signature: String, _ challenge: String, _ command: String,
                        paired: [OwnerKey.PairedDevice]) -> Bool {
        OwnerKey.verify(signature: signature, challenge: challenge, station: station, caller: caller,
                        command: command, paired: paired)
    }

    func testASignatureFromAPairedDeviceIsAccepted() throws {
        let device = P256.Signing.PrivateKey()
        let paired = [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))]
        let signature = try sign("4F2A9C11E07B3D55", "ST", with: device)
        XCTAssertTrue(verify(signature, "4F2A9C11E07B3D55", "ST", paired: paired))
    }

    func testAnUnpairedDeviceIsRefused() throws {
        let paired = [OwnerKey.PairedDevice(name: "iPad",
                                            publicKey: OwnerKey.encode(P256.Signing.PrivateKey().publicKey))]
        let signature = try sign("AA", "ST", with: P256.Signing.PrivateKey())
        XCTAssertFalse(verify(signature, "AA", "ST", paired: paired))
    }

    /// A recorded signature is no good for another challenge, station,
    /// caller or command.
    func testASignatureIsTiedToEverythingItCovers() throws {
        let device = P256.Signing.PrivateKey()
        let paired = [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))]
        XCTAssertFalse(verify(try sign("AA", "ST", with: device), "BB", "ST", paired: paired), "challenge")
        XCTAssertFalse(verify(try sign("AA", "ST", station: "K0EPI-7", with: device), "AA", "ST", paired: paired),
                       "station")
        XCTAssertFalse(verify(try sign("AA", "ST", caller: "K0EPI-9", with: device), "AA", "ST", paired: paired),
                       "caller")
        XCTAssertFalse(verify(try sign("AA", "ST", with: device), "AA", "K 3", paired: paired), "command")
    }

    func testGarbageIsRefused() {
        XCTAssertFalse(verify("not base64!", "AA", "", paired: []))
        XCTAssertNil(OwnerKey.decode("nope"))
    }

    /// 128 random bits: as strong as P-256 itself, and 32 characters.
    func testAChallengeIsFreshEachTime() {
        let a = OwnerKey.newChallenge(), b = OwnerKey.newChallenge()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
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
    private let device = P256.Signing.PrivateKey()
    private var challenges = ["C1", "C2", "C3", "C4", "C5"]

    private func shell(caller: String = "K0EPI-3", paired: Bool = true,
                       checkOwnerCode: ((String, Date) -> OwnerCode.Verdict)? = nil) -> BBSShell {
        let devices = paired ? [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))] : []
        return BBSShell(caller: caller, sysop: "K0EPI-4", pageRows: 0,
                        checkOwnerCode: checkOwnerCode,
                        ownerKeys: devices.isEmpty ? nil : devices,
                        makeChallenge: { [unowned self] in self.challenges.removeFirst() })
    }

    private func signed(_ command: String, _ challenge: String, caller: String = "K0EPI-3") throws -> String {
        let signature = try OwnerKey.sign(challenge: challenge, station: "K0EPI-4", caller: caller,
                                          command: command, with: device)
        return command.isEmpty ? "OWNER SIG \(signature)" : "OWNER SIG \(signature) \(command)"
    }

    /// OWNER KEY, then a signature over no command: signed in, with the
    /// challenge for the next command in the same reply.
    func testTheKeyHandshakeSignsIn() throws {
        var sut = shell()
        let box = BBSShell.Mailbox()
        XCTAssertEqual(sut.handle(line: "OWNER KEY", mailbox: box, now: now).lines, ["Owner challenge: C1"])
        let out = sut.handle(line: try signed("", "C1"), mailbox: box, now: now)
        XCTAssertTrue(sut.isOwner)
        XCTAssertEqual(out.effects, [.ownerSignIn(accepted: true)])
        XCTAssertEqual(out.lines.last, "Owner challenge: C2")
    }

    /// After a key sign-in every owner command is signed, and each answer
    /// brings the next challenge, so signing costs no extra turn.
    func testEachOwnerCommandIsSignedAndBringsTheNextChallenge() throws {
        var sut = shell()
        var box = BBSShell.Mailbox()
        box.ownerStatus = ["Mail for you: 2 unread"]
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        _ = sut.handle(line: try signed("", "C1"), mailbox: box, now: now)
        let first = sut.handle(line: try signed("ST", "C2"), mailbox: box, now: now)
        // The next challenge first, so a long answer's pages cannot hold it back.
        XCTAssertEqual(first.lines, ["Owner challenge: C3", "Mail for you: 2 unread"])
        let second = sut.handle(line: try signed("ST", "C3"), mailbox: box, now: now)
        XCTAssertEqual(second.lines, ["Owner challenge: C4", "Mail for you: 2 unread"])
    }

    /// Someone can put frames into the session under the operator's
    /// callsign. Signed in by key, an owner command without a signature is
    /// refused, so the sign-in cannot be borrowed.
    func testAnUnsignedOwnerCommandAfterAKeySignInIsRefused() throws {
        var sut = shell()
        var box = BBSShell.Mailbox()
        box.ownerStatus = ["Mail for you: 2 unread"]
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        _ = sut.handle(line: try signed("", "C1"), mailbox: box, now: now)
        let out = sut.handle(line: "ST", mailbox: box, now: now)
        XCTAssertFalse(out.lines.contains("Mail for you: 2 unread"))
        XCTAssertEqual(out.lines.first, "Owner commands from a paired device must be signed; AXTerm does it for you.")
    }

    /// A signature heard on the air cannot be sent again: its challenge is
    /// spent.
    func testASignedCommandCannotBeReplayed() throws {
        var sut = shell()
        var box = BBSShell.Mailbox()
        box.ownerStatus = ["Mail for you: 2 unread"]
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        _ = sut.handle(line: try signed("", "C1"), mailbox: box, now: now)
        let line = try signed("ST", "C2")
        _ = sut.handle(line: line, mailbox: box, now: now)
        let again = sut.handle(line: line, mailbox: box, now: now)
        XCTAssertFalse(again.lines.contains("Mail for you: 2 unread"))
        XCTAssertEqual(again.lines.first, "That signature is not from a paired device.")
        XCTAssertEqual(again.lines.last, "Owner challenge: C4", "a fresh challenge, so the operator can go on")
    }

    /// A signature is for the command it was made over.
    func testASignatureCannotCarryAnotherCommand() throws {
        var sut = shell()
        var box = BBSShell.Mailbox()
        box.ownerStatus = ["Mail for you: 2 unread"]
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        _ = sut.handle(line: try signed("", "C1"), mailbox: box, now: now)
        let forged = try signed("H", "C2").replacingOccurrences(of: " H", with: " ST")
        let out = sut.handle(line: forged, mailbox: box, now: now)
        XCTAssertFalse(out.lines.contains("Mail for you: 2 unread"))
        XCTAssertEqual(out.lines.first, "That signature is not from a paired device.")
    }

    /// The caller's callsign is signed too.
    func testASignatureMadeForAnotherCallerIsRefused() throws {
        var sut = shell(caller: "K0EPI-3")
        let box = BBSShell.Mailbox()
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        _ = sut.handle(line: try signed("", "C1", caller: "K0EPI-7"), mailbox: box, now: now)
        XCTAssertFalse(sut.isOwner)
    }

    /// A challenge is good for five minutes.
    func testAChallengeExpires() throws {
        var sut = shell()
        let box = BBSShell.Mailbox()
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        let out = sut.handle(line: try signed("", "C1"), mailbox: box,
                             now: now.addingTimeInterval(OwnerKey.challengeLifetime + 1))
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.lines, ["That challenge has run out. Ask for a new one: OWNER KEY."])
    }

    /// A SIG with no challenge outstanding needs one first.
    func testASignatureNeedsAChallengeFirst() throws {
        var sut = shell()
        let out = sut.handle(line: try signed("", "C1"), mailbox: BBSShell.Mailbox(), now: now)
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.lines, ["Ask for a challenge first: OWNER KEY."])
    }

    func testABadSignatureIsLogged() {
        var sut = shell()
        let box = BBSShell.Mailbox()
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        let out = sut.handle(line: "OWNER SIG AAAA", mailbox: box, now: now)
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.lines.first, "That signature is not from a paired device.")
        XCTAssertEqual(out.effects, [.ownerSignIn(accepted: false)])
    }

    /// Anyone can send wrong codes as the owner's callsign and lock codes
    /// out for 15 minutes. A paired device's key cannot be guessed, so the
    /// code lockout does not stop it: the owner can always get in.
    func testAKeySignsInWhileCodesAreLockedOut() throws {
        var sut = shell(checkOwnerCode: { _, _ in .lockedOut })
        let box = BBSShell.Mailbox()
        XCTAssertEqual(sut.handle(line: "OWNER 123456", mailbox: box, now: now).lines,
                       ["Too many wrong codes. Try again in 15 minutes."])
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        _ = sut.handle(line: try signed("", "C1"), mailbox: box, now: now)
        XCTAssertTrue(sut.isOwner)
    }

    /// Signed in with a code, from a plain terminal, owner commands that
    /// only read are typed as they are.
    func testACodeSignInRunsReadingCommandsUnsigned() {
        var sut = shell(paired: false, checkOwnerCode: { _, _ in .accepted })
        var box = BBSShell.Mailbox()
        box.ownerStatus = ["Mail for you: 2 unread"]
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
        XCTAssertEqual(out.lines, ["No device is paired with this mailbox. Pair one in its owner settings at home."])
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
/// mailbox's challenge is answered with a signature over no command; after
/// that, each owner command the operator types is signed with the latest
/// challenge before it goes out. The operator types ST and nothing else.
final class OwnerSignInResponderTests: XCTestCase {

    private func sign(_ challenge: String, _ station: String, _ caller: String, _ command: String) -> String? {
        "SIG(\(challenge),\(station),\(caller),\(command))"
    }

    func testTheChallengeIsAnsweredOnce() {
        var responder = OwnerSignInResponder()
        responder.begin(peer: "k0epi-4")
        XCTAssertEqual(responder.reply(toLine: "Owner challenge: 4F2A", from: "K0EPI-4", caller: "K0EPI-3", sign: sign),
                       "OWNER SIG SIG(4F2A,K0EPI-4,K0EPI-3,)")
        XCTAssertNil(responder.reply(toLine: "Owner challenge: 4F2A", from: "K0EPI-4", caller: "K0EPI-3", sign: sign))
    }

    /// A challenge nobody asked for, or from another station, is not answered.
    func testOnlyWhatWasAskedIsAnswered() {
        var responder = OwnerSignInResponder()
        XCTAssertNil(responder.reply(toLine: "Owner challenge: 4F2A", from: "K0EPI-4", caller: "K0EPI-3", sign: sign))
        responder.begin(peer: "K0EPI-4")
        XCTAssertNil(responder.reply(toLine: "Owner challenge: 4F2A", from: "W0ARP-1", caller: "K0EPI-3", sign: sign))
        XCTAssertNil(responder.reply(toLine: "Welcome", from: "K0EPI-4", caller: "K0EPI-3", sign: sign))
        XCTAssertNotNil(responder.reply(toLine: "Owner challenge: 4F2A", from: "K0EPI-4", caller: "K0EPI-3", sign: sign))
    }

    /// After the sign-in, an owner command typed by the operator goes out
    /// signed with the challenge the last reply brought, once.
    func testAnOwnerCommandIsSignedWithTheLatestChallenge() {
        var responder = OwnerSignInResponder()
        responder.begin(peer: "K0EPI-4")
        _ = responder.reply(toLine: "Owner challenge: C1", from: "K0EPI-4", caller: "K0EPI-3", sign: sign)
        _ = responder.reply(toLine: "Owner challenge: C2", from: "K0EPI-4", caller: "K0EPI-3", sign: sign)
        XCTAssertEqual(responder.signed(line: "st", to: "K0EPI-4", caller: "K0EPI-3", sign: sign),
                       "OWNER SIG SIG(C2,K0EPI-4,K0EPI-3,st) st")
        XCTAssertNil(responder.signed(line: "ST", to: "K0EPI-4", caller: "K0EPI-3", sign: sign),
                     "C2 is spent until the next reply brings C3")
    }

    /// Everything else goes as typed, and nothing is signed for a station
    /// never signed in to.
    func testOtherLinesGoAsTyped() {
        var responder = OwnerSignInResponder()
        XCTAssertNil(responder.signed(line: "ST", to: "K0EPI-4", caller: "K0EPI-3", sign: sign))
        responder.begin(peer: "K0EPI-4")
        _ = responder.reply(toLine: "Owner challenge: C1", from: "K0EPI-4", caller: "K0EPI-3", sign: sign)
        _ = responder.reply(toLine: "Owner challenge: C2", from: "K0EPI-4", caller: "K0EPI-3", sign: sign)
        XCTAssertNil(responder.signed(line: "L", to: "K0EPI-4", caller: "K0EPI-3", sign: sign))
        XCTAssertNil(responder.signed(line: "ST", to: "W0ARP-1", caller: "K0EPI-3", sign: sign))
    }

    /// The disconnect forgets the sign-in.
    func testEndingTheSessionForgetsIt() {
        var responder = OwnerSignInResponder()
        responder.begin(peer: "K0EPI-4")
        _ = responder.reply(toLine: "Owner challenge: C1", from: "K0EPI-4", caller: "K0EPI-3", sign: sign)
        _ = responder.reply(toLine: "Owner challenge: C2", from: "K0EPI-4", caller: "K0EPI-3", sign: sign)
        responder.end(peer: "K0EPI-4")
        XCTAssertNil(responder.signed(line: "ST", to: "K0EPI-4", caller: "K0EPI-3", sign: sign))
    }

    /// The mailbox's own replies to real signatures, end to end.
    func testRealSignaturesSignInAndRunACommand() throws {
        let device = P256.Signing.PrivateKey()
        var shell = BBSShell(caller: "K0EPI-3", sysop: "K0EPI-4", pageRows: 0,
                             ownerKeys: [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))])
        var box = BBSShell.Mailbox()
        box.ownerStatus = ["Mail for you: 2 unread"]
        var responder = OwnerSignInResponder()
        let realSign: (String, String, String, String) -> String? = { challenge, station, caller, command in
            try? OwnerKey.sign(challenge: challenge, station: station, caller: caller, command: command, with: device)
        }
        responder.begin(peer: "K0EPI-4")
        var lines = shell.handle(line: "OWNER KEY", mailbox: box, now: Date()).lines
        let signIn = try XCTUnwrap(responder.reply(toLine: lines[0], from: "K0EPI-4", caller: "K0EPI-3", sign: realSign))
        lines = shell.handle(line: signIn, mailbox: box, now: Date()).lines
        XCTAssertTrue(shell.isOwner)
        for line in lines { _ = responder.reply(toLine: line, from: "K0EPI-4", caller: "K0EPI-3", sign: realSign) }
        let st = try XCTUnwrap(responder.signed(line: "ST", to: "K0EPI-4", caller: "K0EPI-3", sign: realSign))
        XCTAssertTrue(shell.handle(line: st, mailbox: box, now: Date()).lines.contains("Mail for you: 2 unread"))
    }
}
