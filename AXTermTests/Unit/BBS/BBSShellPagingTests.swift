//
//  BBSShellPagingTests.swift
//  AXTermTests
//
//  The mailbox from a plain terminal (operator, 2026-10-11:
//  Docs/RemoteAccessPlan.md, part 2). Long output comes in pages, with
//  "Enter for more, A to stop", so a caller on a 1200-baud link can stop a
//  long message after the part they wanted. FBB's OP sets the page length;
//  OP 0 turns paging off.
//

import XCTest
@testable import AXTerm

final class BBSShellPagingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func mailbox(bodyLines: Int) -> BBSShell.Mailbox {
        let body = (1...bodyLines).map { "Line \($0)" }.joined(separator: "\n")
        return BBSShell.Mailbox(messages: [BBSMessage(id: 1, from: "W0ARP", to: "K0XYZ", subject: "Long",
                                                      body: body, receivedAt: now)], nextID: 2)
    }

    private func shell(pageRows: Int) -> BBSShell {
        BBSShell(caller: "K0XYZ", sysop: "K0EPI-4", calendar: utc, pageRows: pageRows)
    }

    func testLongOutputComesInPages() {
        var sut = shell(pageRows: 5)
        let box = mailbox(bodyLines: 12)
        let whole = shell(pageRows: 0)
        var unpaged = whole
        let all = unpaged.handle(line: "R 1", mailbox: box, now: now).lines
        XCTAssertGreaterThan(all.count, 10)

        var seen: [String] = []
        var out = sut.handle(line: "R 1", mailbox: box, now: now)
        XCTAssertEqual(out.lines.count, 5)
        XCTAssertEqual(out.prompt, BBSShell.morePrompt(remaining: all.count - 5))
        seen += out.lines
        while out.prompt != BBSShell.commandPrompt {
            out = sut.handle(line: "", mailbox: box, now: now)
            XCTAssertLessThanOrEqual(out.lines.count, 5)
            seen += out.lines
        }
        XCTAssertEqual(seen, all, "every line once, in order")
        XCTAssertEqual(sut.state, .command)
    }

    func testAStopsTheRest() {
        var sut = shell(pageRows: 5)
        let box = mailbox(bodyLines: 12)
        _ = sut.handle(line: "R 1", mailbox: box, now: now)
        let out = sut.handle(line: "a", mailbox: box, now: now)
        XCTAssertEqual(out.lines, [])
        XCTAssertEqual(out.prompt, BBSShell.commandPrompt)
        XCTAssertEqual(sut.state, .command)
    }

    /// Typing a command in place of Enter stops the pages and runs it.
    func testACommandWhilePagedRunsIt() {
        var sut = shell(pageRows: 5)
        let box = mailbox(bodyLines: 12)
        _ = sut.handle(line: "R 1", mailbox: box, now: now)
        let out = sut.handle(line: "V", mailbox: box, now: now)
        XCTAssertTrue(out.lines.contains(BBSShell.version), "\(out.lines)")
        XCTAssertEqual(out.prompt, BBSShell.commandPrompt)
    }

    func testShortOutputIsNotPaged() {
        var sut = shell(pageRows: 24)
        let out = sut.handle(line: "R 1", mailbox: mailbox(bodyLines: 3), now: now)
        XCTAssertEqual(out.prompt, BBSShell.commandPrompt)
    }

    func testOPSetsThePageLength() {
        var sut = shell(pageRows: 24)
        let box = mailbox(bodyLines: 12)
        XCTAssertEqual(sut.handle(line: "OP 4", mailbox: box, now: now).lines, ["Pages of 4 lines."])
        XCTAssertEqual(sut.handle(line: "R 1", mailbox: box, now: now).lines.count, 4)
        _ = sut.handle(line: "A", mailbox: box, now: now)
        XCTAssertEqual(sut.handle(line: "OP 0", mailbox: box, now: now).lines, ["No pages: output comes whole."])
        XCTAssertEqual(sut.handle(line: "R 1", mailbox: box, now: now).prompt, BBSShell.commandPrompt)
        XCTAssertEqual(sut.handle(line: "OP", mailbox: box, now: now).lines,
                       ["No pages: output comes whole. OP n sets pages of n lines."])
    }

    /// A plain terminal shows 24 lines; paging is on unless OP 0 says not.
    func testPagesOf24ByDefault() {
        XCTAssertEqual(BBSShell(caller: "K0XYZ", sysop: "K0EPI-4").pageRows, 24)
    }

    func testHelpMentionsOP() {
        var sut = shell(pageRows: 0)
        let help = sut.handle(line: "H", mailbox: mailbox(bodyLines: 1), now: now).lines.joined(separator: "\n")
        XCTAssertTrue(help.contains("OP n"), help)
    }
}
