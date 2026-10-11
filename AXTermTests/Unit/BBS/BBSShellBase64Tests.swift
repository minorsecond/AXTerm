//
//  BBSShellBase64Tests.swift
//  AXTermTests
//
//  DB, a download as base64 text (Docs/RemoteAccessPlan.md, part 2): for a
//  caller whose link carries only lines, such as a NET/ROM circuit through
//  the node, or a terminal without YAPP. It costs a third more airtime than
//  the file, so it is offered, never chosen for the caller.
//

import XCTest
@testable import AXTerm

final class BBSShellBase64Tests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func shell(linesOnly: Bool = false, bytesPerSecond: Double = 1_000) -> BBSShell {
        BBSShell(caller: "K0XYZ", sysop: "K0EPI-4", bytesPerSecond: bytesPerSecond,
                 linesOnlyDirectCall: linesOnly ? "K0EPI-4" : nil, pageRows: 0)
    }

    private func mailbox(_ files: [BBSSharedFile]) -> BBSShell.Mailbox {
        BBSShell.Mailbox(files: BBSFileIndex(areas: [BBSFileArea(name: "PARK")], files: files))
    }

    private func photo(bytes: Int = 9_000) -> BBSSharedFile {
        BBSSharedFile(area: "PARK", name: "photo.jpg", byteCount: bytes, modifiedAt: now, about: "")
    }

    /// Over a link that carries only lines, D of a binary points at DB.
    func testDOfABinaryOverLinesOnlyOffersDB() {
        var sut = shell(linesOnly: true)
        let out = sut.handle(line: "D photo.jpg", mailbox: mailbox([photo()]), now: now)
        XCTAssertTrue(out.lines.joined().contains("DB photo.jpg"), "\(out.lines)")
        XCTAssertTrue(out.effects.isEmpty)
    }

    func testDBSendsItAsBase64() {
        var sut = shell(linesOnly: true)
        let file = photo()
        let out = sut.handle(line: "DB photo.jpg", mailbox: mailbox([file]), now: now)
        XCTAssertEqual(out.effects, [.viewFileAsBase64(file)])
        XCTAssertTrue(out.lines.first?.contains("base64") ?? false, "\(out.lines)")
    }

    /// Anyone may ask for it, on any link: a terminal without YAPP.
    func testDBWorksOnADirectLinkToo() {
        var sut = shell()
        let file = photo()
        XCTAssertEqual(sut.handle(line: "DB photo.jpg", mailbox: mailbox([file]), now: now).effects,
                       [.viewFileAsBase64(file)])
    }

    func testABigFileIsRefused() {
        var sut = shell()
        let out = sut.handle(line: "DB photo.jpg", mailbox: mailbox([photo(bytes: 200_000)]), now: now)
        XCTAssertTrue(out.effects.isEmpty)
        XCTAssertTrue(out.lines.joined().contains("too big"), "\(out.lines)")
    }

    /// A long one asks first, like D.
    func testALongOneAsksFirst() {
        var sut = shell(bytesPerSecond: 20)
        let file = photo(bytes: 20_000)
        XCTAssertTrue(sut.handle(line: "DB photo.jpg", mailbox: mailbox([file]), now: now).effects.isEmpty)
        XCTAssertEqual(sut.handle(line: "DB photo.jpg", mailbox: mailbox([file]), now: now).effects,
                       [.viewFileAsBase64(file)])
    }

    func testHelpMentionsDB() {
        var sut = shell()
        XCTAssertTrue(sut.handle(line: "H", mailbox: mailbox([]), now: now).lines.joined().contains("DB <name>"))
    }
}
