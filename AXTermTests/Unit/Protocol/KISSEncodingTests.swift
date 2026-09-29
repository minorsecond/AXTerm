//
//  KISSEncodingTests.swift
//  AXTermTests
//
//  Comprehensive tests for KISS frame encoding and decoding.
//  Ensures correct FEND/FESC escaping per KISS protocol spec.
//
//  Spec reference: KISS protocol specification, AXTERM-TRANSMISSION-SPEC.md Section 3
//

import XCTest
@testable import AXTerm

final class KISSEncodingTests: XCTestCase {

    // MARK: - KISS Constants

    func testKISSConstants() {
        XCTAssertEqual(KISS.FEND, 0xC0)
        XCTAssertEqual(KISS.FESC, 0xDB)
        XCTAssertEqual(KISS.TFEND, 0xDC)
        XCTAssertEqual(KISS.TFESC, 0xDD)
        XCTAssertEqual(KISS.CMD_DATA, 0x00)
    }

    // MARK: - Escape Tests

    func testEscapeFEND() {
        // FEND (0xC0) should become FESC TFEND (0xDB 0xDC)
        let input = Data([0xC0])
        let escaped = KISS.escape(input)

        XCTAssertEqual(escaped, Data([0xDB, 0xDC]))
    }

    func testEscapeFESC() {
        // FESC (0xDB) should become FESC TFESC (0xDB 0xDD)
        let input = Data([0xDB])
        let escaped = KISS.escape(input)

        XCTAssertEqual(escaped, Data([0xDB, 0xDD]))
    }

    func testEscapeNoSpecialBytes() {
        // Bytes that don't need escaping should pass through
        let input = Data([0x00, 0x01, 0x42, 0xFF, 0xFE])
        let escaped = KISS.escape(input)

        XCTAssertEqual(escaped, input)
    }

    func testEscapeMixedContent() {
        // Mix of special and normal bytes
        let input = Data([0x01, 0xC0, 0x02, 0xDB, 0x03])
        let escaped = KISS.escape(input)

        let expected = Data([0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03])
        XCTAssertEqual(escaped, expected)
    }

    func testEscapeConsecutiveSpecialBytes() {
        // Multiple consecutive special bytes
        let input = Data([0xC0, 0xC0, 0xDB, 0xDB, 0xC0])
        let escaped = KISS.escape(input)

        let expected = Data([0xDB, 0xDC, 0xDB, 0xDC, 0xDB, 0xDD, 0xDB, 0xDD, 0xDB, 0xDC])
        XCTAssertEqual(escaped, expected)
    }

    func testEscapeEmpty() {
        let input = Data()
        let escaped = KISS.escape(input)

        XCTAssertEqual(escaped, Data())
    }

    func testEscapeAllFENDs() {
        let input = Data(repeating: 0xC0, count: 10)
        let escaped = KISS.escape(input)

        // Each FEND becomes 2 bytes
        XCTAssertEqual(escaped.count, 20)
        for i in stride(from: 0, to: 20, by: 2) {
            XCTAssertEqual(escaped[i], 0xDB)
            XCTAssertEqual(escaped[i + 1], 0xDC)
        }
    }

    func testEscapeAllFESCs() {
        let input = Data(repeating: 0xDB, count: 10)
        let escaped = KISS.escape(input)

        // Each FEND becomes 2 bytes
        XCTAssertEqual(escaped.count, 20)
        for i in stride(from: 0, to: 20, by: 2) {
            XCTAssertEqual(escaped[i], 0xDB)
            XCTAssertEqual(escaped[i + 1], 0xDD)
        }
    }

    // MARK: - Unescape Tests

    func testUnescapeFEND() {
        // FESC TFEND (0xDB 0xDC) should become FEND (0xC0)
        let escaped = Data([0xDB, 0xDC])
        let unescaped = KISS.unescape(escaped)

        XCTAssertEqual(unescaped, Data([0xC0]))
    }

    func testUnescapeFESC() {
        // FESC TFESC (0xDB 0xDD) should become FESC (0xDB)
        let escaped = Data([0xDB, 0xDD])
        let unescaped = KISS.unescape(escaped)

        XCTAssertEqual(unescaped, Data([0xDB]))
    }

    func testUnescapeNoEscapeSequences() {
        let input = Data([0x00, 0x01, 0x42, 0xFF, 0xFE])
        let unescaped = KISS.unescape(input)

        XCTAssertEqual(unescaped, input)
    }

    func testUnescapeMixedContent() {
        let escaped = Data([0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03])
        let unescaped = KISS.unescape(escaped)

        let expected = Data([0x01, 0xC0, 0x02, 0xDB, 0x03])
        XCTAssertEqual(unescaped, expected)
    }

    func testUnescapeTrailingFESC() {
        // FESC at end with no following byte - should handle gracefully
        let escaped = Data([0x01, 0x02, 0xDB])
        let unescaped = KISS.unescape(escaped)

        // Implementation-dependent: either drop FESC or include it
        XCTAssertNotNil(unescaped)
    }

    func testUnescapeInvalidSequence() {
        // FESC followed by invalid byte (not TFEND or TFESC)
        let escaped = Data([0xDB, 0x42])
        let unescaped = KISS.unescape(escaped)

        // Should handle gracefully without crash
        XCTAssertNotNil(unescaped)
    }

    // MARK: - Round-Trip Tests

    func testEscapeUnescapeRoundTrip() {
        let testCases: [Data] = [
            Data(),
            Data([0x00]),
            Data([0xC0]),
            Data([0xDB]),
            Data([0xC0, 0xDB]),
            Data([0x01, 0xC0, 0x02, 0xDB, 0x03]),
            Data(repeating: 0xC0, count: 100),
            Data(repeating: 0xDB, count: 100),
            Data((0...255).map { UInt8($0) }),
        ]

        for original in testCases {
            let escaped = KISS.escape(original)
            let unescaped = KISS.unescape(escaped)
            XCTAssertEqual(unescaped, original, "Round-trip failed for \(original.count) bytes")
        }
    }

    func testRandomDataRoundTrip() {
        for _ in 0..<100 {
            let length = Int.random(in: 0...500)
            let original = Data((0..<length).map { _ in UInt8.random(in: 0...255) })

            let escaped = KISS.escape(original)
            let unescaped = KISS.unescape(escaped)

            XCTAssertEqual(unescaped, original)
        }
    }

    // MARK: - Frame Encoding Tests

    func testEncodeFrameBasic() {
        let payload = Data([0x01, 0x02, 0x03])
        let frame = KISS.encodeFrame(payload: payload, port: 0)

        // Frame structure: FEND + command + escaped_payload + FEND
        XCTAssertEqual(frame.first, 0xC0)  // Start FEND
        XCTAssertEqual(frame.last, 0xC0)   // End FEND
        XCTAssertEqual(frame[1], 0x00)     // Command byte (port 0, data frame)
    }

    func testEncodeFrameWithPort() {
        let payload = Data([0x42])

        for port: UInt8 in 0..<16 {
            let frame = KISS.encodeFrame(payload: payload, port: port)
            let commandByte = frame[1]
            let decodedPort = (commandByte >> 4) & 0x0F

            XCTAssertEqual(decodedPort, port, "Port \(port) not encoded correctly")
        }
    }

    func testEncodeFrameEscapesPayload() {
        // Payload with bytes that need escaping
        let payload = Data([0xC0, 0xDB])
        let frame = KISS.encodeFrame(payload: payload, port: 0)

        // FEND + cmd + FESC + TFEND + FESC + TFESC + FEND = 7 bytes
        XCTAssertEqual(frame.count, 7)
        XCTAssertEqual(frame, Data([0xC0, 0x00, 0xDB, 0xDC, 0xDB, 0xDD, 0xC0]))
    }

    func testEncodeFrameEmpty() {
        let payload = Data()
        let frame = KISS.encodeFrame(payload: payload, port: 0)

        // FEND + cmd + FEND = 3 bytes
        XCTAssertEqual(frame.count, 3)
        XCTAssertEqual(frame, Data([0xC0, 0x00, 0xC0]))
    }

    // MARK: - Frame Parser Tests

    func testParserBasicFrame() {
        var parser = KISSFrameParser()

        let payload = Data([0x01, 0x02, 0x03])
        let kissFrame = KISS.encodeFrame(payload: payload, port: 0)
        let frames = parser.feed(kissFrame)

        XCTAssertEqual(frames.count, 1)
        if case .ax25(let d) = frames[0] { XCTAssertEqual(d, payload) } else { XCTFail() }
    }

    func testParserMultipleFrames() {
        var parser = KISSFrameParser()

        let payload1 = Data([0x01])
        let payload2 = Data([0x02])
        let payload3 = Data([0x03])

        var data = KISS.encodeFrame(payload: payload1, port: 0)
        data.append(KISS.encodeFrame(payload: payload2, port: 0))
        data.append(KISS.encodeFrame(payload: payload3, port: 0))

        let frames = parser.feed(data)

        XCTAssertEqual(frames.count, 3)
        if case .ax25(let d0) = frames[0] { XCTAssertEqual(d0, payload1) } else { XCTFail() }
        if case .ax25(let d1) = frames[1] { XCTAssertEqual(d1, payload2) } else { XCTFail() }
        if case .ax25(let d2) = frames[2] { XCTAssertEqual(d2, payload3) } else { XCTFail() }
    }

    func testParserFragmentedInput() {
        var parser = KISSFrameParser()

        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let kissFrame = KISS.encodeFrame(payload: payload, port: 0)

        // Feed one byte at a time
        var allFrames: [KISSFrameOutput] = []
        for byte in kissFrame {
            let frames = parser.feed(Data([byte]))
            allFrames.append(contentsOf: frames)
        }

        XCTAssertEqual(allFrames.count, 1)
        if case .ax25(let d) = allFrames[0] { XCTAssertEqual(d, payload) } else { XCTFail() }
    }

    func testParserMultipleFENDs() {
        var parser = KISSFrameParser()

        // Multiple FENDs between frames (common in noisy links)
        var data = Data([0xC0, 0xC0, 0xC0])  // Leading FENDs
        data.append(Data([0x00, 0x42]))      // Command + payload
        data.append(Data([0xC0, 0xC0, 0xC0]))  // Trailing FENDs

        let frames = parser.feed(data)

        XCTAssertEqual(frames.count, 1)
        if case .ax25(let d) = frames[0] { XCTAssertEqual(d, Data([0x42])) } else { XCTFail() }
    }

    func testParserStripsCommandByte() {
        var parser = KISSFrameParser()

        let frame = Data([0xC0, 0x00, 0x41, 0x42, 0x43, 0xC0])
        let frames = parser.feed(frame)

        XCTAssertEqual(frames.count, 1)
        // Command byte (0x00) should be stripped
        if case .ax25(let d) = frames[0] { XCTAssertEqual(d, Data([0x41, 0x42, 0x43])) } else { XCTFail() }
    }

    func testParserHandlesEscaping() {
        var parser = KISSFrameParser()

        // Frame with escaped FEND and FESC in payload
        let original = Data([0xC0, 0xDB, 0x42])
        let kissFrame = KISS.encodeFrame(payload: original, port: 0)
        let frames = parser.feed(kissFrame)

        XCTAssertEqual(frames.count, 1)
        if case .ax25(let d) = frames[0] { XCTAssertEqual(d, original) } else { XCTFail() }
    }

    func testParserEmptyFrame() {
        var parser = KISSFrameParser()

        // Just command byte, no payload
        let frame = Data([0xC0, 0x00, 0xC0])
        let frames = parser.feed(frame)

        // Empty payload should be ignored
        XCTAssertEqual(frames.count, 0)
    }

    func testParserResetsOnFEND() {
        var parser = KISSFrameParser()

        // Partial frame followed by new frame
        var data = Data([0xC0, 0x00, 0x01, 0x02])  // Incomplete frame
        data.append(Data([0xC0, 0x00, 0x42, 0xC0]))  // Complete frame

        let frames = parser.feed(data)

        // Should get the complete frame, partial is discarded on new FEND
        XCTAssertGreaterThanOrEqual(frames.count, 1)
    }

    // MARK: - Integration with AX.25

    func testKISSWithAX25Frame() {
        // Build a complete AX.25 frame
        let from = AX25Address(call: "N0CALL", ssid: 0)
        let to = AX25Address(call: "CQ", ssid: 0)
        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: Data("Test".utf8))

        // Wrap in KISS
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        // Parse KISS
        var parser = KISSFrameParser()
        let frames = parser.feed(kissFrame)

        XCTAssertEqual(frames.count, 1)

        // Decode AX.25
        var frameData: Data?
        if case .ax25(let d) = frames[0] { frameData = d } else { XCTFail(); return }
        let decoded = AX25.decodeFrame(ax25: frameData!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.from?.call, "N0CALL")
        XCTAssertEqual(decoded?.to?.call, "CQ")
    }

    func testKISSWithAX25FrameContainingFENDs() {
        // AX.25 frame where the info field contains FEND bytes
        let from = AX25Address(call: "SRC", ssid: 0)
        let to = AX25Address(call: "DST", ssid: 0)
        let infoWithFEND = Data([0x41, 0xC0, 0x42, 0xC0, 0x43])  // Contains 0xC0
        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: infoWithFEND)

        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        var parser = KISSFrameParser()
        let frames = parser.feed(kissFrame)

        XCTAssertEqual(frames.count, 1)

        var frameData: Data?
        if case .ax25(let d) = frames[0] { frameData = d } else { XCTFail(); return }
        let decoded = AX25.decodeFrame(ax25: frameData!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, infoWithFEND)
    }

    // MARK: - Edge Cases

    func testVeryLongFrame() {
        let largePayload = Data(repeating: 0x42, count: 1000)
        let kissFrame = KISS.encodeFrame(payload: largePayload, port: 0)

        var parser = KISSFrameParser()
        let frames = parser.feed(kissFrame)

        XCTAssertEqual(frames.count, 1)
        if case .ax25(let d) = frames[0] { XCTAssertEqual(d, largePayload) } else { XCTFail() }
    }

    func testFrameAllSpecialBytes() {
        // Worst case: every byte needs escaping
        var payload = Data()
        for _ in 0..<100 {
            payload.append(0xC0)
            payload.append(0xDB)
        }

        let kissFrame = KISS.encodeFrame(payload: payload, port: 0)

        var parser = KISSFrameParser()
        let frames = parser.feed(kissFrame)

        XCTAssertEqual(frames.count, 1)
        if case .ax25(let d) = frames[0] { XCTAssertEqual(d, payload) } else { XCTFail() }
    }

    func testParserMemoryReset() {
        var parser = KISSFrameParser()

        // Send many frames to ensure no memory leaks or accumulation issues
        for _ in 0..<1000 {
            let payload = Data([UInt8.random(in: 0...255)])
            let kissFrame = KISS.encodeFrame(payload: payload, port: 0)
            let frames = parser.feed(kissFrame)
            XCTAssertEqual(frames.count, 1)
        }
    }
}
