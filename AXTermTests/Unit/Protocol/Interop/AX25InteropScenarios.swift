//
//  AX25InteropScenarios.swift
//  AXTermTests
//
//  The scenario matrix every peer model runs: both directions, direct and
//  through one and two digipeaters, connect (with and without XID), data
//  both ways, REJ and T1 recovery, RNR, T3, disconnect, DM on a stale
//  session, FRMR, and addressing. Suites call these with their profile.
//

import Foundation
import XCTest
@testable import AXTerm

extension AX25InteropTestCase {

    static let paths: [[String]] = [[], ["DIGI1"], ["DIGI1", "DIGI2"]]

    // MARK: Connect, data both ways, disconnect

    /// AXTerm calls, both ends talk (a short line each way and bursts at
    /// AXTerm's default K 2 / paclen 128), AXTerm hangs up.
    func scenarioAXTermCalls(_ profile: PeerProfile, negotiate: Bool = true,
                             file: StaticString = #filePath, line: UInt = #line) {
        for path in Self.paths {
            build(profile, digis: path, negotiate: negotiate)
            axtermConnects(file: file, line: line)
            axtermSends(Data("hello from axterm\r".utf8), file: file, line: line)
            peerSends(Data("hello from \(profile.name)\r".utf8), file: file, line: line)
            axtermSends(Self.burst(600, tag: "A"), file: file, line: line)
            peerSends(Self.burst(700, tag: "P"), file: file, line: line)
            axterm.disconnect(from: peerCall)
            run(until: { peer.state == .disconnected && axSession?.state == .disconnected }, limit: 120)
            let label = "\(profile.name) path \(path) negotiate \(negotiate)"
            XCTAssertEqual(peer.state, .disconnected, "\(label) \(trace())", file: file, line: line)
            XCTAssertEqual(axSession?.state, .disconnected, label, file: file, line: line)
            XCTAssertEqual(axtermRetransmissions, 0, "\(label): a clean link needs no retransmission \(trace())",
                           file: file, line: line)
            XCTAssertEqual(peer.linkFailures, 0, label, file: file, line: line)
            assertWindowAndPaclenHeld(file: file, line: line)
            assertNoViolations(file: file, line: line)
        }
    }

    /// The peer calls AXTerm, both talk, the peer hangs up.
    func scenarioPeerCalls(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        for path in Self.paths {
            build(profile, digis: path)
            peerConnects(file: file, line: line)
            peerSends(Data("hello from \(profile.name)\r".utf8), file: file, line: line)
            axtermSends(Data("hello from axterm\r".utf8), file: file, line: line)
            peerSends(Self.burst(700, tag: "P"), file: file, line: line)
            axtermSends(Self.burst(600, tag: "A"), file: file, line: line)
            peer.disconnect()
            run(until: { peer.state == .disconnected && axSession?.state == .disconnected }, limit: 120)
            let label = "\(profile.name) path \(path)"
            XCTAssertEqual(peer.state, .disconnected, "\(label) \(trace())", file: file, line: line)
            XCTAssertEqual(axSession?.state, .disconnected, "\(label) \(trace())", file: file, line: line)
            XCTAssertEqual(axtermRetransmissions, 0, "\(label) \(trace())", file: file, line: line)
            XCTAssertEqual(peer.linkFailures, 0, label, file: file, line: line)
            assertWindowAndPaclenHeld(file: file, line: line)
            assertNoViolations(file: file, line: line)
        }
    }

    // MARK: Loss recovery

    /// One of AXTerm's I-frames is lost on its way to the peer. The peer's
    /// REJ (or SREJ, where negotiated) brings it back; nothing arrives twice.
    func scenarioAXTermFrameLost(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        for path in Self.paths {
            build(profile, digis: path)
            axtermConnects(file: file, line: line)
            var dropped = false
            let peerCall = self.peerCall
            channel.dropRule = { d in
                guard !dropped, d.receiver == peerCall, d.frame?.src.display == Self.axtermCall,
                      case .i(let ns, _, _) = d.frame?.kind, ns == 1 else { return false }
                dropped = true
                return true
            }
            axtermSends(Self.burst(600, tag: "R"), file: file, line: line)
            XCTAssertTrue(dropped, "\(profile.name) path \(path)", file: file, line: line)
            XCTAssertLessThanOrEqual(axtermRetransmissions, 4,
                                     "\(profile.name) path \(path): recovery, not a storm \(trace())", file: file, line: line)
            XCTAssertEqual(axSession?.state, .connected, file: file, line: line)
            assertNoViolations(file: file, line: line)
        }
    }

    /// One of the peer's I-frames is lost on its way to AXTerm. AXTerm asks
    /// again (REJ, or SREJ when the link negotiated it) and delivers the
    /// stream once, in order.
    func scenarioPeerFrameLost(_ profile: PeerProfile, expectSREJ: Bool = false,
                               file: StaticString = #filePath, line: UInt = #line) {
        for path in Self.paths {
            build(profile, digis: path)
            axtermConnects(file: file, line: line)
            var dropped = false
            channel.dropRule = { d in
                guard !dropped, d.receiver == "AXTerm", d.frame?.src.display != Self.axtermCall, case .i(let ns, _, _) = d.frame?.kind, ns == 1 else { return false }
                dropped = true
                return true
            }
            // Enough frames that the lost one is never the last in flight.
            peerSends(Self.burst(4 * profile.paclen + 50, tag: "L"), file: file, line: line)
            XCTAssertTrue(dropped, file: file, line: line)
            let asked = expectSREJ ? axtermSent("SREJ") : axtermSent("REJ")
            XCTAssertFalse(asked.isEmpty, "\(profile.name) path \(path): AXTerm asks for the gap \(trace())",
                           file: file, line: line)
            if !expectSREJ {
                XCTAssertTrue(axtermSent("SREJ").isEmpty, "\(profile.name): SREJ was not negotiated", file: file, line: line)
            }
            assertNoViolations(file: file, line: line)
        }
    }

    /// The peer's acknowledgment is lost. AXTerm's T1 runs out no sooner
    /// than FRACK x (2 x digis + 1), and its poll is answered without the
    /// peer receiving anything twice.
    func scenarioAckLost(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        for path in Self.paths {
            build(profile, digis: path)
            axtermConnects(file: file, line: line)
            var dropped = false
            channel.dropRule = { d in
                guard !dropped, d.receiver == "AXTerm", d.frame?.src.display != Self.axtermCall, case .s(.rr, _, _) = d.frame?.kind else { return false }
                dropped = true
                return true
            }
            let start = clock.currentTime
            let before = axterm.sent.count
            let t1 = axtermT1
            axtermSends(Data("needs an ack\r".utf8), limit: 200, file: file, line: line)
            // The first frame AXTerm sends after the line is the recovery.
            if let recovery = axterm.sent.dropFirst(before + 1).first?.time {
                XCTAssertGreaterThanOrEqual(recovery - start, t1 - 0.01,
                                            "\(profile.name) path \(path): T1 fired before T1V \(t1) \(trace())",
                                            file: file, line: line)
            } else {
                XCTFail("\(profile.name) path \(path): AXTerm never recovered \(trace())", file: file, line: line)
            }
            XCTAssertLessThanOrEqual(axtermRetransmissions, 1, "one recovery, no storm \(trace())", file: file, line: line)
            assertNoViolations(file: file, line: line)
        }
    }

    /// AXTerm's only frame is lost, so the peer has no gap to REJ. AXTerm's
    /// T1, no sooner than FRACK x (2 x digis + 1), resends it with P=1 and
    /// the peer delivers it once.
    func scenarioLastFrameLost(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        for path in Self.paths {
            build(profile, digis: path)
            axtermConnects(file: file, line: line)
            axtermSends(Data("warm up\r".utf8), file: file, line: line)
            var dropped = false
            let peerCall = self.peerCall
            channel.dropRule = { d in
                guard !dropped, d.receiver == peerCall, d.frame?.src.display == Self.axtermCall,
                      case .i = d.frame?.kind else { return false }
                dropped = true
                return true
            }
            let start = clock.currentTime
            let before = axterm.sent.count
            let t1 = axtermT1
            axtermSends(Data("only frame\r".utf8), file: file, line: line)
            XCTAssertTrue(dropped, file: file, line: line)
            let resend = axterm.sent.dropFirst(before + 1).first
            XCTAssertEqual(resend?.frame.frameType, "i", "\(profile.name) path \(path): T1 resends the frame \(trace())",
                           file: file, line: line)
            XCTAssertEqual((resend?.frame.controlByte ?? 0) & 0x10, 0x10, "the resend polls", file: file, line: line)
            if let time = resend?.time {
                XCTAssertGreaterThanOrEqual(time - start, t1 - 0.01,
                                            "\(profile.name) path \(path): T1 fired before T1V \(t1)", file: file, line: line)
            }
            XCTAssertEqual(axtermRetransmissions, 1, "\(profile.name) path \(path) \(trace())", file: file, line: line)
            assertNoViolations(file: file, line: line)
        }
    }

    /// The peer restarted and calls again while AXTerm still holds the old
    /// link. AXTerm resets the link (§6.3.1: SABM on a live link) and both
    /// ends count from zero.
    func scenarioPeerReconnectsOverStaleLink(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        build(profile)
        peerConnects(file: file, line: line)
        peerSends(Self.burst(300, tag: "1"), file: file, line: line)
        axtermSends(Data("before\r".utf8), file: file, line: line)
        peer.forgetLink()
        peerConnects(file: file, line: line)
        peerSends(Data("after restart\r".utf8), file: file, line: line)
        axtermSends(Data("after\r".utf8), file: file, line: line)
        XCTAssertEqual(axSession?.state, .connected, file: file, line: line)
        assertNoViolations(file: file, line: line)
    }

    // MARK: Flow control and keepalive

    /// The peer goes busy (RNR). AXTerm holds its data, polls on T1 without
    /// pushing I-frames into the full buffer, and resumes on RR.
    func scenarioPeerBusy(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        build(profile)
        axtermConnects(file: file, line: line)
        peer.receiverBusy = true
        let data = Self.burst(600, tag: "B")
        axterm.send(data, to: peerCall)
        run(30)
        XCTAssertTrue(axSession?.stateMachine.peerBusy ?? false, "\(profile.name): AXTerm holds while the peer is busy \(trace())",
                      file: file, line: line)
        XCTAssertEqual(axSession?.state, .connected, file: file, line: line)
        let iFramesWhileBusy = axterm.sent.filter { $0.frame.frameType == "i" }.count
        XCTAssertLessThanOrEqual(iFramesWhileBusy, 2 + 2, "\(profile.name): no I-frame flood into a busy receiver",
                                 file: file, line: line)
        peer.receiverBusy = false
        run(until: { peer.delivered.count >= data.count }, limit: 120)
        XCTAssertEqual(peer.delivered, data, "\(profile.name) \(trace())", file: file, line: line)
        XCTAssertEqual(axSession?.state, .connected, file: file, line: line)
        assertNoViolations(file: file, line: line)
    }

    /// AXTerm's T3 enquiry (RR P=1 after T3 idle, 300 s by default) is
    /// answered and the link stays up; the peer's own idle enquiry is
    /// answered too.
    func scenarioKeepalive(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        build(profile)
        axtermConnects(file: file, line: line)
        let isPoll: ((time: TimeInterval, frame: OutboundFrame)) -> Bool = {
            $0.frame.frameType == "s" && $0.frame.isCommand == true
        }
        let before = axterm.sent.filter(isPoll).count
        let t3 = AppSettingsStore.defaultAX25T3IdleSeconds
        run(max(3 * t3 + 30, profile.t3 + 30))
        let polls = axterm.sent.filter(isPoll).count - before
        XCTAssertGreaterThanOrEqual(polls, 3, "\(profile.name): about one enquiry per T3 idle", file: file, line: line)
        XCTAssertLessThanOrEqual(polls, 5, "\(profile.name): no more than one per three quarters of T3",
                                 file: file, line: line)
        XCTAssertEqual(axSession?.state, .connected, "\(profile.name) \(trace())", file: file, line: line)
        XCTAssertTrue(peer.isConnected, "\(profile.name) \(trace())", file: file, line: line)
        XCTAssertEqual(peer.linkFailures, 0, file: file, line: line)
        assertNoViolations(file: file, line: line)
    }

    // MARK: Stale sessions and FRMR

    /// AXTerm forgot the link (a restart); the peer still holds it and
    /// talks. AXTerm answers its poll with DM (§6.3.5), the peer drops its
    /// side, and AXTerm does not DM every frame.
    func scenarioPeerHoldsStaleLink(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        for path in Self.paths {
            build(profile, digis: path)
            peer.assumeConnected(to: Self.axtermCall, via: peerPath)
            peer.send("anyone there?\r")
            run(until: { peer.state == .disconnected }, limit: 120)
            XCTAssertEqual(peer.state, .disconnected, "\(profile.name) path \(path): the DM must reach the peer \(trace())",
                           file: file, line: line)
            XCTAssertLessThanOrEqual(axtermSent("DM").count, 2, "\(profile.name) path \(path): no DM storm",
                                     file: file, line: line)
            assertNoViolations(file: file, line: line)
        }
    }

    /// The peer forgot the link; AXTerm still holds it and sends. The
    /// peer's DM ends AXTerm's session instead of a retry to N2.
    func scenarioAXTermHoldsStaleLink(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        build(profile)
        axtermConnects(file: file, line: line)
        peer.forgetLink()
        axterm.send("are you still there?\r", to: peerCall)
        run(until: { axSession?.state == .disconnected }, limit: 120)
        XCTAssertEqual(axSession?.state, .disconnected, "\(profile.name) \(trace())", file: file, line: line)
        XCTAssertLessThanOrEqual(axtermRetransmissions, 2, "\(profile.name): cleared on the first poll, not at N2",
                                 file: file, line: line)
        assertNoViolations(file: file, line: line)
    }

    /// The peer sends FRMR on a live link. AXTerm stops using it, and a
    /// fresh connect works.
    func scenarioFRMR(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        build(profile)
        axtermConnects(file: file, line: line)
        peer.injectFRMR()
        run(5)
        XCTAssertEqual(axSession?.state, .error, file: file, line: line)
        axtermConnects(file: file, line: line)
        axtermSends(Data("after FRMR\r".utf8), file: file, line: line)
        assertNoViolations(file: file, line: line)
    }

    // MARK: Addressing

    /// Everything AXTerm sends on a link the peer opened comes from the
    /// address the peer called, goes to the peer's own SSID, and travels the
    /// call's path reversed.
    func scenarioAddressing(_ profile: PeerProfile, file: StaticString = #filePath, line: UInt = #line) {
        for path in Self.paths {
            build(profile, peerCall: "W1PEER-15", digis: path)
            peerConnects(file: file, line: line)
            peerSends(Data("ping\r".utf8), file: file, line: line)
            axtermSends(Data("pong\r".utf8), file: file, line: line)
            let fromAXTerm = peer.heard.map(\.frame)
            let label = "\(profile.name) path \(path)"
            XCTAssertFalse(fromAXTerm.isEmpty, "\(label): nothing from AXTerm reached the peer \(trace())", file: file, line: line)
            XCTAssertTrue(fromAXTerm.allSatisfy { $0.src.display == Self.axtermCall }, label, file: file, line: line)
            XCTAssertTrue(fromAXTerm.allSatisfy { $0.dest.display == "W1PEER-15" }, label, file: file, line: line)
            XCTAssertTrue(fromAXTerm.allSatisfy { $0.via.map(\.display) == path }, "\(label) \(trace())", file: file, line: line)
            assertNoViolations(file: file, line: line)
        }
    }

    /// XID before the first SABM: one XID, then SABM, and the verdict is
    /// kept for the next connect.
    func scenarioXIDOnce(_ profile: PeerProfile, expectSREJ: Bool,
                         file: StaticString = #filePath, line: UInt = #line) {
        for path in [[String](), ["DIGI1"]] {
            build(profile, digis: path)
            axtermConnects(file: file, line: line)
            let label = "\(profile.name) path \(path)"
            XCTAssertEqual(axtermSent("XID").count, 1, "\(label): one XID, then SABM \(trace())", file: file, line: line)
            XCTAssertEqual(axSession?.stateMachine.config.srejEnabled, expectSREJ, label, file: file, line: line)
            axtermSends(Data("after XID\r".utf8), file: file, line: line)
            axterm.disconnect(from: peerCall)
            run(until: { axSession?.state == .disconnected }, limit: 60)
            axtermConnects(file: file, line: line)
            XCTAssertEqual(axtermSent("XID").count, 1, "\(label): the verdict is cached, no second XID", file: file, line: line)
            XCTAssertEqual(axSession?.stateMachine.config.srejEnabled, expectSREJ, label, file: file, line: line)
            assertNoViolations(file: file, line: line)
        }
    }
}
