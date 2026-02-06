//
//  OutboundFrameTests.swift
//  AXTermTests
//
//  Tests for TX queue models.
//

import XCTest
@testable import AXTerm

final class OutboundFrameTests: XCTestCase {

    // MARK: - TxPriority Tests

    func testTxPriorityOrdering() {
        XCTAssertTrue(TxPriority.bulk < TxPriority.normal)
        XCTAssertTrue(TxPriority.normal < TxPriority.interactive)
        XCTAssertTrue(TxPriority.bulk < TxPriority.interactive)
    }

    func testTxPriorityRawValues() {
        XCTAssertEqual(TxPriority.bulk.rawValue, 10)
        XCTAssertEqual(TxPriority.normal.rawValue, 50)
        XCTAssertEqual(TxPriority.interactive.rawValue, 100)
    }

    // MARK: - DigiPath Tests

    func testDigiPathEmpty() {
        let path = DigiPath()
        XCTAssertTrue(path.isEmpty)
        XCTAssertEqual(path.count, 0)
        XCTAssertEqual(path.display, "")
    }

    func testDigiPathFromAddresses() {
        let digis = [
            AX25Address(call: "WIDE1", ssid: 1),
            AX25Address(call: "WIDE2", ssid: 1)
        ]
        let path = DigiPath(digis)

        XCTAssertEqual(path.count, 2)
        XCTAssertEqual(path.digis[0].call, "WIDE1")
        XCTAssertEqual(path.digis[1].call, "WIDE2")
    }

    func testDigiPathFromStrings() {
        let path = DigiPath.from(["WIDE1-1", "WIDE2-1"])

        XCTAssertEqual(path.count, 2)
        XCTAssertEqual(path.digis[0].call, "WIDE1")
        XCTAssertEqual(path.digis[0].ssid, 1)
        XCTAssertEqual(path.digis[1].call, "WIDE2")
        XCTAssertEqual(path.digis[1].ssid, 1)
    }

    func testDigiPathFromStringsNoSSID() {
        let path = DigiPath.from(["RELAY", "WIDE1-1"])

        XCTAssertEqual(path.count, 2)
        XCTAssertEqual(path.digis[0].call, "RELAY")
        XCTAssertEqual(path.digis[0].ssid, 0)
    }

    func testDigiPathLimitsTo8() {
        var digis: [AX25Address] = []
        for i in 0..<12 {
            digis.append(AX25Address(call: "D\(i)", ssid: 0))
        }
        let path = DigiPath(digis)

        XCTAssertEqual(path.count, 8, "Should limit to 8 digipeaters")
    }

    func testDigiPathDisplay() {
        let path = DigiPath.from(["WIDE1-1", "WIDE2-1"])
        XCTAssertEqual(path.display, "WIDE1-1,WIDE2-1")
    }

    func testDigiPathDisplayNoSSID() {
        let path = DigiPath.from(["RELAY"])
        XCTAssertEqual(path.display, "RELAY")
    }

    // MARK: - OutboundFrame Tests

    func testOutboundFrameCreation() {
        let dest = AX25Address(call: "APRS", ssid: 0)
        let src = AX25Address(call: "N0CALL", ssid: 1)
        let payload = Data("Test".utf8)

        let frame = OutboundFrame(
            destination: dest,
            source: src,
            payload: payload
        )

        XCTAssertEqual(frame.destination.call, "APRS")
        XCTAssertEqual(frame.source.call, "N0CALL")
        XCTAssertEqual(frame.source.ssid, 1)
        XCTAssertEqual(frame.payload, payload)
        XCTAssertEqual(frame.priority, .normal)
        XCTAssertEqual(frame.frameType, "ui")
        XCTAssertEqual(frame.pid, 0xF0)
        XCTAssertEqual(frame.channel, 0)
        XCTAssertNil(frame.sessionId)
    }

    func testOutboundFrameWithPath() {
        let frame = OutboundFrame(
            destination: AX25Address(call: "DST", ssid: 0),
            source: AX25Address(call: "SRC", ssid: 0),
            path: DigiPath.from(["WIDE1-1"]),
            payload: Data()
        )

        XCTAssertEqual(frame.path.count, 1)
        XCTAssertEqual(frame.path.digis[0].call, "WIDE1")
    }

    func testOutboundFrameWithSession() {
        let sessionId = UUID()
        let frame = OutboundFrame(
            destination: AX25Address(call: "DST", ssid: 0),
            source: AX25Address(call: "SRC", ssid: 0),
            payload: Data(),
            frameType: "i",
            sessionId: sessionId
        )

        XCTAssertEqual(frame.frameType, "i")
        XCTAssertEqual(frame.sessionId, sessionId)
    }

    func testOutboundFrameWithAXDP() {
        let frame = OutboundFrame(
            destination: AX25Address(call: "DST", ssid: 0),
            source: AX25Address(call: "SRC", ssid: 0),
            payload: Data(),
            axdpMessageId: 12345,
            displayInfo: "Chat message"
        )

        XCTAssertEqual(frame.axdpMessageId, 12345)
        XCTAssertEqual(frame.displayInfo, "Chat message")
    }

    // MARK: - TxFrameState Tests

    func testTxFrameStateInitial() {
        let frameId = UUID()
        let state = TxFrameState(frameId: frameId)

        XCTAssertEqual(state.frameId, frameId)
        XCTAssertEqual(state.status, .queued)
        XCTAssertEqual(state.attempts, 0)
        XCTAssertNil(state.lastAttemptAt)
        XCTAssertNil(state.sentAt)
        XCTAssertNil(state.ackedAt)
        XCTAssertNil(state.errorMessage)
    }

    func testTxFrameStateMarkSending() {
        var state = TxFrameState(frameId: UUID())

        state.markSending()

        XCTAssertEqual(state.status, .sending)
        XCTAssertEqual(state.attempts, 1)
        XCTAssertNotNil(state.lastAttemptAt)
    }

    func testTxFrameStateMarkSendingIncrementsAttempts() {
        var state = TxFrameState(frameId: UUID())

        state.markSending()
        state.markSending()
        state.markSending()

        XCTAssertEqual(state.attempts, 3)
    }

    func testTxFrameStateMarkSent() {
        var state = TxFrameState(frameId: UUID())
        state.markSending()

        state.markSent()

        XCTAssertEqual(state.status, .sent)
        XCTAssertNotNil(state.sentAt)
    }

    func testTxFrameStateMarkAwaitingAck() {
        var state = TxFrameState(frameId: UUID())
        state.markSending()
        state.markSent()

        state.markAwaitingAck()

        XCTAssertEqual(state.status, .awaitingAck)
    }

    func testTxFrameStateMarkAcked() {
        var state = TxFrameState(frameId: UUID())
        state.markSending()
        state.markAwaitingAck()

        state.markAcked()

        XCTAssertEqual(state.status, .acked)
        XCTAssertNotNil(state.ackedAt)
    }

    func testTxFrameStateMarkFailed() {
        var state = TxFrameState(frameId: UUID())
        state.markSending()

        state.markFailed(reason: "Max retries exceeded")

        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.errorMessage, "Max retries exceeded")
    }

    func testTxFrameStateMarkCancelled() {
        var state = TxFrameState(frameId: UUID())

        state.markCancelled()

        XCTAssertEqual(state.status, .cancelled)
    }

    // MARK: - TxQueueEntry Tests

    func testTxQueueEntryCreation() {
        let frame = OutboundFrame(
            destination: AX25Address(call: "DST", ssid: 0),
            source: AX25Address(call: "SRC", ssid: 0),
            payload: Data("test".utf8)
        )

        let entry = TxQueueEntry(frame: frame)

        XCTAssertEqual(entry.id, frame.id)
        XCTAssertEqual(entry.state.status, .queued)
        XCTAssertEqual(entry.frame.payload, Data("test".utf8))
    }

    // MARK: - Codable Tests

    func testOutboundFrameCodable() throws {
        let frame = OutboundFrame(
            destination: AX25Address(call: "DST", ssid: 5),
            source: AX25Address(call: "SRC", ssid: 1),
            path: DigiPath.from(["WIDE1-1"]),
            payload: Data("Hello".utf8),
            priority: .interactive,
            axdpMessageId: 42
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(frame)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(OutboundFrame.self, from: data)

        XCTAssertEqual(decoded.id, frame.id)
        XCTAssertEqual(decoded.destination.call, "DST")
        XCTAssertEqual(decoded.destination.ssid, 5)
        XCTAssertEqual(decoded.source.call, "SRC")
        XCTAssertEqual(decoded.path.count, 1)
        XCTAssertEqual(decoded.priority, .interactive)
        XCTAssertEqual(decoded.axdpMessageId, 42)
    }

    func testTxFrameStateCodable() throws {
        var state = TxFrameState(frameId: UUID())
        state.markSending()
        state.markAcked()

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TxFrameState.self, from: data)

        XCTAssertEqual(decoded.frameId, state.frameId)
        XCTAssertEqual(decoded.status, .acked)
        XCTAssertEqual(decoded.attempts, 1)
    }

    // MARK: - AX.25 Encoding Tests

    func testOutboundFrameEncodeAX25Basic() {
        let frame = OutboundFrame(
            destination: AX25Address(call: "CQ", ssid: 0),
            source: AX25Address(call: "N0CALL", ssid: 0),
            payload: Data("Test".utf8)
        )

        let encoded = frame.encodeAX25()

        // Verify structure: dest(7) + src(7) + control(1) + pid(1) + info
        XCTAssertGreaterThanOrEqual(encoded.count, 20)

        // Should be decodable
        let decoded = AX25.decodeFrame(ax25: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.from?.call, "N0CALL")
        XCTAssertEqual(decoded?.to?.call, "CQ")
        XCTAssertEqual(decoded?.info, Data("Test".utf8))
    }

    func testOutboundFrameExtensionBitNoDigis() {
        // Critical test: Destination should NOT have extension bit set
        let frame = OutboundFrame(
            destination: AX25Address(call: "CQ", ssid: 0),
            source: AX25Address(call: "K0EPI", ssid: 0),
            payload: Data("test".utf8)
        )

        let encoded = frame.encodeAX25()

        // Destination SSID byte (byte 6): extension bit = 0
        XCTAssertEqual(encoded[6] & 0x01, 0x00, "Destination must NOT have extension bit set")

        // Source SSID byte (byte 13): extension bit = 1 (last address when no digis)
        XCTAssertEqual(encoded[13] & 0x01, 0x01, "Source must have extension bit set when no digis")
    }

    func testOutboundFrameExtensionBitWithOneDigis() {
        let frame = OutboundFrame(
            destination: AX25Address(call: "DST", ssid: 0),
            source: AX25Address(call: "SRC", ssid: 0),
            path: DigiPath.from(["WIDE1-1"]),
            payload: Data()
        )

        let encoded = frame.encodeAX25()

        // Destination (byte 6): extension bit = 0
        XCTAssertEqual(encoded[6] & 0x01, 0x00, "Destination must NOT have extension bit")

        // Source (byte 13): extension bit = 0 (digis follow)
        XCTAssertEqual(encoded[13] & 0x01, 0x00, "Source must NOT have extension bit when digis follow")

        // WIDE1-1 (byte 20): extension bit = 1 (last address)
        XCTAssertEqual(encoded[20] & 0x01, 0x01, "Last digi must have extension bit set")
    }

    func testOutboundFrameExtensionBitWithMultipleDigis() {
        let frame = OutboundFrame(
            destination: AX25Address(call: "DST", ssid: 0),
            source: AX25Address(call: "SRC", ssid: 0),
            path: DigiPath.from(["WIDE1-1", "WIDE2-1", "RELAY"]),
            payload: Data()
        )

        let encoded = frame.encodeAX25()

        // Destination (byte 6): extension bit = 0
        XCTAssertEqual(encoded[6] & 0x01, 0x00)

        // Source (byte 13): extension bit = 0
        XCTAssertEqual(encoded[13] & 0x01, 0x00)

        // First digi WIDE1-1 (byte 20): extension bit = 0
        XCTAssertEqual(encoded[20] & 0x01, 0x00)

        // Second digi WIDE2-1 (byte 27): extension bit = 0
        XCTAssertEqual(encoded[27] & 0x01, 0x00)

        // Third digi RELAY (byte 34): extension bit = 1 (last)
        XCTAssertEqual(encoded[34] & 0x01, 0x01)
    }

    func testOutboundFrameRoundTripWithDigis() {
        let frame = OutboundFrame(
            destination: AX25Address(call: "APRS", ssid: 0),
            source: AX25Address(call: "N0CALL", ssid: 7),
            path: DigiPath.from(["WIDE1-1", "WIDE2-1"]),
            payload: Data("Hello World".utf8)
        )

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.from?.call, "N0CALL")
        XCTAssertEqual(decoded?.from?.ssid, 7)
        XCTAssertEqual(decoded?.to?.call, "APRS")
        XCTAssertEqual(decoded?.to?.ssid, 0)
        XCTAssertEqual(decoded?.via.count, 2)
        XCTAssertEqual(decoded?.via[0].call, "WIDE1")
        XCTAssertEqual(decoded?.via[0].ssid, 1)
        XCTAssertEqual(decoded?.via[1].call, "WIDE2")
        XCTAssertEqual(decoded?.via[1].ssid, 1)
        XCTAssertEqual(decoded?.info, Data("Hello World".utf8))
    }

    func testOutboundFrameAllSSIDValues() {
        // Test all valid SSID combinations
        for srcSSID in 0...15 {
            for dstSSID in 0...15 {
                let frame = OutboundFrame(
                    destination: AX25Address(call: "DST", ssid: dstSSID),
                    source: AX25Address(call: "SRC", ssid: srcSSID),
                    payload: Data([0x42])
                )

                let encoded = frame.encodeAX25()
                let decoded = AX25.decodeFrame(ax25: encoded)

                XCTAssertNotNil(decoded)
                XCTAssertEqual(decoded?.from?.ssid, srcSSID, "Source SSID \(srcSSID) not preserved")
                XCTAssertEqual(decoded?.to?.ssid, dstSSID, "Dest SSID \(dstSSID) not preserved")
            }
        }
    }

    func testOutboundFrameWithExplicitControlByte() {
        // Test S-frame (RR)
        let frame = OutboundFrame(
            destination: AX25Address(call: "K0ABC", ssid: 0),
            source: AX25Address(call: "N0CALL", ssid: 0),
            payload: Data(),
            frameType: "s",
            pid: nil,
            controlByte: 0x01  // RR with nr=0
        )

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .s)
    }

    func testOutboundFrameIFrameSequenceNumbers() {
        let frame = OutboundFrame(
            destination: AX25Address(call: "K0ABC", ssid: 0),
            source: AX25Address(call: "N0CALL", ssid: 0),
            payload: Data("I-frame".utf8),
            frameType: "i",
            controlByte: 0xA6,  // ns=3, nr=5
            ns: 3,
            nr: 5
        )

        XCTAssertEqual(frame.ns, 3)
        XCTAssertEqual(frame.nr, 5)

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .i)
    }

    // MARK: - AXDP Integration Tests

    func testOutboundFrameWithAXDPChat() {
        let axdpMsg = AXDP.Message(
            type: .chat,
            sessionId: 1,
            messageId: 1,
            payload: Data("Hello via AXDP".utf8)
        )
        let axdpPayload = axdpMsg.encode()

        let frame = OutboundFrame(
            destination: AX25Address(call: "K0ABC", ssid: 0),
            source: AX25Address(call: "N0CALL", ssid: 0),
            payload: axdpPayload,
            axdpMessageId: 1
        )

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)

        // Verify AXDP can be extracted and decoded
        if let info = decoded?.info {
            XCTAssertTrue(AXDP.hasMagic(info))
            let decodedAXDP = AXDP.Message.decode(from: info)
            XCTAssertNotNil(decodedAXDP)
            XCTAssertEqual(decodedAXDP?.type, .chat)
            XCTAssertEqual(decodedAXDP?.payload, Data("Hello via AXDP".utf8))
        }
    }

    func testOutboundFrameWithAXDPFileChunk() {
        let chunkData = Data(repeating: 0x42, count: 128)
        let axdpMsg = AXDP.Message(
            type: .fileChunk,
            sessionId: 100,
            messageId: 5,
            chunkIndex: 0,
            totalChunks: 10,
            payload: chunkData,
            payloadCRC32: AXDP.crc32(chunkData)
        )
        let axdpPayload = axdpMsg.encode()

        let frame = OutboundFrame(
            destination: AX25Address(call: "K0ABC", ssid: 0),
            source: AX25Address(call: "N0CALL", ssid: 0),
            payload: axdpPayload,
            priority: .bulk,
            axdpMessageId: 5
        )

        XCTAssertEqual(frame.priority, .bulk)

        let encoded = frame.encodeAX25()
        let decoded = AX25.decodeFrame(ax25: encoded)

        XCTAssertNotNil(decoded)

        if let info = decoded?.info {
            let decodedAXDP = AXDP.Message.decode(from: info)
            XCTAssertNotNil(decodedAXDP)
            XCTAssertEqual(decodedAXDP?.type, .fileChunk)
            XCTAssertEqual(decodedAXDP?.chunkIndex, 0)
            XCTAssertEqual(decodedAXDP?.totalChunks, 10)
        }
    }
}
