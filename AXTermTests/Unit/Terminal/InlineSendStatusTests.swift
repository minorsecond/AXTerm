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

    private func progress(text: String = "test", bytes: Int = 5, sent: Int = 0, acked: Int = 0,
                          onAir: Bool = false, hasAcks: Bool = true, viaAXDP: Bool = false) -> OutboundMessageProgress {
        var p = OutboundMessageProgress(
            id: UUID(), text: text, totalBytes: bytes, bytesSent: sent, bytesAcked: acked,
            destination: "K0EPI-4", ackPeer: "K0EPI-4", timestamp: Date(),
            hasAcks: hasAcks, startingVs: 0, totalChunks: 1, paclen: 128,
            lastKnownVa: 0, chunksAcked: 0)
        p.onAir = onAir
        p.viaAXDP = viaAXDP
        return p
    }

    func testNotYetOnTheAirIsTheDimmedLine() {
        XCTAssertEqual(InlineSendStatus.make(progress: progress(sent: 0), deliveredAtLineCount: nil, lineCount: 9),
                       .waiting(text: "test"))
    }

    /// Waiting means nothing of it has reached the air. A 26.8 KB message
    /// read "Waiting to send…" until its last frame had gone, with 9.7 KB
    /// already at the iPad (retest 2026-10-10, finding 8).
    func testWaitingEndsWithTheFirstFrameOnTheAir() {
        let p = progress(bytes: 26_816, sent: 9_984, acked: 9_728, onAir: true)
        XCTAssertEqual(InlineSendStatus.make(progress: p, deliveredAtLineCount: nil, lineCount: 9),
                       .sending(acked: 9_728, total: 26_816, axdpPeer: nil))
    }

    func testOnTheAirCountsTheAcknowledgedBytes() {
        let p = progress(bytes: 300, sent: 300, acked: 128, onAir: true, viaAXDP: true)
        XCTAssertEqual(InlineSendStatus.make(progress: p, deliveredAtLineCount: nil, lineCount: 9),
                       .sending(acked: 128, total: 300, axdpPeer: "K0EPI-4"))
    }

    /// What the row says, for the progress bar beside it (finding 9).
    func testTheSendingWords() {
        XCTAssertEqual(InlineSendStatus.deliveredAmount(acked: 9_728, total: 26_816), "Delivered 9.7 of 26.8 KB")
        XCTAssertEqual(InlineSendStatus.deliveredAmount(acked: 128, total: 300), "Delivered 128 of 300 bytes")
        XCTAssertEqual(InlineSendStatus.axdpNote(peer: "K0EPI-3"), "K0EPI-3 sees it when it has all arrived")
    }

    func testDeliveredStaysUntilTheNextLine() {
        let done = progress(sent: 5, acked: 5, onAir: true)
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
        XCTAssertNil(InlineSendStatus.make(progress: progress(sent: 5, onAir: true, hasAcks: false),
                                           deliveredAtLineCount: nil, lineCount: 9))
    }

    func testNothingGoingOutShowsNothing() {
        XCTAssertNil(InlineSendStatus.make(progress: nil, deliveredAtLineCount: nil, lineCount: 9))
    }

    // MARK: Counting from the session (finding 8)

    /// The message's bytes are the session's own counts since it started:
    /// first transmissions only, and acknowledgments frame by frame, so
    /// retransmissions, other traffic and a paclen that changes midway do
    /// not throw them off.
    func testTheCountsComeFromTheSessionSinceTheMessageStarted() {
        var p = progress(bytes: 300)
        p.sentBase = 1_000
        p.ackedBase = 900
        p.apply(sessionBytesSent: 1_128, sessionBytesAcked: 900)
        XCTAssertEqual(p.bytesSent, 128)
        XCTAssertEqual(p.bytesAcked, 0)
        p.apply(sessionBytesSent: 1_500, sessionBytesAcked: 1_250)
        XCTAssertEqual(p.bytesSent, 300, "never more than the message")
        XCTAssertEqual(p.bytesAcked, 300)
        XCTAssertTrue(p.isComplete)
    }

    // MARK: Scrolling (retest 2026-10-10, findings 7 and 10)

    /// The history follows the status row when it appears, goes or changes
    /// kind. A count changing inside it is not a reason to scroll: on the
    /// iPad every delivery of a long message, and every acknowledgment of a
    /// line going out, scrolled to the marker below the padding and back.
    func testOnlyANewKindOfRowScrolls() {
        let receiving1 = InlineSendStatus.receiving(from: "K0EPI-2", amount: "1.0 of 3.0 KB")
        let receiving2 = InlineSendStatus.receiving(from: "K0EPI-2", amount: "1.2 of 3.0 KB")
        let sending1 = InlineSendStatus.sending(acked: 128, total: 26_816, axdpPeer: nil)
        let sending2 = InlineSendStatus.sending(acked: 256, total: 26_816, axdpPeer: nil)

        XCTAssertTrue(InlineSendStatus.needsScroll(from: nil, to: receiving1))
        XCTAssertFalse(InlineSendStatus.needsScroll(from: receiving1, to: receiving2))
        XCTAssertFalse(InlineSendStatus.needsScroll(from: sending1, to: sending2))
        XCTAssertFalse(InlineSendStatus.needsScroll(from: .receivingFile(name: "a", percent: 10),
                                                    to: .receivingFile(name: "a", percent: 40)))
        XCTAssertTrue(InlineSendStatus.needsScroll(from: .waiting(text: "hi"), to: sending1))
        XCTAssertTrue(InlineSendStatus.needsScroll(from: sending2, to: .delivered))
        XCTAssertTrue(InlineSendStatus.needsScroll(from: .delivered, to: nil))
    }
}
