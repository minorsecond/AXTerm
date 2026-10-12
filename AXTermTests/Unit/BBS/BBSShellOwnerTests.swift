//
//  BBSShellOwnerTests.swift
//  AXTermTests
//
//  Owner commands from the road (Docs/RemoteAccessPlan.md, "Signing in").
//  The operator signs in at the mailbox with OWNER and the six-digit code
//  from an authenticator app; the command and code go in plain text, and
//  the code works once. Signed in, ST shows the station. To anyone else,
//  and to the operator with owner commands off, OWNER and ST are unknown
//  commands like any other.
//

import XCTest
@testable import AXTerm

final class BBSShellOwnerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_111_111_111)
    private let secret = Data("12345678901234567890".utf8)
    private var checker: OwnerCode.Checker!

    override func setUp() {
        super.setUp()
        checker = OwnerCode.Checker(secret: secret)
    }

    private func shell(caller: String = "K0EPI-3", owner: Bool = true) -> BBSShell {
        BBSShell(caller: caller, sysop: "K0EPI-4", pageRows: 0,
                 checkOwnerCode: owner ? { [unowned self] code, at in self.checker.check(code, at: at) } : nil)
    }

    private var box: BBSShell.Mailbox {
        var mailbox = BBSShell.Mailbox()
        mailbox.ownerStatus = ["Mail for you: 2 unread", "Uploads waiting in Inbox: 1"]
        return mailbox
    }

    private var code: String { OwnerCode.code(secret: secret, at: now) }

    func testTheRightCodeSignsIn() {
        var sut = shell()
        let out = sut.handle(line: "OWNER \(code)", mailbox: box, now: now)
        XCTAssertTrue(sut.isOwner)
        XCTAssertEqual(out.effects, [.ownerSignIn(accepted: true)])
        XCTAssertEqual(out.lines, ["Signed in as the owner until you disconnect. ST shows the station."])
    }

    func testAWrongCodeSaysSoAndIsLogged() {
        var sut = shell()
        let out = sut.handle(line: "OWNER 000000", mailbox: box, now: now)
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.effects, [.ownerSignIn(accepted: false)])
        XCTAssertEqual(out.lines, ["That code is not right."])
    }

    func testAUsedCodeIsRefused() {
        var first = shell()
        _ = first.handle(line: "OWNER \(code)", mailbox: box, now: now)
        var second = shell()
        let out = second.handle(line: "OWNER \(code)", mailbox: box, now: now.addingTimeInterval(3))
        XCTAssertFalse(second.isOwner)
        XCTAssertEqual(out.lines, ["That code was already used. Wait for the next one."])
    }

    func testTooManyWrongCodesLockItOut() {
        var sut = shell()
        for _ in 0..<3 { _ = sut.handle(line: "OWNER 000000", mailbox: box, now: now) }
        let out = sut.handle(line: "OWNER \(code)", mailbox: box, now: now)
        XCTAssertFalse(sut.isOwner)
        XCTAssertEqual(out.lines, ["Too many wrong codes. Codes are refused for now; a paired device's key still works."])
    }

    func testSignedInSTShowsTheStation() {
        var sut = shell()
        _ = sut.handle(line: "OWNER \(code)", mailbox: box, now: now)
        XCTAssertEqual(sut.handle(line: "ST", mailbox: box, now: now).lines, box.ownerStatus)
    }

    func testSTBeforeSigningInSaysHow() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "ST", mailbox: box, now: now).lines,
                       ["Sign in first: OWNER and the six-digit code from your authenticator app."])
    }

    /// To another caller the commands do not exist.
    func testAnotherCallerSeesUnknownCommands() {
        var owner = shell(caller: "K0EPI-3", owner: true)
        var stranger = shell(caller: "W0ARP", owner: false)
        var nonsense = shell(caller: "W0ARP", owner: false)
        for verb in ["OWNER \(code)", "ST"] {
            let theirs = stranger.handle(line: verb, mailbox: box, now: now).lines
            let unknown = nonsense.handle(line: verb.replacingOccurrences(of: "OWNER", with: "ZZZZZ")
                                            .replacingOccurrences(of: "ST", with: "ZZ"), mailbox: box, now: now).lines
            XCTAssertEqual(theirs.first?.hasPrefix("? "), true, "\(verb): \(theirs)")
            XCTAssertEqual(theirs.count, unknown.count)
        }
        XCTAssertFalse(owner.handle(line: "ST", mailbox: box, now: now).lines.first?.hasPrefix("? ") ?? true)
    }

    func testHelpShowsOwnerCommandsOnlyToTheOwner() {
        var owner = shell(caller: "K0EPI-3", owner: true)
        var stranger = shell(caller: "W0ARP", owner: false)
        XCTAssertTrue(owner.handle(line: "H", mailbox: box, now: now).lines.joined().contains("OWNER"))
        XCTAssertFalse(stranger.handle(line: "H", mailbox: box, now: now).lines.joined().contains("OWNER"))
    }

    /// Only the operator's own callsign, at any SSID, may sign in.
    func testOnlyTheOperatorsCallsignIsAnOwner() {
        XCTAssertTrue(BBSShell.isOwnerCallsign("K0EPI-3", station: "K0EPI-4"))
        XCTAssertTrue(BBSShell.isOwnerCallsign("k0epi", station: "K0EPI-4"))
        XCTAssertFalse(BBSShell.isOwnerCallsign("W0ARP-3", station: "K0EPI-4"))
    }
}
