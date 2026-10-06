//
//  CommandBitDecodeTests.swift
//  AXTermTests
//
//  Bit 7 of an address's SSID byte means two things in AX.25 2.x. On the
//  destination and source it is the command/response (C) bit; only on a
//  digipeater is it the H bit, "has been repeated". The decoder read it as
//  `repeated` on every address, so a response frame's source decoded as
//  repeated (seen under lldb on 2026-10-06, smoke run 2026-10-03-1, issue
//  90 row), and an address compared with `==` could miss its station.
//

import XCTest
@testable import AXTerm

final class CommandBitDecodeTests: XCTestCase {

    private let local = AX25Address(call: "K0EPI", ssid: 2)
    private let peer = AX25Address(call: "K0EPI", ssid: 3)

    func testAResponsesSourceIsNotRepeated() throws {
        let ua = AX25FrameBuilder.buildUA(from: peer, to: local, pf: true).encodeAX25()
        let frame = try AX25.checkFrame(ax25: ua).get()
        XCTAssertEqual(frame.from?.repeated, false, "the source's bit 7 is the C bit")
        XCTAssertEqual(frame.to?.repeated, false)
        XCTAssertEqual(frame.from, peer, "the decoded address equals the station")
        XCTAssertEqual(frame.isCommand, false)
    }

    func testACommandStillReadsAsACommand() throws {
        let sabm = AX25FrameBuilder.buildSABM(from: local, to: peer, pf: true).encodeAX25()
        let frame = try AX25.checkFrame(ax25: sabm).get()
        XCTAssertEqual(frame.to?.repeated, false, "the destination's bit 7 is the C bit")
        XCTAssertEqual(frame.isCommand, true)
    }

    /// Both C bits equal is AX.25 1.x, which says neither.
    func testEqualCBitsSayNeither() throws {
        var bytes = AX25FrameBuilder.buildSABM(from: local, to: peer, pf: true).encodeAX25()
        bytes[bytes.startIndex + 6] &= 0x7F
        bytes[bytes.startIndex + 13] &= 0x7F
        XCTAssertNil(try AX25.checkFrame(ax25: bytes).get().isCommand)
    }

    func testADigipeatersHBitIsStillRepeated() throws {
        let via = DigiPath.from(["WIDE1-1"])
        var bytes = AX25FrameBuilder.buildUI(from: local, to: AX25Address(call: "APRS"), via: via,
                                             payload: Data("x".utf8)).encodeAX25()
        bytes[bytes.startIndex + 20] |= 0x80   // H bit on the digipeater
        let frame = try AX25.checkFrame(ax25: bytes).get()
        XCTAssertEqual(frame.via.first?.repeated, true)
        XCTAssertEqual(frame.from?.repeated, false)
    }

    /// A packet keeps its raw bytes, and its command/response comes from
    /// them, so it survives the decoder no longer carrying the C bit in
    /// `repeated`, and a packet read back from the database.
    func testAPacketReadsItsCommandBitFromItsRawBytes() {
        let ua = AX25FrameBuilder.buildUA(from: peer, to: local, pf: true).encodeAX25()
        let packet = Packet(from: peer, to: local, frameType: .u, control: 0x73,
                            info: Data(), rawAx25: ua)
        XCTAssertFalse(packet.isCommand)
        let sabm = AX25FrameBuilder.buildSABM(from: local, to: peer, pf: true).encodeAX25()
        let command = Packet(from: local, to: peer, frameType: .u, control: 0x3F,
                             info: Data(), rawAx25: sabm)
        XCTAssertTrue(command.isCommand)
    }
}
