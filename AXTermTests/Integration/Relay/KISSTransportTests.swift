//
//  KISSTransportTests.swift
//  AXTermTests
//
//  TDD tests for KISSTransport - TCP TX to Direwolf.
//

import XCTest
@testable import AXTerm

final class KISSTransportTests: XCTestCase {

    // MARK: - KISS Encoding Tests

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
        // Given data with special bytes
        let original = Data([KISS.FEND, 0x00, KISS.FESC, 0xFF, KISS.FEND])

        // When we escape and unescape
        let escaped = KISS.escape(original)
        let unescaped = KISS.unescape(escaped)

        // Then we should get the original back
        XCTAssertEqual(unescaped, original)
    }

    func testEmptyPayloadKISSFrame() {
        // Given an empty payload
        let ax25Payload = Data()

        // When we build a KISS frame
        let kissFrame = KISS.encodeFrame(payload: ax25Payload, port: 0)

        // Then it should have just framing: FEND + cmd + FEND
        XCTAssertEqual(kissFrame.count, 3)
        XCTAssertEqual(kissFrame[0], KISS.FEND)
        XCTAssertEqual(kissFrame[1], 0x00)
        XCTAssertEqual(kissFrame[2], KISS.FEND)
    }

    func testLargePayloadKISSFrame() {
        // Given a larger payload
        let ax25Payload = Data(repeating: 0x55, count: 256)

        // When we build a KISS frame
        let kissFrame = KISS.encodeFrame(payload: ax25Payload, port: 0)

        // Then it should have correct size (no escaping needed for 0x55)
        XCTAssertEqual(kissFrame.count, 259)  // FEND + cmd + 256 + FEND
    }

    func testAllKISSPorts() {
        // Test all 16 KISS ports
        for port: UInt8 in 0..<16 {
            let payload = Data([0x01])
            let frame = KISS.encodeFrame(payload: payload, port: port)

            // Command byte should be port << 4 | 0
            XCTAssertEqual(frame[1], port << 4)
        }
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
        XCTAssertGreaterThan(kissFrame.count, ax25Frame.count + 2)
    }

    func testBuildIFrameAndKISSEncode() {
        // Given source and destination for I-frame
        let source = AX25Address(call: "N0CALL", ssid: 0)
        let dest = AX25Address(call: "REMOTE", ssid: 1)
        let info = Data("Data payload".utf8)

        // When we build an AX.25 I-frame
        let ax25Frame = AX25.encodeIFrame(
            from: source,
            to: dest,
            via: [],
            ns: 3,
            nr: 5,
            pf: true,
            pid: 0xF0,
            info: info
        )

        // And wrap it in KISS
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        // Then the KISS frame should be valid
        XCTAssertEqual(kissFrame.first, KISS.FEND)
        XCTAssertEqual(kissFrame.last, KISS.FEND)
    }

    // MARK: - Transport Types Tests

    func testTransportStateEquality() {
        // Verify state equality works
        XCTAssertEqual(KISSTransportState.disconnected, KISSTransportState.disconnected)
        XCTAssertEqual(KISSTransportState.connected, KISSTransportState.connected)
        XCTAssertNotEqual(KISSTransportState.disconnected, KISSTransportState.connected)
    }

    func testTransportStateRawValue() {
        // Verify state raw values
        XCTAssertEqual(KISSTransportState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(KISSTransportState.connecting.rawValue, "connecting")
        XCTAssertEqual(KISSTransportState.connected.rawValue, "connected")
        XCTAssertEqual(KISSTransportState.failed.rawValue, "failed")
    }

    func testTransportErrorDescriptions() {
        // Verify error descriptions
        let notConnected = KISSTransportError.notConnected
        XCTAssertEqual(notConnected.errorDescription, "Transport not connected")

        let connFailed = KISSTransportError.connectionFailed("timeout")
        XCTAssertEqual(connFailed.errorDescription, "Connection failed: timeout")

        let sendFailed = KISSTransportError.sendFailed("buffer full")
        XCTAssertEqual(sendFailed.errorDescription, "Send failed: buffer full")
    }

    func testPendingFrameCreation() {
        // Given frame parameters
        let frameId = UUID()
        let ax25Data = Data([0x01, 0x02, 0x03])

        // When we create a pending frame
        let pending = PendingFrame(id: frameId, ax25Frame: ax25Data, port: 0)

        // Then it should have KISS-encoded data
        XCTAssertEqual(pending.id, frameId)
        XCTAssertEqual(pending.kissData.first, KISS.FEND)
        XCTAssertEqual(pending.kissData.last, KISS.FEND)
        XCTAssertNotNil(pending.queuedAt)
    }
}
