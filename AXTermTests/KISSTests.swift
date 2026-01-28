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
        XCTAssertEqual(frames[0], Data([0x01, 0x02, 0x03]))
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
        XCTAssertEqual(frames2[0], Data([0x01, 0x02, 0x03, 0x04]))
    }

    func testKISSStreamParserMultipleFramesInOneChunk() {
        var parser = KISSFrameParser()

        // Two complete frames in one chunk
        let chunk = Data([0xC0, 0x00, 0x01, 0x02, 0xC0, 0xC0, 0x00, 0x03, 0x04, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], Data([0x01, 0x02]))
        XCTAssertEqual(frames[1], Data([0x03, 0x04]))
    }

    func testKISSStreamParserWithEscapedContent() {
        var parser = KISSFrameParser()

        // Frame with escaped FEND inside: FEND + cmd + FESC TFEND + FEND
        let chunk = Data([0xC0, 0x00, 0xDB, 0xDC, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([0xC0])) // Unescaped FEND
    }

    func testKISSStreamParserIgnoresNonPort0() {
        var parser = KISSFrameParser()

        // Frame on port 1 (command byte 0x10)
        let chunk = Data([0xC0, 0x10, 0x01, 0x02, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 0, "Should ignore non-port-0 frames")
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
        XCTAssertEqual(frames[0], Data([0x03, 0x04]))
    }

    func testKISSStreamParserEmptyFrame() {
        var parser = KISSFrameParser()

        // Empty frame (just command byte)
        let chunk = Data([0xC0, 0x00, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 0, "Empty payload should be ignored")
    }
}
