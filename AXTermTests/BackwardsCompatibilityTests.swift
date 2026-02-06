//
//  BackwardsCompatibilityTests.swift
//  AXTermTests
//
//  Tests for backwards compatibility between AXDP extensions and standard AX.25 payloads.
//  Ensures the system correctly handles both AXDP-encoded and standard AX.25 payloads.
//
//  Architecture note: AXTerm communicates with Direwolf (TNC) via KISS protocol.
//  Direwolf handles the actual AX.25/FX.25 encoding for RF transmission.
//  AXTerm only needs to correctly frame KISS data and handle AX.25 address/control fields.
//
//  Critical invariants:
//  1. Standard AX.25 frames MUST be decoded correctly even without AXDP
//  2. AXDP payloads MUST be distinguishable from standard payloads via magic header
//  3. Non-AXDP payloads MUST NOT cause crashes or errors
//  4. The system MUST gracefully handle mixed traffic (APRS, AXDP, plain text, etc.)
//

import XCTest
@testable import AXTerm

final class BackwardsCompatibilityTests: XCTestCase {

    // MARK: - Standard AX.25 Frame Handling

    /// Verifies that standard AX.25 UI frames with plain text are decoded correctly
    func testStandardAX25UIFrameWithPlainText() {
        // Build a standard AX.25 UI frame with plain ASCII payload (no AXDP)
        let from = AX25Address(call: "N0CALL", ssid: 1)
        let to = AX25Address(call: "CQ", ssid: 0)
        let plainText = Data("Hello, this is a test message!".utf8)

        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: plainText)
        let decoded = AX25.decodeFrame(ax25: frame)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.from?.call, "N0CALL")
        XCTAssertEqual(decoded?.to?.call, "CQ")
        XCTAssertEqual(decoded?.frameType, .ui)
        XCTAssertEqual(decoded?.info, plainText)

        // Verify it's NOT detected as AXDP
        XCTAssertFalse(AXDP.hasMagic(plainText), "Plain text should not have AXDP magic")
    }

    /// Verifies that APRS position reports are handled correctly
    func testStandardAX25APRSPositionReport() {
        // Typical APRS position report format
        let aprsPayload = Data("!4903.50N/07201.75W-PHG2360/Test".utf8)

        let from = AX25Address(call: "N0CALL", ssid: 9)
        let to = AX25Address(call: "APRS", ssid: 0)
        let via = [AX25Address(call: "WIDE1", ssid: 1)]

        let frame = AX25.encodeUIFrame(from: from, to: to, via: via, pid: 0xF0, info: aprsPayload)
        let decoded = AX25.decodeFrame(ax25: frame)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.from?.call, "N0CALL")
        XCTAssertEqual(decoded?.from?.ssid, 9)
        XCTAssertEqual(decoded?.to?.call, "APRS")
        XCTAssertEqual(decoded?.via.count, 1)
        XCTAssertEqual(decoded?.via.first?.call, "WIDE1")
        XCTAssertEqual(decoded?.info, aprsPayload)

        // Verify it's NOT detected as AXDP
        XCTAssertFalse(AXDP.hasMagic(aprsPayload), "APRS payload should not have AXDP magic")
    }

    /// Verifies that APRS messages are handled correctly
    func testStandardAX25APRSMessage() {
        // APRS message format: :DESTCALL :message{msgno}
        let aprsMessage = Data(":N0CALL-5 :Test message{001".utf8)

        let from = AX25Address(call: "K0ABC", ssid: 0)
        let to = AX25Address(call: "APRS", ssid: 0)

        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: aprsMessage)
        let decoded = AX25.decodeFrame(ax25: frame)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, aprsMessage)
        XCTAssertFalse(AXDP.hasMagic(aprsMessage))
    }

    // MARK: - AXDP Detection

    /// Verifies AXDP magic header detection works correctly
    func testAXDPMagicDetection() {
        // AXDP payload should be detected
        let axdpMsg = AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("Test".utf8))
        let axdpPayload = axdpMsg.encode()
        XCTAssertTrue(AXDP.hasMagic(axdpPayload), "AXDP encoded message should have magic")

        // Plain text should NOT be detected as AXDP
        let plainText = Data("Hello World".utf8)
        XCTAssertFalse(AXDP.hasMagic(plainText))

        // Data starting with "AXT" but not "AXT1" should NOT be detected
        let almostMagic = Data("AXT2test".utf8)
        XCTAssertFalse(AXDP.hasMagic(almostMagic))

        // Empty data should NOT be detected
        XCTAssertFalse(AXDP.hasMagic(Data()))

        // Short data should NOT be detected
        XCTAssertFalse(AXDP.hasMagic(Data("AXT".utf8)))
    }

    /// Verifies that AXDP payloads inside AX.25 frames are correctly identified
    func testAXDPPayloadInAX25Frame() {
        let axdpMsg = AXDP.Message(type: .chat, sessionId: 123, messageId: 456, payload: Data("Hello AXDP!".utf8))
        let axdpPayload = axdpMsg.encode()

        let from = AX25Address(call: "K0EPI", ssid: 0)
        let to = AX25Address(call: "N0CALL", ssid: 5)

        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: axdpPayload)
        let decoded = AX25.decodeFrame(ax25: frame)

        XCTAssertNotNil(decoded)
        XCTAssertTrue(AXDP.hasMagic(decoded!.info), "Decoded frame info should have AXDP magic")

        // Should be decodable as AXDP
        let decodedAXDP = AXDP.Message.decode(from: decoded!.info)
        XCTAssertNotNil(decodedAXDP)
        XCTAssertEqual(decodedAXDP?.type, .chat)
        XCTAssertEqual(decodedAXDP?.sessionId, 123)
    }

    // MARK: - Mixed Traffic Handling

    /// Simulates receiving a mix of AXDP and standard AX.25 frames
    func testMixedTrafficHandling() {
        // Simulate a sequence of frames: APRS, AXDP, plain text, AXDP
        let frames: [(String, Data, Bool)] = [
            ("APRS", Data("!4903.50N/07201.75W-".utf8), false),
            ("AXDP Chat", AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("Hi".utf8)).encode(), true),
            ("Plain Text", Data("CQ CQ CQ de N0CALL".utf8), false),
            ("AXDP Ping", AXDP.Message(type: .ping, sessionId: 2, messageId: 1).encode(), true),
        ]

        for (name, payload, shouldBeAXDP) in frames {
            let hasAXDP = AXDP.hasMagic(payload)
            XCTAssertEqual(hasAXDP, shouldBeAXDP, "\(name) AXDP detection mismatch")

            if hasAXDP {
                let decoded = AXDP.Message.decode(from: payload)
                XCTAssertNotNil(decoded, "\(name) should decode as AXDP")
            }
        }
    }

    // MARK: - Non-AXDP Binary Payloads

    /// Verifies that binary payloads that happen to start with similar bytes don't crash
    func testBinaryPayloadNotMisidentifiedAsAXDP() {
        // Binary data that starts with 'A', 'X', 'T' but not exactly "AXT1"
        let binaryPayloads: [Data] = [
            Data([0x41, 0x58, 0x54, 0x00]),  // "AXT" + null
            Data([0x41, 0x58, 0x54, 0x32]),  // "AXT2"
            Data([0x41, 0x58, 0x00, 0x31]),  // "AX" + null + "1"
            Data([0x00, 0x41, 0x58, 0x54, 0x31]),  // null + "AXT1"
        ]

        for payload in binaryPayloads {
            XCTAssertFalse(AXDP.hasMagic(payload), "Binary payload should not be detected as AXDP: \(payload.hexString)")

            // Attempting to decode should return nil, not crash
            let decoded = AXDP.Message.decode(from: payload)
            XCTAssertNil(decoded, "Binary payload should not decode as AXDP")
        }
    }

    /// Verifies that random binary data doesn't cause issues
    func testRandomBinaryPayload() {
        // Generate pseudo-random data
        var randomData = Data(count: 256)
        for i in 0..<256 {
            randomData[i] = UInt8(i ^ 0xAA)
        }

        XCTAssertFalse(AXDP.hasMagic(randomData))

        // Attempting to decode should return nil
        let decoded = AXDP.Message.decode(from: randomData)
        XCTAssertNil(decoded)
    }

    // MARK: - NET/ROM Compatibility

    /// Verifies that NET/ROM frames are not misidentified as AXDP
    func testNetRomFrameNotMisidentifiedAsAXDP() {
        // NET/ROM routing broadcast (PID 0xCF)
        let netromPayload = Data([
            0xFF,  // Signature
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,  // Callsign
            0x41, 0x58, 0x54, 0x45, 0x52, 0x4D,  // "AXTERM" (coincidentally contains AXT)
        ])

        XCTAssertFalse(AXDP.hasMagic(netromPayload), "NET/ROM payload should not be AXDP")
    }

    // MARK: - Payload Type Detection

    /// Verifies that standard text payloads are correctly identified as non-AXDP
    func testStandardPayloadDetection() {
        let standardPayloads: [Data] = [
            Data("Connected mode test".utf8),
            Data("CQ CQ CQ de N0CALL".utf8),
            Data(">Status message".utf8),
            Data([0x01, 0x02, 0x03, 0x04]),  // Binary data
        ]

        for payload in standardPayloads {
            XCTAssertFalse(AXDP.hasMagic(payload), "Standard payload should not have AXDP magic")
            // Attempting to decode as AXDP should return nil
            XCTAssertNil(AXDP.Message.decode(from: payload))
        }
    }

    /// Verifies that AXDP payloads are correctly identified
    func testAXDPPayloadDetection() {
        let axdpPayloads: [AXDP.Message] = [
            AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("Test".utf8)),
            AXDP.Message(type: .fileChunk, sessionId: 100, messageId: 5, chunkIndex: 0, totalChunks: 10, payload: Data(repeating: 0x42, count: 64)),
            AXDP.Message(type: .ping, sessionId: 2, messageId: 1),
            AXDP.Message(type: .ack, sessionId: 3, messageId: 10),
        ]

        for msg in axdpPayloads {
            let encoded = msg.encode()
            XCTAssertTrue(AXDP.hasMagic(encoded), "AXDP message should have magic header")

            // Should decode back correctly
            let decoded = AXDP.Message.decode(from: encoded)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.type, msg.type)
        }
    }

    // MARK: - KISS Framing Compatibility

    /// Verifies KISS framing works with standard AX.25 frames
    func testKISSFramingWithStandardAX25() {
        let payload = Data("Standard AX.25 test".utf8)
        let from = AX25Address(call: "N0CALL", ssid: 0)
        let to = AX25Address(call: "CQ", ssid: 0)

        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: payload)
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        // Verify KISS frame structure
        XCTAssertEqual(kissFrame.first, KISS.FEND, "Should start with FEND")
        XCTAssertEqual(kissFrame.last, KISS.FEND, "Should end with FEND")

        // Parse KISS frame
        var parser = KISSFrameParser()
        let parsed = parser.feed(kissFrame)

        XCTAssertEqual(parsed.count, 1, "Should produce one AX.25 frame")
        XCTAssertEqual(parsed.first, ax25Frame)
    }

    /// Verifies KISS framing works with AXDP-encoded AX.25 frames
    func testKISSFramingWithAXDP() {
        let axdpMsg = AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("AXDP test".utf8))
        let axdpPayload = axdpMsg.encode()

        let from = AX25Address(call: "K0EPI", ssid: 0)
        let to = AX25Address(call: "N0CALL", ssid: 0)

        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: axdpPayload)
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        var parser = KISSFrameParser()
        let parsed = parser.feed(kissFrame)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first, ax25Frame)

        // Verify the payload inside is still valid AXDP
        let decodedAX25 = AX25.decodeFrame(ax25: parsed.first!)
        XCTAssertNotNil(decodedAX25)
        XCTAssertTrue(AXDP.hasMagic(decodedAX25!.info))
    }

    // MARK: - Edge Cases

    /// Verifies empty payloads are handled correctly
    func testEmptyPayload() {
        let from = AX25Address(call: "N0CALL", ssid: 0)
        let to = AX25Address(call: "BEACON", ssid: 0)

        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: Data())
        let decoded = AX25.decodeFrame(ax25: frame)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info.count, 0)
        XCTAssertFalse(AXDP.hasMagic(Data()))
    }

    /// Verifies very long payloads work (up to AX.25 max)
    func testMaxLengthPayload() {
        // AX.25 max info field is typically 256 bytes, but can be configured higher
        let maxPayload = Data(repeating: 0x41, count: 256)

        let from = AX25Address(call: "N0CALL", ssid: 0)
        let to = AX25Address(call: "TEST", ssid: 0)

        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: maxPayload)
        let decoded = AX25.decodeFrame(ax25: frame)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info.count, 256)
    }

    /// Verifies payloads that exactly match "AXT1" length are handled
    func testPayloadExactlyFourBytes() {
        // Test with exactly 4 bytes that are NOT "AXT1"
        let payload = Data("TEST".utf8)
        XCTAssertEqual(payload.count, 4)
        XCTAssertFalse(AXDP.hasMagic(payload))

        // Test with exactly "AXT1" (magic only, no TLVs)
        let magicOnly = Data("AXT1".utf8)
        XCTAssertTrue(AXDP.hasMagic(magicOnly))

        // But it shouldn't decode to a valid message (no TLVs)
        let decoded = AXDP.Message.decode(from: magicOnly)
        XCTAssertNil(decoded, "Magic only without TLVs should not decode")
    }
}

// MARK: - Helper Extensions

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
