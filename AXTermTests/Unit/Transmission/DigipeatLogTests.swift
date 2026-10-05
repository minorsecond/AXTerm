//
//  DigipeatLogTests.swift
//  AXTermTests
//
//  A frame we digipeat is logged as one we sent.
//
//  Smoke run 2026-10-03-1, issue 42: Station A's console said "Digipeated
//  K0EPI-3 → APZAXT" at 01:08:27Z, but its packet log had no transmitted
//  frame then. The repeat went straight to the radio and only a console line
//  was kept.
//

import XCTest
@testable import AXTerm

@MainActor
final class DigipeatLogTests: XCTestCase {

    /// B (ID-50)'s position beacon as A (705) heard it, path WIDE1-1,WIDE2-1.
    private let beaconFromB = Data(hex:
        "82A0B482B0A8E096608AA0924066AE92888A624062AE92888A64406303F0"
        + "21333933362E32354E2F31303434322E3530572D")

    func testTheRepeatIsLoggedAsSentWithOurEntryMarkedUsed() throws {
        let repeated = try XCTUnwrap(AX25Digipeater.repeatFrame(
            beaconFromB, myCall: AX25Address(call: "K0EPI", ssid: 2), aliases: [],
            fillIn: true, wideAreaMaxHops: 0))

        let packet = PacketEngine.transmittedPacket(
            repeated, radio: RadioID(rawValue: "radio-primary"), port: 0, linkDescription: "IC-705 via localhost")

        XCTAssertEqual(packet.direction, .tx)
        XCTAssertEqual(packet.from?.display, "K0EPI-3")
        XCTAssertEqual(packet.to?.display, "APZAXT")
        let ours = try XCTUnwrap(packet.via.first)
        XCTAssertEqual(ours.display, "K0EPI-2")
        XCTAssertTrue(ours.repeated, "our trace entry goes out with its H bit set")
        XCTAssertEqual(packet.rawAx25, repeated)
        XCTAssertEqual(packet.frameType, .ui)
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
