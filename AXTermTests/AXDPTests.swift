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

        let tlvs = AXDP.decodeTLVs(from: data)

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

        let tlvs = AXDP.decodeTLVs(from: data)

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
        let decoded = AXDP.Message.decode(from: encoded)
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
        let decoded = AXDP.Message.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileChunk)
        XCTAssertEqual(decoded?.chunkIndex, 3)
        XCTAssertEqual(decoded?.totalChunks, 10)
        XCTAssertEqual(decoded?.payloadCRC32, AXDP.crc32(payload))
    }

    func testEncodeAckMessage() {
        let msg = AXDP.Message(
            type: .ack,
            sessionId: 1,
            messageId: 42
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .ack)
        XCTAssertEqual(decoded?.messageId, 42)
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
        let decoded = AXDP.Message.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.sackBitmap, sackBitmap)
    }

    // MARK: - Compatibility Tests (Critical for AXDP)

    func testDecodeOlderVersionSafely() {
        // Simulate older version with fewer TLVs
        var data = AXDP.magic
        data.append(AXDP.TLV(type: 0x01, value: Data([0x01])).encode())  // Just type

        let decoded = AXDP.Message.decode(from: data)

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

        let decoded = AXDP.Message.decode(from: data)

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
            let decoded = AXDP.Message.decode(from: data)
            // Should return nil, not crash
            XCTAssertNil(decoded, "Test case \(index) should return nil for malformed data")
        }
    }

    func testDecodeInvalidLengthDoesNotCrash() {
        // TLV with length exceeding data
        var data = AXDP.magic
        data.append(Data([0x01, 0xFF, 0xFF, 0x01]))  // Type=1, Length=65535, only 1 byte value

        let decoded = AXDP.Message.decode(from: data)
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
            let decoded = AXDP.Message.decode(from: encoded)

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
        let decoded = AXDP.Message.decode(from: encoded)

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
}
