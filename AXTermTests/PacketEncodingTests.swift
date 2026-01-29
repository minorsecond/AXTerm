//
//  PacketEncodingTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import XCTest
@testable import AXTerm

final class PacketEncodingTests: XCTestCase {
    func testViaPathRoundTripWithRepeatMarker() {
        let path = [
            AX25Address(call: "DRLNOD"),
            AX25Address(call: "WIDE1", ssid: 1, repeated: true)
        ]
        let encoded = PacketEncoding.encodeViaPath(path)
        XCTAssertEqual(encoded, "DRLNOD,WIDE1-1*")

        let decoded = PacketEncoding.decodeViaPath(encoded)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].display, "DRLNOD")
        XCTAssertEqual(decoded[1].display, "WIDE1-1")
        XCTAssertTrue(decoded[1].repeated)
    }

    func testInfoASCIIRenderingIsDeterministic() {
        let data = Data([0x41, 0x00, 0x7F, 0x42])
        XCTAssertEqual(PacketEncoding.asciiString(data), "A··B")
    }

    func testHexEncodingDeterministic() {
        let data = Data([0x01, 0xAB, 0x00, 0xFF])
        XCTAssertEqual(PacketEncoding.encodeHex(data), "01AB00FF")
    }

    func testHexDisplayStringDeterministic() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(PacketEncoding.hexString(data, bytesPerLine: 2), "01 02\n03 04")
    }

    func testSSIDParsingNormalizesCalls() {
        let parsed = PacketEncoding.parseCallsign("KB5YZB-7")
        XCTAssertEqual(parsed.call, "KB5YZB")
        XCTAssertEqual(parsed.ssid, 7)

        let noSSID = PacketEncoding.parseCallsign("ID")
        XCTAssertEqual(noSSID.call, "ID")
        XCTAssertEqual(noSSID.ssid, 0)

        let clamped = PacketEncoding.parseCallsign("CALL-15")
        XCTAssertEqual(clamped.call, "CALL")
        XCTAssertEqual(clamped.ssid, 15)
    }
}
