//
//  ConversationTranscriptTests.swift
//  AXTermTests
//
//  The iPhone and iPad Session view reads as a conversation (park rehearsal
//  2026-10-08, operator's choice): a BBS listing was one bubble per line with
//  a header each, interleaved with I(6,5), RR(1) F and RTO notes. Protocol
//  frames and link chatter stay out of it (the Packets tab has them), and
//  consecutive text from one station reads as one block.
//

import XCTest
@testable import AXTerm

final class ConversationTranscriptTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    private func data(_ text: String, from: String = "K0EPI-4", to: String = "K0EPI-3",
                      at seconds: TimeInterval = 0) -> ConsoleLine {
        ConsoleLine.packet(from: from, to: to, text: text, timestamp: t0.addingTimeInterval(seconds),
                           messageType: .data)
    }

    private func control(_ text: String, at seconds: TimeInterval = 0) -> ConsoleLine {
        ConsoleLine.packet(from: "K0EPI-4", to: "K0EPI-3", text: text,
                           timestamp: t0.addingTimeInterval(seconds), messageType: .prompt)
    }

    func testProtocolFramesAndLinkChatterAreLinkControl() {
        for text in ["I(6,5)", "I(7,5) P", "RR(1) F", "RR(0)", "REJ(3)", "RNR(2) P/F", "SABM P", "UA F",
                     "DISC P", "DM F", "XID", "XID P/F"] {
            XCTAssertTrue(ConversationTranscript.isLinkControl(control(text)), text)
        }
        XCTAssertTrue(ConversationTranscript.isLinkControl(
            ConsoleLine(kind: .system, text: "Frame sent successfully")))
        XCTAssertTrue(ConversationTranscript.isLinkControl(
            ConsoleLine(kind: .system, text: "Adaptive: RTO 7.6→7.5s (updated) [session: K0EPI-4 direct on ]")))
    }

    func testWhatTheStationSaysIsNotLinkControl() {
        for text in [">", "NAME              SIZE  TIME  ABOUT", "D <name> fetches one. U uploads to the sysop.",
                     "RR is a reply", "I (6,5) P"] {
            XCTAssertFalse(ConversationTranscript.isLinkControl(control(text)), text)
        }
        XCTAssertFalse(ConversationTranscript.isLinkControl(ConsoleLine(kind: .system, text: "Connected to K0EPI-4")))
    }

    func testConsecutiveTextFromOneStationReadsAsOneBlock() {
        let lines = [data("NAME              SIZE  TIME  ABOUT", at: 0),
                     control("I(6,5)", at: 0.5),
                     data("IMG_2820.jpg       24K    5m  backyard", at: 1),
                     data(">", at: 1.2),
                     data("W PARK", from: "K0EPI-3", to: "K0EPI-4", at: 5),
                     data("NAME              SIZE  TIME  ABOUT", at: 30)]

        let blocks = ConversationTranscript.lines(lines)

        XCTAssertEqual(blocks.map(\.text), [
            "NAME              SIZE  TIME  ABOUT\nIMG_2820.jpg       24K    5m  backyard\n>",
            "W PARK",
            "NAME              SIZE  TIME  ABOUT",
        ], "the I-frame is gone, the reply is one block, and a reply or a long pause starts a new one")
        XCTAssertEqual(blocks.first?.from, "K0EPI-4")
        XCTAssertEqual(blocks.first?.timestamp, t0, "a block is dated by its first line")
    }
}
