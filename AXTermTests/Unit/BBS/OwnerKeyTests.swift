//
//  OwnerKeyTests.swift
//  AXTermTests
//
//  Signing in as the owner from another AXTerm with a key pair
//  (Docs/RemoteAccessPlan.md, "Signing in"). The device keeps its private
//  key; home keeps the public keys of the devices paired with it. Home sends
//  a fresh challenge, the device signs the challenge and home's callsign,
//  and everything on the air stays readable: the challenge and signature are
//  extra characters, not a cipher.
//

import CryptoKit
import XCTest
@testable import AXTerm

final class OwnerKeyTests: XCTestCase {

    private let station = "K0EPI-4"

    func testASignatureFromAPairedDeviceIsAccepted() throws {
        let device = P256.Signing.PrivateKey()
        let paired = [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))]
        let challenge = "4F2A9C11E07B3D55"
        let signature = try OwnerKey.sign(challenge: challenge, station: station, with: device)
        XCTAssertTrue(OwnerKey.verify(signature: signature, challenge: challenge, station: station, paired: paired))
    }

    func testAnUnpairedDeviceIsRefused() throws {
        let stranger = P256.Signing.PrivateKey()
        let paired = [OwnerKey.PairedDevice(name: "iPad",
                                            publicKey: OwnerKey.encode(P256.Signing.PrivateKey().publicKey))]
        let signature = try OwnerKey.sign(challenge: "AA", station: station, with: stranger)
        XCTAssertFalse(OwnerKey.verify(signature: signature, challenge: "AA", station: station, paired: paired))
    }

    /// A recorded signature is no good for another challenge or station.
    func testASignatureIsTiedToItsChallengeAndStation() throws {
        let device = P256.Signing.PrivateKey()
        let paired = [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))]
        let signature = try OwnerKey.sign(challenge: "AA", station: station, with: device)
        XCTAssertFalse(OwnerKey.verify(signature: signature, challenge: "BB", station: station, paired: paired))
        XCTAssertFalse(OwnerKey.verify(signature: signature, challenge: "AA", station: "K0EPI-7", paired: paired))
    }

    func testGarbageIsRefused() {
        XCTAssertFalse(OwnerKey.verify(signature: "not base64!", challenge: "AA", station: station, paired: []))
        XCTAssertNil(OwnerKey.decode("nope"))
    }

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

    private func shell(caller: String = "K0EPI-3", paired: Bool = true) -> BBSShell {
        let devices = paired ? [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))] : []
        return BBSShell(caller: caller, sysop: "K0EPI-4", pageRows: 0,
                        ownerKeys: devices.isEmpty ? nil : devices,
                        makeChallenge: { "4F2A9C11E07B3D55" })
    }

    func testTheKeyHandshakeSignsIn() throws {
        var sut = shell()
        let box = BBSShell.Mailbox()
        let asked = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        XCTAssertEqual(asked.lines, ["Owner challenge: 4F2A9C11E07B3D55"])
        let signature = try OwnerKey.sign(challenge: "4F2A9C11E07B3D55", station: "K0EPI-4", with: device)
        let out = sut.handle(line: "OWNER SIG \(signature)", mailbox: box, now: now)
        XCTAssertTrue(sut.isOwner)
        XCTAssertEqual(out.effects, [.ownerSignIn(accepted: true)])
    }

    /// The challenge is used once: a second SIG needs a new KEY.
    func testAChallengeWorksOnce() throws {
        var sut = shell()
        let box = BBSShell.Mailbox()
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        let signature = try OwnerKey.sign(challenge: "4F2A9C11E07B3D55", station: "K0EPI-4", with: device)
        _ = sut.handle(line: "OWNER SIG garbage", mailbox: box, now: now)
        let out = sut.handle(line: "OWNER SIG \(signature)", mailbox: box, now: now)
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.lines, ["Ask for a challenge first: OWNER KEY."])
    }

    func testABadSignatureIsLogged() {
        var sut = shell()
        let box = BBSShell.Mailbox()
        _ = sut.handle(line: "OWNER KEY", mailbox: box, now: now)
        let out = sut.handle(line: "OWNER SIG AAAA", mailbox: box, now: now)
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.lines, ["That signature is not from a paired device."])
        XCTAssertEqual(out.effects, [.ownerSignIn(accepted: false)])
    }

    /// Without paired devices, OWNER KEY is unknown like any command.
    func testNoPairedDevicesMeansUnknown() {
        var sut = shell(paired: false)
        XCTAssertTrue(sut.handle(line: "OWNER KEY", mailbox: BBSShell.Mailbox(), now: now).lines.first?
            .hasPrefix("? OWNER") ?? false)
    }
}

/// The terminal's side: after Sign In as Owner sends OWNER KEY, the
/// mailbox's challenge line is answered with the signature, once.
final class OwnerSignInResponderTests: XCTestCase {

    private func sign(_ challenge: String, _ station: String) -> String? { "SIG(\(challenge),\(station))" }

    func testTheChallengeIsAnsweredOnce() {
        var responder = OwnerSignInResponder()
        responder.begin(peer: "k0epi-4")
        XCTAssertEqual(responder.reply(toLine: "Owner challenge: 4F2A", from: "K0EPI-4", sign: sign),
                       "OWNER SIG SIG(4F2A,K0EPI-4)")
        XCTAssertNil(responder.reply(toLine: "Owner challenge: 4F2A", from: "K0EPI-4", sign: sign))
    }

    /// A challenge nobody asked for, or from another station, is not answered.
    func testOnlyWhatWasAskedIsAnswered() {
        var responder = OwnerSignInResponder()
        XCTAssertNil(responder.reply(toLine: "Owner challenge: 4F2A", from: "K0EPI-4", sign: sign))
        responder.begin(peer: "K0EPI-4")
        XCTAssertNil(responder.reply(toLine: "Owner challenge: 4F2A", from: "W0ARP-1", sign: sign))
        XCTAssertNil(responder.reply(toLine: "Welcome", from: "K0EPI-4", sign: sign))
        XCTAssertNotNil(responder.reply(toLine: "Owner challenge: 4F2A", from: "K0EPI-4", sign: sign))
    }

    /// The mailbox's own reply to a real signature, end to end.
    func testARealSignatureSignsIn() throws {
        let device = P256.Signing.PrivateKey()
        var shell = BBSShell(caller: "K0EPI-3", sysop: "K0EPI-4", pageRows: 0,
                             ownerKeys: [OwnerKey.PairedDevice(name: "iPad", publicKey: OwnerKey.encode(device.publicKey))])
        var responder = OwnerSignInResponder()
        responder.begin(peer: "K0EPI-4")
        let challengeLine = try XCTUnwrap(shell.handle(line: "OWNER KEY", mailbox: BBSShell.Mailbox(), now: Date()).lines.first)
        let reply = try XCTUnwrap(responder.reply(toLine: challengeLine, from: "K0EPI-4") { challenge, station in
            try? OwnerKey.sign(challenge: challenge, station: station, with: device)
        })
        _ = shell.handle(line: reply, mailbox: BBSShell.Mailbox(), now: Date())
        XCTAssertTrue(shell.isOwner)
    }
}
