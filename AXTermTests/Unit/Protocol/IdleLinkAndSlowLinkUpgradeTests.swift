//
//  IdleLinkAndSlowLinkUpgradeTests.swift
//  AXTermTests
//
//  Two defects found on the air against KB5YZB-7 (2026-08-26), both of which
//  produce perfectly legal AX.25 while the operator gets nothing useful.
//
//  1. The adaptive controller widened the window to K=2 / P=128 on a path whose
//     round trip measured 12 s, because the samples were clean. Clean and slow
//     are different things: loss says the path works, RTT says how badly. A
//     12-second link cannot afford a wider window, and widening it turns every
//     recovery into a minute.
//
//  2. The link stayed "connected" for ninety seconds, answering ten polls,
//     never carrying a byte. Every frame was correct — the peer polled, we
//     answered — so nothing in the protocol layer had an opinion, and the
//     session strip said "connected" the whole time. Only the shape is wrong,
//     and only one level up can see it.
//

import XCTest
@testable import AXTerm

final class IdleLinkAndSlowLinkUpgradeTests: XCTestCase {

    // MARK: - 1. Slow links do not earn a wider window

    /// The field capture: loss 0.00, ETX 1.00, SRTT 12 s — and the controller
    /// still climbed to K=2 / P=128. Clean samples alone must not widen a link
    /// whose round trip cannot pay for the recovery.
    func testCleanButSlowLinkNeverEarnsAnUpgrade() {
        var settings = TxAdaptiveSettings()
        let baseWindow = settings.windowSize.currentAdaptive
        let basePaclen = settings.paclen.currentAdaptive

        for _ in 0..<200 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 12.02,
                                           newFrames: 1, retransmits: 0)
        }

        XCTAssertEqual(settings.windowSize.currentAdaptive, baseWindow,
                       "a 12-second round trip must not widen the window however clean the samples")
        XCTAssertEqual(settings.paclen.currentAdaptive, basePaclen,
                       "nor lengthen frames — longer frames cost more on a slow path, not less")
    }

    /// The same samples on the healthy sibling path (DRLNOD measured 1.53 s)
    /// must still earn everything they used to. The gate is a ceiling on
    /// optimism, not a brake on good links.
    func testCleanAndFastLinkStillUpgrades() {
        var settings = TxAdaptiveSettings()
        let baseWindow = settings.windowSize.currentAdaptive

        for _ in 0..<200 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 1.53,
                                           newFrames: 1, retransmits: 0)
        }

        XCTAssertGreaterThan(settings.windowSize.currentAdaptive, baseWindow,
                             "a fast clean path must still climb the ladder")
    }

    /// A link with no RTT sample yet is not assumed slow — an unmeasured path
    /// upgrades on its loss evidence, exactly as before this gate existed.
    func testUnmeasuredRoundTripDoesNotBlockUpgrades() {
        var settings = TxAdaptiveSettings()
        let baseWindow = settings.windowSize.currentAdaptive

        for _ in 0..<200 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil,
                                           newFrames: 1, retransmits: 0)
        }

        XCTAssertGreaterThan(settings.windowSize.currentAdaptive, baseWindow,
                             "no RTT sample is not evidence of a slow link")
    }

    /// The boundary itself upgrades — five seconds is the last acceptable value,
    /// not the first rejected one.
    func testCeilingIsInclusive() {
        var settings = TxAdaptiveSettings()
        let baseWindow = settings.windowSize.currentAdaptive

        for _ in 0..<200 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0,
                                           srtt: TxAdaptiveSettings.upgradeSrttCeiling,
                                           newFrames: 1, retransmits: 0)
        }

        XCTAssertGreaterThan(settings.windowSize.currentAdaptive, baseWindow)
    }

    /// A slow link is not *downgraded* on RTT alone. A path that is merely slow
    /// still carries traffic, and shrinking its window would only make it worse.
    func testSlowLinkIsNotDowngradedOnRoundTripAlone() {
        var settings = TxAdaptiveSettings()
        for _ in 0..<200 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 1.5,
                                           newFrames: 1, retransmits: 0)
        }
        let earned = settings.windowSize.currentAdaptive
        XCTAssertGreaterThan(earned, 1, "precondition: the fast phase earned a wider window")

        // The path slows down but stays clean.
        for _ in 0..<50 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 12.0,
                                           newFrames: 1, retransmits: 0)
        }

        XCTAssertEqual(settings.windowSize.currentAdaptive, earned,
                       "clean-but-slow holds what it earned; only loss takes it away")
    }

    // MARK: - 2. A connected link that carries nothing

    /// Ten polls, no data, `vr` never leaves 0 — the exact shape of the stuck
    /// session. Answering each poll is mandatory and correct; the count is what
    /// lets the layer above say so out loud.
    func testAnsweredPollsWithNoTrafficAccumulate() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)
        XCTAssertEqual(sm.idlePollCount, 0)

        for _ in 0..<10 {
            let actions = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: true))
            XCTAssertTrue(actions.contains(where: {
                if case .sendRR(_, let pf, let isCommand) = $0 { return pf && !isCommand }
                return false
            }), "the poll is still answered — this is a report, never a suppression")
        }

        XCTAssertEqual(sm.idlePollCount, 10)
        XCTAssertEqual(sm.state, .connected, "an idle link is not a failed link")
    }

    /// One I-frame from the peer and the link is doing its job. Nothing further
    /// is reported, however many polls follow.
    func testInboundDataClearsTheIdleCount() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        for _ in 0..<4 {
            _ = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: true))
        }
        XCTAssertEqual(sm.idlePollCount, 4)

        _ = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false,
                                             payload: Data("Hello.\r".utf8)))
        XCTAssertEqual(sm.idlePollCount, 0, "the link carried data — it is working")

        for _ in 0..<10 {
            _ = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: true))
        }
        XCTAssertEqual(sm.idlePollCount, 0,
                       "polls on a link that has carried data are ordinary keepalives")
    }

    /// A poll that acknowledges outstanding data is not idle — our own frames
    /// are in flight, so the link is demonstrably being used.
    func testPollWithOutstandingFramesIsNotIdle() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        sm.sequenceState.incrementVS()
        XCTAssertGreaterThan(sm.sequenceState.outstandingCount, 0)

        _ = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: true))

        XCTAssertEqual(sm.idlePollCount, 0)
    }

    /// A plain RR with no poll bit is not an exchange we answered — it must not
    /// count toward a report about unanswered polling.
    func testUnpolledRRDoesNotCount() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        for _ in 0..<10 {
            _ = sm.handle(event: .receivedRR(nr: 0, pf: false, isCommand: true))
        }

        XCTAssertEqual(sm.idlePollCount, 0)
    }

    /// The counter is an observation, not a failure condition: it must never
    /// tear the link down on its own.
    func testIdlePollsNeverDisconnect() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)

        for _ in 0..<200 {
            let actions = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: true))
            XCTAssertFalse(actions.contains(where: {
                if case .sendDISC = $0 { return true }
                if case .notifyDisconnected = $0 { return true }
                return false
            }))
        }
        XCTAssertEqual(sm.state, .connected)
    }
}
