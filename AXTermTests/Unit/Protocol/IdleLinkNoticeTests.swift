//
//  IdleLinkNoticeTests.swift
//  AXTermTests
//
//  The note for a connected link that has carried no data. On the air on
//  2026-09-30 (K0EPI-2 and K0EPI-3 on 145.070) it said the far end "may not
//  be answering" while both stations answered every 30 s keepalive poll. An
//  answered poll proves the link works in both directions, so the note may
//  only doubt the far end when this station's own polls go unanswered.
//

import XCTest
@testable import AXTerm

final class IdleLinkNoticeTests: XCTestCase {

    private func connected() -> AX25StateMachine {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        return sm
    }

    // MARK: - What the state machine knows about our polls

    func testANewLinkHasNoPollEvidence() {
        XCTAssertEqual(connected().pollEvidence, .none)
    }

    /// Our T3 enquiry, answered by the peer's F=1 response.
    func testAnF1ResponseToOurPollIsAnAnswer() {
        var sm = connected()
        _ = sm.handle(event: .t3Timeout)
        _ = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: false))
        XCTAssertEqual(sm.pollEvidence, .answered)
    }

    /// A busy peer still answers.
    func testAnF1RNRResponseIsAnAnswer() {
        var sm = connected()
        _ = sm.handle(event: .t3Timeout)
        _ = sm.handle(event: .receivedRNR(nr: 0, pf: true, isCommand: false))
        XCTAssertEqual(sm.pollEvidence, .answered)
    }

    /// The enquiry's T1 ran out with no response.
    func testAPollWhoseT1ExpiresIsUnanswered() {
        var sm = connected()
        _ = sm.handle(event: .t3Timeout)
        _ = sm.handle(event: .t1Timeout)
        XCTAssertEqual(sm.pollEvidence, .unanswered)
    }

    /// The most recent poll decides: a late answer after a timeout means the
    /// link is answering again.
    func testTheLatestPollDecides() {
        var sm = connected()
        _ = sm.handle(event: .t3Timeout)
        _ = sm.handle(event: .t1Timeout)
        _ = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: false))
        XCTAssertEqual(sm.pollEvidence, .answered)
    }

    /// The peer's own poll, which we answer, says nothing about whether the
    /// peer answers ours.
    func testThePeersPollIsNotAnAnswerToOurs() {
        var sm = connected()
        _ = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: true))
        XCTAssertEqual(sm.pollEvidence, .none)
    }

    // MARK: - What the note says

    /// The field case: both stations answering keepalive polls, nobody has
    /// typed anything yet. Say so, and do not doubt the far end.
    func testAnsweredPollsDoNotSuggestThePeerIsNotAnswering() {
        let text = IdleLinkNotice.text(display: "K0EPI-3", route: "direct", polls: 5,
                                       acknowledged: false, pollEvidence: .answered)
        XCTAssertFalse(text.contains("may not be answering"), text)
        XCTAssertFalse(text.contains("not replying"), text)
        XCTAssertTrue(text.contains("K0EPI-3 (direct)"), text)
        XCTAssertTrue(text.contains("No data has passed"), text)
        XCTAssertTrue(text.contains("answering polls"), text)
    }

    /// Our own polls going unanswered is the case that can doubt the far end.
    func testUnansweredPollsStillWarn() {
        let text = IdleLinkNotice.text(display: "K0EPI-3", route: "direct", polls: 5,
                                       acknowledged: false, pollEvidence: .unanswered)
        XCTAssertTrue(text.contains("may not be hearing"), text)
        XCTAssertTrue(text.contains("not answered"), text)
    }

    /// No poll of ours has gone out yet, so there is no evidence either way
    /// and the note claims nothing about the far end.
    func testNoPollEvidenceMakesNoClaimAboutTheFarEnd() {
        let text = IdleLinkNotice.text(display: "K0EPI-3", route: "direct", polls: 5,
                                       acknowledged: false, pollEvidence: .none)
        XCTAssertFalse(text.contains("may not"), text)
        XCTAssertFalse(text.contains("not answer"), text)
        XCTAssertTrue(text.contains("No data has passed"), text)
    }

    /// Unchanged: an ack proves both directions, so the silence is the far
    /// end's application.
    func testAnAcknowledgedLinkKeepsItsReading() {
        let text = IdleLinkNotice.text(display: "KB5YZB-7", route: "direct", polls: 6,
                                       acknowledged: true, pollEvidence: .answered)
        XCTAssertTrue(text.contains("acknowledged what you sent"), text)
        XCTAssertTrue(text.contains("6 polls"), text)
    }
}
