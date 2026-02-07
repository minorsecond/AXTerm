//
//  AX25ControlFieldDecoderTests.swift
//  AXTermTests
//
//  Tests for AX.25 Control Field decoding (I/S/U frames).
//  Written TDD-style: these tests must fail initially until production code is implemented.
//

import XCTest
@testable import AXTerm

final class AX25ControlFieldDecoderTests: XCTestCase {

    // MARK: - I-Frame Tests (Modulo-8)

    /// Test decoding a standard modulo-8 I-frame with single control byte.
    /// I-frame: bit 0 = 0
    /// Format: NNNPSSS0 where NNN=N(R), P=P/F, SSS=N(S), 0=I-frame indicator
    func testDecodeIFrameModulo8() {
        // I-frame with N(S)=3, P/F=1, N(R)=5
        // Control byte: 101 1 011 0 = 0xB6
        // - bits 5-7: N(R)=5 = 0b101
        // - bit 4: P/F=1
        // - bits 1-3: N(S)=3 = 0b011
        // - bit 0: 0 (I-frame indicator)
        let controlBytes: [UInt8] = [0xB6]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .I)
        XCTAssertEqual(decoded.ns, 3)
        XCTAssertEqual(decoded.nr, 5)
        XCTAssertEqual(decoded.pf, 1)
        XCTAssertEqual(decoded.ctl0, 0xB6)
        XCTAssertNil(decoded.ctl1)
        XCTAssertNil(decoded.sType)
        XCTAssertNil(decoded.uType)
        XCTAssertFalse(decoded.isExtended)
    }

    /// Test I-frame with different sequence numbers and P/F=0
    func testDecodeIFrameModulo8_PFZero() {
        // I-frame with N(S)=0, P/F=0, N(R)=7
        // Control byte: 111 0 000 0 = 0xE0
        // - bits 5-7: N(R)=7 = 0b111
        // - bit 4: P/F=0
        // - bits 1-3: N(S)=0 = 0b000
        // - bit 0: 0 (I-frame indicator)
        let controlBytes: [UInt8] = [0xE0]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .I)
        XCTAssertEqual(decoded.ns, 0)
        XCTAssertEqual(decoded.nr, 7)
        XCTAssertEqual(decoded.pf, 0)
        XCTAssertFalse(decoded.isExtended)
    }

    /// Test I-frame with maximum sequence numbers
    func testDecodeIFrameModulo8_MaxSequences() {
        // I-frame with N(S)=7, P/F=1, N(R)=7
        // Control byte: 111 1 111 0 = 0xFE
        // - bits 5-7: N(R)=7 = 0b111
        // - bit 4: P/F=1
        // - bits 1-3: N(S)=7 = 0b111
        // - bit 0: 0 (I-frame indicator)
        let controlBytes: [UInt8] = [0xFE]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .I)
        XCTAssertEqual(decoded.ns, 7)
        XCTAssertEqual(decoded.nr, 7)
        XCTAssertEqual(decoded.pf, 1)
    }

    /// Test I-frame with single control byte (standard modulo-8 mode)
    /// Modulo-8 I-frames use a single byte, not two bytes
    func testDecodeIFrameSingleByte() {
        // Control byte: 0x00 = N(S)=0, P/F=0, N(R)=0
        let controlBytes: [UInt8] = [0x00]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        // Single byte is correct for modulo-8 I-frames
        XCTAssertEqual(decoded.frameClass, .I)
        XCTAssertEqual(decoded.ns, 0)
        XCTAssertEqual(decoded.nr, 0)
        XCTAssertEqual(decoded.pf, 0)
        XCTAssertEqual(decoded.ctl0, 0x00)
        XCTAssertNil(decoded.ctl1)
    }

    // MARK: - S-Frame Tests (Modulo-8)

    /// Test decoding S-frame RR (Receive Ready)
    /// S-frame: (ctl0 & 0x03) == 0x01
    /// Subtype in bits 2-3: RR=0b00
    /// N(R) in bits 5-7
    /// P/F in bit 4
    func testDecodeSFrameRR() {
        // S-frame RR with N(R)=4, P/F=1
        // ctl0: 0b10010001 = 0x91 (N(R)=4 in bits 5-7, P/F=1 in bit 4, RR=0b00 in bits 2-3, 0b01 in bits 0-1)
        let controlBytes: [UInt8] = [0x91]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .S)
        XCTAssertEqual(decoded.sType, .RR)
        XCTAssertEqual(decoded.nr, 4)
        XCTAssertEqual(decoded.pf, 1)
        XCTAssertNil(decoded.ns)
        XCTAssertNil(decoded.uType)
        XCTAssertEqual(decoded.ctl0, 0x91)
        XCTAssertNil(decoded.ctl1)
        XCTAssertFalse(decoded.isExtended)
    }

    /// Test decoding S-frame RR with P/F=0
    func testDecodeSFrameRR_PFZero() {
        // S-frame RR with N(R)=2, P/F=0
        // ctl0: 0b01000001 = 0x41 (N(R)=2 in bits 5-7, P/F=0, RR=0b00, S-frame=0b01)
        let controlBytes: [UInt8] = [0x41]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .S)
        XCTAssertEqual(decoded.sType, .RR)
        XCTAssertEqual(decoded.nr, 2)
        XCTAssertEqual(decoded.pf, 0)
    }

    /// Test decoding S-frame RNR (Receive Not Ready)
    func testDecodeSFrameRNR() {
        // S-frame RNR with N(R)=3, P/F=0
        // ctl0: 0b01100101 = 0x65 (N(R)=3 in bits 5-7, P/F=0, RNR=0b01 in bits 2-3, S-frame=0b01 in bits 0-1)
        let controlBytes: [UInt8] = [0x65]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .S)
        XCTAssertEqual(decoded.sType, .RNR)
        XCTAssertEqual(decoded.nr, 3)
        XCTAssertEqual(decoded.pf, 0)
    }

    /// Test decoding S-frame REJ (Reject)
    func testDecodeSFrameREJ() {
        // S-frame REJ with N(R)=6, P/F=1
        // ctl0: 0b11011001 = 0xD9 (N(R)=6 in bits 5-7, P/F=1 in bit 4, REJ=0b10 in bits 2-3, S-frame=0b01)
        let controlBytes: [UInt8] = [0xD9]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .S)
        XCTAssertEqual(decoded.sType, .REJ)
        XCTAssertEqual(decoded.nr, 6)
        XCTAssertEqual(decoded.pf, 1)
    }

    /// Test decoding S-frame SREJ (Selective Reject)
    func testDecodeSFrameSREJ() {
        // S-frame SREJ with N(R)=1, P/F=0
        // ctl0: 0b00101101 = 0x2D (N(R)=1 in bits 5-7, P/F=0, SREJ=0b11 in bits 2-3, S-frame=0b01)
        let controlBytes: [UInt8] = [0x2D]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .S)
        XCTAssertEqual(decoded.sType, .SREJ)
        XCTAssertEqual(decoded.nr, 1)
        XCTAssertEqual(decoded.pf, 0)
    }

    // MARK: - U-Frame Tests

    /// Test decoding U-frame UI (Unnumbered Information)
    /// U-frame: (ctl0 & 0x03) == 0x03
    /// UI = 0x03 (with P/F in bit 4)
    func testDecodeUFrameUI() {
        // U-frame UI with P/F=0
        // ctl0: 0x03
        let controlBytes: [UInt8] = [0x03]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .UI)
        XCTAssertEqual(decoded.pf, 0)
        XCTAssertNil(decoded.ns)
        XCTAssertNil(decoded.nr)
        XCTAssertNil(decoded.sType)
        XCTAssertEqual(decoded.ctl0, 0x03)
        XCTAssertFalse(decoded.isExtended)
    }

    /// Test decoding U-frame UI with P/F=1
    func testDecodeUFrameUI_PFOne() {
        // U-frame UI with P/F=1
        // ctl0: 0x13 (0x03 | 0x10)
        let controlBytes: [UInt8] = [0x13]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .UI)
        XCTAssertEqual(decoded.pf, 1)
    }

    /// Test decoding U-frame SABM (Set Asynchronous Balanced Mode)
    func testDecodeUFrameSABM() {
        // U-frame SABM with P/F=1 (typical for connection request)
        // SABM = 0x2F, with P/F: 0x3F
        let controlBytes: [UInt8] = [0x3F]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .SABM)
        XCTAssertEqual(decoded.pf, 1)
    }

    /// Test decoding U-frame SABM without P/F
    func testDecodeUFrameSABM_PFZero() {
        // SABM = 0x2F
        let controlBytes: [UInt8] = [0x2F]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .SABM)
        XCTAssertEqual(decoded.pf, 0)
    }

    /// Test decoding U-frame SABME (Set Asynchronous Balanced Mode Extended)
    func testDecodeUFrameSABME() {
        // SABME = 0x6F
        let controlBytes: [UInt8] = [0x6F]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .SABME)
        XCTAssertEqual(decoded.pf, 0)
    }

    /// Test decoding U-frame DISC (Disconnect)
    func testDecodeUFrameDISC() {
        // DISC = 0x43, with P/F: 0x53
        let controlBytes: [UInt8] = [0x53]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .DISC)
        XCTAssertEqual(decoded.pf, 1)
    }

    /// Test decoding U-frame UA (Unnumbered Acknowledge)
    func testDecodeUFrameUA() {
        // UA = 0x63, with P/F: 0x73
        let controlBytes: [UInt8] = [0x73]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .UA)
        XCTAssertEqual(decoded.pf, 1)
    }

    /// Test decoding U-frame DM (Disconnected Mode)
    func testDecodeUFrameDM() {
        // DM = 0x0F, with P/F: 0x1F
        let controlBytes: [UInt8] = [0x1F]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .DM)
        XCTAssertEqual(decoded.pf, 1)
    }

    /// Test decoding U-frame FRMR (Frame Reject)
    func testDecodeUFrameFRMR() {
        // FRMR = 0x87
        let controlBytes: [UInt8] = [0x87]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .FRMR)
        XCTAssertEqual(decoded.pf, 0)
    }

    // MARK: - Unknown / Malformed Tests

    /// Test decoding unknown U-frame returns UNKNOWN uType but still U frameClass
    func testDecodeUnknownUFrame() {
        // Unknown U-frame pattern (not matching known types)
        // 0xAF is a U-frame (bits 0-1 = 0b11) but not a known subtype
        let controlBytes: [UInt8] = [0xAF]

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .U)
        XCTAssertEqual(decoded.uType, .UNKNOWN)
        XCTAssertEqual(decoded.ctl0, 0xAF)
    }

    /// Test decoding does not crash on malformed input
    func testDecodeUnknownDoesNotCrash() {
        // Various malformed inputs - should not crash
        let testCases: [[UInt8]] = [
            [0xFF],
            [0xFF, 0xFF],
            [0x00, 0x00, 0x00], // Extra bytes
            [0x80],
            [0x7F]
        ]

        for controlBytes in testCases {
            let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)
            // Should return something without crashing
            XCTAssertNotNil(decoded.frameClass)
            XCTAssertNotNil(decoded.ctl0)
        }
    }

    /// Test decoding empty bytes does not crash
    func testDecodeEmptyBytesDoesNotCrash() {
        let controlBytes: [UInt8] = []

        let decoded = AX25ControlFieldDecoder.decode(controlBytes: controlBytes)

        XCTAssertEqual(decoded.frameClass, .unknown)
        XCTAssertNil(decoded.ctl0)
        XCTAssertNil(decoded.ctl1)
        XCTAssertNil(decoded.ns)
        XCTAssertNil(decoded.nr)
        XCTAssertNil(decoded.pf)
    }

    // MARK: - Frame Class Determination Tests

    /// Test all frame class patterns are correctly identified
    func testFrameClassDetermination() {
        // I-frame: bit 0 = 0 (single byte in modulo-8 mode)
        let iFrame = AX25ControlFieldDecoder.decode(controlBytes: [0x00])
        XCTAssertEqual(iFrame.frameClass, .I)

        // S-frame: bits 0-1 = 01
        let sFrame = AX25ControlFieldDecoder.decode(controlBytes: [0x01])
        XCTAssertEqual(sFrame.frameClass, .S)

        // U-frame: bits 0-1 = 11
        let uFrame = AX25ControlFieldDecoder.decode(controlBytes: [0x03])
        XCTAssertEqual(uFrame.frameClass, .U)
    }
}
