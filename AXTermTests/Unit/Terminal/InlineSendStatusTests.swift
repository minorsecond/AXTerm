//
//  InlineSendStatusTests.swift
//  AXTermTests
//
//  Park rehearsal 2026-10-08, finding 39. A message going out was shown in a
//  panel that floated over the foot of the Session history: it covered the
//  last lines and came and went with each send. It now sits in the history
//  itself, like Messages: the line dimmed while it waits to go on the air,
//  then a small "Sending…" under it, then "Delivered", which stays until the
//  next line arrives so nothing collapses under the reader.
//

import XCTest
@testable import AXTerm

final class InlineSendStatusTests: XCTestCase {

    private func progress(text: String = "test", bytes: Int = 5, sent: Int = 0, chunks: Int = 1,
                          acked: Int = 0, hasAcks: Bool = true) -> OutboundMessageProgress {
        OutboundMessageProgress(
            id: UUID(), text: text, totalBytes: bytes, bytesSent: sent,
            bytesAcked: acked == chunks ? bytes : 0,
            destination: "K0EPI-4", ackPeer: "K0EPI-4", timestamp: Date(),
            hasAcks: hasAcks, startingVs: 0, totalChunks: chunks, paclen: 128,
            lastKnownVa: 0, chunksAcked: acked)
    }

    func testNotYetOnTheAirIsTheDimmedLine() {
        XCTAssertEqual(InlineSendStatus.make(progress: progress(sent: 0), deliveredAtLineCount: nil, lineCount: 9),
                       .waiting(text: "test"))
    }

    func testOnTheAirCountsTheAcknowledgments() {
        let p = progress(bytes: 300, sent: 300, chunks: 3, acked: 1)
        XCTAssertEqual(InlineSendStatus.make(progress: p, deliveredAtLineCount: nil, lineCount: 9),
                       .sending(acknowledged: 1, of: 3))
    }

    func testDeliveredStaysUntilTheNextLine() {
        let done = progress(sent: 5, acked: 1)
        XCTAssertEqual(InlineSendStatus.make(progress: done, deliveredAtLineCount: 9, lineCount: 9), .delivered)
        XCTAssertEqual(InlineSendStatus.make(progress: nil, deliveredAtLineCount: 9, lineCount: 9), .delivered,
                       "still there after the progress itself is cleared")
        XCTAssertNil(InlineSendStatus.make(progress: nil, deliveredAtLineCount: 9, lineCount: 10),
                     "gone once a newer line is in the history")
    }

    /// A broadcast has no acknowledgments: once it is on the air its own line
    /// is the whole story.
    func testABroadcastShowsOnlyWhileWaiting() {
        XCTAssertEqual(InlineSendStatus.make(progress: progress(sent: 0, hasAcks: false),
                                             deliveredAtLineCount: nil, lineCount: 9),
                       .waiting(text: "test"))
        XCTAssertNil(InlineSendStatus.make(progress: progress(sent: 5, hasAcks: false),
                                           deliveredAtLineCount: nil, lineCount: 9))
    }

    func testNothingGoingOutShowsNothing() {
        XCTAssertNil(InlineSendStatus.make(progress: nil, deliveredAtLineCount: nil, lineCount: 9))
    }
}
