//
//  PhoneFrameSequenceReplayTests.swift
//  AXTermTests
//
//  The I-frames the iPhone logged from A (705) during smoke run 2026-10-03-1,
//  test 13.3 (12:33:23–12:34:28), in order, with each T2 expiry where the
//  phone sent its delayed RR. On the phone three of them were logged but
//  never reached the state machine (issue 104). Played into the shared state
//  machine directly, every one is handled as AX.25 2.2 says: which shows the
//  fault is outside the protocol code, and keeps it that way.
//
//  Payloads stand in for the real ones: a frame's resent copy carries the
//  same bytes as the original, which is all the receive path compares.
//

import XCTest
@testable import AXTerm

final class PhoneFrameSequenceReplayTests: XCTestCase {

    private enum Step {
        case frame(ns: Int, pf: Bool, lap: Int = 0)
        case t2
    }

    /// From the phone's packet log; nr was 0 to 7 throughout and acks the
    /// phone's own frames, which the replay does not send.
    private let steps: [Step] = [
        .frame(ns: 0, pf: false), .frame(ns: 1, pf: false), .t2,
        .frame(ns: 2, pf: false), .t2,
        .frame(ns: 3, pf: false), .t2,
        .frame(ns: 4, pf: false),             // 12:33:55.267, lost on the phone
        .frame(ns: 5, pf: true),              // the phone answered SREJ 4
        .frame(ns: 6, pf: true),              // 12:34:01.747, no answer on the phone
        .frame(ns: 4, pf: false), .t2,        // A's resend after the SREJ
        .frame(ns: 7, pf: true),              // 12:34:10.986, no answer on the phone
        .frame(ns: 6, pf: true), .t2,
        .frame(ns: 7, pf: false),
        .frame(ns: 0, pf: true, lap: 1),      // the cancel, I0 of the next lap
        .frame(ns: 7, pf: true), .t2,
    ]

    private func payload(ns: Int, lap: Int) -> Data { Data("lap\(lap)-ns\(ns)".utf8) }

    func testEveryLoggedFrameIsHandledAndEveryPollAnswered() {
        var sm = AX25StateMachine(config: AX25SessionConfig(srejEnabled: true))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        var delivered: [Data] = []
        var finals: [Int] = []
        var srejs = 0
        for step in steps {
            let actions: [AX25SessionAction]
            switch step {
            case .t2:
                actions = sm.handle(event: .t2Timeout)
            case .frame(let ns, let pf, let lap):
                actions = sm.handle(event: .receivedIFrame(ns: ns, nr: 0, pf: pf,
                                                           payload: payload(ns: ns, lap: lap), pid: 0xF0))
                if pf {
                    let answered = actions.contains {
                        switch $0 {
                        case .sendRR(_, true, _), .sendSREJ(_, true, _), .sendREJ(_, true, _): return true
                        default: return false
                        }
                    }
                    XCTAssertTrue(answered, "a P=1 I-frame (N(S) \(ns)) is always answered with F=1")
                }
            }
            for action in actions {
                switch action {
                case .deliverData(let data, _): delivered.append(data)
                case .sendRR(let nr, true, _): finals.append(nr)
                case .sendSREJ: srejs += 1
                default: break
                }
            }
        }

        XCTAssertEqual(delivered, (0...7).map { payload(ns: $0, lap: 0) } + [payload(ns: 0, lap: 1)],
                       "each frame delivered once, in order, the cancel last")
        XCTAssertEqual(srejs, 0, "nothing was missing, so nothing is selectively rejected")
        XCTAssertEqual(finals.first, 6, "I5 P is answered RR 6 F: I4 was taken")
        XCTAssertEqual(sm.sequenceState.vr, 1)
    }
}
