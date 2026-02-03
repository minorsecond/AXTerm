//
//  AXDPCompatibilityTests.swift
//  AXTermTests
//
//  Comprehensive backwards/forwards compatibility tests for AXDP.
//  Critical: AXDP MUST remain compatible with all versions of itself
//  and gracefully handle non-AXDP standard packet users.
//
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 6, transmitting.md
//

import XCTest
@testable import AXTerm

final class AXDPCompatibilityTests: XCTestCase {

    // MARK: - Backwards Compatibility: Older AXDP Versions

    func testDecodeAXDPv1MinimalMessage() {
        // Simulate oldest possible v1 message: just magic + messageType
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.chat.rawValue])).encode())

        let decoded = AXDP.Message.decode(from: data)

        XCTAssertNotNil(decoded, "Should decode minimal v1 message")
        XCTAssertEqual(decoded?.type, .chat)
        // Missing fields should have defaults
        XCTAssertEqual(decoded?.sessionId, 0)
        XCTAssertEqual(decoded?.messageId, 0)
    }

    func testDecodeAXDPv1WithoutSessionId() {
        // v1 message with type and messageId but no sessionId
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.ack.rawValue])).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.messageId.rawValue, value: AXDP.encodeUInt32(42)).encode())

        let decoded = AXDP.Message.decode(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .ack)
        XCTAssertEqual(decoded?.messageId, 42)
        XCTAssertEqual(decoded?.sessionId, 0)  // Default
    }

    func testDecodeAXDPv1WithoutCapabilities() {
        // Old peer sending PING without capabilities TLV
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.ping.rawValue])).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(0)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.messageId.rawValue, value: AXDP.encodeUInt32(1)).encode())

        let decoded = AXDP.Message.decode(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .ping)
        XCTAssertNil(decoded?.capabilities)  // Legacy peer has no caps
    }

    func testDecodeAXDPv1FileChunkWithoutCompression() {
        // Old-style file chunk without compression TLVs
        let payload = Data(repeating: 0x42, count: 64)
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.fileChunk.rawValue])).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(100)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.messageId.rawValue, value: AXDP.encodeUInt32(5)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.chunkIndex.rawValue, value: AXDP.encodeUInt32(0)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.totalChunks.rawValue, value: AXDP.encodeUInt32(10)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.payload.rawValue, value: payload).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.payloadCRC32.rawValue, value: AXDP.encodeUInt32(AXDP.crc32(payload))).encode())

        let decoded = AXDP.Message.decode(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileChunk)
        XCTAssertEqual(decoded?.payload, payload)
        XCTAssertEqual(decoded?.compression, AXDPCompression.Algorithm.none)  // No compression used
    }

    // MARK: - Forwards Compatibility: Future AXDP Versions

    func testDecodeAXDPWithUnknownTLVTypes() {
        // Future version with TLVs we don't understand (0x40-0x7F range)
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.chat.rawValue])).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(1)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.messageId.rawValue, value: AXDP.encodeUInt32(1)).encode())
        // Unknown future TLVs
        data.append(AXDP.TLV(type: 0x40, value: Data([0x01, 0x02, 0x03, 0x04])).encode())
        data.append(AXDP.TLV(type: 0x50, value: Data(repeating: 0xFF, count: 100)).encode())
        data.append(AXDP.TLV(type: 0x7F, value: Data()).encode())
        // Known TLV after unknown ones
        data.append(AXDP.TLV(type: AXDP.TLVType.payload.rawValue, value: Data("Hello".utf8)).encode())

        let decoded = AXDP.Message.decode(from: data)

        XCTAssertNotNil(decoded, "Should decode despite unknown TLVs")
        XCTAssertEqual(decoded?.type, .chat)
        XCTAssertEqual(decoded?.payload, Data("Hello".utf8))
        XCTAssertEqual(decoded?.unknownTLVs.count, 3, "Should preserve unknown TLVs")
    }

    func testDecodeAXDPWithExperimentalTLVs() {
        // Experimental/private range: 0x80-0xFF
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.chat.rawValue])).encode())
        data.append(AXDP.TLV(type: 0x80, value: Data([0xDE, 0xAD])).encode())
        data.append(AXDP.TLV(type: 0xFE, value: Data([0xBE, 0xEF])).encode())
        data.append(AXDP.TLV(type: 0xFF, value: Data()).encode())

        let decoded = AXDP.Message.decode(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.unknownTLVs.count, 3)
    }

    func testDecodeAXDPWithFutureMessageType() {
        // Message type value that doesn't exist yet (0x10+)
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([0x10])).encode())  // Unknown type

        let decoded = AXDP.Message.decode(from: data)

        // Should fail gracefully for completely unknown message type
        XCTAssertNil(decoded, "Unknown message type should return nil")
    }

    func testDecodeAXDPWithFutureCapabilities() {
        // Peer advertising capabilities we don't understand
        var capData = Data()
        // Known: protoMin
        capData.append(AXDPCapability.SubTLVType.protoMin.rawValue)
        capData.append(contentsOf: AXDP.encodeUInt16(1))
        capData.append(0x01)
        // Known: protoMax
        capData.append(AXDPCapability.SubTLVType.protoMax.rawValue)
        capData.append(contentsOf: AXDP.encodeUInt16(1))
        capData.append(0x02)  // Future version 2
        // Unknown sub-TLV
        capData.append(0x10)  // Unknown capability sub-TLV
        capData.append(contentsOf: AXDP.encodeUInt16(4))
        capData.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        // Unknown feature flag
        capData.append(AXDPCapability.SubTLVType.featuresBitset.rawValue)
        capData.append(contentsOf: AXDP.encodeUInt16(4))
        capData.append(contentsOf: AXDP.encodeUInt32(0xFFFFFFFF))  // All flags set including future ones

        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.pong.rawValue])).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(0)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.messageId.rawValue, value: AXDP.encodeUInt32(1)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.capabilities.rawValue, value: capData).encode())

        let decoded = AXDP.Message.decode(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .pong)
        XCTAssertNotNil(decoded?.capabilities)
        // Should only recognize known features
        XCTAssertTrue(decoded?.capabilities?.features.contains(.sack) ?? false)
        XCTAssertTrue(decoded?.capabilities?.features.contains(.compression) ?? false)
    }

    func testDecodeAXDPWithFutureCompressionAlgorithm() {
        // Peer using unknown compression algorithm
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.fileChunk.rawValue])).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(1)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.messageId.rawValue, value: AXDP.encodeUInt32(1)).encode())
        // Unknown compression algorithm (0xFF)
        data.append(AXDP.TLV(type: AXDP.TLVType.compression.rawValue, value: Data([0xFF])).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.originalLength.rawValue, value: AXDP.encodeUInt32(100)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.payloadCompressed.rawValue, value: Data(repeating: 0x42, count: 50)).encode())

        let decoded = AXDP.Message.decode(from: data)

        // Should decode but payload might be nil (can't decompress unknown algo)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileChunk)
    }

    // MARK: - Mixed Mode: AXDP Over UI and Connected Frames

    func testAXDPPayloadInUIFrame() {
        // AXDP message should work in UI frame
        let axdpMsg = AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("Hello".utf8))
        let axdpPayload = axdpMsg.encode()

        // Build UI frame with AXDP payload
        let from = AX25Address(call: "N0CALL", ssid: 0)
        let to = AX25Address(call: "K0ABC", ssid: 0)
        let uiFrame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: axdpPayload)

        // Decode the UI frame
        let decodedFrame = AX25.decodeFrame(ax25: uiFrame)
        XCTAssertNotNil(decodedFrame)
        XCTAssertEqual(decodedFrame?.frameType, .ui)

        // Extract and decode AXDP from info field
        if let info = decodedFrame?.info {
            XCTAssertTrue(AXDP.hasMagic(info), "Info should contain AXDP magic")
            let decodedAXDP = AXDP.Message.decode(from: info)
            XCTAssertNotNil(decodedAXDP)
            XCTAssertEqual(decodedAXDP?.type, .chat)
            XCTAssertEqual(decodedAXDP?.payload, Data("Hello".utf8))
        }
    }

    func testAXDPDetectionInMixedTraffic() {
        // Non-AXDP plain text
        let plainText = Data("Hello from legacy station".utf8)
        XCTAssertFalse(AXDP.hasMagic(plainText))

        // AXDP message
        let axdpMsg = AXDP.Message(type: .chat, sessionId: 1, messageId: 1).encode()
        XCTAssertTrue(AXDP.hasMagic(axdpMsg))

        // Data that starts with AXT but not AXT1
        let almostAXDP = Data("AXT2 something".utf8)
        XCTAssertFalse(AXDP.hasMagic(almostAXDP))

        // Binary data that happens to contain AXT1
        var binaryWithMagic = Data([0x00, 0x01, 0x02])
        binaryWithMagic.append(AXDP.magic)
        binaryWithMagic.append(Data([0x03, 0x04]))
        XCTAssertFalse(AXDP.hasMagic(binaryWithMagic))  // Magic must be at start
    }

    // MARK: - Compatibility with Standard Packet (Non-AXDP Users)

    func testPlainTextUIFrameCompatibility() {
        // Standard packet user sending plain text
        let from = AX25Address(call: "LEGACY", ssid: 0)
        let to = AX25Address(call: "CQ", ssid: 0)
        let plainInfo = Data("Hello, this is a plain text message!".utf8)

        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: plainInfo)
        let decoded = AX25.decodeFrame(ax25: frame)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, plainInfo)
        XCTAssertFalse(AXDP.hasMagic(decoded?.info ?? Data()))

        // Should be displayable as text
        if let text = String(data: plainInfo, encoding: .utf8) {
            XCTAssertEqual(text, "Hello, this is a plain text message!")
        }
    }

    func testAXDPMessageDisplaysToLegacy() {
        // When AXDP is displayed to legacy monitor, it should show "AXT1" prefix
        let msg = AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("Test".utf8))
        let encoded = msg.encode()

        // First 4 bytes should be readable ASCII
        let prefix = String(data: encoded.prefix(4), encoding: .ascii)
        XCTAssertEqual(prefix, "AXT1", "AXDP should have readable ASCII prefix for legacy displays")
    }

    func testBinaryPayloadInStandardFrame() {
        // Standard packet with binary data (not AXDP)
        let binaryData = Data([0x00, 0x01, 0xFF, 0xFE, 0x42, 0x00])
        let from = AX25Address(call: "TEST", ssid: 0)
        let to = AX25Address(call: "DEST", ssid: 0)

        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: binaryData)
        let decoded = AX25.decodeFrame(ax25: frame)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, binaryData)
        XCTAssertFalse(AXDP.hasMagic(decoded?.info ?? Data()))
    }

    // MARK: - TLV Length Edge Cases

    func testDecodeTLVWithExactlyZeroLength() {
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.chat.rawValue])).encode())
        // TLV with zero-length value (valid)
        data.append(Data([0x09, 0x00, 0x00]))  // metadata TLV with empty value

        let decoded = AXDP.Message.decode(from: data)
        XCTAssertNotNil(decoded)
    }

    func testDecodeTLVWithMaxUInt16Length() {
        // TLV claiming maximum length (65535 bytes)
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.chat.rawValue])).encode())
        // Very large TLV
        data.append(Data([0x06, 0xFF, 0xFF]))  // payload type, length 65535
        data.append(Data(repeating: 0x42, count: 65535))

        let decoded = AXDP.Message.decode(from: data)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.payload?.count, 65535)
    }

    func testDecodeTLVWithLengthExceedingData() {
        // Malformed: TLV claims more bytes than available
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.chat.rawValue])).encode())
        // Claims 1000 bytes but only provides 10
        data.append(Data([0x06, 0x03, 0xE8]))  // type=6, length=1000
        data.append(Data(repeating: 0x42, count: 10))

        let decoded = AXDP.Message.decode(from: data)
        // Should handle gracefully - either partial decode or nil
        // The important thing is no crash
        XCTAssertNotNil(decoded)  // Should still decode the chat type
    }

    // MARK: - Version Negotiation Edge Cases

    func testNegotiateWithIdenticalCapabilities() {
        let caps = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.sack, .compression],
            compressionAlgos: [.lz4, .zstd],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let negotiated = AXDPCapability.negotiate(local: caps, remote: caps)

        XCTAssertEqual(negotiated.protoMin, 1)
        XCTAssertEqual(negotiated.protoMax, 1)
        XCTAssertTrue(negotiated.features.contains(.sack))
        XCTAssertTrue(negotiated.features.contains(.compression))
        XCTAssertEqual(negotiated.compressionAlgos, [.lz4, .zstd])
    }

    func testNegotiateWithNoOverlappingFeatures() {
        let local = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.sack],
            compressionAlgos: [.lz4],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let remote = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.resume],
            compressionAlgos: [.deflate],
            maxDecompressedLen: 8192,
            maxChunkLen: 256
        )

        let negotiated = AXDPCapability.negotiate(local: local, remote: remote)

        // No common features
        XCTAssertTrue(negotiated.features.isEmpty)
        // No common compression
        XCTAssertTrue(negotiated.compressionAlgos.isEmpty)
        // Should use minimum of limits
        XCTAssertEqual(negotiated.maxDecompressedLen, 4096)
        XCTAssertEqual(negotiated.maxChunkLen, 128)
    }

    func testNegotiatePreservesCompressionOrder() {
        let local = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.compression],
            compressionAlgos: [.zstd, .lz4, .deflate],  // Local preference order
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let remote = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.compression],
            compressionAlgos: [.lz4, .deflate],  // Remote supports these
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let negotiated = AXDPCapability.negotiate(local: local, remote: remote)

        // Should preserve local preference order, filtered by remote support
        XCTAssertEqual(negotiated.compressionAlgos, [.lz4, .deflate])
    }

    // MARK: - Robustness Tests

    func testDecodeMalformedMagicDoesNotCrash() {
        let testCases: [Data] = [
            Data(),                           // Empty
            Data([0x41]),                     // "A" only
            Data([0x41, 0x58]),               // "AX" only
            Data([0x41, 0x58, 0x54]),         // "AXT" only
            Data("AXT2".utf8),                // Wrong version
            Data("AYT1".utf8),                // Wrong magic
            Data("axt1".utf8),                // Wrong case
            Data([0x00, 0x00, 0x00, 0x00]),   // Null bytes
            Data([0xFF, 0xFF, 0xFF, 0xFF]),   // All 1s
        ]

        for testCase in testCases {
            let decoded = AXDP.Message.decode(from: testCase)
            XCTAssertNil(decoded, "Should return nil for invalid magic: \(testCase.map { String(format: "%02X", $0) }.joined())")
        }
    }

    func testDecodePartiallyCorruptedMessage() {
        // Valid start, then garbage in middle, then valid TLV
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.chat.rawValue])).encode())
        // Garbage bytes that look like a TLV header but with invalid length
        data.append(Data([0x50, 0xFF, 0xFE]))  // Claims huge length
        // This won't be reached due to above

        let decoded = AXDP.Message.decode(from: data)
        // Should at least decode the message type
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .chat)
    }

    func testDecodeRepeatedTLVTypes() {
        // Same TLV type appearing multiple times (should use last or first consistently)
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.chat.rawValue])).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(100)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(200)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(300)).encode())

        let decoded = AXDP.Message.decode(from: data)
        XCTAssertNotNil(decoded)
        // Implementation-dependent: check it handles consistently without crash
    }

    // MARK: - Round-Trip Tests

    func testFullMessageRoundTripAllTypes() {
        let messageTypes: [AXDP.MessageType] = [.chat, .fileMeta, .fileChunk, .ack, .nack, .ping, .pong]

        for msgType in messageTypes {
            let original = AXDP.Message(
                type: msgType,
                sessionId: UInt32.random(in: 0...UInt32.max),
                messageId: UInt32.random(in: 0...UInt32.max)
            )

            let encoded = original.encode()
            let decoded = AXDP.Message.decode(from: encoded)

            XCTAssertNotNil(decoded, "Round-trip failed for \(msgType)")
            XCTAssertEqual(decoded?.type, original.type)
            XCTAssertEqual(decoded?.sessionId, original.sessionId)
            XCTAssertEqual(decoded?.messageId, original.messageId)
        }
    }

    func testFileChunkRoundTripWithCRC() {
        let payload = Data((0..<200).map { UInt8($0 % 256) })
        let crc = AXDP.crc32(payload)

        let original = AXDP.Message(
            type: .fileChunk,
            sessionId: 12345,
            messageId: 1,
            chunkIndex: 5,
            totalChunks: 100,
            payload: payload,
            payloadCRC32: crc
        )

        let encoded = original.encode()
        let decoded = AXDP.Message.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.payload, payload)
        XCTAssertEqual(decoded?.payloadCRC32, crc)
        XCTAssertEqual(decoded?.chunkIndex, 5)
        XCTAssertEqual(decoded?.totalChunks, 100)
    }

    func testCapabilityRoundTrip() {
        let original = AXDPCapability(
            protoMin: 1,
            protoMax: 2,
            features: [.sack, .compression, .resume, .extendedMetadata],
            compressionAlgos: [.lz4, .zstd, .deflate],
            maxDecompressedLen: 8192,
            maxChunkLen: 256
        )

        let encoded = original.encode()
        let decoded = AXDPCapability.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.protoMin, original.protoMin)
        XCTAssertEqual(decoded?.protoMax, original.protoMax)
        XCTAssertEqual(decoded?.features, original.features)
        XCTAssertEqual(decoded?.compressionAlgos, original.compressionAlgos)
        XCTAssertEqual(decoded?.maxDecompressedLen, original.maxDecompressedLen)
        XCTAssertEqual(decoded?.maxChunkLen, original.maxChunkLen)
    }
}
