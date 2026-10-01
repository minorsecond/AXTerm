//
//  XIDServiceAddressTests.swift
//  AXTermTests
//
//  Answering an XID from the address it was sent to.
//
//  On 2026-10-01 station A sent XID to K0EPI-8, the mailbox on station B,
//  and B answered from K0EPI-3, its station callsign. A was negotiating
//  with K0EPI-8 and heard an answer from somebody else. An XID addressed to
//  one of our service addresses is answered from that address, as the SABM
//  that follows it is.
//

import XCTest
@testable import AXTerm

@MainActor
final class XIDServiceAddressTests: XCTestCase {

    private let caller = AX25Address(call: "K0EPI", ssid: 2)
    private let station = AX25Address(call: "K0EPI", ssid: 3)
    private let mailbox = AX25Address(call: "K0EPI", ssid: 8)

    private func manager() -> AX25SessionManager {
        let manager = AX25SessionManager(localCallsign: station, clock: AX25VirtualClock())
        manager.setServiceAddress(mailbox, for: "bbs")
        return manager
    }

    func testAnXIDToTheMailboxIsAnsweredFromTheMailbox() throws {
        let responses = manager().handleInboundXID(from: caller, to: mailbox, path: DigiPath(), radio: .primary,
                                                   info: AX25XIDParameters().encoded(isCommand: true), isCommand: true, pf: true)
        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.source.display, "K0EPI-8",
                       "the mailbox's XID was answered as \(response.source.display)")
        XCTAssertEqual(response.destination.display, "K0EPI-2")
    }

    func testAnXIDToTheStationIsAnsweredFromTheStation() throws {
        let responses = manager().handleInboundXID(from: caller, to: station, path: DigiPath(), radio: .primary,
                                                   info: AX25XIDParameters().encoded(isCommand: true), isCommand: true, pf: true)
        XCTAssertEqual(try XCTUnwrap(responses.first).source.display, "K0EPI-3")
    }
}
