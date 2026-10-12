//
//  TalkExitTests.swift
//  AXTermTests
//
//  While a caller talks with the operator, `/EX` or `/EXIT` alone on a
//  line takes them back to where they were, the node or the mailbox. The
//  BBS convention for ending something typed. Everything else is the chat.
//

import XCTest
@testable import AXTerm

final class TalkExitTests: XCTestCase {

    private func feed(_ chunks: [Data]) -> [Bool] {
        var exit = TalkExit()
        return chunks.map { exit.feed($0) }
    }

    private func text(_ s: String) -> Data { Data(s.utf8) }

    func testExAloneOnALineLeaves() {
        for line in ["/EX\r", "/ex\r", "/EXIT\r", "/exit\n", "  /Ex  \r"] {
            XCTAssertEqual(feed([text(line)]), [true], line.debugDescription)
        }
    }

    func testChatIsNotLeaving() {
        XCTAssertEqual(feed([text("hello\r"), text("/exit now\r"), text("try /ex\r"), text("/E\r")]),
                       [false, false, false, false])
    }

    func testALineAcrossFramesIsReadWhole() {
        XCTAssertEqual(feed([text("hi\r/E"), text("X"), text("\r")]), [false, false, true])
    }

    func testAnExitAfterOtherLinesInOneFrame() {
        XCTAssertEqual(feed([text("bye for now\r/ex\r")]), [true])
    }

    /// An AXTerm caller's lines come as AXDP chat.
    func testAXDPChatIsReadToo() {
        let chat = { (s: String) in
            AXDP.Message(type: .chat, sessionId: 0, messageId: 1, payload: Data(s.utf8)).encode()
        }
        XCTAssertEqual(feed([chat("hello")]), [false])
        XCTAssertEqual(feed([chat("/ex")]), [true])
        let split = chat("/EXIT")
        XCTAssertEqual(feed([split.prefix(9), split.dropFirst(9)]), [false, true])
    }
}
