//
//  KISSTransportTests.swift
//  AXTermTests
//
//  TDD tests for KISSTransport - TCP TX to Direwolf.
//

import XCTest
@testable import AXTerm

final class KISSTransportTests: XCTestCase {

    // MARK: - KISS Encoding Tests (Pure functions - no class instantiation)

    func testBuildKISSFrame() {
        // Given a raw AX.25 payload
        let ax25Payload = Data([0x01, 0x02, 0x03, 0x04])

        // When we build a KISS frame
        let kissFrame = KISS.encodeFrame(payload: ax25Payload, port: 0)

        // Then it should have correct structure: FEND + cmd + payload + FEND
        XCTAssertEqual(kissFrame.first, KISS.FEND)
        XCTAssertEqual(kissFrame.last, KISS.FEND)
        XCTAssertEqual(kissFrame[1], 0x00)  // Port 0, Data command
        // Count: FEND (1) + cmd (1) + payload (4) + FEND (1) = 7
        XCTAssertEqual(kissFrame.count, 7)
    }

    func testBuildKISSFrameWithPort() {
        // Given a raw AX.25 payload
        let ax25Payload = Data([0x01, 0x02, 0x03])

        // When we build a KISS frame for port 2
        let kissFrame = KISS.encodeFrame(payload: ax25Payload, port: 2)

        // Then command byte should have port in high nibble
        XCTAssertEqual(kissFrame[1], 0x20)  // Port 2 = 0x20
    }

    func testBuildKISSFrameWithEscaping() {
        // Given a payload containing FEND and FESC bytes
        let ax25Payload = Data([0x01, KISS.FEND, 0x02, KISS.FESC, 0x03])

        // When we build a KISS frame
        let kissFrame = KISS.encodeFrame(payload: ax25Payload, port: 0)

        // Then FEND should be escaped to FESC+TFEND and FESC to FESC+TFESC
        // Escaped payload: 0x01 (1) + FESC+TFEND (2) + 0x02 (1) + FESC+TFESC (2) + 0x03 (1) = 7 bytes
        // Total: FEND (1) + cmd (1) + escaped payload (7) + FEND (1) = 10 bytes
        XCTAssertEqual(kissFrame.count, 10)

        // Verify structure
        XCTAssertEqual(kissFrame[0], KISS.FEND)
        XCTAssertEqual(kissFrame[1], 0x00)  // cmd

        // Verify escaping is correct
        XCTAssertEqual(kissFrame[2], 0x01)
        XCTAssertEqual(kissFrame[3], KISS.FESC)
        XCTAssertEqual(kissFrame[4], KISS.TFEND)
        XCTAssertEqual(kissFrame[5], 0x02)
        XCTAssertEqual(kissFrame[6], KISS.FESC)
        XCTAssertEqual(kissFrame[7], KISS.TFESC)
        XCTAssertEqual(kissFrame[8], 0x03)
        XCTAssertEqual(kissFrame[9], KISS.FEND)
    }

    func testKISSEscapeRoundTrip() {
        // Given some bytes that need escaping
        let original = Data([0x01, KISS.FEND, 0x02, KISS.FESC, KISS.FEND, 0x03])

        // When we escape and unescape
        let escaped = KISS.escape(original)
        let unescaped = KISS.unescape(escaped)

        // Then we should get back the original
        XCTAssertEqual(unescaped, original)
    }

    // MARK: - AX.25 Frame Building Integration

    func testBuildUIFrameAndKISSEncode() {
        // Given source and destination
        let source = AX25Address(call: "N0CALL", ssid: 1)
        let dest = AX25Address(call: "TEST", ssid: 0)
        let payload = Data("Hello".utf8)

        // When we build an AX.25 UI frame
        let ax25Frame = AX25.encodeUIFrame(
            from: source,
            to: dest,
            via: [],
            pid: 0xF0,
            info: payload
        )

        // And wrap it in KISS
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        // Then the KISS frame should be valid
        XCTAssertEqual(kissFrame.first, KISS.FEND)
        XCTAssertEqual(kissFrame.last, KISS.FEND)
        XCTAssertGreaterThan(kissFrame.count, ax25Frame.count + 2)  // At least FEND + cmd + data + FEND
    }

    func testBuildIFrameAndKISSEncode() {
        // Given an I-frame with sequence numbers
        let source = AX25Address(call: "N0CALL", ssid: 1)
        let dest = AX25Address(call: "TEST", ssid: 0)
        let payload = Data("Test data".utf8)

        // When we build an I-frame
        let ax25Frame = AX25.encodeIFrame(
            from: source,
            to: dest,
            via: [],
            ns: 3,
            nr: 5,
            pf: true,
            pid: 0xF0,
            info: payload
        )

        // And wrap it in KISS
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        // Then the KISS frame should be valid
        XCTAssertEqual(kissFrame.first, KISS.FEND)
        XCTAssertEqual(kissFrame.last, KISS.FEND)
        XCTAssertGreaterThan(kissFrame.count, 20)  // Addresses + control + PID + payload + KISS framing
    }

    // MARK: - Transport State Tests (enum only, no class instantiation)

    func testTransportStateEquality() {
        // Transport states should be equatable
        XCTAssertEqual(KISSTransportState.disconnected, KISSTransportState.disconnected)
        XCTAssertEqual(KISSTransportState.connecting, KISSTransportState.connecting)
        XCTAssertEqual(KISSTransportState.connected, KISSTransportState.connected)
        XCTAssertEqual(KISSTransportState.failed, KISSTransportState.failed)
        XCTAssertNotEqual(KISSTransportState.disconnected, KISSTransportState.connected)
    }

    func testTransportStateRawValue() {
        // Transport states have string raw values
        XCTAssertEqual(KISSTransportState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(KISSTransportState.connecting.rawValue, "connecting")
        XCTAssertEqual(KISSTransportState.connected.rawValue, "connected")
        XCTAssertEqual(KISSTransportState.failed.rawValue, "failed")
    }

    // MARK: - Transport Error Tests (enum only, no class instantiation)

    func testTransportErrorDescriptions() {
        let notConnected = KISSTransportError.notConnected
        XCTAssertEqual(notConnected.errorDescription, "Transport not connected")

        let connectionFailed = KISSTransportError.connectionFailed("Connection refused")
        XCTAssertEqual(connectionFailed.errorDescription, "Connection failed: Connection refused")

        let sendFailed = KISSTransportError.sendFailed("Network unreachable")
        XCTAssertEqual(sendFailed.errorDescription, "Send failed: Network unreachable")
    }

    // MARK: - KISS Port Tests

    func testAllKISSPorts() {
        // KISS supports 16 ports (0-15)
        for port: UInt8 in 0...15 {
            let ax25Payload = Data([0x01, 0x02, 0x03])
            let kissFrame = KISS.encodeFrame(payload: ax25Payload, port: port)

            // Command byte: high nibble is port
            let commandByte = kissFrame[1]
            let extractedPort = (commandByte >> 4) & 0x0F
            XCTAssertEqual(extractedPort, port, "Port \(port) should encode correctly")
        }
    }

    // MARK: - Empty Payload Tests

    func testEmptyPayloadKISSFrame() {
        let emptyPayload = Data()
        let kissFrame = KISS.encodeFrame(payload: emptyPayload, port: 0)

        // Should still have FEND + cmd + FEND = 3 bytes
        XCTAssertEqual(kissFrame.count, 3)
        XCTAssertEqual(kissFrame[0], KISS.FEND)
        XCTAssertEqual(kissFrame[1], 0x00)
        XCTAssertEqual(kissFrame[2], KISS.FEND)
    }

    // MARK: - Large Payload Tests

    func testLargePayloadKISSFrame() {
        // Create a large payload (300 bytes, typical max AX.25 info field)
        var largePayload = Data()
        for i in 0..<300 {
            largePayload.append(UInt8(i % 256))
        }

        let kissFrame = KISS.encodeFrame(payload: largePayload, port: 0)

        // Should be at least payload size + 3 (FEND + cmd + FEND)
        XCTAssertGreaterThanOrEqual(kissFrame.count, 303)
        XCTAssertEqual(kissFrame.first, KISS.FEND)
        XCTAssertEqual(kissFrame.last, KISS.FEND)
    }
}
