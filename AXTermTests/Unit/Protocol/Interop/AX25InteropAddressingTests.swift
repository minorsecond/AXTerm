//
//  AX25InteropAddressingTests.swift
//  AXTermTests
//
//  Answers come from the address that was called. AXTerm answers to more
//  than one address: the station's own and any a service registers (a
//  mailbox on its own SSID). A station matches every frame of a link by
//  both addresses, so an answer from the wrong SSID is, to the caller, a
//  frame from some other station.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25InteropAddressingTests: AX25InteropTestCase {

    private let mailbox = "N0AXT-8"

    private func buildWithMailbox(_ profile: PeerProfile, digis: [String] = []) {
        build(profile, digis: digis)
        axterm.manager.setServiceAddress(AXTermInteropStation.address(mailbox), for: "bbs")
    }

    /// A call to the mailbox is answered by the mailbox, frame after frame.
    func testACallToTheMailboxIsAnsweredFromTheMailbox() {
        for path in Self.paths {
            buildWithMailbox(.tnc2(), digis: path)
            peer.connect(to: mailbox, via: peerPath)
            run(until: { peer.isConnected }, limit: 60)
            XCTAssertTrue(peer.isConnected, "path \(path) \(trace())")
            peerSends(Data("hello mailbox\r".utf8))
            axtermSends(Data("mailbox here\r".utf8))
            let fromAXTerm = peer.heard.map(\.frame)
            XCTAssertTrue(fromAXTerm.allSatisfy { $0.src.display == mailbox }, "path \(path) \(trace())")
            XCTAssertEqual(peer.strayFrames, 0, "path \(path)")
            assertNoViolations()
        }
    }

    /// AXTerm restarted while a caller held a link to the mailbox. The
    /// caller's poll must draw DM from the mailbox: a DM from the station
    /// address belongs to no link the caller has, so it would poll on to N2.
    func testAStaleLinkToTheMailboxIsClearedByADMFromTheMailbox() {
        for path in Self.paths {
            buildWithMailbox(.tnc2(), digis: path)
            peer.assumeConnected(to: mailbox, via: peerPath)
            peer.send("still there?\r")
            run(until: { peer.state == .disconnected }, limit: 120)
            XCTAssertEqual(peer.state, .disconnected, "path \(path): the DM must come from \(mailbox) \(trace())")
            XCTAssertEqual(peer.linkFailures, 0, "path \(path): cleared by the DM, not by N2")
            XCTAssertTrue(axtermSent("DM").allSatisfy { $0.source.display == mailbox }, "path \(path)")
            assertNoViolations()
        }
    }

    /// The same for Linux, which polls with RR on T1 rather than resending
    /// the I-frame.
    func testAStaleLinuxLinkToTheMailboxIsClearedByADMFromTheMailbox() {
        buildWithMailbox(.linux())
        peer.assumeConnected(to: mailbox, via: [])
        peer.send("still there?\r")
        run(until: { peer.state == .disconnected }, limit: 120)
        XCTAssertEqual(peer.state, .disconnected, trace())
        XCTAssertEqual(peer.linkFailures, 0, "cleared by the DM, not by N2")
        XCTAssertTrue(axtermSent("DM").allSatisfy { $0.source.display == mailbox })
    }

    /// A caller hanging up a link AXTerm no longer holds gets DM, from the
    /// address it is hanging up on.
    func testADISCToTheMailboxWithNoLinkIsAnsweredFromTheMailbox() {
        buildWithMailbox(.tnc2())
        peer.assumeConnected(to: mailbox, via: [])
        peer.disconnect()
        run(until: { peer.state == .disconnected }, limit: 60)
        XCTAssertEqual(peer.state, .disconnected, trace())
        let discs = peer.transmitted.filter { if case .u(.disc, _) = $0.frame.kind { return true }; return false }
        XCTAssertEqual(discs.count, 1, "the first DM must close the caller's side, not N2 \(trace())")
        XCTAssertTrue(axtermSent("DM").allSatisfy { $0.source.display == mailbox })
    }
}
