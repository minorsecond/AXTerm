//
//  AX25XIDTests.swift
//  AXTermTests
//
//  XID parameter negotiation (AX.25 2.2 §4.3.3.7 / §6.3.2). The wire
//  format and bit values follow the de-facto field reference (Direwolf's
//  xid.c, which interoperates with BPQ and UZ7HO): FI 0x82, GI 0x80,
//  16-bit group length, then PI/PL/PV triplets. A command offers a menu
//  of acceptable options; a response picks exactly one.
//

import XCTest
@testable import AXTerm

final class AX25XIDTests: XCTestCase {

    // MARK: - Encoding

    func testCommandEncodesTheDirewolfReferenceLayout() {
        var params = AX25XIDParameters()
        params.supportsSREJ = true
        params.iFieldLengthRx = 256
        params.windowSizeRx = 7
        params.ackTimerMs = 3000
        params.retries = 10

        let info = params.encoded(isCommand: true)
        let b = [UInt8](info)

        XCTAssertEqual(b[0], 0x82, "FI")
        XCTAssertEqual(b[1], 0x80, "GI")
        XCTAssertEqual(Int(b[2]) << 8 | Int(b[3]), b.count - 4, "GL covers the parameter fields")

        // PI 2, Classes of Procedures: balanced ABM + half duplex.
        XCTAssertEqual(Array(b[4...7]), [2, 2, 0x21, 0x00])

        // PI 3, HDLC Optional Functions: a command OFFERS a menu —
        // REJ and SREJ both set, modulo 8, plus the fixed bits
        // (extended address, TEST, 16-bit FCS, synchronous TX).
        XCTAssertEqual(b[8], 3)
        XCTAssertEqual(b[9], 3)
        let opt = UInt32(b[10]) << 16 | UInt32(b[11]) << 8 | UInt32(b[12])
        XCTAssertEqual(opt & 0x020000, 0x020000, "REJ offered")
        XCTAssertEqual(opt & 0x040000, 0x040000, "SREJ offered")
        XCTAssertEqual(opt & 0x000400, 0x000400, "modulo 8")
        XCTAssertEqual(opt & 0x000800, 0, "modulo 128 NOT offered — the receive path is modulo-8")
        XCTAssertEqual(opt & 0x800000, 0x800000, "extended address")
        XCTAssertEqual(opt & 0x008000, 0x008000, "16-bit FCS")

        // PI 6, I Field Length Rx — in BITS.
        XCTAssertEqual(Array(b[13...16]), [6, 2, UInt8((256 * 8) >> 8), UInt8((256 * 8) & 0xFF)])

        // PI 8, Window Size Rx.
        XCTAssertEqual(Array(b[17...19]), [8, 1, 7])

        // PI 9, Ack Timer (ms); PI 10, Retries.
        XCTAssertEqual(Array(b[20...23]), [9, 2, UInt8(3000 >> 8), UInt8(3000 & 0xFF)])
        XCTAssertEqual(Array(b[24...26]), [10, 1, 10])
    }

    func testResponsePicksExactlyOneRejectMode() {
        var params = AX25XIDParameters()
        params.supportsSREJ = true
        let b = [UInt8](params.encoded(isCommand: false))
        let opt = UInt32(b[10]) << 16 | UInt32(b[11]) << 8 | UInt32(b[12])
        XCTAssertEqual(opt & 0x040000, 0x040000, "response selects SREJ")
        XCTAssertEqual(opt & 0x020000, 0, "response must not also select REJ")
    }

    // MARK: - Parsing

    func testRoundTrip() throws {
        var params = AX25XIDParameters()
        params.supportsSREJ = true
        params.iFieldLengthRx = 512
        params.windowSizeRx = 4
        params.ackTimerMs = 4000
        params.retries = 15

        let parsed = try XCTUnwrap(AX25XIDParameters.parse(params.encoded(isCommand: false)))
        XCTAssertTrue(parsed.supportsSREJ)
        XCTAssertEqual(parsed.iFieldLengthRx, 512)
        XCTAssertEqual(parsed.windowSizeRx, 4)
        XCTAssertEqual(parsed.ackTimerMs, 4000)
        XCTAssertEqual(parsed.retries, 15)
        XCTAssertFalse(parsed.modulo128)
    }

    func testParseToleratesUnknownParameters() throws {
        var params = AX25XIDParameters()
        params.supportsSREJ = true
        var info = params.encoded(isCommand: false)
        // Append an unknown PI 65 (compression mask) — must be skipped.
        info.append(contentsOf: [65, 2, 0xAB, 0xCD])
        // Fix up the group length.
        let gl = info.count - 4
        info[2] = UInt8(gl >> 8); info[3] = UInt8(gl & 0xFF)

        let parsed = try XCTUnwrap(AX25XIDParameters.parse(info))
        XCTAssertTrue(parsed.supportsSREJ)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(AX25XIDParameters.parse(Data()))
        XCTAssertNil(AX25XIDParameters.parse(Data([0x00, 0x80, 0, 0])))
        XCTAssertNil(AX25XIDParameters.parse(Data([0x82, 0x00, 0, 0])))
        // Truncated mid-parameter.
        XCTAssertNil(AX25XIDParameters.parse(Data([0x82, 0x80, 0, 4, 3, 3, 0x86])))
    }

    func testParseDetectsModulo128Peer() throws {
        // A peer offering modulo 128 (e.g. Direwolf with maxv22): we must
        // see the flag so negotiation can decline it and stay modulo-8.
        var info = Data([0x82, 0x80, 0, 5, 3, 3])
        info.append(contentsOf: [0x86, 0x0C, 0x02] as [UInt8])  // ext addr + SREJ+REJ menu, modulo 128+8, sync TX
        let parsed = try XCTUnwrap(AX25XIDParameters.parse(info))
        XCTAssertTrue(parsed.modulo128)
        XCTAssertTrue(parsed.supportsSREJ)
    }
}
