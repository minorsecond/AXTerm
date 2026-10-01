//
//  AX25InteropTNC2Tests.swift
//  AXTermTests
//
//  AXTerm against an AX.25 2.0 TNC-2 style station (TAPR TNC-2, and KPC
//  firmware with the same command set): no XID, fixed FRACK scaled by
//  (2m + 1), RESPTIME-delayed acks, REJ, MAXFRAME 1 to 7, PACLEN 128 to
//  256. See AX25PeerModels.swift for the sources.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25InteropTNC2Tests: AX25InteropTestCase {

    func testAXTermCalls() { scenarioAXTermCalls(.tnc2()) }
    func testAXTermCallsWithoutXID() { scenarioAXTermCalls(.tnc2(), negotiate: false) }
    func testTNC2Calls() { scenarioPeerCalls(.tnc2()) }
    func testAXTermFrameLostDrawsREJ() { scenarioAXTermFrameLost(.tnc2()) }
    func testTNC2FrameLostDrawsREJ() { scenarioPeerFrameLost(.tnc2()) }
    func testLostAckRecoveredByT1() { scenarioAckLost(.tnc2()) }
    func testRNR() { scenarioPeerBusy(.tnc2()) }
    func testLastFrameLostRecoveredByT1() { scenarioLastFrameLost(.tnc2()) }
    func testTNC2ReconnectsOverStaleLink() { scenarioPeerReconnectsOverStaleLink(.tnc2()) }
    func testKeepalive() { scenarioKeepalive(.tnc2()) }
    func testTNC2StaleLinkClearedByDM() { scenarioPeerHoldsStaleLink(.tnc2()) }
    func testAXTermStaleLinkClearedByDM() { scenarioAXTermHoldsStaleLink(.tnc2()) }
    func testFRMR() { scenarioFRMR(.tnc2()) }
    func testAddressing() { scenarioAddressing(.tnc2()) }

    /// The MAXFRAME and PACLEN range a TNC-2 operator may set. A peer
    /// running seven outstanding frames must not trip AXTerm's receive span.
    func testMaxframeAndPaclenRange() {
        for (maxframe, paclen) in [(1, 128), (4, 256), (7, 128), (7, 256)] {
            build(.tnc2(maxframe: maxframe, paclen: paclen))
            axtermConnects()
            peerSends(Self.burst(2000, tag: "M\(maxframe)P\(paclen)-"))
            axtermSends(Self.burst(900, tag: "A"))
            XCTAssertEqual(axtermRetransmissions, 0, "MAXFRAME \(maxframe) PACLEN \(paclen) \(trace())")
            assertNoViolations()
        }
    }

    /// A seven-frame burst with its first frame lost: AXTerm holds three
    /// frames past the gap (its receive span is half the modulo) and asks
    /// once with REJ; the go-back-N resend completes the stream.
    func testMaxframe7BurstWithItsFirstFrameLost() {
        build(.tnc2(maxframe: 7, paclen: 128))
        axtermConnects()
        var dropped = false
        channel.dropRule = { d in
            guard !dropped, d.receiver == "AXTerm", d.frame?.src.display != Self.axtermCall,
                  case .i(0, _, _) = d.frame?.kind else { return false }
            dropped = true
            return true
        }
        peerSends(Self.burst(7 * 128, tag: "S"))
        XCTAssertTrue(dropped)
        XCTAssertEqual(axtermSent("REJ").count, 1, "one REJ per gap \(trace())")
        assertNoViolations()
    }

    /// Every way a 2.0 station meets AXTerm's XID: FRMR (§6.3.2), DM, or
    /// silence. Each falls back to plain SABM after exactly one XID, and
    /// the next connect skips the probe.
    func testXIDFallbackAgainstEachPre22Answer() {
        scenarioXIDOnce(.tnc2(xid: .frmr), expectSREJ: false)
        scenarioXIDOnce(.tnc2(xid: .dm), expectSREJ: false)
        scenarioXIDOnce(.tnc2(xid: .ignore), expectSREJ: false)
    }

    /// Both ends call at once. Each answers the other's SABM with UA
    /// (§6.3.3, SABM collision) and one link results.
    func testSABMCollision() {
        build(.tnc2(), negotiate: false)
        axterm.connect(to: peerCall)
        peer.connect(to: Self.axtermCall)
        run(until: { axSession?.state == .connected && peer.isConnected }, limit: 60)
        XCTAssertEqual(axSession?.state, .connected, trace())
        XCTAssertTrue(peer.isConnected)
        axtermSends(Data("after collision\r".utf8))
        peerSends(Data("same here\r".utf8))
        XCTAssertEqual(axterm.manager.sessions.values.filter { $0.state == .connected }.count, 1)
        assertNoViolations()
    }

    /// A station already holding a link with someone else turns AXTerm's
    /// call away with DM, and AXTerm gives up at once instead of retrying.
    func testABusyStationRefusesWithDM() {
        build(.tnc2(), negotiate: false)
        peer.assumeConnected(to: "K9OTHR", via: [])
        axterm.connect(to: peerCall)
        run(30)
        XCTAssertEqual(axSession?.state, .disconnected, trace())
        XCTAssertTrue(axSession?.peerRefusedConnect ?? false)
        XCTAssertEqual(axtermSent("SABM").count, 1)
        assertNoViolations()
    }

    /// With negotiation off the very first frame is SABM.
    func testWithoutXIDTheFirstFrameIsSABM() {
        build(.tnc2(), negotiate: false)
        axtermConnects()
        XCTAssertEqual(axterm.sent.first?.frame.displayInfo, "SABM")
        XCTAssertTrue(axtermSent("XID").isEmpty)
        assertNoViolations()
    }
}
