//
//  AX25InteropLinuxTests.swift
//  AXTermTests
//
//  AXTerm against the Linux kernel AX.25 stack with its default
//  parameters (include/net/ax25.h): T1 10 s with linear backoff, T2 3 s,
//  T3 300 s, N2 10, window 2, paclen 256. The kernel does not implement
//  XID and answers any frame it holds no link for with DM, so AXTerm's XID
//  draws DM. Any N(S) other than V(R), a duplicate included, draws REJ.
//  See AX25PeerModels.swift for the sources.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25InteropLinuxTests: AX25InteropTestCase {

    func testAXTermCalls() { scenarioAXTermCalls(.linux()) }
    func testAXTermCallsWithoutXID() { scenarioAXTermCalls(.linux(), negotiate: false) }
    func testLinuxCalls() { scenarioPeerCalls(.linux()) }
    func testAXTermFrameLostDrawsREJ() { scenarioAXTermFrameLost(.linux()) }
    func testLinuxFrameLostDrawsREJ() { scenarioPeerFrameLost(.linux()) }
    func testLostAckRecoveredByT1() { scenarioAckLost(.linux()) }
    func testRNR() { scenarioPeerBusy(.linux()) }
    func testLastFrameLostRecoveredByT1() { scenarioLastFrameLost(.linux()) }
    func testLinuxReconnectsOverStaleLink() { scenarioPeerReconnectsOverStaleLink(.linux()) }
    func testKeepalive() { scenarioKeepalive(.linux()) }
    func testLinuxStaleLinkClearedByDM() { scenarioPeerHoldsStaleLink(.linux()) }
    func testAXTermStaleLinkClearedByDM() { scenarioAXTermHoldsStaleLink(.linux()) }
    func testFRMR() { scenarioFRMR(.linux()) }
    func testAddressing() { scenarioAddressing(.linux()) }
    func testXIDDrawsDMAndFallsBack() { scenarioXIDOnce(.linux(), expectSREJ: false) }

    /// Linux holds the ack for an unpolled frame for its 3 s T2. AXTerm's
    /// T1 floor (FRACK 4 s, times 2 x digis + 1) must outlast it, so lone
    /// lines sent one at a time are never resent.
    func testUnpolledLinesOutlastLinuxT2() {
        for path in Self.paths {
            build(.linux(), digis: path)
            axtermConnects()
            for n in 0..<6 {
                axtermSends(Data("line \(n)\r".utf8))
                run(5)
            }
            XCTAssertEqual(axtermRetransmissions, 0, "path \(path) \(trace())")
            assertNoViolations()
        }
    }

    /// Linux's 256-byte frames against AXTerm's 128-byte paclen: AXTerm
    /// accepts the larger I field and keeps sending its own size.
    func testLinuxPaclen256IntoAXTerm() {
        build(.linux())
        axtermConnects()
        peerSends(Self.burst(1500, tag: "K"))
        XCTAssertTrue(peer.transmitted.contains { $0.frame.info.count == 256 })
        axtermSends(Self.burst(500, tag: "A"))
        assertWindowAndPaclenHeld()
        assertNoViolations()
    }
}
