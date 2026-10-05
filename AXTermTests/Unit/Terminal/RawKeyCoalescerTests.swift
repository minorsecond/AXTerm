//
//  RawKeyCoalescerTests.swift
//  AXTermTests
//
//  Raw terminal mode (Docs/TerminalInputModes.md): which bytes each key
//  makes, when the buffer is sent, and what the echo line shows.
//

import XCTest
@testable import AXTerm

final class RawKeyCoalescerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func coalescer(paclen: Int = 128) -> RawKeyCoalescer {
        RawKeyCoalescer(maxChunk: paclen)
    }

    // MARK: Key map

    func testKeysMapToTheBytesInTheTable() {
        XCTAssertEqual(RawKeyCoalescer.bytes(for: .text("a")), Data([0x61]))
        XCTAssertEqual(RawKeyCoalescer.bytes(for: .text("é")), Data("é".utf8))
        XCTAssertEqual(RawKeyCoalescer.bytes(for: .returnKey), Data([0x0D]))
        XCTAssertEqual(RawKeyCoalescer.bytes(for: .backspace), Data([0x08]))
        XCTAssertEqual(RawKeyCoalescer.bytes(for: .tab), Data([0x09]))
        XCTAssertEqual(RawKeyCoalescer.bytes(for: .escape), Data([0x1B]))
    }

    func testControlLettersMapToC0Codes() {
        XCTAssertEqual(RawKeyCoalescer.controlByte(for: "c"), 0x03)
        XCTAssertEqual(RawKeyCoalescer.controlByte(for: "C"), 0x03)
        XCTAssertEqual(RawKeyCoalescer.controlByte(for: "z"), 0x1A)
        XCTAssertEqual(RawKeyCoalescer.controlByte(for: "@"), 0x00)
        XCTAssertEqual(RawKeyCoalescer.controlByte(for: "["), 0x1B)
        XCTAssertEqual(RawKeyCoalescer.controlByte(for: "_"), 0x1F)
        XCTAssertNil(RawKeyCoalescer.controlByte(for: "1"))
        XCTAssertNil(RawKeyCoalescer.controlByte(for: "é"))
    }

    func testPastedLineEndingsBecomeOneCR() {
        XCTAssertEqual(RawKeyCoalescer.bytes(for: .text("a\nb")), Data([0x61, 0x0D, 0x62]))
        XCTAssertEqual(RawKeyCoalescer.bytes(for: .text("a\r\nb")), Data([0x61, 0x0D, 0x62]))
        XCTAssertEqual(RawKeyCoalescer.bytes(for: .text("a\rb")), Data([0x61, 0x0D, 0x62]))
    }

    // MARK: When bytes leave

    func testPrintableKeysWaitInTheBuffer() {
        var c = coalescer()
        XCTAssertTrue(c.input(.text("d"), at: t0).chunks.isEmpty)
        XCTAssertTrue(c.input(.text("i"), at: t0).chunks.isEmpty)
        XCTAssertEqual(c.pending, Data("di".utf8))
    }

    func testReturnSendsTheBufferWithTheCRAtItsEnd() {
        var c = coalescer()
        _ = c.input(.text("dir"), at: t0)
        let out = c.input(.returnKey, at: t0)
        XCTAssertEqual(out.chunks, [Data("dir\r".utf8)])
        XCTAssertTrue(c.pending.isEmpty)
    }

    func testControlKeysSendAtOnce() {
        var c = coalescer()
        _ = c.input(.text("ab"), at: t0)
        XCTAssertEqual(c.input(.control(0x03), at: t0).chunks, [Data([0x61, 0x62, 0x03])])
        XCTAssertEqual(c.input(.escape, at: t0).chunks, [Data([0x1B])])
    }

    func testBackspaceAndTabWaitLikePrintableKeys() {
        var c = coalescer()
        XCTAssertTrue(c.input(.backspace, at: t0).chunks.isEmpty)
        XCTAssertTrue(c.input(.tab, at: t0).chunks.isEmpty)
        XCTAssertEqual(c.pending, Data([0x08, 0x09]))
    }

    func testTheBufferGoesOutAfterOneSecondOfQuiet() {
        var c = coalescer()
        _ = c.input(.text("y"), at: t0)
        XCTAssertEqual(c.flushDeadline, t0.addingTimeInterval(RawKeyCoalescer.idleSend))
        XCTAssertNil(c.flushIfIdle(at: t0.addingTimeInterval(0.99)))
        XCTAssertEqual(c.flushIfIdle(at: t0.addingTimeInterval(1.0)), Data("y".utf8))
        XCTAssertNil(c.flushDeadline)
    }

    func testEachKeyRestartsTheQuietTimer() {
        var c = coalescer()
        _ = c.input(.text("a"), at: t0)
        _ = c.input(.text("b"), at: t0.addingTimeInterval(0.8))
        XCTAssertNil(c.flushIfIdle(at: t0.addingTimeInterval(1.2)))
        XCTAssertEqual(c.flushIfIdle(at: t0.addingTimeInterval(1.8)), Data("ab".utf8))
    }

    func testIdleIsOneSecondLikeTNC2Pactime() {
        XCTAssertEqual(RawKeyCoalescer.idleSend, 1.0)
    }

    func testAFullPaclenGoesOutAndTypingCarriesOn() {
        var c = coalescer(paclen: 4)
        XCTAssertTrue(c.input(.text("abc"), at: t0).chunks.isEmpty)
        XCTAssertEqual(c.input(.text("de"), at: t0).chunks, [Data("abcd".utf8)])
        XCTAssertEqual(c.pending, Data("e".utf8))
    }

    func testALongPasteIsCutAtPaclenAndAtEachCR() {
        var c = coalescer(paclen: 4)
        let out = c.input(.text("abcdefg\nhi"), at: t0)
        XCTAssertEqual(out.chunks, [Data("abcd".utf8), Data("efg\r".utf8)])
        XCTAssertEqual(c.pending, Data("hi".utf8))
    }

    func testNoChunkIsEverLongerThanPaclen() {
        var c = coalescer(paclen: 3)
        let out = c.input(.text(String(repeating: "x", count: 10) + "\n"), at: t0)
        XCTAssertTrue(out.chunks.allSatisfy { $0.count <= 3 })
        XCTAssertEqual(out.chunks.reduce(Data(), +), Data((String(repeating: "x", count: 10) + "\r").utf8))
    }

    func testFlushAllEmptiesTheBuffer() {
        var c = coalescer()
        _ = c.input(.text("half"), at: t0)
        XCTAssertEqual(c.flushAll(), Data("half".utf8))
        XCTAssertNil(c.flushAll())
        XCTAssertNil(c.flushDeadline)
    }

    func testAPaclenBelowOneIsTreatedAsOne() {
        var c = RawKeyCoalescer(maxChunk: 0)
        XCTAssertEqual(c.input(.text("ab"), at: t0).chunks, [Data("a".utf8), Data("b".utf8)])
    }

    // MARK: Echo line

    func testEchoShowsTypedTextAndBackspaceRemovesIt() {
        var c = coalescer()
        _ = c.input(.text("dirx"), at: t0)
        _ = c.input(.backspace, at: t0)
        XCTAssertEqual(c.echoLine, "dir")
    }

    func testBackspaceOnAnEmptyEchoLineStillSendsBS() {
        var c = coalescer()
        _ = c.input(.backspace, at: t0)
        XCTAssertEqual(c.echoLine, "")
        XCTAssertEqual(c.flushAll(), Data([0x08]))
    }

    func testReturnCommitsTheEchoLine() {
        var c = coalescer()
        _ = c.input(.text("list"), at: t0)
        let out = c.input(.returnKey, at: t0)
        XCTAssertEqual(out.committedLines, ["list"])
        XCTAssertEqual(c.echoLine, "")
    }

    func testAPasteCommitsEachLine() {
        var c = coalescer()
        let out = c.input(.text("one\ntwo\nthr"), at: t0)
        XCTAssertEqual(out.committedLines, ["one", "two"])
        XCTAssertEqual(c.echoLine, "thr")
    }

    func testControlKeysLeaveTheEchoLineAlone() {
        var c = coalescer()
        _ = c.input(.text("ab"), at: t0)
        _ = c.input(.control(0x03), at: t0)
        _ = c.input(.escape, at: t0)
        XCTAssertEqual(c.echoLine, "ab")
    }

    func testTabEchoesAsASpace() {
        var c = coalescer()
        _ = c.input(.tab, at: t0)
        XCTAssertEqual(c.echoLine, " ")
    }

    func testResetEchoForgetsTheLineWithoutSending() {
        var c = coalescer()
        _ = c.input(.text("ab"), at: t0)
        c.resetEcho()
        XCTAssertEqual(c.echoLine, "")
        XCTAssertEqual(c.pending, Data("ab".utf8))
    }

    // MARK: Console text

    func testConsoleTextNamesControlBytes() {
        XCTAssertEqual(RawKeyCoalescer.consoleText(for: Data("dir\r".utf8)), "dir↵")
        XCTAssertEqual(RawKeyCoalescer.consoleText(for: Data([0x61, 0x08])), "a⌫")
        XCTAssertEqual(RawKeyCoalescer.consoleText(for: Data([0x03])), "^C")
        XCTAssertEqual(RawKeyCoalescer.consoleText(for: Data([0x1B])), "^[")
        XCTAssertEqual(RawKeyCoalescer.consoleText(for: Data([0x09])), "⇥")
        XCTAssertEqual(RawKeyCoalescer.consoleText(for: Data([0x00])), "^@")
        XCTAssertEqual(RawKeyCoalescer.consoleText(for: Data([0x7F])), "^?")
        XCTAssertEqual(RawKeyCoalescer.consoleText(for: Data("é".utf8)), "é")
    }

    func testConsoleTextIsNeverEmptyForData() {
        XCTAssertFalse(RawKeyCoalescer.consoleText(for: Data([0x0A])).isEmpty)
    }
}
