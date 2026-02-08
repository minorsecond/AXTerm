//
//  AXDPCapabilityTests.swift
//  AXTermTests
//
//  TDD tests for AXDP capability discovery (PING/PONG) and compression.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 6.x.3, 6.x.4
//

import XCTest
@testable import AXTerm

final class AXDPCapabilityTests: XCTestCase {

    // MARK: - Capability Sub-TLV Tests

    func testCapabilitySubTLVTypes() {
        // Verify capability sub-TLV type constants
        XCTAssertEqual(AXDPCapability.SubTLVType.protoMin.rawValue, 0x01)
        XCTAssertEqual(AXDPCapability.SubTLVType.protoMax.rawValue, 0x02)
        XCTAssertEqual(AXDPCapability.SubTLVType.featuresBitset.rawValue, 0x03)
        XCTAssertEqual(AXDPCapability.SubTLVType.compressionAlgos.rawValue, 0x04)
        XCTAssertEqual(AXDPCapability.SubTLVType.maxDecompressedLen.rawValue, 0x05)
        XCTAssertEqual(AXDPCapability.SubTLVType.maxChunkLen.rawValue, 0x06)
    }

    func testFeatureFlagsDefinition() {
        // Verify feature flag bit positions
        XCTAssertEqual(AXDPCapability.Features.sack.rawValue, 1 << 0)
        XCTAssertEqual(AXDPCapability.Features.resume.rawValue, 1 << 1)
        XCTAssertEqual(AXDPCapability.Features.compression.rawValue, 1 << 2)
        XCTAssertEqual(AXDPCapability.Features.extendedMetadata.rawValue, 1 << 3)
    }

    func testCompressionAlgorithmIds() {
        XCTAssertEqual(AXDPCompression.Algorithm.none.rawValue, 0)
        XCTAssertEqual(AXDPCompression.Algorithm.lz4.rawValue, 1)
        XCTAssertEqual(AXDPCompression.Algorithm.zstd.rawValue, 2)
        XCTAssertEqual(AXDPCompression.Algorithm.deflate.rawValue, 3)
    }

    // MARK: - Capability Encoding Tests

    func testEncodeCapabilities() {
        let caps = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.sack, .compression],
            compressionAlgos: [.lz4],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let encoded = caps.encode()

        // Should be non-empty
        XCTAssertFalse(encoded.isEmpty)

        // Should be decodable
        let decoded = AXDPCapability.decode(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.protoMin, 1)
        XCTAssertEqual(decoded?.protoMax, 1)
        XCTAssertTrue(decoded?.features.contains(.sack) ?? false)
        XCTAssertTrue(decoded?.features.contains(.compression) ?? false)
        XCTAssertEqual(decoded?.compressionAlgos, [.lz4])
        XCTAssertEqual(decoded?.maxDecompressedLen, 4096)
        XCTAssertEqual(decoded?.maxChunkLen, 128)
    }

    func testEncodeCapabilitiesMinimal() {
        let caps = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [],
            compressionAlgos: [],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let encoded = caps.encode()
        let decoded = AXDPCapability.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded?.features.isEmpty ?? false)
        XCTAssertTrue(decoded?.compressionAlgos.isEmpty ?? false)
    }

    func testDecodeCapabilitiesWithUnknownSubTLVs() {
        // Build capabilities with an unknown sub-TLV
        var data = Data()

        // ProtoMin
        data.append(0x01)  // type
        data.append(contentsOf: AXDP.encodeUInt16(1))  // length
        data.append(0x01)  // value

        // Unknown future sub-TLV (type 0x99)
        data.append(0x99)
        data.append(contentsOf: AXDP.encodeUInt16(4))
        data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        // ProtoMax
        data.append(0x02)
        data.append(contentsOf: AXDP.encodeUInt16(1))
        data.append(0x01)

        let decoded = AXDPCapability.decode(from: data)

        // Should decode successfully, skipping unknown sub-TLV
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.protoMin, 1)
        XCTAssertEqual(decoded?.protoMax, 1)
    }

    // MARK: - PING/PONG Message Tests

    func testEncodePingMessage() {
        let caps = AXDPCapability.defaultLocal()
        let ping = AXDP.Message(
            type: .ping,
            sessionId: 0,
            messageId: 1,
            capabilities: caps
        )

        let encoded = ping.encode()
        XCTAssertTrue(AXDP.hasMagic(encoded))

        let decoded = AXDP.Message.decodeMessage(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .ping)
        XCTAssertNotNil(decoded?.capabilities)
    }

    func testEncodePongMessage() {
        let caps = AXDPCapability.defaultLocal()
        let pong = AXDP.Message(
            type: .pong,
            sessionId: 0,
            messageId: 1,
            capabilities: caps
        )

        let encoded = pong.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .pong)
        XCTAssertNotNil(decoded?.capabilities)
    }

    // MARK: - Capability Cache Tests

    func testCapabilityCacheStorageAndRetrieval() {
        var cache = AXDPCapabilityCache()
        let caps = AXDPCapability.defaultLocal()
        let peerKey = AXDPPeerKey(callsign: "N0CALL", ssid: 0)

        // Initially empty
        XCTAssertNil(cache.get(for: peerKey))

        // Store
        cache.store(caps, for: peerKey)

        // Retrieve
        let retrieved = cache.get(for: peerKey)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.protoMax, caps.protoMax)
    }

    func testCapabilityCacheExpiry() {
        var cache = AXDPCapabilityCache(maxAge: 0.1)  // 100ms expiry
        let caps = AXDPCapability.defaultLocal()
        let peerKey = AXDPPeerKey(callsign: "N0CALL", ssid: 0)

        cache.store(caps, for: peerKey)
        XCTAssertNotNil(cache.get(for: peerKey))

        // Wait for expiry
        Thread.sleep(forTimeInterval: 0.15)

        XCTAssertNil(cache.get(for: peerKey))
    }

    func testCapabilityCacheNeedsNegotiation() {
        var cache = AXDPCapabilityCache()
        let peerKey = AXDPPeerKey(callsign: "N0CALL", ssid: 0)

        // No cache entry - needs negotiation
        XCTAssertTrue(cache.needsNegotiation(for: peerKey))

        // Store capabilities
        cache.store(AXDPCapability.defaultLocal(), for: peerKey)

        // Now has valid entry - doesn't need negotiation
        XCTAssertFalse(cache.needsNegotiation(for: peerKey))
    }

    // MARK: - Compression TLV Tests

    func testCompressionTLVEncoding() {
        // Use larger, more compressible data
        let original = Data(repeating: 0x42, count: 256)
        let compressed = AXDPCompression.compress(original, algorithm: .lz4)

        // LZ4 should compress repetitive data effectively
        if let c = compressed {
            XCTAssertLessThan(c.count, original.count)
        }
        // Note: compress() returns nil if compression doesn't reduce size
    }

    func testCompressionTLVDecoding() {
        let original = Data(repeating: 0x42, count: 256)  // Compressible data

        if let compressed = AXDPCompression.compress(original, algorithm: .lz4) {
            let decompressed = AXDPCompression.decompress(
                compressed,
                algorithm: .lz4,
                originalLength: UInt32(original.count),
                maxLength: 4096
            )

            XCTAssertNotNil(decompressed)
            XCTAssertEqual(decompressed, original)
        }
    }

    func testCompressionRejectsOversizedOutput() {
        let original = Data(repeating: 0x42, count: 256)

        if let compressed = AXDPCompression.compress(original, algorithm: .lz4) {
            // Try to decompress with a max length smaller than original
            let decompressed = AXDPCompression.decompress(
                compressed,
                algorithm: .lz4,
                originalLength: UInt32(original.count),
                maxLength: 100  // Too small
            )

            // Should reject due to maxLength
            XCTAssertNil(decompressed)
        }
    }

    func testCompressionMessageRoundTrip() {
        let payload = Data(repeating: 0x41, count: 200)

        let msg = AXDP.Message(
            type: .fileChunk,
            sessionId: 1,
            messageId: 1,
            chunkIndex: 0,
            totalChunks: 1,
            payload: payload,
            payloadCRC32: AXDP.crc32(payload),
            compression: .lz4
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileChunk)
        // Payload should be decompressed on decode
        XCTAssertEqual(decoded?.payload, payload)
    }

    func testNoneCompressionPassesThrough() {
        let payload = Data("Test".utf8)

        let msg = AXDP.Message(
            type: .chat,
            sessionId: 1,
            messageId: 1,
            payload: payload,
            compression: .none
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertEqual(decoded?.payload, payload)
    }

    // MARK: - Compression Guard Tests (Anti-Zip-Bomb)

    func testMaxDecompressedLenHardLimit() {
        // Hard limit is 8192 per spec
        XCTAssertEqual(AXDPCompression.absoluteMaxDecompressedLen, 8192)
    }

    func testDecompressionRejectsExceedingOriginalLength() {
        // Simulate a malicious payload claiming larger originalLength
        let smallData = Data([0x00, 0x01, 0x02])

        let result = AXDPCompression.decompress(
            smallData,
            algorithm: .lz4,
            originalLength: 10000,  // Claims large size
            maxLength: 4096
        )

        // Should reject because originalLength > maxLength
        XCTAssertNil(result)
    }

    // MARK: - Capability Negotiation Tests

    func testNegotiateSelectsCommonFeatures() {
        let local = AXDPCapability(
            protoMin: 1,
            protoMax: 2,
            features: [.sack, .compression, .resume],
            compressionAlgos: [.lz4, .zstd],
            maxDecompressedLen: 8192,
            maxChunkLen: 256
        )

        let remote = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.sack, .compression],
            compressionAlgos: [.lz4],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let negotiated = AXDPCapability.negotiate(local: local, remote: remote)

        // Should use lowest common protocol version
        XCTAssertEqual(negotiated.protoMax, 1)

        // Should intersect features
        XCTAssertTrue(negotiated.features.contains(.sack))
        XCTAssertTrue(negotiated.features.contains(.compression))
        XCTAssertFalse(negotiated.features.contains(.resume))

        // Should intersect compression algorithms
        XCTAssertEqual(negotiated.compressionAlgos, [.lz4])

        // Should use minimum of limits
        XCTAssertEqual(negotiated.maxDecompressedLen, 4096)
        XCTAssertEqual(negotiated.maxChunkLen, 128)
    }

    func testNegotiateWithNoCommonCompression() {
        let local = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.compression],
            compressionAlgos: [.lz4],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let remote = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.compression],
            compressionAlgos: [.zstd],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let negotiated = AXDPCapability.negotiate(local: local, remote: remote)

        // No common compression - should be empty
        XCTAssertTrue(negotiated.compressionAlgos.isEmpty)
    }

    // MARK: - FILE_META Tests

    func testFileMetaEncoding() {
        let meta = AXDPFileMeta(
            filename: "test.txt",
            fileSize: 1024,
            sha256: Data(repeating: 0xAB, count: 32),
            chunkSize: 128,
            description: "Test file"
        )

        let encoded = meta.encode()
        let decoded = AXDPFileMeta.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.filename, "test.txt")
        XCTAssertEqual(decoded?.fileSize, 1024)
        XCTAssertEqual(decoded?.sha256.count, 32)
        XCTAssertEqual(decoded?.chunkSize, 128)
        XCTAssertEqual(decoded?.description, "Test file")
    }

    func testFileMetaWithoutDescription() {
        let meta = AXDPFileMeta(
            filename: "data.bin",
            fileSize: 512,
            sha256: Data(repeating: 0x00, count: 32),
            chunkSize: 64,
            description: nil
        )

        let encoded = meta.encode()
        let decoded = AXDPFileMeta.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.filename, "data.bin")
        XCTAssertNil(decoded?.description)
    }

    func testFileMetaInMessage() {
        let meta = AXDPFileMeta(
            filename: "photo.jpg",
            fileSize: 50000,
            sha256: Data(repeating: 0x12, count: 32),
            chunkSize: 128,
            description: nil
        )

        let msg = AXDP.Message(
            type: .fileMeta,
            sessionId: 100,
            messageId: 1,
            fileMeta: meta
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileMeta)
        XCTAssertNotNil(decoded?.fileMeta)
        XCTAssertEqual(decoded?.fileMeta?.filename, "photo.jpg")
        XCTAssertEqual(decoded?.fileMeta?.fileSize, 50000)
    }

    // MARK: - Backward Compatibility Tests

    func testDecodePeerWithoutCapabilities() {
        // Simulate older peer sending PING without capabilities TLV
        var data = AXDP.magic
        data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.ping.rawValue])).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(0)).encode())
        data.append(AXDP.TLV(type: AXDP.TLVType.messageId.rawValue, value: AXDP.encodeUInt32(1)).encode())

        let decoded = AXDP.Message.decodeMessage(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .ping)
        XCTAssertNil(decoded?.capabilities)  // No capabilities = legacy peer
    }

    func testDecodeUnknownCompressionAlgorithm() {
        // Peer advertises unknown compression algorithm
        let caps = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [.compression],
            compressionAlgos: [],  // Will add unknown manually
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        var data = caps.encode()
        // Append unknown compression algo (0xFF)
        data.append(AXDPCapability.SubTLVType.compressionAlgos.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(2))
        data.append(contentsOf: [0x01, 0xFF])  // LZ4 + unknown

        let decoded = AXDPCapability.decode(from: data)

        XCTAssertNotNil(decoded)
        // Should only include known algorithm
        XCTAssertEqual(decoded?.compressionAlgos, [.lz4])
    }

    func testReceiveCompressedFromPeerWithoutNegotiation() {
        // If we receive compressed data without prior negotiation,
        // we should still try to decompress it (be liberal in receiving)
        let payload = Data(repeating: 0x42, count: 100)

        if let compressed = AXDPCompression.compress(payload, algorithm: .lz4) {
            // Build message manually with compression TLVs
            var data = AXDP.magic
            data.append(AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([AXDP.MessageType.fileChunk.rawValue])).encode())
            data.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(1)).encode())
            data.append(AXDP.TLV(type: AXDP.TLVType.messageId.rawValue, value: AXDP.encodeUInt32(1)).encode())
            data.append(AXDP.TLV(type: AXDP.TLVType.compression.rawValue, value: Data([AXDPCompression.Algorithm.lz4.rawValue])).encode())
            data.append(AXDP.TLV(type: AXDP.TLVType.originalLength.rawValue, value: AXDP.encodeUInt32(UInt32(payload.count))).encode())
            data.append(AXDP.TLV(type: AXDP.TLVType.payloadCompressed.rawValue, value: compressed).encode())

            let decoded = AXDP.Message.decodeMessage(from: data)

            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.payload, payload)
        }
    }
}
