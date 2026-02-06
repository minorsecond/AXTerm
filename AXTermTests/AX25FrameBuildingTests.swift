//
//  AX25FrameBuildingTests.swift
//  AXTermTests
//
//  Comprehensive tests for AX.25 frame building and encoding.
//  Ensures protocol-correct frame construction per AX.25 v2.2 spec.
//
//  Spec references:
//  - AX.25 v2.2 specification
//  - AXTERM-TRANSMISSION-SPEC.md Section 5
//

import XCTest
@testable import AXTerm

final class AX25FrameBuildingTests: XCTestCase {

    // MARK: - Address Encoding Tests

    func testAddressEncodingShiftsByOne() {
        // Each character should be shifted left by 1 bit
        let address = AX25Address(call: "N0CALL", ssid: 0)
        let encoded = address.encodeForAX25(isLast: false)

        // 'N' = 0x4E, shifted = 0x9C
        XCTAssertEqual(encoded[0], 0x9C)
        // '0' = 0x30, shifted = 0x60
        XCTAssertEqual(encoded[1], 0x60)
        // 'C' = 0x43, shifted = 0x86
        XCTAssertEqual(encoded[2], 0x86)
        // 'A' = 0x41, shifted = 0x82
        XCTAssertEqual(encoded[3], 0x82)
        // 'L' = 0x4C, shifted = 0x98
        XCTAssertEqual(encoded[4], 0x98)
        // 'L' = 0x4C, shifted = 0x98
        XCTAssertEqual(encoded[5], 0x98)
    }

    func testAddressEncodingPadsWithSpaces() {
        // Short callsign should be padded to 6 characters
        let address = AX25Address(call: "K0X", ssid: 0)
        let encoded = address.encodeForAX25(isLast: true)

        // Bytes 3, 4, 5 should be space (0x20) shifted = 0x40
        XCTAssertEqual(encoded[3], 0x40)
        XCTAssertEqual(encoded[4], 0x40)
        XCTAssertEqual(encoded[5], 0x40)
    }

    func testAddressEncodingSSIDInByte7() {
        // SSID is encoded in bits 1-4 of byte 7
        for ssid in 0...15 {
            let address = AX25Address(call: "TEST", ssid: ssid)
            let encoded = address.encodeForAX25(isLast: true)

            let ssidByte = encoded[6]
            let decodedSSID = Int((ssidByte >> 1) & 0x0F)
            XCTAssertEqual(decodedSSID, ssid, "SSID \(ssid) not encoded correctly")
        }
    }

    func testAddressEncodingExtensionBit() {
        let address = AX25Address(call: "TEST", ssid: 0)

        // Not last: bit 0 should be 0
        let notLast = address.encodeForAX25(isLast: false)
        XCTAssertEqual(notLast[6] & 0x01, 0x00, "Extension bit should be 0 for non-last")

        // Last: bit 0 should be 1
        let isLast = address.encodeForAX25(isLast: true)
        XCTAssertEqual(isLast[6] & 0x01, 0x01, "Extension bit should be 1 for last")
    }

    func testAddressEncodingReservedBits() {
        // Bits 5-6 of SSID byte should be set (0b01100000)
        let address = AX25Address(call: "TEST", ssid: 0)
        let encoded = address.encodeForAX25(isLast: false)

        let reservedBits = (encoded[6] >> 5) & 0x03
        XCTAssertEqual(reservedBits, 0x03, "Reserved bits 5-6 should be set")
    }

    func testAddressEncodingUppercases() {
        // Lowercase callsigns should be uppercased
        let address = AX25Address(call: "n0call", ssid: 0)
        XCTAssertEqual(address.call, "N0CALL")
    }

    func testAddressEncodingTrimsWhitespace() {
        let address = AX25Address(call: "  N0CALL  ", ssid: 0)
        XCTAssertEqual(address.call, "N0CALL")
    }

    func testAddressEncodingClampsSSID() {
        // SSID > 15 should be clamped
        let highSSID = AX25Address(call: "TEST", ssid: 20)
        XCTAssertEqual(highSSID.ssid, 15)

        // SSID < 0 should be clamped to 0
        let negativeSSID = AX25Address(call: "TEST", ssid: -5)
        XCTAssertEqual(negativeSSID.ssid, 0)
    }

    // MARK: - Frame Structure Tests

    func testUIFrameStructure() {
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "N0CALL", ssid: 0),
            to: AX25Address(call: "CQ", ssid: 0),
            via: DigiPath(),
            pid: 0xF0,
            payload: Data("Test".utf8)
        )

        let encoded = frame.encodeAX25()

        // Minimum size: dest(7) + src(7) + control(1) + pid(1) + info(4) = 20
        XCTAssertGreaterThanOrEqual(encoded.count, 20)

        // Verify can be decoded
        let decoded = AX25.decodeFrame(ax25: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .ui)
        XCTAssertEqual(decoded?.from?.call, "N0CALL")
        XCTAssertEqual(decoded?.to?.call, "CQ")
    }

    func testUIFrameWithDigipeaters() {
        let path = DigiPath.from(["WIDE1-1", "WIDE2-1"])
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "N0CALL", ssid: 0),
            to: AX25Address(call: "APRS", ssid: 0),
            via: path,
            pid: 0xF0,
            payload: Data("Test".utf8)
        )

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.via.count, 2)
        XCTAssertEqual(decoded?.via[0].call, "WIDE1")
        XCTAssertEqual(decoded?.via[0].ssid, 1)
        XCTAssertEqual(decoded?.via[1].call, "WIDE2")
        XCTAssertEqual(decoded?.via[1].ssid, 1)
    }

    func testUIFrameWithMaxDigipeaters() {
        // AX.25 allows up to 8 digipeaters
        var digis: [String] = []
        for i in 0..<8 {
            digis.append("DIGI\(i)-\(i % 16)")
        }
        let path = DigiPath.from(digis)

        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "SRC", ssid: 0),
            to: AX25Address(call: "DST", ssid: 0),
            via: path,
            pid: 0xF0,
            payload: Data()
        )

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.via.count, 8)
    }

    func testUIFrameExtensionBitOnlyOnLast() {
        let path = DigiPath.from(["WIDE1-1", "WIDE2-1"])
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "SRC", ssid: 0),
            to: AX25Address(call: "DST", ssid: 0),
            via: path,
            pid: 0xF0,
            payload: Data()
        )

        let encoded = frame.encodeAX25()

        // Check extension bits:
        // Dest (bytes 0-6): bit 0 of byte 6 should be 0
        XCTAssertEqual(encoded[6] & 0x01, 0x00, "Destination should not be last")
        // Source (bytes 7-13): bit 0 of byte 13 should be 0
        XCTAssertEqual(encoded[13] & 0x01, 0x00, "Source should not be last (digis follow)")
        // WIDE1-1 (bytes 14-20): bit 0 of byte 20 should be 0
        XCTAssertEqual(encoded[20] & 0x01, 0x00, "First digi should not be last")
        // WIDE2-1 (bytes 21-27): bit 0 of byte 27 should be 1
        XCTAssertEqual(encoded[27] & 0x01, 0x01, "Last digi should have extension bit set")
    }

    // MARK: - Control Frame Tests

    func testSABMFrameBuilding() {
        let frame = AX25FrameBuilder.buildSABM(
            from: AX25Address(call: "N0CALL", ssid: 0),
            to: AX25Address(call: "K0ABC", ssid: 0),
            via: DigiPath(),
            pf: true
        )

        XCTAssertEqual(frame.frameType, "u")
        XCTAssertEqual(frame.controlByte, 0x3F)  // SABM with P bit

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .u)
    }

    func testSABMEFrameBuilding() {
        let frame = AX25FrameBuilder.buildSABM(
            from: AX25Address(call: "N0CALL", ssid: 0),
            to: AX25Address(call: "K0ABC", ssid: 0),
            via: DigiPath(),
            extended: true,
            pf: true
        )

        XCTAssertEqual(frame.frameType, "u")
        XCTAssertEqual(frame.controlByte, 0x7F)  // SABME with P bit
    }

    func testUAFrameBuilding() {
        let frame = AX25FrameBuilder.buildUA(
            from: AX25Address(call: "K0ABC", ssid: 0),
            to: AX25Address(call: "N0CALL", ssid: 0),
            via: DigiPath(),
            pf: true
        )

        XCTAssertEqual(frame.frameType, "u")
        XCTAssertEqual(frame.controlByte, 0x73)  // UA with F bit
    }

    func testDMFrameBuilding() {
        let frame = AX25FrameBuilder.buildDM(
            from: AX25Address(call: "K0ABC", ssid: 0),
            to: AX25Address(call: "N0CALL", ssid: 0),
            via: DigiPath(),
            pf: true
        )

        XCTAssertEqual(frame.frameType, "u")
        XCTAssertEqual(frame.controlByte, 0x1F)  // DM with F bit
    }

    func testDISCFrameBuilding() {
        let frame = AX25FrameBuilder.buildDISC(
            from: AX25Address(call: "N0CALL", ssid: 0),
            to: AX25Address(call: "K0ABC", ssid: 0),
            via: DigiPath(),
            pf: true
        )

        XCTAssertEqual(frame.frameType, "u")
        XCTAssertEqual(frame.controlByte, 0x53)  // DISC with P bit
    }

    // MARK: - S-Frame Tests

    func testRRFrameBuilding() {
        for nr in 0..<8 {
            let frame = AX25FrameBuilder.buildRR(
                from: AX25Address(call: "N0CALL", ssid: 0),
                to: AX25Address(call: "K0ABC", ssid: 0),
                via: DigiPath(),
                nr: nr,
                pf: false
            )

            XCTAssertEqual(frame.frameType, "s")
            // RR control: NNN_P_0001 where NNN = N(R)
            let expectedControl = UInt8((nr << 5) | 0x01)
            XCTAssertEqual(frame.controlByte, expectedControl, "RR with nr=\(nr) should be \(String(format: "0x%02X", expectedControl))")
        }
    }

    func testRRFrameWithPF() {
        let frame = AX25FrameBuilder.buildRR(
            from: AX25Address(call: "N0CALL", ssid: 0),
            to: AX25Address(call: "K0ABC", ssid: 0),
            via: DigiPath(),
            nr: 3,
            pf: true
        )

        // RR with nr=3, P=1: 011_1_0001 = 0x71
        XCTAssertEqual(frame.controlByte, 0x71)
    }

    func testRNRFrameBuilding() {
        let frame = AX25FrameBuilder.buildRNR(
            from: AX25Address(call: "N0CALL", ssid: 0),
            to: AX25Address(call: "K0ABC", ssid: 0),
            via: DigiPath(),
            nr: 5,
            pf: false
        )

        // RNR control: NNN_P_0101 where NNN = N(R)
        // nr=5: 101_0_0101 = 0xA5
        XCTAssertEqual(frame.controlByte, 0xA5)
    }

    func testREJFrameBuilding() {
        let frame = AX25FrameBuilder.buildREJ(
            from: AX25Address(call: "N0CALL", ssid: 0),
            to: AX25Address(call: "K0ABC", ssid: 0),
            via: DigiPath(),
            nr: 2,
            pf: true
        )

        // REJ control: NNN_P_1001 where NNN = N(R)
        // nr=2, P=1: 010_1_1001 = 0x59
        XCTAssertEqual(frame.controlByte, 0x59)
    }

    // MARK: - I-Frame Tests

    func testIFrameBuilding() {
        let payload = Data("Hello, World!".utf8)
        let frame = AX25FrameBuilder.buildIFrame(
            from: AX25Address(call: "N0CALL", ssid: 0),
            to: AX25Address(call: "K0ABC", ssid: 0),
            via: DigiPath(),
            ns: 3,
            nr: 5,
            pid: 0xF0,
            payload: payload,
            pf: false
        )

        XCTAssertEqual(frame.frameType, "i")
        // I-frame control: NNN_P_SSS_0 where NNN = N(R), SSS = N(S)
        // nr=5, ns=3, P=0: 101_0_011_0 = 0xA6
        XCTAssertEqual(frame.controlByte, 0xA6)
        XCTAssertEqual(frame.ns, 3)
        XCTAssertEqual(frame.nr, 5)

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .i)
        XCTAssertEqual(decoded?.info, payload)
    }

    func testIFrameSequenceNumberWrap() {
        // Test all combinations of ns and nr (0-7)
        for ns in 0..<8 {
            for nr in 0..<8 {
                let frame = AX25FrameBuilder.buildIFrame(
                    from: AX25Address(call: "SRC", ssid: 0),
                    to: AX25Address(call: "DST", ssid: 0),
                    via: DigiPath(),
                    ns: ns,
                    nr: nr,
                    pid: 0xF0,
                    payload: Data([0x42]),
                    pf: false
                )

                XCTAssertEqual(frame.ns, ns)
                XCTAssertEqual(frame.nr, nr)
            }
        }
    }

    // MARK: - PID Tests

    func testPIDValuesInUIFrame() {
        let pidValues: [UInt8] = [0x01, 0x06, 0x07, 0x08, 0xC3, 0xC4, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xF0]

        for pid in pidValues {
            let frame = AX25FrameBuilder.buildUI(
                from: AX25Address(call: "SRC", ssid: 0),
                to: AX25Address(call: "DST", ssid: 0),
                via: DigiPath(),
                pid: pid,
                payload: Data([0x42])
            )

            let encoded = frame.encodeAX25()
            let decoded = AX25.decodeFrame(ax25: encoded)

            XCTAssertEqual(decoded?.pid, pid, "PID 0x\(String(format: "%02X", pid)) not preserved")
        }
    }

    // MARK: - Empty Payload Tests

    func testUIFrameEmptyPayload() {
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "SRC", ssid: 0),
            to: AX25Address(call: "DST", ssid: 0),
            via: DigiPath(),
            pid: 0xF0,
            payload: Data()
        )

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .ui)
        XCTAssertEqual(decoded?.info.count, 0)
    }

    func testSFrameHasNoPayload() {
        let frame = AX25FrameBuilder.buildRR(
            from: AX25Address(call: "SRC", ssid: 0),
            to: AX25Address(call: "DST", ssid: 0),
            via: DigiPath(),
            nr: 0,
            pf: false
        )

        let encoded = frame.encodeAX25()

        // S-frames should only have address + control, no PID or info
        // Address = 14 bytes (dst + src), control = 1 byte
        XCTAssertEqual(encoded.count, 15)
    }

    // MARK: - Large Payload Tests

    func testUIFrameMaxPayload() {
        // Test with typical max payload (256 bytes)
        let largePayload = Data(repeating: 0x42, count: 256)
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "SRC", ssid: 0),
            to: AX25Address(call: "DST", ssid: 0),
            via: DigiPath(),
            pid: 0xF0,
            payload: largePayload
        )

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, largePayload)
    }

    // MARK: - Round-Trip Tests

    func testUIFrameRoundTrip() {
        let fromAddr = AX25Address(call: "N0CALL", ssid: 7)
        let toAddr = AX25Address(call: "K0ABC", ssid: 15)
        let path = DigiPath.from(["WIDE1-1"])
        let payload = Data("The quick brown fox jumps over the lazy dog".utf8)

        let frame = AX25FrameBuilder.buildUI(
            from: fromAddr,
            to: toAddr,
            via: path,
            pid: 0xF0,
            payload: payload
        )

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.from?.call, fromAddr.call)
        XCTAssertEqual(decoded?.from?.ssid, fromAddr.ssid)
        XCTAssertEqual(decoded?.to?.call, toAddr.call)
        XCTAssertEqual(decoded?.to?.ssid, toAddr.ssid)
        XCTAssertEqual(decoded?.via.count, 1)
        XCTAssertEqual(decoded?.via[0].call, "WIDE1")
        XCTAssertEqual(decoded?.via[0].ssid, 1)
        XCTAssertEqual(decoded?.info, payload)
        XCTAssertEqual(decoded?.pid, 0xF0)
    }

    func testAllSSIDsRoundTrip() {
        for srcSSID in 0...15 {
            for dstSSID in 0...15 {
                let fromAddr = AX25Address(call: "SRC", ssid: srcSSID)
                let toAddr = AX25Address(call: "DST", ssid: dstSSID)

                let frame = AX25FrameBuilder.buildUI(
                    from: fromAddr,
                    to: toAddr,
                    via: DigiPath(),
                    pid: 0xF0,
                    payload: Data([0x42])
                )

                let encoded = frame.encodeAX25()
                let decoded = AX25.decodeFrame(ax25: encoded)

                XCTAssertNotNil(decoded)
                XCTAssertEqual(decoded?.from?.ssid, srcSSID, "Source SSID \(srcSSID) not preserved")
                XCTAssertEqual(decoded?.to?.ssid, dstSSID, "Dest SSID \(dstSSID) not preserved")
            }
        }
    }
}
