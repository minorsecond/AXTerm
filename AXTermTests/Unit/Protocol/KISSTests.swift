//
//  KISSTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest
@testable import AXTerm

final class KISSTests: XCTestCase {

    // MARK: - KISS Unescape Tests

    func testUnescapeTFEND() {
        // FESC TFEND -> FEND
        let escaped = Data([0xDB, 0xDC])
        let unescaped = KISS.unescape(escaped)
        XCTAssertEqual(unescaped, Data([0xC0]))
    }

    func testUnescapeTFESC() {
        // FESC TFESC -> FESC
        let escaped = Data([0xDB, 0xDD])
        let unescaped = KISS.unescape(escaped)
        XCTAssertEqual(unescaped, Data([0xDB]))
    }

    func testUnescapeMixed() {
        // Test mixed content with escapes
        let escaped = Data([0x01, 0x02, 0xDB, 0xDC, 0x03, 0xDB, 0xDD, 0x04])
        let unescaped = KISS.unescape(escaped)
        XCTAssertEqual(unescaped, Data([0x01, 0x02, 0xC0, 0x03, 0xDB, 0x04]))
    }

    func testUnescapeNoEscapes() {
        // No escapes, should pass through unchanged
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let unescaped = KISS.unescape(data)
        XCTAssertEqual(unescaped, data)
    }

    func testUnescapeTrailingFESC() {
        // FESC at end without follow-up byte
        let escaped = Data([0x01, 0xDB])
        let unescaped = KISS.unescape(escaped)
        XCTAssertEqual(unescaped, Data([0x01, 0xDB]))
    }

    // MARK: - KISS Frame Parser Tests

    func testKISSStreamParserSingleFrame() {
        var parser = KISSFrameParser()

        // Complete frame: FEND + cmd + data + FEND
        let chunk = Data([0xC0, 0x00, 0x01, 0x02, 0x03, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.count, 1)
        if case .ax25(let data) = frames[0] {
            XCTAssertEqual(data, Data([0x01, 0x02, 0x03]))
        } else {
            XCTFail("Expected .ax25 frame")
        }
    }

    func testKISSStreamParserSplitsFramesAcrossChunks() {
        var parser = KISSFrameParser()

        // First chunk: start of frame
        let chunk1 = Data([0xC0, 0x00, 0x01, 0x02])
        let frames1 = parser.feed(chunk1)
        XCTAssertEqual(frames1.count, 0, "Should not have complete frame yet")

        // Second chunk: end of frame
        let chunk2 = Data([0x03, 0x04, 0xC0])
        let frames2 = parser.feed(chunk2)
        XCTAssertEqual(frames2.count, 1)
        XCTAssertEqual(frames2.count, 1)
        if case .ax25(let data) = frames2[0] {
            XCTAssertEqual(data, Data([0x01, 0x02, 0x03, 0x04]))
        } else {
            XCTFail("Expected .ax25 frame")
        }
    }

    func testKISSStreamParserMultipleFramesInOneChunk() {
        var parser = KISSFrameParser()

        // Two complete frames in one chunk
        let chunk = Data([0xC0, 0x00, 0x01, 0x02, 0xC0, 0xC0, 0x00, 0x03, 0x04, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.count, 2)
        
        if case .ax25(let data1) = frames[0] {
            XCTAssertEqual(data1, Data([0x01, 0x02]))
        } else {
            XCTFail("Frame 0: Expected .ax25 frame")
        }
        
        if case .ax25(let data2) = frames[1] {
            XCTAssertEqual(data2, Data([0x03, 0x04]))
        } else {
            XCTFail("Frame 1: Expected .ax25 frame")
        }
    }

    func testKISSStreamParserWithEscapedContent() {
        var parser = KISSFrameParser()

        // Frame with escaped FEND inside: FEND + cmd + FESC TFEND + FEND
        let chunk = Data([0xC0, 0x00, 0xDB, 0xDC, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.count, 1)
        if case .ax25(let data) = frames[0] {
            XCTAssertEqual(data, Data([0xC0])) // Unescaped FEND
        } else {
             XCTFail("Expected .ax25 frame")
        }
    }

    func testKISSStreamParserAcceptsNonPort0DataFrames() {
        var parser = KISSFrameParser()

        // Frame on port 1 (command byte 0x10) — data frames on any port should be accepted
        let chunk = Data([0xC0, 0x10, 0x01, 0x02, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 1, "Should accept data frames on any KISS port")
        if case .ax25(let data) = frames[0] {
            XCTAssertEqual(data, Data([0x01, 0x02]))
        } else {
            XCTFail("Expected .ax25 frame")
        }
    }

    func testKISSStreamParserReset() {
        var parser = KISSFrameParser()

        // Start a frame
        _ = parser.feed(Data([0xC0, 0x00, 0x01, 0x02]))

        // Reset
        parser.reset()

        // New frame should work independently
        let frames = parser.feed(Data([0xC0, 0x00, 0x03, 0x04, 0xC0]))
        XCTAssertEqual(frames.count, 1)
        
        if case .ax25(let data) = frames[0] {
            XCTAssertEqual(data, Data([0x03, 0x04]))
        } else {
             XCTFail("Expected .ax25 frame")
        }
    }

    func testKISSStreamParserEmptyFrame() {
        var parser = KISSFrameParser()

        // Empty frame (just command byte)
        let chunk = Data([0xC0, 0x00, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 0, "Empty payload should be ignored")
    }

    // MARK: - KISS Escape Tests (TX)

    func testEscapeFEND() {
        // FEND -> FESC TFEND
        let data = Data([0xC0])
        let escaped = KISS.escape(data)
        XCTAssertEqual(escaped, Data([0xDB, 0xDC]))
    }

    func testEscapeFESC() {
        // FESC -> FESC TFESC
        let data = Data([0xDB])
        let escaped = KISS.escape(data)
        XCTAssertEqual(escaped, Data([0xDB, 0xDD]))
    }

    func testEscapeMixed() {
        // Test mixed content with bytes that need escaping
        let data = Data([0x01, 0x02, 0xC0, 0x03, 0xDB, 0x04])
        let escaped = KISS.escape(data)
        XCTAssertEqual(escaped, Data([0x01, 0x02, 0xDB, 0xDC, 0x03, 0xDB, 0xDD, 0x04]))
    }

    func testEscapeNoEscapesNeeded() {
        // No escapes needed, should pass through unchanged
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let escaped = KISS.escape(data)
        XCTAssertEqual(escaped, data)
    }

    func testEscapeEmpty() {
        let data = Data()
        let escaped = KISS.escape(data)
        XCTAssertEqual(escaped, Data())
    }

    func testEscapeUnescapeRoundTrip() {
        // Round-trip: escape then unescape should return original
        let original = Data([0x01, 0xC0, 0x02, 0xDB, 0x03, 0xC0, 0xDB])
        let escaped = KISS.escape(original)
        let unescaped = KISS.unescape(escaped)
        XCTAssertEqual(unescaped, original)
    }

    func testEscapeUnescapeRoundTripAllBytes() {
        // Test all possible byte values round-trip correctly
        var original = Data()
        for byte in UInt8.min...UInt8.max {
            original.append(byte)
        }
        let escaped = KISS.escape(original)
        let unescaped = KISS.unescape(escaped)
        XCTAssertEqual(unescaped, original)
    }

    // MARK: - KISS Frame Encoding Tests (TX)

    func testEncodeFrameBasic() {
        // Build a complete KISS frame from AX.25 payload
        let ax25Payload = Data([0x01, 0x02, 0x03, 0x04])
        let kissFrame = KISS.encodeFrame(payload: ax25Payload, port: 0)

        // Expected: FEND + command(0x00) + payload + FEND
        XCTAssertEqual(kissFrame, Data([0xC0, 0x00, 0x01, 0x02, 0x03, 0x04, 0xC0]))
    }

    func testEncodeFrameWithEscaping() {
        // Payload contains FEND - should be escaped
        let ax25Payload = Data([0x01, 0xC0, 0x02])
        let kissFrame = KISS.encodeFrame(payload: ax25Payload, port: 0)

        // Expected: FEND + cmd + 0x01 + FESC+TFEND + 0x02 + FEND
        XCTAssertEqual(kissFrame, Data([0xC0, 0x00, 0x01, 0xDB, 0xDC, 0x02, 0xC0]))
    }

    func testEncodeFramePort1() {
        // Test non-zero port encoding
        let ax25Payload = Data([0x01, 0x02])
        let kissFrame = KISS.encodeFrame(payload: ax25Payload, port: 1)

        // Command byte for port 1: 0x10
        XCTAssertEqual(kissFrame, Data([0xC0, 0x10, 0x01, 0x02, 0xC0]))
    }

    func testEncodeDecodeRoundTrip() {
        // Encode a frame, then parse it back
        let originalPayload = Data([0x01, 0xC0, 0xDB, 0x02, 0x03])
        let kissFrame = KISS.encodeFrame(payload: originalPayload, port: 0)

        var parser = KISSFrameParser()
        let frames = parser.feed(kissFrame)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.count, 1)
        if case .ax25(let data) = frames[0] {
            XCTAssertEqual(data, originalPayload)
        } else {
             XCTFail("Expected .ax25 frame")
        }
    }
}
