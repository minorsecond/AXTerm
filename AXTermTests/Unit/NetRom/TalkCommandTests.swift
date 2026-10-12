//
//  TalkCommandTests.swift
//  AXTermTests
//
//  Talking to the operator without leaving (operator, 2026-10-12): `T` or
//  `TALK` at the node or the mailbox pages whoever is at the station, as
//  a BBS's "talk to the sysop" does. The commands only ask; paging, the
//  chat and the way back are the station's (`TalkRelay`).
//

import XCTest
@testable import AXTerm

final class TalkCommandTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func node() -> NetRomNodeShell {
        NetRomNodeShell(nodeAlias: "EPINOD", nodeCall: "K0EPI-7", version: "AXTerm 1.0", caller: "K0EPI-3")
    }

    private func mailbox() -> BBSShell {
        BBSShell(caller: "K0EPI-3", sysop: "K0EPI-4")
    }

    func testTalkAtTheNodePagesTheOperator() {
        for word in ["T", "t", "TA", "TALK", "talk"] {
            var shell = node()
            let out = shell.handle(line: word, snapshot: .init(), now: now)
            XCTAssertEqual(out.effects, [.talk], word)
            XCTAssertEqual(out.lines, ["Paging the operator\u{2026}"], word)
            XCTAssertNil(out.prompt, "\(word): the station answers next, not the prompt")
        }
    }

    func testTheNodeOffersTalk() {
        let greeting = node().greeting(snapshot: .init(bbsAvailable: true))
        XCTAssertEqual(greeting.lines.last, "BBS CONNECT INFO NODES ROUTES MH TALK BYE  (? for help)")
        var shell = node()
        let help = shell.handle(line: "?", snapshot: .init(), now: now).lines
        XCTAssertTrue(help.contains("TALK    page the operator to chat"), "\(help)")
    }

    func testTalkAtTheMailboxPagesTheOperator() {
        for word in ["T", "TALK", "talk"] {
            var shell = mailbox()
            let out = shell.handle(line: word, mailbox: .init(), now: now)
            XCTAssertEqual(out.effects, [.talk], word)
            XCTAssertEqual(out.lines, ["Paging the operator\u{2026}"], word)
            XCTAssertNil(out.prompt, word)
        }
    }

    func testTheMailboxOffersTalk() {
        // The whole help, not its first page.
        var shell = BBSShell(caller: "K0EPI-3", sysop: "K0EPI-4", pageRows: 0)
        let help = shell.handle(line: "H", mailbox: .init(), now: now).lines
        XCTAssertTrue(help.contains("B          disconnect         T  page the operator to chat"), "\(help)")
        XCTAssertTrue(BBSShell.builtInVerbs.isSuperset(of: ["T", "TALK"]),
                      "an owner command cannot take the word")
    }

    /// While composing a message, T is text, like any other command.
    func testTIsTextWhileComposing() {
        var shell = mailbox()
        _ = shell.handle(line: "S K0EPI", mailbox: .init(nextID: 1), now: now)
        _ = shell.handle(line: "Subject", mailbox: .init(nextID: 1), now: now)
        XCTAssertTrue(shell.handle(line: "T", mailbox: .init(nextID: 1), now: now).effects.isEmpty)
    }
}
