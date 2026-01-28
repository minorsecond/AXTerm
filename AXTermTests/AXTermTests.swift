//
//  AXTermTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest
@testable import AXTerm

final class AXTermTests: XCTestCase {

    // MARK: - AX25Address Tests

    func testAX25AddressDisplay() {
        let addrWithSSID = AX25Address(call: "N0CALL", ssid: 1)
        XCTAssertEqual(addrWithSSID.display, "N0CALL-1")

        let addrNoSSID = AX25Address(call: "N0CALL", ssid: 0)
        XCTAssertEqual(addrNoSSID.display, "N0CALL")
    }

    func testAX25AddressNormalization() {
        let addr = AX25Address(call: "  n0call  ", ssid: 1)
        XCTAssertEqual(addr.call, "N0CALL")
    }

    func testAX25AddressSSIDClamping() {
        let addrHighSSID = AX25Address(call: "TEST", ssid: 20)
        XCTAssertEqual(addrHighSSID.ssid, 15) // Clamped to max

        let addrNegSSID = AX25Address(call: "TEST", ssid: -5)
        XCTAssertEqual(addrNegSSID.ssid, 0) // Clamped to min
    }

    // MARK: - Packet Tests

    func testPacketDisplayHelpers() {
        let packet = Packet(
            from: AX25Address(call: "N0CALL", ssid: 1),
            to: AX25Address(call: "APRS"),
            via: [AX25Address(call: "WIDE1", ssid: 1, repeated: true)],
            frameType: .ui,
            info: "Test".data(using: .ascii)!
        )

        XCTAssertEqual(packet.fromDisplay, "N0CALL-1")
        XCTAssertEqual(packet.toDisplay, "APRS")
        XCTAssertTrue(packet.viaDisplay.contains("WIDE1-1*"))
        XCTAssertEqual(packet.typeDisplay, "UI")
    }

    func testPacketInfoPreview() {
        let longInfo = String(repeating: "A", count: 100)
        let packet = Packet(info: longInfo.data(using: .ascii)!)

        XCTAssertTrue(packet.infoPreview.count <= Packet.infoPreviewLimit)
        XCTAssertTrue(packet.infoPreview.hasSuffix("..."))
    }

    func testPacketWithNilAddresses() {
        let packet = Packet()

        XCTAssertEqual(packet.fromDisplay, "?")
        XCTAssertEqual(packet.toDisplay, "?")
        XCTAssertEqual(packet.viaDisplay, "")
    }

    // MARK: - FrameType Tests

    func testFrameTypeDisplayName() {
        XCTAssertEqual(FrameType.ui.displayName, "UI")
        XCTAssertEqual(FrameType.i.displayName, "I")
        XCTAssertEqual(FrameType.s.displayName, "S")
        XCTAssertEqual(FrameType.u.displayName, "U")
        XCTAssertEqual(FrameType.unknown.displayName, "?")
    }

    func testFrameTypeIconMapping() {
        XCTAssertEqual(FrameType.ui.icon, "📡")
        XCTAssertEqual(FrameType.i.icon, "💬")
        XCTAssertEqual(FrameType.s.icon, "🔁")
        XCTAssertEqual(FrameType.u.icon, "⚙️")
        XCTAssertEqual(FrameType.unknown.icon, "❓")
    }

    // MARK: - ConsoleLine Tests

    func testConsoleLineFormatting() {
        let line = ConsoleLine.packet(from: "N0CALL", to: "APRS", text: "Test message")

        XCTAssertEqual(line.kind, .packet)
        XCTAssertEqual(line.from, "N0CALL")
        XCTAssertEqual(line.to, "APRS")
        XCTAssertEqual(line.text, "Test message")
    }

    func testConsoleLineSystem() {
        let line = ConsoleLine.system("Connected")

        XCTAssertEqual(line.kind, .system)
        XCTAssertNil(line.from)
        XCTAssertNil(line.to)
    }

    func testConsoleLineError() {
        let line = ConsoleLine.error("Connection failed")

        XCTAssertEqual(line.kind, .error)
        XCTAssertEqual(line.text, "Connection failed")
    }

    // MARK: - RawChunk Tests

    func testRawChunkHex() {
        let chunk = RawChunk(data: Data([0xC0, 0x00, 0x01, 0x02]))

        XCTAssertEqual(chunk.hex, "C0 00 01 02")
    }
}
