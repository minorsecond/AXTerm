//
//  AXDPTests.swift
//  AXTermTests
//
//  TDD tests for AXDP TLV encoder/decoder.
//  Spec: AXTERM-TRANSMISSION-SPEC.md Section 6
//

import XCTest
@testable import AXTerm

final class AXDPTests: XCTestCase {

    // MARK: - Magic Header Tests

    func testMagicHeaderIsAXT1() {
        XCTAssertEqual(AXDP.magic, Data("AXT1".utf8))
    }

    func testValidatesMagicHeader() {
        let validData = Data("AXT1".utf8) + Data([0x01, 0x00, 0x01, 0x01])
        XCTAssertTrue(AXDP.hasMagic(validData))

        let invalidData = Data("AXT2".utf8) + Data([0x01, 0x00, 0x01, 0x01])
        XCTAssertFalse(AXDP.hasMagic(invalidData))

        let shortData = Data("AXT".utf8)
        XCTAssertFalse(AXDP.hasMagic(shortData))
    }

    // MARK: - TLV Encoding Tests

    func testEncodeTLVBasic() {
        let tlv = AXDP.TLV(type: 0x01, value: Data([0x05]))
        let encoded = tlv.encode()

        // Type (1) + Length (2) + Value
        XCTAssertEqual(encoded, Data([0x01, 0x00, 0x01, 0x05]))
    }

    func testEncodeTLVEmpty() {
        let tlv = AXDP.TLV(type: 0x06, value: Data())
        let encoded = tlv.encode()

        XCTAssertEqual(encoded, Data([0x06, 0x00, 0x00]))
    }

    func testEncodeTLVLargeValue() {
        // Test with 300 bytes (length needs 2 bytes)
        let value = Data(repeating: 0xAB, count: 300)
        let tlv = AXDP.TLV(type: 0x06, value: value)
        let encoded = tlv.encode()

        // Type (1) + Length (2 bytes big-endian: 0x01, 0x2C = 300) + Value
        XCTAssertEqual(encoded.prefix(3), Data([0x06, 0x01, 0x2C]))
        XCTAssertEqual(encoded.count, 303)
    }

    // MARK: - TLV Decoding Tests

    func testDecodeTLVBasic() {
        let encoded = Data([0x01, 0x00, 0x01, 0x05])
        let result = AXDP.TLV.decode(from: encoded, at: 0)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tlv.type, 0x01)
        XCTAssertEqual(result?.tlv.value, Data([0x05]))
        XCTAssertEqual(result?.nextOffset, 4)
    }

    func testDecodeTLVEmpty() {
        let encoded = Data([0x06, 0x00, 0x00])
        let result = AXDP.TLV.decode(from: encoded, at: 0)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tlv.type, 0x06)
        XCTAssertEqual(result?.tlv.value, Data())
        XCTAssertEqual(result?.nextOffset, 3)
    }

    func testDecodeTLVLargeValue() {
        var encoded = Data([0x06, 0x01, 0x2C])  // Type=6, Length=300
        encoded.append(Data(repeating: 0xAB, count: 300))

        let result = AXDP.TLV.decode(from: encoded, at: 0)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tlv.type, 0x06)
        XCTAssertEqual(result?.tlv.value.count, 300)
    }

    func testDecodeTLVTruncatedHeader() {
        let encoded = Data([0x01, 0x00])  // Missing length byte
        let result = AXDP.TLV.decode(from: encoded, at: 0)
        XCTAssertNil(result)
    }

    func testDecodeTLVTruncatedValue() {
        let encoded = Data([0x01, 0x00, 0x05, 0x01])  // Says 5 bytes but only has 1
        let result = AXDP.TLV.decode(from: encoded, at: 0)
        XCTAssertNil(result)
    }

    // MARK: - Multiple TLV Parsing Tests

    func testDecodeMultipleTLVs() {
        // Two TLVs: MessageType=1, SessionId=12345
        var data = Data()
        data.append(AXDP.TLV(type: 0x01, value: Data([0x01])).encode())  // CHAT
        data.append(AXDP.TLV(type: 0x02, value: AXDP.encodeUInt32(12345)).encode())

        let (tlvs, _, _) = AXDP.decodeTLVs(from: data)

        XCTAssertEqual(tlvs.count, 2)
        XCTAssertEqual(tlvs[0].type, 0x01)
        XCTAssertEqual(tlvs[1].type, 0x02)
    }

    func testDecodeSkipsUnknownTLVs() {
        // Known TLV, Unknown TLV (type 0x99), Known TLV
        var data = Data()
        data.append(AXDP.TLV(type: 0x01, value: Data([0x01])).encode())
        data.append(AXDP.TLV(type: 0x99, value: Data([0xDE, 0xAD, 0xBE, 0xEF])).encode())  // Unknown
        data.append(AXDP.TLV(type: 0x03, value: AXDP.encodeUInt32(42)).encode())

        let (tlvs, _, _) = AXDP.decodeTLVs(from: data)

        // Should parse all three, including unknown
        XCTAssertEqual(tlvs.count, 3)
        XCTAssertEqual(tlvs[0].type, 0x01)
        XCTAssertEqual(tlvs[1].type, 0x99)  // Unknown type preserved
        XCTAssertEqual(tlvs[2].type, 0x03)
    }

    // MARK: - Message Encoding/Decoding Tests

    func testEncodeChatMessage() {
        let msg = AXDP.Message(
            type: .chat,
            sessionId: 1,
            messageId: 1,
            payload: Data("Hello".utf8)
        )

        let encoded = msg.encode()

        // Should start with magic
        XCTAssertTrue(AXDP.hasMagic(encoded))
        // Should be decodable
        let decoded = AXDP.Message.decodeMessage(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .chat)
        XCTAssertEqual(decoded?.sessionId, 1)
        XCTAssertEqual(decoded?.payload, Data("Hello".utf8))
    }

    func testEncodeFileChunkMessage() {
        let payload = Data(repeating: 0x42, count: 64)
        let msg = AXDP.Message(
            type: .fileChunk,
            sessionId: 100,
            messageId: 5,
            chunkIndex: 3,
            totalChunks: 10,
            payload: payload,
            payloadCRC32: AXDP.crc32(payload)
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileChunk)
        XCTAssertEqual(decoded?.chunkIndex, 3)
        XCTAssertEqual(decoded?.totalChunks, 10)
        XCTAssertEqual(decoded?.payloadCRC32, AXDP.crc32(payload))
    }

    /// Wrong PayloadCRC32 is detectable (receiver would reject chunk and request retransmit via NACK)
    func testFileChunkWrongPayloadCRC32Detectable() {
        let chunkData = Data(repeating: 0x42, count: 128)
        let wrongCRC: UInt32 = 0xDEAD_BEEF

        let msg = AXDP.Message(
            type: .fileChunk,
            sessionId: 12345,
            messageId: 1,
            chunkIndex: 0,
            totalChunks: 8,
            payload: chunkData,
            payloadCRC32: wrongCRC
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.payload, chunkData)
        XCTAssertEqual(decoded?.payloadCRC32, wrongCRC)
        let computedCRC = AXDP.crc32(decoded!.payload!)
        XCTAssertNotEqual(computedCRC, decoded!.payloadCRC32!, "Receiver must detect mismatch and not count chunk")
    }

    func testEncodeAckMessage() {
        let msg = AXDP.Message(
            type: .ack,
            sessionId: 1,
            messageId: 42
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .ack)
        XCTAssertEqual(decoded?.messageId, 42)
    }

    func testEncodeAckMessageWithTransferMetrics() {
        let metrics = AXDP.AXDPTransferMetrics(
            dataDurationMs: 1234,
            processingDurationMs: 250,
            bytesReceived: 4096,
            decompressedBytes: 8192
        )
        let msg = AXDP.Message(
            type: .ack,
            sessionId: 99,
            messageId: 0xFFFF_FFFF,
            transferMetrics: metrics
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.transferMetrics, metrics)
    }

    func testEncodeSackBitmap() {
        let sackBitmap = Data([0xFF, 0x00, 0xAA])  // Bits for chunks received
        let msg = AXDP.Message(
            type: .ack,
            sessionId: 1,
            messageId: 10,
            sackBitmap: sackBitmap
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.sackBitmap, sackBitmap)
    }

    // MARK: - Compatibility Tests (Critical for AXDP)

    func testDecodeOlderVersionSafely() {
        // Simulate older version with fewer TLVs
        var data = AXDP.magic
        data.append(AXDP.TLV(type: 0x01, value: Data([0x01])).encode())  // Just type

        let decoded = AXDP.Message.decodeMessage(from: data)

        // Should parse what it can
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .chat)
    }

    func testDecodeNewerVersionWithUnknownTLVs() {
        // Simulate newer version with unknown future TLVs
        var data = AXDP.magic
        data.append(AXDP.TLV(type: 0x01, value: Data([0x01])).encode())
        data.append(AXDP.TLV(type: 0x02, value: AXDP.encodeUInt32(1)).encode())
        data.append(AXDP.TLV(type: 0x03, value: AXDP.encodeUInt32(1)).encode())
        // Future unknown TLV type
        data.append(AXDP.TLV(type: 0x8F, value: Data([0x01, 0x02, 0x03, 0x04])).encode())

        let decoded = AXDP.Message.decodeMessage(from: data)

        // Should decode successfully, ignoring unknown TLV
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .chat)
    }

    func testDecodeMalformedDataDoesNotCrash() {
        // Various malformed inputs
        let testCases: [Data] = [
            Data(),                           // Empty
            Data([0x00]),                     // Too short
            Data("AXT1".utf8),                // Magic only
            Data("AXT1".utf8) + Data([0x01]), // Truncated TLV
            Data("XXXX".utf8) + Data([0x01, 0x00, 0x01, 0x01]),  // Wrong magic
        ]

        for (index, data) in testCases.enumerated() {
            let decoded = AXDP.Message.decodeMessage(from: data)
            // Should return nil, not crash
            XCTAssertNil(decoded, "Test case \(index) should return nil for malformed data")
        }
    }

    func testDecodeInvalidLengthDoesNotCrash() {
        // TLV with length exceeding data
        var data = AXDP.magic
        data.append(Data([0x01, 0xFF, 0xFF, 0x01]))  // Type=1, Length=65535, only 1 byte value

        let decoded = AXDP.Message.decodeMessage(from: data)
        XCTAssertNil(decoded)
    }

    // MARK: - Helper Function Tests

    func testEncodeDecodeUInt32() {
        let values: [UInt32] = [0, 1, 255, 256, 65535, 65536, UInt32.max]

        for value in values {
            let encoded = AXDP.encodeUInt32(value)
            XCTAssertEqual(encoded.count, 4)

            let decoded = AXDP.decodeUInt32(encoded)
            XCTAssertEqual(decoded, value, "Round-trip failed for \(value)")
        }
    }

    func testEncodeDecodeUInt16() {
        let values: [UInt16] = [0, 1, 255, 256, 65535]

        for value in values {
            let encoded = AXDP.encodeUInt16(value)
            XCTAssertEqual(encoded.count, 2)

            let decoded = AXDP.decodeUInt16(encoded)
            XCTAssertEqual(decoded, value, "Round-trip failed for \(value)")
        }
    }

    func testCRC32Calculation() {
        let data = Data("Hello, World!".utf8)
        let crc = AXDP.crc32(data)

        // CRC32 should be consistent
        XCTAssertEqual(AXDP.crc32(data), crc)

        // Different data should have different CRC
        let data2 = Data("Hello, World?".utf8)
        XCTAssertNotEqual(AXDP.crc32(data2), crc)
    }

    // MARK: - Message Type Tests

    func testAllMessageTypesEncodable() {
        let types: [AXDP.MessageType] = [.chat, .fileMeta, .fileChunk, .ack, .nack, .ping, .pong]

        for msgType in types {
            let msg = AXDP.Message(type: msgType, sessionId: 1, messageId: 1)
            let encoded = msg.encode()
            let decoded = AXDP.Message.decodeMessage(from: encoded)

            XCTAssertNotNil(decoded, "Failed to decode \(msgType)")
            XCTAssertEqual(decoded?.type, msgType)
        }
    }

    // MARK: - Round-Trip Tests

    func testFullMessageRoundTrip() {
        let payload = Data("The quick brown fox jumps over the lazy dog".utf8)
        let original = AXDP.Message(
            type: .fileChunk,
            sessionId: 0xDEADBEEF,
            messageId: 1000,
            chunkIndex: 5,
            totalChunks: 100,
            payload: payload,
            payloadCRC32: AXDP.crc32(payload),
            sackBitmap: Data([0xFF, 0x0F])
        )

        let encoded = original.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, original.type)
        XCTAssertEqual(decoded?.sessionId, original.sessionId)
        XCTAssertEqual(decoded?.messageId, original.messageId)
        XCTAssertEqual(decoded?.chunkIndex, original.chunkIndex)
        XCTAssertEqual(decoded?.totalChunks, original.totalChunks)
        XCTAssertEqual(decoded?.payload, original.payload)
        XCTAssertEqual(decoded?.payloadCRC32, original.payloadCRC32)
        XCTAssertEqual(decoded?.sackBitmap, original.sackBitmap)
    }

    // MARK: - SACK Bitmap Tests

    func testSACKBitmapSetAndGet() {
        var sack = AXDPSACKBitmap(baseChunk: 5, windowSize: 16)

        // Initially all bits are false
        XCTAssertFalse(sack.isReceived(chunk: 5))
        XCTAssertFalse(sack.isReceived(chunk: 10))

        // Mark chunk 7 as received
        sack.markReceived(chunk: 7)
        XCTAssertTrue(sack.isReceived(chunk: 7))
        XCTAssertFalse(sack.isReceived(chunk: 6))
    }

    func testSACKBitmapBaseAdvance() {
        var sack = AXDPSACKBitmap(baseChunk: 0, windowSize: 8)

        // Receive chunks 0, 1, 2 contiguously
        sack.markReceived(chunk: 0)
        sack.markReceived(chunk: 1)
        sack.markReceived(chunk: 2)

        // Also receive chunk 5 (gap at 3,4)
        sack.markReceived(chunk: 5)

        // Highest contiguous should be 2 (0,1,2 are contiguous)
        XCTAssertEqual(sack.highestContiguous, 2)

        // Missing chunks in window
        let missing = sack.missingChunks(upTo: 7)
        XCTAssertEqual(missing, [3, 4, 6, 7])
    }

    func testSACKBitmapEncodeDecode() {
        var sack = AXDPSACKBitmap(baseChunk: 10, windowSize: 16)
        sack.markReceived(chunk: 10)
        sack.markReceived(chunk: 12)
        sack.markReceived(chunk: 15)

        let encoded = sack.encode()
        let decoded = AXDPSACKBitmap.decode(from: encoded, baseChunk: 10, windowSize: 16)

        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.isReceived(chunk: 10))
        XCTAssertFalse(decoded!.isReceived(chunk: 11))
        XCTAssertTrue(decoded!.isReceived(chunk: 12))
        XCTAssertTrue(decoded!.isReceived(chunk: 15))
    }

    // MARK: - Message ID Tracker Tests

    func testMessageIdTrackerDeduplication() {
        var tracker = AXDPMessageIdTracker(windowSize: 100)

        // First time seeing message ID 1 - should not be duplicate
        XCTAssertFalse(tracker.isDuplicate(sessionId: 1, messageId: 1))

        // Second time - should be duplicate
        XCTAssertTrue(tracker.isDuplicate(sessionId: 1, messageId: 1))

        // Different session, same message ID - not duplicate
        XCTAssertFalse(tracker.isDuplicate(sessionId: 2, messageId: 1))
    }

    func testMessageIdTrackerWindowEviction() {
        var tracker = AXDPMessageIdTracker(windowSize: 3)

        // Fill window
        _ = tracker.isDuplicate(sessionId: 1, messageId: 1)
        _ = tracker.isDuplicate(sessionId: 1, messageId: 2)
        _ = tracker.isDuplicate(sessionId: 1, messageId: 3)

        // All should be duplicates now
        XCTAssertTrue(tracker.isDuplicate(sessionId: 1, messageId: 1))
        XCTAssertTrue(tracker.isDuplicate(sessionId: 1, messageId: 2))
        XCTAssertTrue(tracker.isDuplicate(sessionId: 1, messageId: 3))

        // Add one more - should evict oldest
        _ = tracker.isDuplicate(sessionId: 1, messageId: 4)

        // Message 1 should be evicted
        XCTAssertFalse(tracker.isDuplicate(sessionId: 1, messageId: 1))
    }

    // MARK: - Retry Policy Tests

    func testRetryPolicyExponentialBackoff() {
        let policy = AXDPRetryPolicy(
            maxRetries: 5,
            baseInterval: 2.0,
            maxInterval: 30.0,
            jitterFraction: 0.0  // Disable jitter for deterministic test
        )

        // First retry at base interval
        XCTAssertEqual(policy.retryInterval(attempt: 0), 2.0, accuracy: 0.01)

        // Second retry at 2 * base
        XCTAssertEqual(policy.retryInterval(attempt: 1), 4.0, accuracy: 0.01)

        // Third retry at 4 * base
        XCTAssertEqual(policy.retryInterval(attempt: 2), 8.0, accuracy: 0.01)

        // Should cap at maxInterval
        XCTAssertEqual(policy.retryInterval(attempt: 10), 30.0, accuracy: 0.01)
    }

    func testRetryPolicyShouldRetry() {
        let policy = AXDPRetryPolicy(maxRetries: 3, baseInterval: 1.0, maxInterval: 10.0)

        XCTAssertTrue(policy.shouldRetry(attempt: 0))
        XCTAssertTrue(policy.shouldRetry(attempt: 2))
        XCTAssertFalse(policy.shouldRetry(attempt: 3))  // Exceeded
    }

    // MARK: - Transfer State Tests

    func testTransferStateTracksSentChunks() {
        var state = AXDPTransferState(sessionId: 1, totalChunks: 10)

        XCTAssertEqual(state.pendingChunks.count, 10)
        XCTAssertFalse(state.isComplete)

        // Acknowledge chunk 0
        state.acknowledgeChunk(0)
        XCTAssertEqual(state.pendingChunks.count, 9)
        XCTAssertFalse(state.pendingChunks.contains(0))

        // Acknowledge all remaining
        for i in 1..<10 {
            state.acknowledgeChunk(UInt32(i))
        }
        XCTAssertTrue(state.isComplete)
    }

    func testTransferStateTracksRetries() {
        var state = AXDPTransferState(sessionId: 1, totalChunks: 5)

        XCTAssertEqual(state.retryCount(for: 0), 0)

        state.recordRetry(for: 0)
        XCTAssertEqual(state.retryCount(for: 0), 1)

        state.recordRetry(for: 0)
        state.recordRetry(for: 0)
        XCTAssertEqual(state.retryCount(for: 0), 3)
    }

    func testTransferStateWithSACK() {
        var state = AXDPTransferState(sessionId: 1, totalChunks: 8)

        // Create SACK acknowledging chunks 0, 2, 5
        var sack = AXDPSACKBitmap(baseChunk: 0, windowSize: 8)
        sack.markReceived(chunk: 0)
        sack.markReceived(chunk: 2)
        sack.markReceived(chunk: 5)

        state.applySelectiveAck(sack)

        // Should have 5 pending: 1, 3, 4, 6, 7
        XCTAssertEqual(state.pendingChunks.count, 5)
        XCTAssertFalse(state.pendingChunks.contains(0))
        XCTAssertTrue(state.pendingChunks.contains(1))
        XCTAssertFalse(state.pendingChunks.contains(2))
        XCTAssertTrue(state.pendingChunks.contains(3))
    }
}
