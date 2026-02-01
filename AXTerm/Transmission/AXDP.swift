//
//  AXDP.swift
//  AXTerm
//
//  AXTerm Datagram Protocol - TLV-based application protocol for packet radio.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 6
//
//  IMPORTANT: Unknown TLVs MUST be safely skipped for forward compatibility.
//  Sending may be conservative; receiving must be liberal.
//

import Foundation

/// AXTerm Datagram Protocol - application-layer reliability over AX.25 UI/I frames.
enum AXDP {

    // MARK: - Protocol Constants

    /// Magic header identifying AXDP payloads: "AXT1"
    static let magic = Data("AXT1".utf8)

    /// Current protocol version
    static let version: UInt8 = 1

    // MARK: - TLV Type Constants

    /// Core TLV types (0x01-0x1F reserved)
    enum TLVType: UInt8 {
        case messageType    = 0x01
        case sessionId      = 0x02
        case messageId      = 0x03
        case chunkIndex     = 0x04
        case totalChunks    = 0x05
        case payload        = 0x06
        case payloadCRC32   = 0x07
        case sackBitmap     = 0x08
        case metadata       = 0x09

        // Capabilities (0x20-0x2F)
        case capabilities   = 0x20
        case ackedMessageId = 0x21

        // Compression (0x30-0x3F)
        case compression        = 0x30
        case originalLength     = 0x31
        case payloadCompressed  = 0x32
    }

    // MARK: - Message Types

    /// AXDP message types
    enum MessageType: UInt8, Codable {
        case chat       = 1
        case fileMeta   = 2
        case fileChunk  = 3
        case ack        = 4
        case nack       = 5
        case ping       = 6
        case pong       = 7
    }

    // MARK: - TLV Structure

    /// Type-Length-Value structure for AXDP encoding
    struct TLV {
        let type: UInt8
        let value: Data

        /// Encode TLV to bytes: type (1) + length (2, big-endian) + value
        func encode() -> Data {
            var data = Data()
            data.append(type)
            data.append(encodeUInt16(UInt16(value.count)))
            data.append(value)
            return data
        }

        /// Decode result containing TLV and next offset
        struct DecodeResult {
            let tlv: TLV
            let nextOffset: Int
        }

        /// Decode a TLV from data at given offset.
        /// Returns nil if data is truncated or malformed.
        static func decode(from data: Data, at offset: Int) -> DecodeResult? {
            // Need at least 3 bytes: type (1) + length (2)
            guard offset + 3 <= data.count else { return nil }

            let type = data[offset]
            let length = decodeUInt16(data.subdata(in: (offset + 1)..<(offset + 3)))

            let valueStart = offset + 3
            let valueEnd = valueStart + Int(length)

            // Check value doesn't exceed data
            guard valueEnd <= data.count else { return nil }

            let value = data.subdata(in: valueStart..<valueEnd)
            return DecodeResult(tlv: TLV(type: type, value: value), nextOffset: valueEnd)
        }
    }

    // MARK: - Message Structure

    /// AXDP message containing decoded TLV fields
    struct Message {
        var type: MessageType = .chat
        var sessionId: UInt32 = 0
        var messageId: UInt32 = 0
        var chunkIndex: UInt32?
        var totalChunks: UInt32?
        var payload: Data?
        var payloadCRC32: UInt32?
        var sackBitmap: Data?
        var metadata: Data?

        // Unknown TLVs preserved for forward compatibility
        var unknownTLVs: [TLV] = []

        init(
            type: MessageType,
            sessionId: UInt32,
            messageId: UInt32,
            chunkIndex: UInt32? = nil,
            totalChunks: UInt32? = nil,
            payload: Data? = nil,
            payloadCRC32: UInt32? = nil,
            sackBitmap: Data? = nil,
            metadata: Data? = nil
        ) {
            self.type = type
            self.sessionId = sessionId
            self.messageId = messageId
            self.chunkIndex = chunkIndex
            self.totalChunks = totalChunks
            self.payload = payload
            self.payloadCRC32 = payloadCRC32
            self.sackBitmap = sackBitmap
            self.metadata = metadata
        }

        /// Encode message to bytes with magic header + TLVs
        func encode() -> Data {
            var data = AXDP.magic

            // MessageType (required)
            data.append(TLV(type: TLVType.messageType.rawValue, value: Data([type.rawValue])).encode())

            // SessionId (required)
            data.append(TLV(type: TLVType.sessionId.rawValue, value: encodeUInt32(sessionId)).encode())

            // MessageId (required)
            data.append(TLV(type: TLVType.messageId.rawValue, value: encodeUInt32(messageId)).encode())

            // Optional fields
            if let chunkIndex = chunkIndex {
                data.append(TLV(type: TLVType.chunkIndex.rawValue, value: encodeUInt32(chunkIndex)).encode())
            }

            if let totalChunks = totalChunks {
                data.append(TLV(type: TLVType.totalChunks.rawValue, value: encodeUInt32(totalChunks)).encode())
            }

            if let payload = payload, !payload.isEmpty {
                data.append(TLV(type: TLVType.payload.rawValue, value: payload).encode())
            }

            if let crc = payloadCRC32 {
                data.append(TLV(type: TLVType.payloadCRC32.rawValue, value: encodeUInt32(crc)).encode())
            }

            if let sack = sackBitmap, !sack.isEmpty {
                data.append(TLV(type: TLVType.sackBitmap.rawValue, value: sack).encode())
            }

            if let meta = metadata, !meta.isEmpty {
                data.append(TLV(type: TLVType.metadata.rawValue, value: meta).encode())
            }

            return data
        }

        /// Decode message from bytes.
        /// Returns nil if magic header is missing or data is malformed.
        /// Unknown TLVs are safely skipped (forward compatibility).
        static func decode(from data: Data) -> Message? {
            // Check magic header
            guard hasMagic(data) else { return nil }

            // Parse TLVs after magic
            let tlvData = data.subdata(in: magic.count..<data.count)
            let tlvs = decodeTLVs(from: tlvData)

            guard !tlvs.isEmpty else { return nil }

            // Build message from TLVs
            var msg = Message(type: .chat, sessionId: 0, messageId: 0)
            var hasType = false

            for tlv in tlvs {
                switch tlv.type {
                case TLVType.messageType.rawValue:
                    if let rawType = tlv.value.first, let msgType = MessageType(rawValue: rawType) {
                        msg.type = msgType
                        hasType = true
                    }

                case TLVType.sessionId.rawValue:
                    if tlv.value.count >= 4 {
                        msg.sessionId = decodeUInt32(tlv.value)
                    }

                case TLVType.messageId.rawValue:
                    if tlv.value.count >= 4 {
                        msg.messageId = decodeUInt32(tlv.value)
                    }

                case TLVType.chunkIndex.rawValue:
                    if tlv.value.count >= 4 {
                        msg.chunkIndex = decodeUInt32(tlv.value)
                    }

                case TLVType.totalChunks.rawValue:
                    if tlv.value.count >= 4 {
                        msg.totalChunks = decodeUInt32(tlv.value)
                    }

                case TLVType.payload.rawValue:
                    msg.payload = tlv.value

                case TLVType.payloadCRC32.rawValue:
                    if tlv.value.count >= 4 {
                        msg.payloadCRC32 = decodeUInt32(tlv.value)
                    }

                case TLVType.sackBitmap.rawValue:
                    msg.sackBitmap = tlv.value

                case TLVType.metadata.rawValue:
                    msg.metadata = tlv.value

                default:
                    // Unknown TLV - preserve for forward compatibility
                    msg.unknownTLVs.append(tlv)
                }
            }

            // Must have at least message type
            guard hasType else { return nil }

            return msg
        }
    }

    // MARK: - Helper Functions

    /// Check if data starts with AXDP magic header
    static func hasMagic(_ data: Data) -> Bool {
        guard data.count >= magic.count else { return false }
        return data.prefix(magic.count) == magic
    }

    /// Decode all TLVs from data, skipping malformed ones
    static func decodeTLVs(from data: Data) -> [TLV] {
        var tlvs: [TLV] = []
        var offset = 0

        while offset < data.count {
            guard let result = TLV.decode(from: data, at: offset) else {
                break  // Stop on malformed TLV
            }
            tlvs.append(result.tlv)
            offset = result.nextOffset
        }

        return tlvs
    }

    // MARK: - Integer Encoding (Big-Endian)

    /// Encode UInt32 to 4 bytes big-endian
    static func encodeUInt32(_ value: UInt32) -> Data {
        var data = Data(count: 4)
        data[0] = UInt8((value >> 24) & 0xFF)
        data[1] = UInt8((value >> 16) & 0xFF)
        data[2] = UInt8((value >> 8) & 0xFF)
        data[3] = UInt8(value & 0xFF)
        return data
    }

    /// Decode UInt32 from big-endian bytes
    static func decodeUInt32(_ data: Data) -> UInt32 {
        guard data.count >= 4 else { return 0 }
        return (UInt32(data[0]) << 24) |
               (UInt32(data[1]) << 16) |
               (UInt32(data[2]) << 8) |
               UInt32(data[3])
    }

    /// Encode UInt16 to 2 bytes big-endian
    static func encodeUInt16(_ value: UInt16) -> Data {
        var data = Data(count: 2)
        data[0] = UInt8((value >> 8) & 0xFF)
        data[1] = UInt8(value & 0xFF)
        return data
    }

    /// Decode UInt16 from big-endian bytes
    static func decodeUInt16(_ data: Data) -> UInt16 {
        guard data.count >= 2 else { return 0 }
        return (UInt16(data[0]) << 8) | UInt16(data[1])
    }

    // MARK: - CRC32 Calculation

    /// Calculate CRC32 checksum (IEEE polynomial)
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF

        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320  // IEEE polynomial
                } else {
                    crc >>= 1
                }
            }
        }

        return crc ^ 0xFFFFFFFF
    }
}
