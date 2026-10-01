//
//  NoSessionAnswerAddressTests.swift
//  AXTermTests
//
//  A frame for a link this station no longer holds is answered with DM
//  (AX.25 2.0 / 2.2 §6.3.5), and the DM comes from the address the frame
//  was sent to. The caller matches the DM to its link by both addresses;
//  a DM from the station address to a caller whose link was with the
//  mailbox SSID clears nothing, and the caller polls until its N2 runs
//  out. XIDServiceAddressTests covers the same rule for XID.
//

import XCTest
@testable import AXTerm

@MainActor
final class NoSessionAnswerAddressTests: XCTestCase {

    private let station = AX25Address(call: "N0AXT", ssid: 1)
    private let mailbox = AX25Address(call: "N0AXT", ssid: 8)
    private let caller = AX25Address(call: "W1PEER", ssid: 0)

    private func manager() -> AX25SessionManager {
        let m = AX25SessionManager(localCallsign: station)
        m.setServiceAddress(mailbox, for: "bbs")
        return m
    }

    func testAnIFramePollToTheMailboxDrawsDMFromTheMailbox() throws {
        let dm = try XCTUnwrap(manager().handleInboundIFrame(
            from: caller, to: mailbox, path: DigiPath(), radio: .primary,
            ns: 0, nr: 0, pf: true, payload: Data("x\r".utf8)))
        XCTAssertEqual(dm.displayInfo, "DM")
        XCTAssertEqual(dm.source, mailbox)
    }

    func testSupervisoryPollsToTheMailboxDrawDMFromTheMailbox() throws {
        let m = manager()
        let rr = try XCTUnwrap(m.handleInboundRRFrames(from: caller, to: mailbox, path: DigiPath(), radio: .primary,
                                                       nr: 0, pf: true, isCommand: true).first)
        let rnr = try XCTUnwrap(m.handleInboundRNR(from: caller, to: mailbox, path: DigiPath(), radio: .primary,
                                                   nr: 0, pf: true, isCommand: true).first)
        let rej = try XCTUnwrap(m.handleInboundREJ(from: caller, to: mailbox, path: DigiPath(), radio: .primary,
                                                   nr: 0, pf: true, isCommand: true).first)
        for dm in [rr, rnr, rej] {
            XCTAssertEqual(dm.displayInfo, "DM")
            XCTAssertEqual(dm.source, mailbox)
        }
    }

    func testADISCToTheMailboxDrawsDMFromTheMailbox() throws {
        let dm = try XCTUnwrap(manager().handleInboundDISC(from: caller, to: mailbox, path: DigiPath(), radio: .primary))
        XCTAssertEqual(dm.displayInfo, "DM")
        XCTAssertEqual(dm.source, mailbox)
    }

    /// Without a called address, or with one that is not ours, the answer
    /// comes from the radio's address as before.
    func testOtherwiseTheRadiosAddressAnswers() throws {
        let m = manager()
        let unaddressed = try XCTUnwrap(m.handleInboundDISC(from: caller, path: DigiPath(), radio: .primary))
        XCTAssertEqual(unaddressed.source, station)
        let foreign = try XCTUnwrap(m.handleInboundDISC(from: caller, to: AX25Address(call: "K9XYZ"),
                                                        path: DigiPath(), radio: .primary))
        XCTAssertEqual(foreign.source, station)
    }
}
