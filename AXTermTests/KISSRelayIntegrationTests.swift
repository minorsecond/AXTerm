//
//  KISSRelayIntegrationTests.swift
//  AXTermTests
//
//  Integration tests using Docker KISS relay for actual send/receive testing.
//  Requires Docker to be running with: docker-compose up -d
//
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md
//

import XCTest
@testable import AXTerm
import Foundation

/// Simple TCP socket helper for testing
class TestSocket {
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var host: String
    private var port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func connect() -> Bool {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)

        guard let read = readStream, let write = writeStream else {
            return false
        }

        inputStream = read.takeRetainedValue()
        outputStream = write.takeRetainedValue()

        inputStream?.open()
        outputStream?.open()

        // Wait for connection
        let deadline = Date().addingTimeInterval(2.0)
        while inputStream?.streamStatus == .opening || outputStream?.streamStatus == .opening {
            if Date() > deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        return inputStream?.streamStatus == .open && outputStream?.streamStatus == .open
    }

    func send(_ data: Data) -> Bool {
        guard let output = outputStream else { return false }

        let bytes = [UInt8](data)
        let written = output.write(bytes, maxLength: bytes.count)
        return written == bytes.count
    }

    func receive(timeout: TimeInterval = 3.0) -> Data? {
        guard let input = inputStream else { return nil }

        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if input.hasBytesAvailable {
                let bytesRead = input.read(&buffer, maxLength: buffer.count)
                if bytesRead > 0 {
                    return Data(buffer[0..<bytesRead])
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        return nil
    }

    func close() {
        inputStream?.close()
        outputStream?.close()
    }
}

/// Integration tests that use the Docker KISS relay to test actual frame transmission.
/// These tests require Docker to be running.
final class KISSRelayIntegrationTests: XCTestCase {

    // MARK: - Configuration

    static let stationAHost = "localhost"
    static let stationAPort = 8001
    static let stationBHost = "localhost"
    static let stationBPort = 8002

    // Track if Docker relay is available
    var relayAvailable = false

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        relayAvailable = checkRelayAvailable()

        if !relayAvailable {
            print("WARNING: Docker KISS relay not available. Run 'docker-compose up -d' in Docker folder.")
        }
    }

    // MARK: - Helper Methods

    /// Check if the Docker KISS relay is available
    func checkRelayAvailable() -> Bool {
        let socket = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let connected = socket.connect()
        socket.close()
        return connected
    }

    // MARK: - Basic Relay Tests

    func testRelayAvailability() throws {
        if relayAvailable {
            print("Docker KISS relay is available on ports \(Self.stationAPort) and \(Self.stationBPort)")
        } else {
            throw XCTSkip("Docker KISS relay not available")
        }
    }

    func testKISSFrameRelayAtoB() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        // Connect both stations
        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect(), "Station A should connect")
        XCTAssertTrue(stationB.connect(), "Station B should connect")

        defer {
            stationA.close()
            stationB.close()
        }

        // Give relay time to register both connections
        Thread.sleep(forTimeInterval: 0.2)

        // Build a KISS frame
        let payload = Data("Test message A->B".utf8)
        let kissFrame = KISS.encodeFrame(payload: payload, port: 0)

        print("Sending KISS frame: \(kissFrame.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Send from Station A
        XCTAssertTrue(stationA.send(kissFrame), "Should send frame")

        // Receive at Station B
        guard let received = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive data at Station B")
            return
        }

        print("Received: \(received.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Parse received KISS frame
        var parser = KISSFrameParser()
        let frames = parser.feed(received)

        XCTAssertEqual(frames.count, 1, "Should receive exactly one frame")
        XCTAssertEqual(frames[0], payload, "Payload should match")
    }

    func testKISSFrameRelayBtoA() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        let payload = Data("Test message B->A".utf8)
        let kissFrame = KISS.encodeFrame(payload: payload, port: 0)

        // Send from Station B, receive at Station A
        XCTAssertTrue(stationB.send(kissFrame))

        guard let received = stationA.receive(timeout: 3.0) else {
            XCTFail("Should receive data at Station A")
            return
        }

        var parser = KISSFrameParser()
        let frames = parser.feed(received)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], payload)
    }

    // MARK: - AX.25 Frame Relay Tests

    func testAX25UIFrameRelay() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        // Build complete AX.25 UI frame
        let from = AX25Address(call: "N0CALL", ssid: 7)
        let to = AX25Address(call: "CQ", ssid: 0)
        let info = Data("Hello via relay!".utf8)
        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: info)

        print("AX.25 frame: \(ax25Frame.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Wrap in KISS
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        // Send and receive
        XCTAssertTrue(stationA.send(kissFrame))

        guard let received = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive data")
            return
        }

        // Parse KISS
        var parser = KISSFrameParser()
        let frames = parser.feed(received)

        XCTAssertEqual(frames.count, 1)

        // Decode AX.25
        let decoded = AX25.decodeFrame(ax25: frames[0])
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.from?.call, "N0CALL")
        XCTAssertEqual(decoded?.from?.ssid, 7)
        XCTAssertEqual(decoded?.to?.call, "CQ")
        XCTAssertEqual(decoded?.frameType, .ui)
        XCTAssertEqual(decoded?.info, info)

        print("Decoded from: \(decoded?.from?.display ?? "?"), to: \(decoded?.to?.display ?? "?"), info: \(String(data: decoded?.info ?? Data(), encoding: .utf8) ?? "?")")
    }

    func testAX25UIFrameWithDigipeatersRelay() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        // Build AX.25 frame with via path
        let from = AX25Address(call: "K0ABC", ssid: 1)
        let to = AX25Address(call: "APRS", ssid: 0)
        let via = [
            AX25Address(call: "WIDE1", ssid: 1),
            AX25Address(call: "WIDE2", ssid: 1)
        ]
        let info = Data(">Test with digis".utf8)
        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: via, pid: 0xF0, info: info)

        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        XCTAssertTrue(stationA.send(kissFrame))

        guard let received = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive data")
            return
        }

        var parser = KISSFrameParser()
        let frames = parser.feed(received)

        XCTAssertEqual(frames.count, 1)

        let decoded = AX25.decodeFrame(ax25: frames[0])
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.via.count, 2)
        XCTAssertEqual(decoded?.via[0].call, "WIDE1")
        XCTAssertEqual(decoded?.via[1].call, "WIDE2")

        print("Via path: \(decoded?.via.map { $0.display }.joined(separator: ",") ?? "none")")
    }

    // MARK: - AXDP Frame Relay Tests

    func testAXDPChatMessageRelay() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        // Build AXDP chat message
        let axdpMsg = AXDP.Message(
            type: .chat,
            sessionId: 1,
            messageId: 1,
            payload: Data("Hello AXDP!".utf8)
        )
        let axdpPayload = axdpMsg.encode()

        print("AXDP payload: \(axdpPayload.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Wrap in AX.25 UI frame
        let from = AX25Address(call: "N0CALL", ssid: 0)
        let to = AX25Address(call: "K0ABC", ssid: 0)
        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: axdpPayload)

        // Wrap in KISS
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        // Send and receive
        XCTAssertTrue(stationA.send(kissFrame))

        guard let received = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive data")
            return
        }

        // Parse KISS -> AX.25 -> AXDP
        var parser = KISSFrameParser()
        let frames = parser.feed(received)

        XCTAssertEqual(frames.count, 1)

        let ax25Decoded = AX25.decodeFrame(ax25: frames[0])
        XCTAssertNotNil(ax25Decoded)

        if let info = ax25Decoded?.info {
            XCTAssertTrue(AXDP.hasMagic(info), "Should have AXDP magic")

            let axdpDecoded = AXDP.Message.decode(from: info)
            XCTAssertNotNil(axdpDecoded)
            XCTAssertEqual(axdpDecoded?.type, .chat)
            XCTAssertEqual(axdpDecoded?.sessionId, 1)
            XCTAssertEqual(axdpDecoded?.messageId, 1)
            XCTAssertEqual(axdpDecoded?.payload, Data("Hello AXDP!".utf8))

            print("AXDP decoded: type=\(axdpDecoded?.type ?? .chat), sessionId=\(axdpDecoded?.sessionId ?? 0), payload=\(String(data: axdpDecoded?.payload ?? Data(), encoding: .utf8) ?? "?")")
        }
    }

    func testAXDPFileChunkRelay() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        // Build AXDP file chunk
        let chunkData = Data(repeating: 0x42, count: 128)
        let axdpMsg = AXDP.Message(
            type: .fileChunk,
            sessionId: 100,
            messageId: 5,
            chunkIndex: 3,
            totalChunks: 10,
            payload: chunkData,
            payloadCRC32: AXDP.crc32(chunkData)
        )
        let axdpPayload = axdpMsg.encode()

        let from = AX25Address(call: "SRC", ssid: 0)
        let to = AX25Address(call: "DST", ssid: 0)
        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: axdpPayload)
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        XCTAssertTrue(stationA.send(kissFrame))

        guard let received = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive data")
            return
        }

        var parser = KISSFrameParser()
        let frames = parser.feed(received)

        XCTAssertEqual(frames.count, 1)

        let ax25Decoded = AX25.decodeFrame(ax25: frames[0])
        XCTAssertNotNil(ax25Decoded)

        if let info = ax25Decoded?.info {
            let axdpDecoded = AXDP.Message.decode(from: info)
            XCTAssertNotNil(axdpDecoded)
            XCTAssertEqual(axdpDecoded?.type, .fileChunk)
            XCTAssertEqual(axdpDecoded?.chunkIndex, 3)
            XCTAssertEqual(axdpDecoded?.totalChunks, 10)
            XCTAssertEqual(axdpDecoded?.payload, chunkData)

            // Verify CRC
            if let decodedPayload = axdpDecoded?.payload,
               let decodedCRC = axdpDecoded?.payloadCRC32 {
                let computedCRC = AXDP.crc32(decodedPayload)
                XCTAssertEqual(decodedCRC, computedCRC, "CRC should match")
                print("File chunk: index=\(axdpDecoded?.chunkIndex ?? 0)/\(axdpDecoded?.totalChunks ?? 0), CRC=\(String(format: "0x%08X", decodedCRC))")
            }
        }
    }

    // MARK: - Edge Case Tests

    func testLargeFrameRelay() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        // Test with max typical AX.25 info field size (256 bytes)
        let largePayload = Data((0..<256).map { UInt8($0 % 256) })
        let from = AX25Address(call: "TEST", ssid: 0)
        let to = AX25Address(call: "DEST", ssid: 0)
        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: largePayload)
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        print("Large frame size: \(kissFrame.count) bytes")

        XCTAssertTrue(stationA.send(kissFrame))

        guard let received = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive data")
            return
        }

        var parser = KISSFrameParser()
        let frames = parser.feed(received)

        XCTAssertEqual(frames.count, 1)

        let decoded = AX25.decodeFrame(ax25: frames[0])
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, largePayload)

        print("Large frame received: \(decoded?.info.count ?? 0) bytes payload")
    }

    func testFrameWithSpecialKISSBytesRelay() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        // Info field containing KISS special bytes that need escaping
        let specialInfo = Data([0x41, 0xC0, 0x42, 0xDB, 0x43, 0xC0, 0xDB, 0x44])
        let from = AX25Address(call: "ESC", ssid: 0)
        let to = AX25Address(call: "TEST", ssid: 0)
        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: specialInfo)
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        print("Frame with special bytes: \(kissFrame.map { String(format: "%02X", $0) }.joined(separator: " "))")

        XCTAssertTrue(stationA.send(kissFrame))

        guard let received = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive data")
            return
        }

        var parser = KISSFrameParser()
        let frames = parser.feed(received)

        XCTAssertEqual(frames.count, 1)

        let decoded = AX25.decodeFrame(ax25: frames[0])
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, specialInfo, "Special bytes should survive KISS encoding")

        print("Special bytes preserved correctly")
    }

    // MARK: - Multiple Frame Tests

    func testMultipleFramesBidirectional() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        // Send from A to B
        let msgAtoB = Data("Message from A".utf8)
        let frameAtoB = KISS.encodeFrame(payload: msgAtoB, port: 0)
        XCTAssertTrue(stationA.send(frameAtoB))

        guard let receivedAtB = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive at B")
            return
        }

        var parserB = KISSFrameParser()
        let framesB = parserB.feed(receivedAtB)
        XCTAssertEqual(framesB.count, 1)
        XCTAssertEqual(framesB[0], msgAtoB)

        print("A->B: received '\(String(data: framesB[0], encoding: .utf8) ?? "?")'")

        // Send from B to A
        let msgBtoA = Data("Message from B".utf8)
        let frameBtoA = KISS.encodeFrame(payload: msgBtoA, port: 0)
        XCTAssertTrue(stationB.send(frameBtoA))

        guard let receivedAtA = stationA.receive(timeout: 3.0) else {
            XCTFail("Should receive at A")
            return
        }

        var parserA = KISSFrameParser()
        let framesA = parserA.feed(receivedAtA)
        XCTAssertEqual(framesA.count, 1)
        XCTAssertEqual(framesA[0], msgBtoA)

        print("B->A: received '\(String(data: framesA[0], encoding: .utf8) ?? "?")'")
    }

    func testSequentialFrames() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        var parserB = KISSFrameParser()
        var allReceivedFrames: [Data] = []

        // Send 5 frames in sequence with proper channel access timing
        // The RF simulator has collision detection, so we need realistic delays
        for i in 0..<5 {
            let msg = Data("Frame \(i)".utf8)
            let frame = KISS.encodeFrame(payload: msg, port: 0)
            XCTAssertTrue(stationA.send(frame))

            // Wait for frame to be transmitted and channel to clear
            // RF simulator has ~100ms TX delay + 10ms propagation
            Thread.sleep(forTimeInterval: 0.2)

            // Receive each frame as it arrives
            if let received = stationB.receive(timeout: 0.5) {
                let frames = parserB.feed(received)
                allReceivedFrames.append(contentsOf: frames)
            }
        }

        print("Received \(allReceivedFrames.count) frames")
        for (i, frame) in allReceivedFrames.enumerated() {
            print("  Frame \(i): '\(String(data: frame, encoding: .utf8) ?? "?")'")
        }

        XCTAssertEqual(allReceivedFrames.count, 5, "Should receive all 5 frames")

        // Verify frame contents
        for i in 0..<min(allReceivedFrames.count, 5) {
            let expectedMsg = Data("Frame \(i)".utf8)
            XCTAssertEqual(allReceivedFrames[i], expectedMsg, "Frame \(i) content should match")
        }
    }

    // MARK: - Compatibility Test: Standard Packet vs AXDP

    func testStandardPacketAndAXDPCoexistence() throws {
        guard relayAvailable else {
            throw XCTSkip("Docker KISS relay not available")
        }

        let stationA = TestSocket(host: Self.stationAHost, port: Self.stationAPort)
        let stationB = TestSocket(host: Self.stationBHost, port: Self.stationBPort)

        XCTAssertTrue(stationA.connect())
        XCTAssertTrue(stationB.connect())

        defer {
            stationA.close()
            stationB.close()
        }

        Thread.sleep(forTimeInterval: 0.2)

        // Test 1: Standard packet (plain text, no AXDP)
        print("\n--- Standard Packet (No AXDP) ---")
        let plainText = Data("Hello from legacy station!".utf8)
        let from1 = AX25Address(call: "LEGACY", ssid: 0)
        let to1 = AX25Address(call: "CQ", ssid: 0)
        let ax25Frame1 = AX25.encodeUIFrame(from: from1, to: to1, via: [], pid: 0xF0, info: plainText)
        let kissFrame1 = KISS.encodeFrame(payload: ax25Frame1, port: 0)

        XCTAssertTrue(stationA.send(kissFrame1))

        guard let received1 = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive standard packet")
            return
        }

        var parser1 = KISSFrameParser()
        let frames1 = parser1.feed(received1)
        XCTAssertEqual(frames1.count, 1)

        let decoded1 = AX25.decodeFrame(ax25: frames1[0])
        XCTAssertNotNil(decoded1)
        XCTAssertFalse(AXDP.hasMagic(decoded1?.info ?? Data()), "Should NOT have AXDP magic")
        XCTAssertEqual(decoded1?.info, plainText)
        print("Standard packet received: '\(String(data: decoded1?.info ?? Data(), encoding: .utf8) ?? "?")'")

        // Test 2: AXDP packet
        print("\n--- AXDP Packet ---")
        let axdpMsg = AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("Hello from AXDP station!".utf8))
        let axdpPayload = axdpMsg.encode()
        let from2 = AX25Address(call: "AXDP", ssid: 0)
        let to2 = AX25Address(call: "CQ", ssid: 0)
        let ax25Frame2 = AX25.encodeUIFrame(from: from2, to: to2, via: [], pid: 0xF0, info: axdpPayload)
        let kissFrame2 = KISS.encodeFrame(payload: ax25Frame2, port: 0)

        XCTAssertTrue(stationA.send(kissFrame2))

        guard let received2 = stationB.receive(timeout: 3.0) else {
            XCTFail("Should receive AXDP packet")
            return
        }

        var parser2 = KISSFrameParser()
        let frames2 = parser2.feed(received2)
        XCTAssertEqual(frames2.count, 1)

        let decoded2 = AX25.decodeFrame(ax25: frames2[0])
        XCTAssertNotNil(decoded2)
        XCTAssertTrue(AXDP.hasMagic(decoded2?.info ?? Data()), "Should have AXDP magic")

        let axdpDecoded = AXDP.Message.decode(from: decoded2?.info ?? Data())
        XCTAssertNotNil(axdpDecoded)
        XCTAssertEqual(axdpDecoded?.type, .chat)
        print("AXDP packet received: '\(String(data: axdpDecoded?.payload ?? Data(), encoding: .utf8) ?? "?")'")

        print("\n--- Both packet types coexist correctly ---")
    }
}
