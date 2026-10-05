//
//  RawTerminalInputTests.swift
//  AXTermTests
//
//  The observable wrapper the compose row drives in raw mode.
//

import XCTest
@testable import AXTerm

@MainActor
final class RawTerminalInputTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 2_000_000)

    private func makeInput(paclen: Int = 128) -> RawTerminalInput {
        let input = RawTerminalInput(now: { [unowned self] in self.now })
        input.paclen = paclen
        return input
    }

    func testStartsInLineModeWithNothingBuffered() {
        let input = makeInput()
        XCTAssertEqual(input.mode, .line)
        XCTAssertEqual(input.echoLine, "")
        XCTAssertNil(input.flushDeadline)
    }

    func testKeysUseTheInjectedClockForTheIdleDeadline() {
        let input = makeInput()
        _ = input.input(.text("a"))
        XCTAssertEqual(input.flushDeadline, now.addingTimeInterval(RawKeyCoalescer.idleSend))
        XCTAssertEqual(input.echoLine, "a")
    }

    func testIdleTickSendsOnlyOnceTheDeadlinePasses() {
        let input = makeInput()
        _ = input.input(.text("ab"))
        XCTAssertNil(input.flushIfIdle())
        now = now.addingTimeInterval(1.0)
        XCTAssertEqual(input.flushIfIdle(), Data("ab".utf8))
        XCTAssertNil(input.flushIfIdle())
    }

    func testPaclenChangesApplyToTheNextKey() {
        let input = makeInput(paclen: 128)
        _ = input.input(.text("ab"))
        input.paclen = 3
        XCTAssertEqual(input.input(.text("c")).chunks, [Data("abc".utf8)])
    }

    func testLeavingRawModeHandsBackWhatWasBuffered() {
        let input = makeInput()
        input.mode = .raw
        _ = input.input(.text("half"))
        XCTAssertEqual(input.leaveRawMode(), Data("half".utf8))
        XCTAssertEqual(input.mode, .line)
        XCTAssertEqual(input.echoLine, "half", "the echo stays until a CR or a new session")
    }

    func testSessionEndedDropsTheBufferAndTheEcho() {
        let input = makeInput()
        input.mode = .raw
        _ = input.input(.text("lost"))
        input.sessionEnded()
        XCTAssertNil(input.flushAll())
        XCTAssertEqual(input.echoLine, "")
        XCTAssertEqual(input.mode, .raw, "the operator's choice of mode outlives one session")
    }

    func testPromptTextShowsPrintableBytesOnly() {
        XCTAssertEqual(RawTerminalInput.promptText(for: Data("BBS> ".utf8)), "BBS> ")
        XCTAssertEqual(RawTerminalInput.promptText(for: Data([0x07, 0x41, 0x1B, 0x42, 0x7F])), "AB")
        XCTAssertEqual(RawTerminalInput.promptText(for: Data([0x41, 0x09, 0x42])), "A B")
        XCTAssertEqual(RawTerminalInput.promptText(for: Data("Pass: é".utf8)), "Pass: é")
    }
}
