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
}
