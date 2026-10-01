//
//  AX25InteropQuirkTests.swift
//  AXTermTests
//
//  Stations that bend the rules or are slow: one that never sets F on its
//  answers, one that acks only every third frame, slow TX/RX turnaround,
//  an old node that DMs sessions polling on idle lines, and a peer's poll
//  crossing new frames from AXTerm. Each is the TNC-2 profile with one
//  behavior changed, so a failure points at that behavior. The last test
//  runs the standard stacks with AXTerm's frames lost while the peer polls.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25InteropQuirkTests: AX25InteropTestCase {

    private func profile(_ name: String, _ change: (inout PeerProfile) -> Void) -> PeerProfile {
        var p = PeerProfile.tnc2()
        p.name = name
        change(&p)
        return p
    }

    // MARK: - Never sets F

    private var noFinal: PeerProfile { profile("TNC without F") { $0.setsFinal = false } }

    /// It answers AXTerm's polls with F=0. AX.25 requires F=1; AXTerm must
    /// still make progress on the N(R) those answers carry, and must not
    /// count the link as failed while acks keep arriving.
    func testAStationThatNeverSetsFStillInteroperates() {
        scenarioAXTermCalls(noFinal)
        scenarioPeerCalls(noFinal)
    }

    func testNoFinalBitWithALostAck() { scenarioAckLost(noFinal) }

    func testNoFinalBitKeepalive() {
        build(noFinal)
        axtermConnects()
        run(600)
        XCTAssertEqual(axSession?.state, .connected, "an RR F=0 still answers the enquiry \(trace())")
        assertNoViolations()
    }

    // MARK: - Acks every K frames

    /// It holds its ack until three frames have arrived. AXTerm's window is
    /// two, and a lone line goes out without a poll, so AXTerm's T1 has to
    /// recover each lone line. Delivery must stay exact and the link must
    /// stay up; one recovery per line is the price of the peer's habit.
    func testAStationThatAcksOnlyEveryThirdFrame() {
        build(profile("TNC acking every 3") { $0.acksEvery = 3 })
        axtermConnects()
        let lines = 5
        for n in 0..<lines {
            axtermSends(Data("lone line \(n)\r".utf8), limit: 120)
        }
        axtermSends(Self.burst(900, tag: "K"))
        XCTAssertEqual(axSession?.state, .connected, trace())
        XCTAssertLessThanOrEqual(axtermRetransmissions, lines + 2, "about one recovery per lone line, no storm \(trace())")
        XCTAssertEqual(peer.linkFailures, 0)
        assertNoViolations()
    }

    // MARK: - Slow turnaround

    /// Two seconds to turn around (a slow radio or a long TX delay). The
    /// answers still beat AXTerm's 4 s FRACK floor.
    func testTwoSecondTurnaround() {
        let slow = profile("TNC 2 s turnaround") { $0.turnaround = 2 }
        scenarioAXTermCalls(slow)
        scenarioPeerCalls(slow)
        scenarioAckLost(slow)
    }

    /// Three seconds plus RESPTIME and airtime puts the peer's ack past
    /// 4 s after AXTerm hands an unpolled frame over. T1 is FRACK x
    /// (2 x digis + 1) or the learned RTO, whichever is longer (spec 7.6),
    /// and the operator raises FRACK for a slow path as on any TNC; the
    /// delayed-ack T1 formula stays off by default. Delivery must be exact
    /// and the link must stay up either way.
    func testThreeSecondTurnaround() {
        let slow = profile("TNC 3 s turnaround") { $0.turnaround = 3 }
        for path in Self.paths {
            build(slow, digis: path)
            axtermConnects()
            for n in 0..<4 {
                axtermSends(Data("slow line \(n)\r".utf8))
                run(5)
            }
            peerSends(Self.burst(600, tag: "S"))
            axtermSends(Self.burst(600, tag: "A"))
            XCTAssertEqual(axSession?.state, .connected, "path \(path) \(trace())")
            XCTAssertEqual(peer.linkFailures, 0, "path \(path)")
            XCTAssertLessThanOrEqual(axtermRetransmissions, 6, "path \(path): no storm \(trace())")
            assertNoViolations()
        }
    }

    // MARK: - DM after polls on idle lines

    /// An old node stack that DMs a session polling on every idle line
    /// (AXTerm's notes on DRLNOD). AXTerm polls only its first I-frame and
    /// the frame that fills its window, so lone lines and bursts both
    /// leave the link up.
    func testAnOldNodeThatDMsFrequentPollsKeepsTheLink() {
        let drl = profile("DRLNOD-style node") { $0.dmAfterPolls = (count: 2, window: 120, idleGap: 3) }
        build(drl)
        axtermConnects()
        for n in 0..<5 {
            axtermSends(Data("idle line \(n)\r".utf8))
            run(10)
        }
        axtermSends(Self.burst(900, tag: "N"))
        run(120)
        XCTAssertEqual(peer.dmForPolls, 0, "AXTerm polled on idle lines \(trace())")
        XCTAssertEqual(axSession?.state, .connected, trace())
        assertNoViolations()
    }

    // MARK: - A peer's poll crossing new frames

    /// The peer's T1 runs out on a frame whose ack was lost and it polls,
    /// while AXTerm, knowing nothing of the loss, starts a new two-frame
    /// message. The poll's N(R) cannot yet cover those frames: they were
    /// sent after it. AX.25 2.0 and the 2.2 SDL answer a received poll with
    /// an RR F=1 and nothing more; retransmission follows REJ, or AXTerm's
    /// own T1 and the F=1 answer to its own poll.
    func testAPeerPollCrossingNewFramesDoesNotResendThem() {
        for profile in [PeerProfile.tnc2(), PeerProfile.linux()] {
            build(profile)
            axtermConnects()
            axtermSends(Data("first\r".utf8))
            var droppedAck = false
            var sentAcrossPoll = false
            let peerCall = self.peerCall
            channel.dropRule = { [unowned self] d in
                if !droppedAck, d.receiver == peerCall, d.frame?.src.display == Self.axtermCall, case .s(.rr, _, _) = d.frame?.kind {
                    droppedAck = true
                    return true
                }
                if droppedAck, !sentAcrossPoll, d.sender == peerCall,
                   case .s(.rr, _, true) = d.frame?.kind, d.frame?.isCommand == true {
                    sentAcrossPoll = true
                    _ = self.clock.schedule(delay: 0) { [unowned self] in
                        self.axterm.send(Self.burst(200, tag: "X"), to: peerCall)
                    }
                }
                return false
            }
            peerSends(Data("lost ack\r".utf8))
            run(until: { peer.delivered.count >= 6 + 200 && (axSession?.outstandingCount ?? 1) == 0 }, limit: 120)
            // Let any duplicates already queued land and be answered.
            run(30)
            XCTAssertTrue(sentAcrossPoll, "\(profile.name): the poll never crossed \(trace())")
            XCTAssertEqual(peer.delivered, Data("first\r".utf8) + Self.burst(200, tag: "X"), "\(profile.name) \(trace())")
            // Until 2026-10-01 AXTerm resent its outstanding frames on a poll that
            // acknowledged nothing, and here those resends were duplicates that 2.0
            // and Linux stations answered with REJ, drawing more resends.
            XCTAssertEqual(axtermRetransmissions, 0, "\(profile.name): frames sent after the poll were resent \(trace())")
            assertNoViolations()
        }
    }

    // MARK: - A peer polling because our frames were lost

    /// Both stations are sending when AXTerm's transmissions stop reaching
    /// the peer for 25 s. The peer's T1 runs out on its own frames and it
    /// polls; AXTerm answers each poll with RR F=1 and resends nothing
    /// because of it. Once the path clears, AXTerm's T1 (or the peer's REJ)
    /// brings its frames back, and both streams arrive once, in order.
    func testAPeerPollingAfterOurFramesWereLostStillGetsThem() {
        for profile in [PeerProfile.tnc2(), .linux(), .direwolf(), .bpq()] {
            build(profile)
            axtermConnects()
            let peerCall = self.peerCall
            let outageEnds = clock.currentTime + 25
            var dropped = 0
            var pollTimes: [TimeInterval] = []
            channel.dropRule = { d in
                if d.sender == peerCall, d.frame?.isCommand == true, case .s(_, _, true) = d.frame?.kind {
                    pollTimes.append(d.time)
                }
                guard d.receiver == peerCall, d.frame?.src.display == Self.axtermCall,
                      d.time < outageEnds else { return false }
                dropped += 1
                return true
            }
            let ours = Self.burst(300, tag: "O")
            let theirs = Self.burst(300, tag: "T")
            axterm.send(ours, to: peerCall)
            peer.send(theirs)
            run(until: {
                peer.delivered.count >= ours.count && axDelivered.count >= theirs.count
                    && (axSession?.outstandingCount ?? 1) == 0 && peer.outstanding == 0
            }, limit: 400)
            XCTAssertGreaterThan(dropped, 0, profile.name)
            XCTAssertFalse(pollTimes.isEmpty, "\(profile.name): the peer never polled \(trace())")
            XCTAssertEqual(peer.delivered, ours, "\(profile.name) \(trace())")
            XCTAssertEqual(axDelivered, theirs, "\(profile.name) \(trace())")
            XCTAssertEqual(axSession?.state, .connected, "\(profile.name) \(trace())")
            assertNoViolations()
        }
    }
}
