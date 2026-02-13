//
//  KISSLinkTests.swift
//  AXTermTests
//
//  Tests for KISS framing robustness and KISSLink loopback.
//

import XCTest
@testable import AXTerm

final class KISSLinkTests: XCTestCase {

    // MARK: - KISS Deframing Edge Cases

    func testFrameSplitAcrossThreeChunks() {
        var parser = KISSFrameParser()

        // Frame: FEND 0x00 0xAA 0xBB 0xCC 0xDD FEND
        // Split into three chunks
        let frames1 = parser.feed(Data([0xC0, 0x00]))
        XCTAssertEqual(frames1.count, 0)

        let frames2 = parser.feed(Data([0xAA, 0xBB]))
        XCTAssertEqual(frames2.count, 0)

        let frames3 = parser.feed(Data([0xCC, 0xDD, 0xC0]))
        XCTAssertEqual(frames3.count, 1)
        XCTAssertEqual(frames3[0], Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    func testFENDSplitFromFrameBody() {
        var parser = KISSFrameParser()

        // Opening FEND in one chunk, rest in next
        let frames1 = parser.feed(Data([0xC0]))
        XCTAssertEqual(frames1.count, 0)

        let frames2 = parser.feed(Data([0x00, 0x01, 0x02, 0xC0]))
        XCTAssertEqual(frames2.count, 1)
        XCTAssertEqual(frames2[0], Data([0x01, 0x02]))
    }

    func testMultipleFramesBackToBack() {
        var parser = KISSFrameParser()

        // Three frames with no gaps (shared FEND between frames)
        let data = Data([
            0xC0, 0x00, 0x11, 0xC0,
            0xC0, 0x00, 0x22, 0xC0,
            0xC0, 0x00, 0x33, 0xC0
        ])
        let frames = parser.feed(data)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0], Data([0x11]))
        XCTAssertEqual(frames[1], Data([0x22]))
        XCTAssertEqual(frames[2], Data([0x33]))
    }

    func testNoiseBeforeFirstFEND() {
        var parser = KISSFrameParser()

        // Random garbage before the first FEND should be discarded
        let data = Data([0xFF, 0xFE, 0x42, 0xC0, 0x00, 0x01, 0x02, 0xC0])
        let frames = parser.feed(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([0x01, 0x02]))
    }

    func testNoiseBetweenFrames() {
        var parser = KISSFrameParser()

        // Frame 1, then noise (no FEND start), then Frame 2
        let chunk1 = Data([0xC0, 0x00, 0xAA, 0xC0])
        let frames1 = parser.feed(chunk1)
        XCTAssertEqual(frames1.count, 1)

        // After a FEND closes a frame, parser is in "inFrame" state waiting for next,
        // so these bytes get buffered as if they're frame data until next FEND
        let noise = Data([0xFF, 0xFE])
        let frames2 = parser.feed(noise)
        XCTAssertEqual(frames2.count, 0)

        // Next valid frame start: FEND terminates the noise "frame" (which is invalid
        // because cmd byte 0xFF, port != 0, so processKISSFrame returns nil)
        let chunk3 = Data([0xC0, 0x00, 0xBB, 0xC0])
        let frames3 = parser.feed(chunk3)
        XCTAssertEqual(frames3.count, 1)
        XCTAssertEqual(frames3[0], Data([0xBB]))
    }

    func testEscapedFENDInsideFrame() {
        var parser = KISSFrameParser()

        // Payload contains byte 0xC0 (FEND) — must be escaped as FESC TFEND
        let data = Data([0xC0, 0x00, 0x01, 0xDB, 0xDC, 0x02, 0xC0])
        let frames = parser.feed(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([0x01, 0xC0, 0x02]))
    }

    func testEscapedFESCInsideFrame() {
        var parser = KISSFrameParser()

        // Payload contains byte 0xDB (FESC) — must be escaped as FESC TFESC
        let data = Data([0xC0, 0x00, 0x01, 0xDB, 0xDD, 0x02, 0xC0])
        let frames = parser.feed(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([0x01, 0xDB, 0x02]))
    }

    func testDoubleEscapeSequence() {
        var parser = KISSFrameParser()

        // Two consecutive escaped bytes
        let data = Data([0xC0, 0x00, 0xDB, 0xDC, 0xDB, 0xDD, 0xC0])
        let frames = parser.feed(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([0xC0, 0xDB]))
    }

    func testEscapeSplitAcrossChunks() {
        var parser = KISSFrameParser()

        // FESC at end of one chunk, TFEND at start of next
        let frames1 = parser.feed(Data([0xC0, 0x00, 0x01, 0xDB]))
        XCTAssertEqual(frames1.count, 0)

        let frames2 = parser.feed(Data([0xDC, 0x02, 0xC0]))
        XCTAssertEqual(frames2.count, 1)
        XCTAssertEqual(frames2[0], Data([0x01, 0xC0, 0x02]))
    }

    func testConsecutiveFENDs() {
        var parser = KISSFrameParser()

        // Multiple FENDs in a row (common "idle" pattern)
        let data = Data([0xC0, 0xC0, 0xC0, 0x00, 0x42, 0xC0, 0xC0, 0xC0])
        let frames = parser.feed(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([0x42]))
    }

    func testLargeFrame() {
        var parser = KISSFrameParser()

        // Max AX.25 frame is ~330 bytes — test a larger payload
        var payload = Data(repeating: 0x55, count: 500)
        let kissFrame = KISS.encodeFrame(payload: payload, port: 0)
        let frames = parser.feed(kissFrame)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], payload)
    }

    // MARK: - Encode/Decode Round-Trip Invariants

    func testEncodeDecodeRoundTripAllSpecialBytes() {
        // Payload that contains all KISS special bytes
        let payload = Data([0xC0, 0xDB, 0xDC, 0xDD, 0x00, 0xFF])
        let encoded = KISS.encodeFrame(payload: payload, port: 0)

        var parser = KISSFrameParser()
        let frames = parser.feed(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], payload)
    }

    func testEncodeDecodeRoundTripRandomData() {
        // 100 random payloads of varying sizes
        for _ in 0..<100 {
            let size = Int.random(in: 1...256)
            var payload = Data(count: size)
            for i in 0..<size {
                payload[i] = UInt8.random(in: 0...255)
            }

            let encoded = KISS.encodeFrame(payload: payload, port: 0)

            var parser = KISSFrameParser()
            let frames = parser.feed(encoded)

            XCTAssertEqual(frames.count, 1, "Failed for payload of size \(size)")
            XCTAssertEqual(frames[0], payload, "Round-trip mismatch for payload of size \(size)")
        }
    }

    func testMultipleFramesInStreamRoundTrip() {
        // Encode 5 frames and feed them as one stream
        let payloads: [Data] = (0..<5).map { i in
            Data([UInt8(i), 0xC0, 0xDB, UInt8(i + 10)])
        }

        var stream = Data()
        for payload in payloads {
            stream.append(KISS.encodeFrame(payload: payload, port: 0))
        }

        var parser = KISSFrameParser()
        let frames = parser.feed(stream)
        XCTAssertEqual(frames.count, 5)

        for (i, frame) in frames.enumerated() {
            XCTAssertEqual(frame, payloads[i], "Mismatch at frame \(i)")
        }
    }

    // MARK: - KISSLinkLoopback Tests

    @MainActor
    func testLoopbackLinkSendReceive() async throws {
        let link = KISSLinkLoopback()
        let receiver = TestLinkDelegate()
        link.delegate = receiver

        link.open()
        XCTAssertEqual(link.state, .connected)

        // Encode a KISS frame and send it
        let payload = Data([0x01, 0x02, 0x03])
        let kissFrame = KISS.encodeFrame(payload: payload, port: 0)

        var sendError: Error?
        link.send(kissFrame) { error in
            sendError = error
        }
        XCTAssertNil(sendError)

        // Loopback should have delivered the data synchronously
        XCTAssertEqual(receiver.receivedData.count, 1)
        XCTAssertEqual(receiver.receivedData[0], kissFrame)
    }

    @MainActor
    func testLoopbackLinkStateChanges() async throws {
        let link = KISSLinkLoopback()
        let receiver = TestLinkDelegate()
        link.delegate = receiver

        link.open()
        XCTAssertEqual(receiver.stateChanges.last, .connected)

        link.close()
        XCTAssertEqual(receiver.stateChanges.last, .disconnected)
    }

    @MainActor
    func testLoopbackLinkSimulatedError() async throws {
        let link = KISSLinkLoopback()
        let receiver = TestLinkDelegate()
        link.delegate = receiver

        link.open()
        link.simulatedSendError = KISSSerialError.writeFailed("simulated")

        var sendError: Error?
        link.send(Data([0x01])) { error in
            sendError = error
        }
        XCTAssertNotNil(sendError)
    }

    @MainActor
    func testLoopbackLinkRecordsSentData() async throws {
        let link = KISSLinkLoopback()
        link.loopbackEnabled = false
        let receiver = TestLinkDelegate()
        link.delegate = receiver

        link.open()

        let data1 = Data([0x01, 0x02])
        let data2 = Data([0x03, 0x04])

        link.send(data1) { _ in }
        link.send(data2) { _ in }

        XCTAssertEqual(link.sentData.count, 2)
        XCTAssertEqual(link.sentData[0], data1)
        XCTAssertEqual(link.sentData[1], data2)
        XCTAssertEqual(receiver.receivedData.count, 0, "Loopback disabled should not deliver")
    }

    @MainActor
    func testLoopbackInjectReceived() async throws {
        let link = KISSLinkLoopback()
        let receiver = TestLinkDelegate()
        link.delegate = receiver

        link.open()

        let injected = Data([0xC0, 0x00, 0x42, 0xC0])
        link.injectReceived(injected)

        XCTAssertEqual(receiver.receivedData.count, 1)
        XCTAssertEqual(receiver.receivedData[0], injected)
    }

    // MARK: - Serial Config Tests

    func testSerialConfigBaudRateMapping() {
        XCTAssertEqual(SerialConfig(devicePath: "/dev/cu.test", baudRate: 115200).posixBaudRate, speed_t(B115200))
        XCTAssertEqual(SerialConfig(devicePath: "/dev/cu.test", baudRate: 9600).posixBaudRate, speed_t(B9600))
        XCTAssertEqual(SerialConfig(devicePath: "/dev/cu.test", baudRate: 57600).posixBaudRate, speed_t(B57600))
        // Unknown baud rate defaults to 115200
        XCTAssertEqual(SerialConfig(devicePath: "/dev/cu.test", baudRate: 12345).posixBaudRate, speed_t(B115200))
    }

    func testSerialDeviceEnumeratorFilters() {
        // Just verify the methods don't crash and return arrays
        let tnc = SerialDeviceEnumerator.likelyTNCDevices()
        let all = SerialDeviceEnumerator.allCUDevices()
        // TNC devices should be a subset of all devices
        for device in tnc {
            XCTAssertTrue(all.contains(device), "\(device) should be in all devices")
        }
    }
}

// MARK: - Test Helpers

@MainActor
private class TestLinkDelegate: KISSLinkDelegate {
    var receivedData: [Data] = []
    var stateChanges: [KISSLinkState] = []
    var errors: [String] = []

    func linkDidReceive(_ data: Data) {
        receivedData.append(data)
    }

    func linkDidChangeState(_ state: KISSLinkState) {
        stateChanges.append(state)
    }

    func linkDidError(_ message: String) {
        errors.append(message)
    }
}
