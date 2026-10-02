//
//  ReceiveGapPollLadderTests.swift
//  AXTermTests
//
//  Polling for a frame the peer will never send ends.
//
//  After a REJ (or SREJ) T1 keeps running to time the retransmission we
//  asked for, and each expiry polls the peer. The peer answers RR F=1, and an
//  F=1 answer reset the retry count, so the ladder never climbed and the
//  last-ditch gap flush never ran. Found by the full-stack fuzz, 2026-10-02:
//  a duplicated UA made one station re-establish the link, a late duplicate
//  of an old I-frame then sat out of sequence at the other, and the two
//  traded RR P / RR F every T1 for as long as the run lasted. On the air
//  that is the channel held forever.
//
//  §6.7.1.1: a link that cannot make progress climbs N2. An answered poll
//  that leaves the gap open is not progress for the gap, so those polls are
//  counted on their own, cleared when the gap fills, and at N2 - 1 the
//  existing last-ditch flush runs.
//

import XCTest
@testable import AXTerm

@MainActor
final class ReceiveGapPollLadderTests: XCTestCase {

    private let local = AX25Address(call: "K0BBB", ssid: 2)
    private let peer = AX25Address(call: "K0AAA", ssid: 1)
    private let maxRetries = 6

    private func connected(clock: AX25VirtualClock)
        -> (AX25SessionManager, AX25Session, () -> [OutboundFrame], () -> [Data]) {
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = AX25SessionConfig(windowSize: 4, paclen: 128, maxRetries: maxRetries,
                                                  rtoMin: 0.3, rtoMax: 1.2, initialRto: 0.5,
                                                  t2AckDelay: 0.1, adaptiveTimeout: false)
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
        var sent: [OutboundFrame] = []
        var delivered: [Data] = []
        manager.onSendFrame = { sent.append($0) }
        manager.onDataReceived = { _, data in delivered.append(data) }
        return (manager, session, { sent }, { delivered })
    }

    private func isPoll(_ frame: OutboundFrame) -> Bool {
        frame.frameType == "s" && frame.isCommand == true
            && (frame.controlByte ?? 0) & 0x10 != 0
    }

    private func receive(_ manager: AX25SessionManager, ns: Int, _ text: String) -> OutboundFrame? {
        manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                    ns: ns, nr: 0, pf: false, payload: Data(text.utf8))
    }

    /// Runs the clock for `seconds`, answering every poll with RR F=1 the
    /// way a live peer with nothing to resend does. Returns how many polls
    /// went out.
    private func answerPolls(_ manager: AX25SessionManager, clock: AX25VirtualClock,
                             sent: () -> [OutboundFrame], for seconds: Double) -> Int {
        var answered = sent().filter(isPoll).count
        let start = answered
        var elapsed = 0.0
        while elapsed < seconds {
            clock.advance(by: 0.1)
            elapsed += 0.1
            let polls = sent().filter(isPoll).count
            while answered < polls {
                answered += 1
                _ = manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                  nr: 0, pf: true, isCommand: false)
            }
        }
        return answered - start
    }

    func testPollingForAFrameThePeerNeverSendsStops() {
        let clock = AX25VirtualClock()
        let (manager, session, sent, delivered) = connected(clock: clock)

        // N(S) 1 with V(R) at 0: a frame from before a reset, or one whose
        // predecessor the peer has dropped.
        _ = receive(manager, ns: 1, "stale")
        XCTAssertTrue(session.stateMachine.rejSent)

        // T1 here is 0.5 s backing off to 1.2 s: the ladder is over well
        // inside 15 s, and before the fix it never was.
        let polls = answerPolls(manager, clock: clock, sent: sent, for: 15)
        XCTAssertLessThanOrEqual(polls, maxRetries + 1,
                                 "polled \(polls) times in 15 s for a frame that never came")
        XCTAssertFalse(session.stateMachine.rejSent, "the chase did not end")

        // Afterwards only T3's enquiry, one per 30 s on an idle link.
        let later = answerPolls(manager, clock: clock, sent: sent, for: 60)
        XCTAssertLessThanOrEqual(later, 2, "still polling at T1's pace after the ladder ran out")
        XCTAssertEqual(session.state, .connected, "the peer answers every poll; the link stays up")
        XCTAssertEqual(delivered().last, Data("stale".utf8),
                       "the last-ditch flush delivers what was buffered past the gap")
    }

    /// Gaps that do fill, each after a couple of polls, never add up to a
    /// flush: the count starts again with every gap.
    func testGapsThatFillDoNotAddUp() {
        let clock = AX25VirtualClock()
        let (manager, session, sent, delivered) = connected(clock: clock)

        var ns = 0
        for gap in 0..<4 {
            // Frame ns is lost; ns+1 arrives out of sequence.
            _ = receive(manager, ns: (ns + 1) % 8, "after-\(gap)")
            XCTAssertTrue(session.stateMachine.rejSent)
            let polls = answerPolls(manager, clock: clock, sent: sent, for: 2.5)
            XCTAssertGreaterThan(polls, 0)
            // The peer's T1 resends the missing frame.
            _ = receive(manager, ns: ns, "missing-\(gap)")
            XCTAssertFalse(session.stateMachine.rejSent, "gap \(gap) filled")
            ns = (ns + 2) % 8
        }
        XCTAssertEqual(delivered(), (0..<4).flatMap { [Data("missing-\($0)".utf8), Data("after-\($0)".utf8)] },
                       "every gap healed in order; nothing was flushed")
        XCTAssertEqual(session.state, .connected)
    }
}
