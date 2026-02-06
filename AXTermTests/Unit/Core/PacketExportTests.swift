//
//  PacketExportTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import XCTest
@testable import AXTerm

final class PacketExportTests: XCTestCase {
    func testJSONIncludesExpectedKeys() throws {
        let packet = Packet(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 0),
            from: AX25Address(call: "N0CALL"),
            to: AX25Address(call: "APRS"),
            via: [AX25Address(call: "WIDE1", ssid: 1)],
            frameType: .ui,
            pid: 0xF0,
            info: "CQ".data(using: .ascii) ?? Data(),
            rawAx25: Data([0x01, 0x02])
        )

        let export = PacketExport(packet: packet)
        let data = try export.jsonData()
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try XCTUnwrap(jsonObject as? [String: Any])

        XCTAssertNotNil(dict["frameType"])
        XCTAssertNotNil(dict["from"])
        XCTAssertNotNil(dict["to"])
        XCTAssertNotNil(dict["via"])
        XCTAssertNotNil(dict["pid"])
        XCTAssertNotNil(dict["timestamp"])
        XCTAssertNotNil(dict["infoASCII"])
        XCTAssertNotNil(dict["infoHex"])
        XCTAssertNotNil(dict["rawAx25Hex"])
        XCTAssertNotNil(dict["id"])
    }

    func testWriteJSONWritesFile() throws {
        let packet = Packet(from: AX25Address(call: "N0CALL"))
        let export = PacketExport(packet: packet)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")

        try export.writeJSON(to: tempURL)

        let data = try Data(contentsOf: tempURL)
        XCTAssertFalse(data.isEmpty)
    }
}
