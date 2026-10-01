//
//  AX25InteropDirewolfTests.swift
//  AXTermTests
//
//  AXTerm against a Direwolf-style AX.25 2.2 data link: XID with SREJ, N1
//  and k in the xid.c layout, SABME first with SABM after a DM, FRACK 4 s
//  run through the 2.2 SDL "select T1 value", MAXFRAME 4, PACLEN 256.
//  See AX25PeerModels.swift for the sources and for what is not documented.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25InteropDirewolfTests: AX25InteropTestCase {

    func testAXTermCalls() { scenarioAXTermCalls(.direwolf()) }
    func testAXTermCallsWithoutXID() { scenarioAXTermCalls(.direwolf(), negotiate: false) }
    func testDirewolfCalls() { scenarioPeerCalls(.direwolf()) }
    func testAXTermFrameLostDrawsSREJ() { scenarioAXTermFrameLost(.direwolf()) }
    func testDirewolfFrameLostDrawsSREJ() { scenarioPeerFrameLost(.direwolf(), expectSREJ: true) }
    func testLostAckRecoveredByT1() { scenarioAckLost(.direwolf()) }
    func testRNR() { scenarioPeerBusy(.direwolf()) }
    func testLastFrameLostRecoveredByT1() { scenarioLastFrameLost(.direwolf()) }
    func testDirewolfReconnectsOverStaleLink() { scenarioPeerReconnectsOverStaleLink(.direwolf()) }
    func testKeepalive() { scenarioKeepalive(.direwolf()) }
    func testDirewolfStaleLinkClearedByDM() { scenarioPeerHoldsStaleLink(.direwolf()) }
    func testAXTermStaleLinkClearedByDM() { scenarioAXTermHoldsStaleLink(.direwolf()) }
    func testFRMR() { scenarioFRMR(.direwolf()) }
    func testAddressing() { scenarioAddressing(.direwolf()) }

    /// AXTerm's XID offer reaches Direwolf with its parameters, and the
    /// response turns SREJ on for this link and the next.
    func testXIDNegotiatesSREJ() {
        scenarioXIDOnce(.direwolf(), expectSREJ: true)
    }

    /// The response carries Direwolf's N1 256 and k 4. Both are ceilings
    /// above AXTerm's own K 2 and paclen 128, so AXTerm keeps its values.
    func testXIDResponseNeverRaisesAXTermsKOrPaclen() {
        build(.direwolf())
        axtermConnects()
        let config = axSession?.stateMachine.config
        XCTAssertEqual(config?.windowSize, 2)
        XCTAssertEqual(config?.paclen, 128)
        assertNoViolations()
    }

    /// A Direwolf build that will not SREJ on a modulo 8 link answers the
    /// offer without it. AXTerm then rejects with plain REJ.
    func testDirewolfDecliningSREJOnModulo8() {
        scenarioXIDOnce(.direwolf(srejOnModulo8: false), expectSREJ: false)
        scenarioPeerFrameLost(.direwolf(srejOnModulo8: false), expectSREJ: false)
    }

    /// Direwolf calls with SABME. AXTerm is modulo 8 only and refuses with
    /// DM; Direwolf retries with SABM and the link comes up in 2.0 terms.
    func testDirewolfFallsBackFromSABMEToSABM() {
        build(.direwolf())
        peerConnects()
        XCTAssertEqual(axtermSent("DM").count, 1, "SABME refused once \(trace())")
        XCTAssertEqual(peer.connects, 1)
        XCTAssertFalse(axSession?.stateMachine.config.srejEnabled ?? true, "no XID on this link, so no SREJ")
        peerSends(Self.burst(600, tag: "D"))
        assertNoViolations()
    }

    /// Direwolf opens with its own XID. AXTerm's response must reach it with
    /// parameters it can read; the SABM that follows opens a link with
    /// exactly what the response promised, SREJ included, and Direwolf
    /// keeps to the N1 and k AXTerm advertised.
    func testDirewolfNegotiatesFirstThenCalls() {
        for path in Self.paths {
            build(.direwolf(), digis: path)
            peer.negotiate(with: Self.axtermCall, via: peerPath)
            run(until: { peer.srejEnabled }, limit: 30)
            XCTAssertTrue(peer.srejEnabled, "path \(path): AXTerm's XID response selected SREJ \(trace())")
            let response = axtermSent("XID").last.flatMap { AX25XIDParameters.parse($0.payload) }
            XCTAssertNotNil(response, "path \(path)")
            XCTAssertEqual(peer.sendPaclen, min(256, response?.iFieldLengthRx ?? 256), "path \(path)")
            XCTAssertEqual(peer.sendWindow, min(4, response?.windowSizeRx ?? 4), "path \(path)")

            peer.connect(to: Self.axtermCall, via: peerPath, sabme: false)
            run(until: { axSession?.state == .connected && peer.isConnected }, limit: 60)
            XCTAssertEqual(axSession?.stateMachine.config.srejEnabled, true, "path \(path)")

            var droppedToAXTerm = false
            var droppedToPeer = false
            let peerCall = self.peerCall
            channel.dropRule = { d in
                guard case .i(1, _, _) = d.frame?.kind else { return false }
                if d.receiver == "AXTerm", d.frame?.src.display != Self.axtermCall, !droppedToAXTerm { droppedToAXTerm = true; return true }
                // The peer also hears its own frames repeated; only AXTerm's count here.
                if d.receiver == peerCall, d.frame?.src.display == Self.axtermCall, !droppedToPeer {
                    droppedToPeer = true
                    return true
                }
                return false
            }
            peerSends(Self.burst(600, tag: "W"))
            axtermSends(Self.burst(600, tag: "A"))
            XCTAssertTrue(droppedToAXTerm && droppedToPeer, "path \(path)")
            XCTAssertFalse(axtermSent("SREJ").isEmpty, "path \(path): AXTerm asked with SREJ \(trace())")
            XCTAssertTrue(peer.transmitted.contains { if case .s(.srej, _, _) = $0.frame.kind { return true }; return false },
                          "path \(path): Direwolf asked with SREJ \(trace())")
            assertNoViolations()
        }
    }

    /// A peer that can take only 64-byte frames, one at a time. AXTerm
    /// lowers its paclen and K to what the XID response advertised.
    func testAXTermKeepsToASmallerN1AndKFromXID() {
        var small = PeerProfile.direwolf()
        small.xidN1 = 64
        small.xidK = 1
        build(small)
        axtermConnects()
        XCTAssertEqual(axSession?.stateMachine.config.paclen, 64)
        XCTAssertEqual(axSession?.stateMachine.config.windowSize, 1)
        axtermSends(Self.burst(400, tag: "n"))
        XCTAssertTrue(axterm.sent.filter { $0.frame.frameType == "i" }.allSatisfy { $0.frame.payload.count <= 64 })
        XCTAssertLessThanOrEqual(axterm.maxOutstanding, 1)
        assertNoViolations()
    }

    // MARK: - What AXTerm advertises it can receive

    /// AXTerm's XID offer carries what it can receive, N1 256 and k 4
    /// (2.2 §4.3.3.7, §6.3.2), not its own sending K 2 and paclen 128.
    /// Direwolf then sends 256-byte frames four at a time and AXTerm
    /// delivers every byte once, in order, without asking for anything
    /// again. AXTerm's own frames still keep to K 2 and paclen 128.
    func testDirewolfSendsFullFramesFourAtATimeAfterAXTermsXID() {
        for path in Self.paths {
            build(.direwolf(), digis: path)
            axtermConnects()
            let offer = axtermSent("XID").first.flatMap { AX25XIDParameters.parse($0.payload) }
            XCTAssertEqual(offer?.iFieldLengthRx, 256, "path \(path)")
            XCTAssertEqual(offer?.windowSizeRx, 4, "path \(path)")
            XCTAssertEqual(peer.sendPaclen, 256, "path \(path)")
            XCTAssertEqual(peer.sendWindow, 4, "path \(path)")

            peerSends(Self.burst(8 * 256 + 100, tag: "F"))
            XCTAssertTrue(peer.transmitted.contains { if case .i = $0.frame.kind { return $0.frame.info.count == 256 }; return false },
                          "path \(path): Direwolf sent 256-byte frames \(trace())")
            XCTAssertEqual(peer.maxOutstanding, 4, "path \(path): four frames in flight \(trace())")
            XCTAssertTrue(axtermSent("REJ").isEmpty && axtermSent("SREJ").isEmpty,
                          "path \(path): nothing was lost, so nothing is asked for again \(trace())")

            axtermSends(Self.burst(600, tag: "A"))
            assertWindowAndPaclenHeld()
            assertNoViolations()
        }
    }

    /// The same when Direwolf negotiates first: AXTerm's XID response
    /// advertises N1 256 and k 4, and Direwolf keeps to them.
    func testAXTermsXIDResponseAdvertisesItsReceiveCapacity() {
        build(.direwolf())
        peer.negotiate(with: Self.axtermCall, via: peerPath)
        run(until: { peer.srejEnabled }, limit: 30)
        let response = axtermSent("XID").last.flatMap { AX25XIDParameters.parse($0.payload) }
        XCTAssertEqual(response?.iFieldLengthRx, 256)
        XCTAssertEqual(response?.windowSizeRx, 4)
        XCTAssertEqual(peer.sendPaclen, 256)
        XCTAssertEqual(peer.sendWindow, 4)
        peer.connect(to: Self.axtermCall, via: peerPath, sabme: false)
        run(until: { axSession?.state == .connected && peer.isConnected }, limit: 60)
        peerSends(Self.burst(8 * 256, tag: "G"))
        XCTAssertEqual(peer.maxOutstanding, 4, trace())
        assertNoViolations()
    }

    /// The first of four 256-byte frames is lost. AXTerm holds the three
    /// behind the gap (its receive span is half the modulo, so a peer's
    /// k 4 always fits) and asks for the one missing frame, with SREJ when
    /// negotiated and REJ when not. Every byte arrives once, in order.
    func testFirstOfFourFullFramesLost() {
        for profile in [PeerProfile.direwolf(), PeerProfile.direwolf(srejOnModulo8: false)] {
            for path in Self.paths {
                build(profile, digis: path)
                axtermConnects()
                var dropped = false
                channel.dropRule = { d in
                    guard !dropped, d.receiver == "AXTerm", d.frame?.src.display != Self.axtermCall,
                          case .i(0, _, _) = d.frame?.kind else { return false }
                    dropped = true
                    return true
                }
                peerSends(Self.burst(4 * 256, tag: "H"))
                let label = "\(profile.srejOnModulo8 ? "SREJ" : "REJ") path \(path)"
                XCTAssertTrue(dropped, label)
                XCTAssertEqual(peer.maxOutstanding, 4, "\(label) \(trace())")
                if profile.srejOnModulo8 {
                    XCTAssertEqual(axtermSent("SREJ").count, 1, "\(label): one SREJ for the gap \(trace())")
                } else {
                    XCTAssertEqual(axtermSent("REJ").count, 1, "\(label): one REJ for the gap \(trace())")
                }
                assertNoViolations()
            }
        }
    }

    /// A Direwolf that answers an early XID with DM (no link yet) still
    /// connects after one probe.
    func testDirewolfAnsweringXIDWithDM() {
        scenarioXIDOnce(.direwolf(answersXID: false), expectSREJ: false)
    }
}
