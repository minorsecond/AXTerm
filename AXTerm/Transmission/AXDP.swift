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

        // Extensions (0x40-0x4F)
        case transferMetrics    = 0x40
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

        // Capability discovery (Section 6.x.3)
        var capabilities: AXDPCapability?

        // Compression (Section 6.x.4)
        var compression: AXDPCompression.Algorithm = .none

        // File metadata (Section 9.2)
        var fileMeta: AXDPFileMeta?

        // Transfer metrics (extension)
        var transferMetrics: AXDPTransferMetrics?

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
            metadata: Data? = nil,
            capabilities: AXDPCapability? = nil,
            compression: AXDPCompression.Algorithm = .none,
            fileMeta: AXDPFileMeta? = nil,
            transferMetrics: AXDPTransferMetrics? = nil
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
            self.capabilities = capabilities
            self.compression = compression
            self.fileMeta = fileMeta
            self.transferMetrics = transferMetrics
        }

        /// Encode message to bytes with magic header + TLVs
        func encode() -> Data {
            var data = AXDP.magic

            TxLog.axdpEncode(
                type: String(describing: type),
                sessionId: UInt16(sessionId & 0xFFFF),
                messageId: messageId,
                payloadSize: payload?.count ?? 0
            )

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

            // For FILE_META messages with whole-file compression, encode the compression algorithm
            // separately from payload compression. This tells the receiver to decompress the entire
            // file after reassembly, not individual message payloads.
            if type == .fileMeta && compression != .none {
                data.append(TLV(type: TLVType.compression.rawValue, value: Data([compression.rawValue])).encode())
            }

            // Handle payload with optional per-message compression
            if let payload = payload, !payload.isEmpty {
                // For non-FILE_META messages, compression means compress THIS payload
                if type != .fileMeta && compression != .none,
                   let compressed = AXDPCompression.compress(payload, algorithm: compression) {
                    // Compression successful - use compressed TLVs
                    data.append(TLV(type: TLVType.compression.rawValue, value: Data([compression.rawValue])).encode())
                    data.append(TLV(type: TLVType.originalLength.rawValue, value: encodeUInt32(UInt32(payload.count))).encode())
                    data.append(TLV(type: TLVType.payloadCompressed.rawValue, value: compressed).encode())
                } else {
                    // No compression or compression failed - use raw payload
                    data.append(TLV(type: TLVType.payload.rawValue, value: payload).encode())
                }
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

            // Capabilities (for PING/PONG)
            if let caps = capabilities {
                data.append(TLV(type: TLVType.capabilities.rawValue, value: caps.encode()).encode())
            }

            // File metadata
            if let fm = fileMeta {
                data.append(TLV(type: TLVType.metadata.rawValue, value: fm.encode()).encode())
            }

            // Transfer metrics (extension)
            if let metrics = transferMetrics {
                data.append(TLV(type: TLVType.transferMetrics.rawValue, value: metrics.encode()).encode())
            }

            #if DEBUG
            let hex = AXDP.hexPrefix(data)
            print("[AXDP WIRE][ENC] type=\(type) sessionId=\(sessionId) messageId=\(messageId) bytes=\(data.count) hex=\(hex)")
            #endif

            return data
        }

        /// Decode message from bytes.
        /// Returns nil if magic header is missing or data is malformed.
        /// Unknown TLVs are safely skipped (forward compatibility).
        static func decode(from data: Data) -> Message? {
            // Check magic header
            guard hasMagic(data) else {
                TxLog.debug(.axdp, "No AXDP magic header", ["size": data.count])
                return nil
            }

            // Parse TLVs after magic
            let tlvData = data.subdata(in: magic.count..<data.count)
            let tlvs = decodeTLVs(from: tlvData)

            guard !tlvs.isEmpty else { return nil }

            // Build message from TLVs
            var msg = Message(type: .chat, sessionId: 0, messageId: 0)
            var hasType = false

            // Compression state for deferred decompression
            var compressionAlgo: AXDPCompression.Algorithm = .none
            var originalLength: UInt32 = 0
            var compressedPayload: Data?

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
                    // Try to decode as file metadata first
                    if let fm = AXDPFileMeta.decode(from: tlv.value) {
                        msg.fileMeta = fm
                    } else {
                        msg.metadata = tlv.value
                    }

                case TLVType.capabilities.rawValue:
                    msg.capabilities = AXDPCapability.decode(from: tlv.value)

                case TLVType.compression.rawValue:
                    if let rawAlgo = tlv.value.first,
                       let algo = AXDPCompression.Algorithm(rawValue: rawAlgo) {
                        compressionAlgo = algo
                        msg.compression = algo
                    }

                case TLVType.originalLength.rawValue:
                    if tlv.value.count >= 4 {
                        originalLength = decodeUInt32(tlv.value)
                    }

                case TLVType.payloadCompressed.rawValue:
                    compressedPayload = tlv.value

                case TLVType.transferMetrics.rawValue:
                    if let metrics = AXDPTransferMetrics.decode(from: tlv.value) {
                        msg.transferMetrics = metrics
                    } else {
                        msg.unknownTLVs.append(tlv)
                    }

                default:
                    // Unknown TLV - preserve for forward compatibility
                    msg.unknownTLVs.append(tlv)
                }
            }

            // Handle compressed payload
            if let compressed = compressedPayload,
               compressionAlgo != .none,
               originalLength > 0 {
                // Decompress with default max length
                let maxLen = AXDPCompression.absoluteMaxDecompressedLen
                if let decompressed = AXDPCompression.decompress(
                    compressed,
                    algorithm: compressionAlgo,
                    originalLength: originalLength,
                    maxLength: maxLen
                ) {
                    msg.payload = decompressed
                }
            }

            // Must have at least message type
            guard hasType else {
                TxLog.axdpDecodeError(reason: "Missing message type", data: data)
                return nil
            }

            TxLog.axdpDecode(
                type: String(describing: msg.type),
                sessionId: UInt16(msg.sessionId & 0xFFFF),
                messageId: msg.messageId,
                payloadSize: msg.payload?.count ?? 0
            )

            if !msg.unknownTLVs.isEmpty {
                TxLog.debug(.axdp, "Unknown TLVs preserved", [
                    "count": msg.unknownTLVs.count,
                    "types": msg.unknownTLVs.map { String(format: "0x%02X", $0.type) }.joined(separator: ", ")
                ])
            }

            #if DEBUG
            let hex = AXDP.hexPrefix(data)
            print("[AXDP WIRE][DEC] type=\(msg.type) sessionId=\(msg.sessionId) messageId=\(msg.messageId) bytes=\(data.count) hex=\(hex)")
            #endif

            return msg
        }
    }

    // MARK: - Helper Functions

    /// Transfer metrics extension (durations in milliseconds, sizes in bytes)
    struct AXDPTransferMetrics: Sendable, Equatable {
        static let version: UInt8 = 1

        let dataDurationMs: UInt32
        let processingDurationMs: UInt32
        let bytesReceived: UInt32
        let decompressedBytes: UInt32?

        var dataDurationSeconds: Double {
            Double(dataDurationMs) / 1000.0
        }

        var processingDurationSeconds: Double {
            Double(processingDurationMs) / 1000.0
        }

        var dataBytesPerSecond: Double {
            let seconds = dataDurationSeconds
            guard seconds > 0 else { return 0 }
            return Double(bytesReceived) / seconds
        }

        func encode() -> Data {
            var data = Data()
            data.append(Self.version)
            data.append(encodeUInt32(dataDurationMs))
            data.append(encodeUInt32(processingDurationMs))
            data.append(encodeUInt32(bytesReceived))
            if let decompressedBytes = decompressedBytes {
                data.append(encodeUInt32(decompressedBytes))
            }
            return data
        }

        static func decode(from data: Data) -> AXDPTransferMetrics? {
            guard data.count >= 1 + 12 else { return nil }
            let version = data[0]
            guard version == Self.version else { return nil }

            let dataDurationMs = decodeUInt32(data.subdata(in: 1..<5))
            let processingDurationMs = decodeUInt32(data.subdata(in: 5..<9))
            let bytesReceived = decodeUInt32(data.subdata(in: 9..<13))

            var decompressedBytes: UInt32?
            if data.count >= 17 {
                decompressedBytes = decodeUInt32(data.subdata(in: 13..<17))
            }

            return AXDPTransferMetrics(
                dataDurationMs: dataDurationMs,
                processingDurationMs: processingDurationMs,
                bytesReceived: bytesReceived,
                decompressedBytes: decompressedBytes
            )
        }
    }

    /// Check if data starts with AXDP magic header
    static func hasMagic(_ data: Data) -> Bool {
        guard data.count >= magic.count else { return false }
        return data.prefix(magic.count) == magic
    }

    /// Debug helper to render a compact hex prefix for wire logging.
    static func hexPrefix(_ data: Data, limit: Int = 64) -> String {
        guard !data.isEmpty else { return "" }
        return data.prefix(limit).map { String(format: "%02X", $0) }.joined()
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

// MARK: - SACK Bitmap

/// Selective ACK bitmap for tracking received chunks
struct AXDPSACKBitmap: Sendable {
    /// Base chunk index (lowest chunk in window)
    let baseChunk: UInt32

    /// Window size in chunks
    let windowSize: Int

    /// Bitmap tracking received chunks (bit N = chunk baseChunk+N)
    private var bitmap: [UInt8]

    init(baseChunk: UInt32, windowSize: Int) {
        self.baseChunk = baseChunk
        self.windowSize = windowSize
        // Each byte covers 8 chunks
        let bytes = (windowSize + 7) / 8
        self.bitmap = [UInt8](repeating: 0, count: bytes)
    }

    /// Mark a chunk as received
    mutating func markReceived(chunk: UInt32) {
        guard chunk >= baseChunk else { return }
        let offset = Int(chunk - baseChunk)
        guard offset < windowSize else { return }

        let byteIndex = offset / 8
        let bitIndex = offset % 8
        bitmap[byteIndex] |= (1 << bitIndex)
    }

    /// Check if a chunk has been received
    func isReceived(chunk: UInt32) -> Bool {
        guard chunk >= baseChunk else { return false }
        let offset = Int(chunk - baseChunk)
        guard offset < windowSize else { return false }

        let byteIndex = offset / 8
        let bitIndex = offset % 8
        return (bitmap[byteIndex] & (1 << bitIndex)) != 0
    }

    /// Get the highest contiguous chunk index received from base
    var highestContiguous: UInt32 {
        var highest = baseChunk
        var foundGap = false

        for i in 0..<windowSize {
            let chunk = baseChunk + UInt32(i)
            if isReceived(chunk: chunk) {
                if !foundGap {
                    highest = chunk
                }
            } else {
                foundGap = true
            }
        }

        return highest
    }

    /// Get list of missing chunks up to a given chunk index
    func missingChunks(upTo maxChunk: UInt32) -> [UInt32] {
        var missing: [UInt32] = []
        let limit = min(Int(maxChunk - baseChunk) + 1, windowSize)

        for i in 0..<limit {
            let chunk = baseChunk + UInt32(i)
            if !isReceived(chunk: chunk) {
                missing.append(chunk)
            }
        }

        return missing
    }

    /// Encode bitmap to bytes
    func encode() -> Data {
        return Data(bitmap)
    }

    /// Decode bitmap from bytes
    static func decode(from data: Data, baseChunk: UInt32, windowSize: Int) -> AXDPSACKBitmap? {
        let expectedBytes = (windowSize + 7) / 8
        guard data.count >= expectedBytes else { return nil }

        var sack = AXDPSACKBitmap(baseChunk: baseChunk, windowSize: windowSize)
        for i in 0..<expectedBytes {
            sack.bitmap[i] = data[i]
        }
        return sack
    }
}

// MARK: - Message ID Tracker

/// Tracks message IDs for deduplication
struct AXDPMessageIdTracker: Sendable {
    /// Key for session+messageId pair
    private struct MessageKey: Hashable {
        let sessionId: UInt32
        let messageId: UInt32
    }

    /// Maximum number of message IDs to track
    let windowSize: Int

    /// Set of seen message keys
    private var seen: Set<MessageKey> = []

    /// Order of insertion for LRU eviction
    private var order: [MessageKey] = []

    init(windowSize: Int = 1000) {
        self.windowSize = max(1, windowSize)
    }

    /// Check if this message is a duplicate. If not seen before, marks it as seen.
    /// Returns true if duplicate, false if new.
    mutating func isDuplicate(sessionId: UInt32, messageId: UInt32) -> Bool {
        let key = MessageKey(sessionId: sessionId, messageId: messageId)

        if seen.contains(key) {
            return true
        }

        // Not seen - add it
        seen.insert(key)
        order.append(key)

        // Evict if over window size
        while order.count > windowSize {
            let oldest = order.removeFirst()
            seen.remove(oldest)
        }

        return false
    }

    /// Clear all tracked message IDs
    mutating func clear() {
        seen.removeAll()
        order.removeAll()
    }
}

// MARK: - Retry Policy

/// Configures retry behavior for AXDP reliability
struct AXDPRetryPolicy: Sendable {
    /// Maximum number of retry attempts
    let maxRetries: Int

    /// Base retry interval in seconds
    let baseInterval: Double

    /// Maximum retry interval in seconds
    let maxInterval: Double

    /// Fraction of interval to add as jitter (0.0 to 1.0)
    let jitterFraction: Double

    init(
        maxRetries: Int = 5,
        baseInterval: Double = 2.0,
        maxInterval: Double = 30.0,
        jitterFraction: Double = 0.2
    ) {
        self.maxRetries = max(1, maxRetries)
        self.baseInterval = max(0.1, baseInterval)
        self.maxInterval = max(baseInterval, maxInterval)
        self.jitterFraction = max(0, min(1.0, jitterFraction))
    }

    /// Check if another retry should be attempted
    func shouldRetry(attempt: Int) -> Bool {
        return attempt < maxRetries
    }

    /// Calculate retry interval for given attempt (0-indexed)
    func retryInterval(attempt: Int) -> Double {
        // Exponential backoff: base * 2^attempt
        let exponential = baseInterval * pow(2.0, Double(attempt))
        var interval = min(exponential, maxInterval)

        // Add jitter if enabled
        if jitterFraction > 0 {
            let jitter = interval * jitterFraction * Double.random(in: -1.0...1.0)
            interval = max(baseInterval, interval + jitter)
        }

        return interval
    }
}

// MARK: - Transfer State

/// Tracks state for an AXDP file transfer session
struct AXDPTransferState: Sendable {
    /// Session ID
    let sessionId: UInt32

    /// Total number of chunks in the transfer
    let totalChunks: UInt32

    /// Set of chunk indices still pending (not yet acknowledged)
    private(set) var pendingChunks: Set<UInt32>

    /// Retry counts per chunk
    private var retries: [UInt32: Int] = [:]

    /// Creation timestamp
    let createdAt: Date

    /// Last activity timestamp
    var lastActivity: Date

    /// Check if transfer is complete (all chunks acknowledged)
    var isComplete: Bool {
        pendingChunks.isEmpty
    }

    init(sessionId: UInt32, totalChunks: UInt32) {
        self.sessionId = sessionId
        self.totalChunks = totalChunks
        self.pendingChunks = Set(0..<totalChunks)
        self.createdAt = Date()
        self.lastActivity = Date()
    }

    /// Acknowledge a chunk as received by peer
    mutating func acknowledgeChunk(_ chunk: UInt32) {
        pendingChunks.remove(chunk)
        lastActivity = Date()
    }

    /// Record a retry attempt for a chunk
    mutating func recordRetry(for chunk: UInt32) {
        retries[chunk, default: 0] += 1
        lastActivity = Date()
    }

    /// Get retry count for a chunk
    func retryCount(for chunk: UInt32) -> Int {
        retries[chunk] ?? 0
    }

    /// Apply a selective acknowledgment bitmap
    mutating func applySelectiveAck(_ sack: AXDPSACKBitmap) {
        for chunk in 0..<totalChunks {
            if sack.isReceived(chunk: chunk) {
                pendingChunks.remove(chunk)
            }
        }
        lastActivity = Date()
    }

    /// Get the next chunk to send (lowest pending)
    func nextChunkToSend() -> UInt32? {
        pendingChunks.min()
    }

    /// Get chunks that need retransmission (sorted by chunk index)
    func chunksNeedingRetransmit() -> [UInt32] {
        pendingChunks.sorted()
    }
}
