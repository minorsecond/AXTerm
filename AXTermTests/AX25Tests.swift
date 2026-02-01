//
//  AX25Tests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest
@testable import AXTerm

final class AX25Tests: XCTestCase {

    // MARK: - Address Decoding

    func testDecodeAddressBasicCallSSID() {
        // "N0CALL" with SSID 0, not last address
        // Each char shifted left 1, SSID byte: (0 << 1) | 0 = 0, not last
        let callBytes: [UInt8] = [
            0x9C, // 'N' << 1
            0x60, // '0' << 1
            0x86, // 'C' << 1
            0x82, // 'A' << 1
            0x98, // 'L' << 1
            0x98, // 'L' << 1
            0x00  // SSID 0, not last
        ]
        let data = Data(callBytes)

        let result = AX25.decodeAddress(data: data, offset: 0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.address.call, "N0CALL")
        XCTAssertEqual(result?.address.ssid, 0)
        XCTAssertFalse(result?.isLast ?? true)
        XCTAssertEqual(result?.nextOffset, 7)
    }

    func testDecodeAddressWithSSID() {
        // "WIDE1" with SSID 1, last address
        let callBytes: [UInt8] = [
            0xAE, // 'W' << 1
            0x92, // 'I' << 1
            0x88, // 'D' << 1
            0x8A, // 'E' << 1
            0x62, // '1' << 1
            0x40, // ' ' << 1 (space padding)
            0x03  // SSID 1 << 1 | 1 (last bit set)
        ]
        let data = Data(callBytes)

        let result = AX25.decodeAddress(data: data, offset: 0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.address.call, "WIDE1")
        XCTAssertEqual(result?.address.ssid, 1)
        XCTAssertTrue(result?.isLast ?? false)
    }

    func testDecodeAddressRepeatedBit() {
        // Address with repeated (H) bit set
        let callBytes: [UInt8] = [
            0xAE, 0x92, 0x88, 0x8A, 0x62, 0x40,
            0x83  // SSID 1, last bit set, H bit (0x80) set
        ]
        let data = Data(callBytes)

        let result = AX25.decodeAddress(data: data, offset: 0)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.address.repeated ?? false)
    }

    func testDecodeAddressTooShort() {
        let data = Data([0x9C, 0x60, 0x86]) // Only 3 bytes
        let result = AX25.decodeAddress(data: data, offset: 0)
        XCTAssertNil(result)
    }

    // MARK: - Frame Decoding

    func testDecodeUIFrameParsesFromToViaPidInfo() {
        // Construct a UI frame: DST(7) + SRC(7) + VIA(7) + Control(1) + PID(1) + Info
        var frame = Data()

        // Destination: "APRS" with SSID 0
        frame.append(contentsOf: [
            0x82, 0xA0, 0xA4, 0xA6, 0x40, 0x40, 0x60 // "APRS  " not last
        ])

        // Source: "N0CALL" with SSID 1
        frame.append(contentsOf: [
            0x9C, 0x60, 0x86, 0x82, 0x98, 0x98, 0x62 // "N0CALL" SSID 1, not last
        ])

        // Via: "WIDE1" with SSID 1, repeated, last
        frame.append(contentsOf: [
            0xAE, 0x92, 0x88, 0x8A, 0x62, 0x40, 0xE3 // "WIDE1 " SSID 1, repeated, last
        ])

        // Control: UI frame (0x03)
        frame.append(0x03)

        // PID: No Layer 3 (0xF0)
        frame.append(0xF0)

        // Info: "Test"
        frame.append(contentsOf: [0x54, 0x65, 0x73, 0x74])

        let result = AX25.decodeFrame(ax25: frame)
        XCTAssertNotNil(result)

        XCTAssertEqual(result?.to?.call, "APRS")
        XCTAssertEqual(result?.to?.ssid, 0)

        XCTAssertEqual(result?.from?.call, "N0CALL")
        XCTAssertEqual(result?.from?.ssid, 1)

        XCTAssertEqual(result?.via.count, 1)
        XCTAssertEqual(result?.via.first?.call, "WIDE1")
        XCTAssertEqual(result?.via.first?.ssid, 1)
        XCTAssertTrue(result?.via.first?.repeated ?? false)

        XCTAssertEqual(result?.frameType, .ui)
        XCTAssertEqual(result?.pid, 0xF0)
        XCTAssertEqual(result?.info, Data([0x54, 0x65, 0x73, 0x74]))
    }

    func testDecodeIFrame() {
        // I-frame: control byte has bit 0 = 0
        var frame = Data()

        // DST + SRC (both marked last at SRC)
        frame.append(contentsOf: [
            0x82, 0xA0, 0xA4, 0xA6, 0x40, 0x40, 0x60, // DST
            0x9C, 0x60, 0x86, 0x82, 0x98, 0x98, 0x61  // SRC, last
        ])

        // Control: I-frame (e.g., 0x00)
        frame.append(0x00)

        // PID
        frame.append(0xF0)

        // Info
        frame.append(contentsOf: [0x01, 0x02])

        let result = AX25.decodeFrame(ax25: frame)
        XCTAssertEqual(result?.frameType, .i)
    }

    func testDecodeSFrame() {
        // S-frame: bits 0-1 = 01
        var frame = Data()

        frame.append(contentsOf: [
            0x82, 0xA0, 0xA4, 0xA6, 0x40, 0x40, 0x60,
            0x9C, 0x60, 0x86, 0x82, 0x98, 0x98, 0x61
        ])

        // Control: S-frame (e.g., RR = 0x01)
        frame.append(0x01)

        let result = AX25.decodeFrame(ax25: frame)
        XCTAssertEqual(result?.frameType, .s)
        XCTAssertNil(result?.pid) // S-frames don't have PID
    }

    func testDecodeUFrameNonUI() {
        // U-frame that's not UI (e.g., SABM = 0x2F)
        var frame = Data()

        frame.append(contentsOf: [
            0x82, 0xA0, 0xA4, 0xA6, 0x40, 0x40, 0x60,
            0x9C, 0x60, 0x86, 0x82, 0x98, 0x98, 0x61
        ])

        frame.append(0x2F) // SABM

        let result = AX25.decodeFrame(ax25: frame)
        XCTAssertEqual(result?.frameType, .u)
    }

    func testDecodeFrameTooShort() {
        let frame = Data([0x01, 0x02, 0x03]) // Way too short
        let result = AX25.decodeFrame(ax25: frame)
        XCTAssertNil(result)
    }

    // MARK: - Info Text Heuristic

    func testInfoTextPrintableHeuristic() {
        // Mostly printable ASCII -> should return string
        let printablePacket = Packet(
            info: "Hello World!".data(using: .ascii)!
        )
        XCTAssertNotNil(printablePacket.infoText)
        XCTAssertEqual(printablePacket.infoText, "Hello World!")
    }

    func testInfoTextBinaryReturnsNil() {
        // Binary data with many non-printable bytes
        let binaryPacket = Packet(
            info: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        )
        XCTAssertNil(binaryPacket.infoText)
    }

    func testInfoTextMixedContent() {
        // Mixed but mostly printable (>75%)
        let mixedData = "Hello".data(using: .ascii)! + Data([0x00])
        let packet = Packet(info: mixedData)
        // 5 printable + 1 non-printable = 83% printable
        XCTAssertNotNil(packet.infoText)
    }

    func testInfoTextEmpty() {
        let packet = Packet(info: Data())
        XCTAssertNil(packet.infoText)
    }

    // MARK: - Address Encoding (TX)

    func testEncodeAddressBasic() {
        // Encode "N0CALL" with SSID 0, not last
        let address = AX25Address(call: "N0CALL", ssid: 0)
        let encoded = AX25.encodeAddress(address, isLast: false)

        // Expected: each char shifted left 1, SSID byte with extension bit
        let expected: [UInt8] = [
            0x9C, // 'N' << 1
            0x60, // '0' << 1
            0x86, // 'C' << 1
            0x82, // 'A' << 1
            0x98, // 'L' << 1
            0x98, // 'L' << 1
            0x60  // SSID 0 shifted + reserved bits (0b0110_0000), not last
        ]
        XCTAssertEqual(encoded, Data(expected))
    }

    func testEncodeAddressWithSSID() {
        // Encode "WIDE1" with SSID 1, last address
        let address = AX25Address(call: "WIDE1", ssid: 1)
        let encoded = AX25.encodeAddress(address, isLast: true)

        // Callsign padded to 6 chars with spaces
        let expected: [UInt8] = [
            0xAE, // 'W' << 1
            0x92, // 'I' << 1
            0x88, // 'D' << 1
            0x8A, // 'E' << 1
            0x62, // '1' << 1
            0x40, // ' ' << 1 (padding)
            0x63  // SSID 1 << 1 | 0x60 | 0x01 (last bit)
        ]
        XCTAssertEqual(encoded, Data(expected))
    }

    func testEncodeAddressShortCallsign() {
        // Short callsign should be right-padded with spaces
        let address = AX25Address(call: "K0X", ssid: 5)
        let encoded = AX25.encodeAddress(address, isLast: true)

        let expected: [UInt8] = [
            0x96, // 'K' << 1
            0x60, // '0' << 1
            0xB0, // 'X' << 1
            0x40, // ' ' << 1
            0x40, // ' ' << 1
            0x40, // ' ' << 1
            0x6B  // SSID 5 << 1 | 0x60 | 0x01
        ]
        XCTAssertEqual(encoded, Data(expected))
    }

    func testEncodeDecodeAddressRoundTrip() {
        // Round-trip test: encode then decode should match
        let original = AX25Address(call: "N0CALL", ssid: 7)
        let encoded = AX25.encodeAddress(original, isLast: true)
        let decoded = AX25.decodeAddress(data: encoded, offset: 0)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.address.call, original.call)
        XCTAssertEqual(decoded?.address.ssid, original.ssid)
        XCTAssertTrue(decoded?.isLast ?? false)
    }

    // MARK: - UI Frame Encoding (TX)

    func testEncodeUIFrameBasic() {
        let from = AX25Address(call: "N0CALL", ssid: 1)
        let to = AX25Address(call: "APRS", ssid: 0)
        let info = Data("Test".utf8)

        let frame = AX25.encodeUIFrame(
            from: from,
            to: to,
            via: [],
            pid: 0xF0,
            info: info
        )

        // Parse it back to verify structure
        let decoded = AX25.decodeFrame(ax25: frame)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.from?.call, "N0CALL")
        XCTAssertEqual(decoded?.from?.ssid, 1)
        XCTAssertEqual(decoded?.to?.call, "APRS")
        XCTAssertEqual(decoded?.to?.ssid, 0)
        XCTAssertEqual(decoded?.via.count, 0)
        XCTAssertEqual(decoded?.frameType, .ui)
        XCTAssertEqual(decoded?.pid, 0xF0)
        XCTAssertEqual(decoded?.info, info)
    }

    func testEncodeUIFrameWithDigipeaters() {
        let from = AX25Address(call: "N0CALL", ssid: 1)
        let to = AX25Address(call: "APRS", ssid: 0)
        let via = [
            AX25Address(call: "WIDE1", ssid: 1),
            AX25Address(call: "WIDE2", ssid: 1)
        ]
        let info = Data("Hello".utf8)

        let frame = AX25.encodeUIFrame(
            from: from,
            to: to,
            via: via,
            pid: 0xF0,
            info: info
        )

        let decoded = AX25.decodeFrame(ax25: frame)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.via.count, 2)
        XCTAssertEqual(decoded?.via[0].call, "WIDE1")
        XCTAssertEqual(decoded?.via[0].ssid, 1)
        XCTAssertEqual(decoded?.via[1].call, "WIDE2")
        XCTAssertEqual(decoded?.via[1].ssid, 1)
        XCTAssertEqual(decoded?.info, info)
    }

    func testEncodeUIFrameEmptyInfo() {
        let from = AX25Address(call: "TEST", ssid: 0)
        let to = AX25Address(call: "BEACON", ssid: 0)

        let frame = AX25.encodeUIFrame(
            from: from,
            to: to,
            via: [],
            pid: 0xF0,
            info: Data()
        )

        let decoded = AX25.decodeFrame(ax25: frame)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .ui)
        XCTAssertEqual(decoded?.info.count, 0)
    }

    func testEncodeUIFrameMaxDigipeaters() {
        // Test with 8 digipeaters (AX.25 max)
        let from = AX25Address(call: "SRC", ssid: 0)
        let to = AX25Address(call: "DST", ssid: 0)
        var via: [AX25Address] = []
        for i in 0..<8 {
            via.append(AX25Address(call: "DIGI\(i)", ssid: i % 16))
        }

        let frame = AX25.encodeUIFrame(from: from, to: to, via: via, pid: 0xF0, info: Data())
        let decoded = AX25.decodeFrame(ax25: frame)

        XCTAssertEqual(decoded?.via.count, 8)
    }

    // MARK: - Control Field Encoding (TX)

    func testEncodeControlFieldUI() {
        // UI frame control: 0x03 (bits 0-1 = 11, rest 0)
        let control = AX25.encodeControlField(frameType: .ui, pf: false)
        XCTAssertEqual(control, [0x03])
    }

    func testEncodeControlFieldUIWithPF() {
        // UI frame with P/F bit set: 0x13
        let control = AX25.encodeControlField(frameType: .ui, pf: true)
        XCTAssertEqual(control, [0x13])
    }

    func testEncodeControlFieldSABM() {
        // SABM: 0x2F (or 0x3F with P bit)
        let control = AX25.encodeControlField(frameType: .sabm, pf: true)
        XCTAssertEqual(control, [0x3F])
    }

    func testEncodeControlFieldUA() {
        // UA: 0x63 (or 0x73 with F bit)
        let control = AX25.encodeControlField(frameType: .ua, pf: true)
        XCTAssertEqual(control, [0x73])
    }

    func testEncodeControlFieldDISC() {
        // DISC: 0x43 (or 0x53 with P bit)
        let control = AX25.encodeControlField(frameType: .disc, pf: true)
        XCTAssertEqual(control, [0x53])
    }

    func testEncodeControlFieldDM() {
        // DM: 0x0F (or 0x1F with F bit)
        let control = AX25.encodeControlField(frameType: .dm, pf: true)
        XCTAssertEqual(control, [0x1F])
    }

    func testEncodeControlFieldRR() {
        // RR with N(R)=3: 0x61 (bits: 011 0 0001)
        let control = AX25.encodeControlField(frameType: .rr, nr: 3, pf: false)
        XCTAssertEqual(control, [0x61])
    }

    func testEncodeControlFieldRNR() {
        // RNR with N(R)=5, P/F set: 0xB5
        let control = AX25.encodeControlField(frameType: .rnr, nr: 5, pf: true)
        XCTAssertEqual(control, [0xB5])
    }

    func testEncodeControlFieldREJ() {
        // REJ with N(R)=2: 0x49
        let control = AX25.encodeControlField(frameType: .rej, nr: 2, pf: false)
        XCTAssertEqual(control, [0x49])
    }

    func testEncodeControlFieldIFrame() {
        // I-frame with N(S)=3, N(R)=5: control byte = (N(R) << 5) | (P << 4) | (N(S) << 1) | 0
        // In modulo-8: control = 0x06 (N(S)=3 << 1), second byte = 0xA0 (N(R)=5 << 5)
        // Actually AX.25 I-frame modulo-8: single byte = (N(R) << 5) | (P << 4) | (N(S) << 1) | 0
        let control = AX25.encodeControlField(frameType: .i, ns: 3, nr: 5, pf: false)
        // N(R)=5 << 5 = 0xA0, N(S)=3 << 1 = 0x06, combined = 0xA6
        XCTAssertEqual(control, [0xA6])
    }

    func testEncodeControlFieldIFrameWithPF() {
        // I-frame with N(S)=0, N(R)=0, P/F set
        let control = AX25.encodeControlField(frameType: .i, ns: 0, nr: 0, pf: true)
        // P/F in bit 4 = 0x10
        XCTAssertEqual(control, [0x10])
    }
}
