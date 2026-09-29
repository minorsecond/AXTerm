//
//  LinkDebugLogTests.swift
//  AXTermTests
//
//  Unit tests for LinkDebugLog ring buffers, stats, and clearing.
//

import XCTest
@testable import AXTerm

@MainActor
final class LinkDebugLogTests: XCTestCase {

    var log: LinkDebugLog!

    override func setUp() {
        super.setUp()
        log = LinkDebugLog.shared
        log.clear()
    }

    override func tearDown() {
        log.clear()
        log = nil
        super.tearDown()
    }

    // MARK: - Stats Accumulation

    func testRxBytesAccumulate() {
        log.recordRxBytes(100)
        log.recordRxBytes(100)
        log.recordRxBytes(100)
        XCTAssertEqual(log.totalBytesIn, 300)
    }

    func testTxBytesAccumulate() {
        log.recordTxBytes(50)
        log.recordTxBytes(75)
        XCTAssertEqual(log.totalBytesOut, 125)
    }

    // MARK: - Frame Type Counting

    func testFrameTypeCounting() {
        log.recordFrame(makeFrame(type: "AX25"))
        log.recordFrame(makeFrame(type: "AX25"))
        log.recordFrame(makeFrame(type: "Telemetry"))
        log.recordFrame(makeFrame(type: "Unknown(0xFF)"))

        XCTAssertEqual(log.ax25FrameCount, 2)
        XCTAssertEqual(log.telemetryFrameCount, 1)
        XCTAssertEqual(log.unknownFrameCount, 1)
    }

    // MARK: - Ring Buffer Capping

    func testFrameRingBufferCapping() {
        for i in 0..<600 {
            log.recordFrame(makeFrame(type: "AX25", byteCount: i))
        }

        XCTAssertEqual(log.frames.count, LinkDebugLog.maxFrames)
        // Oldest entries should be evicted — first remaining should have byteCount 100
        XCTAssertEqual(log.frames.first?.byteCount, 100)
        XCTAssertEqual(log.frames.last?.byteCount, 599)
    }

    func testStateTimelineCapping() {
        for i in 0..<150 {
            log.recordStateChange(from: "state\(i)", to: "state\(i+1)", endpoint: "test")
        }

        XCTAssertEqual(log.stateTimeline.count, LinkDebugLog.maxStateEntries)
    }

    func testParseErrorCapping() {
        for i in 0..<150 {
            log.recordParseError(message: "Error \(i)")
        }

        XCTAssertEqual(log.parseErrors.count, LinkDebugLog.maxErrorEntries)
        XCTAssertEqual(log.parseErrorCount, 150) // Count keeps incrementing
    }

    // MARK: - Clear

    func testClearResetsEverything() {
        log.recordRxBytes(500)
        log.recordTxBytes(300)
        log.recordFrame(makeFrame(type: "AX25"))
        log.recordFrame(makeFrame(type: "Telemetry"))
        log.recordFrame(makeFrame(type: "SomeUnknown"))
        log.recordStateChange(from: "disconnected", to: "connected", endpoint: "test")
        log.recordParseError(message: "Bad frame", rawBytes: Data([0xFF]))
        log.recordKISSInit(label: "Duplex = 1", rawBytes: Data([0xC0, 0x05, 0x01, 0xC0]))

        log.clear()

        XCTAssertEqual(log.totalBytesIn, 0)
        XCTAssertEqual(log.totalBytesOut, 0)
        XCTAssertEqual(log.ax25FrameCount, 0)
        XCTAssertEqual(log.telemetryFrameCount, 0)
        XCTAssertEqual(log.unknownFrameCount, 0)
        XCTAssertEqual(log.parseErrorCount, 0)
        XCTAssertTrue(log.frames.isEmpty)
        XCTAssertTrue(log.configEntries.isEmpty)
        XCTAssertTrue(log.stateTimeline.isEmpty)
        XCTAssertTrue(log.parseErrors.isEmpty)
    }

    // MARK: - State History Ordering

    func testStateHistoryIsChronological() {
        log.recordStateChange(from: "disconnected", to: "connecting", endpoint: "test")
        log.recordStateChange(from: "connecting", to: "connected", endpoint: "test")
        log.recordStateChange(from: "connected", to: "disconnected", endpoint: "test")

        XCTAssertEqual(log.stateTimeline.count, 3)
        XCTAssertEqual(log.stateTimeline[0].toState, "connecting")
        XCTAssertEqual(log.stateTimeline[1].toState, "connected")
        XCTAssertEqual(log.stateTimeline[2].toState, "disconnected")

        // Timestamps should be non-decreasing
        for i in 1..<log.stateTimeline.count {
            XCTAssertGreaterThanOrEqual(
                log.stateTimeline[i].timestamp,
                log.stateTimeline[i-1].timestamp)
        }
    }

    // MARK: - Config Recording

    func testKISSInitRecording() {
        let rawBytes = Data([0xC0, 0x05, 0x01, 0xC0])
        log.recordKISSInit(label: "Duplex = 1 (Full)", rawBytes: rawBytes)

        XCTAssertEqual(log.configEntries.count, 1)
        XCTAssertEqual(log.configEntries[0].label, "Duplex = 1 (Full)")
        XCTAssertEqual(log.configEntries[0].rawBytes, rawBytes)
    }

    // MARK: - Parse Error with Raw Bytes

    func testParseErrorRecordsRawBytes() {
        let raw = Data([0xC0, 0x00, 0xFF, 0xC0])
        log.recordParseError(message: "Bad frame", rawBytes: raw)

        XCTAssertEqual(log.parseErrors.count, 1)
        XCTAssertEqual(log.parseErrors[0].message, "Bad frame")
        XCTAssertEqual(log.parseErrors[0].rawBytes, raw)
    }

    // MARK: - Helpers

    private func makeFrame(type: String, byteCount: Int = 10) -> LinkDebugFrameEntry {
        LinkDebugFrameEntry(
            timestamp: Date(),
            direction: .rx,
            rawBytes: Data(repeating: 0xAA, count: byteCount),
            frameType: type,
            byteCount: byteCount
        )
    }
}
