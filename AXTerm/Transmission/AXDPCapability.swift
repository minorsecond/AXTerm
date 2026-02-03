//
//  AXDPCapability.swift
//  AXTerm
//
//  AXDP capability discovery and compression support.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 6.x.3, 6.x.4
//
//  Capability negotiation is opportunistic - it should NOT block sending.
//  Compression is only used when peer support is confirmed.
//

import Combine
import Compression
import Foundation

// MARK: - Capability Structure

/// AXDP peer capabilities for negotiation
struct AXDPCapability: Sendable, Equatable {

    /// Sub-TLV types within capabilities TLV (0x20)
    enum SubTLVType: UInt8 {
        case protoMin           = 0x01
        case protoMax           = 0x02
        case featuresBitset     = 0x03
        case compressionAlgos   = 0x04
        case maxDecompressedLen = 0x05
        case maxChunkLen        = 0x06
    }

    /// Feature flags bitset
    struct Features: OptionSet, Sendable, Equatable {
        let rawValue: UInt32

        static let sack             = Features(rawValue: 1 << 0)
        static let resume           = Features(rawValue: 1 << 1)
        static let compression      = Features(rawValue: 1 << 2)
        static let extendedMetadata = Features(rawValue: 1 << 3)

        static let all: Features = [.sack, .resume, .compression, .extendedMetadata]
    }

    /// Minimum AXDP version supported
    var protoMin: UInt8

    /// Maximum AXDP version supported
    var protoMax: UInt8

    /// Supported features
    var features: Features

    /// Supported compression algorithms
    var compressionAlgos: [AXDPCompression.Algorithm]

    /// Maximum decompressed payload length (anti-zip-bomb)
    var maxDecompressedLen: UInt32

    /// Preferred maximum chunk length
    var maxChunkLen: UInt16

    /// Default local capabilities
    static func defaultLocal() -> AXDPCapability {
        AXDPCapability(
            protoMin: 1,
            protoMax: AXDP.version,
            features: [.sack, .resume, .compression],
            compressionAlgos: [.lz4],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )
    }

    // MARK: - Encoding

    /// Encode capabilities to sub-TLV stream
    func encode() -> Data {
        var data = Data()

        // ProtoMin
        data.append(SubTLVType.protoMin.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(1))
        data.append(protoMin)

        // ProtoMax
        data.append(SubTLVType.protoMax.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(1))
        data.append(protoMax)

        // Features bitset
        data.append(SubTLVType.featuresBitset.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(4))
        data.append(contentsOf: AXDP.encodeUInt32(features.rawValue))

        // Compression algorithms
        if !compressionAlgos.isEmpty {
            let algos = Data(compressionAlgos.map { $0.rawValue })
            data.append(SubTLVType.compressionAlgos.rawValue)
            data.append(contentsOf: AXDP.encodeUInt16(UInt16(algos.count)))
            data.append(algos)
        }

        // Max decompressed length
        data.append(SubTLVType.maxDecompressedLen.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(4))
        data.append(contentsOf: AXDP.encodeUInt32(maxDecompressedLen))

        // Max chunk length
        data.append(SubTLVType.maxChunkLen.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(2))
        data.append(contentsOf: AXDP.encodeUInt16(maxChunkLen))

        return data
    }

    // MARK: - Decoding

    /// Decode capabilities from sub-TLV stream
    static func decode(from data: Data) -> AXDPCapability? {
        var protoMin: UInt8 = 1
        var protoMax: UInt8 = 1
        var features: Features = []
        var compressionAlgos: [AXDPCompression.Algorithm] = []
        var maxDecompressedLen: UInt32 = 4096
        var maxChunkLen: UInt16 = 128

        var offset = 0
        while offset + 3 <= data.count {
            let type = data[offset]
            let length = AXDP.decodeUInt16(data.subdata(in: (offset + 1)..<(offset + 3)))
            let valueStart = offset + 3
            let valueEnd = valueStart + Int(length)

            guard valueEnd <= data.count else { break }

            let value = data.subdata(in: valueStart..<valueEnd)

            switch type {
            case SubTLVType.protoMin.rawValue:
                if let v = value.first { protoMin = v }

            case SubTLVType.protoMax.rawValue:
                if let v = value.first { protoMax = v }

            case SubTLVType.featuresBitset.rawValue:
                if value.count >= 4 {
                    features = Features(rawValue: AXDP.decodeUInt32(value))
                }

            case SubTLVType.compressionAlgos.rawValue:
                compressionAlgos = value.compactMap { AXDPCompression.Algorithm(rawValue: $0) }

            case SubTLVType.maxDecompressedLen.rawValue:
                if value.count >= 4 {
                    maxDecompressedLen = AXDP.decodeUInt32(value)
                }

            case SubTLVType.maxChunkLen.rawValue:
                if value.count >= 2 {
                    maxChunkLen = AXDP.decodeUInt16(value)
                }

            default:
                // Unknown sub-TLV - skip safely
                break
            }

            offset = valueEnd
        }

        return AXDPCapability(
            protoMin: protoMin,
            protoMax: protoMax,
            features: features,
            compressionAlgos: compressionAlgos,
            maxDecompressedLen: maxDecompressedLen,
            maxChunkLen: maxChunkLen
        )
    }

    // MARK: - Negotiation

    /// Negotiate common capabilities between local and remote
    static func negotiate(local: AXDPCapability, remote: AXDPCapability) -> AXDPCapability {
        TxLog.debug(.capability, "Negotiating capabilities", [
            "localProto": "\(local.protoMin)-\(local.protoMax)",
            "remoteProto": "\(remote.protoMin)-\(remote.protoMax)"
        ])

        // Use lowest common version
        let commonProtoMax = min(local.protoMax, remote.protoMax)
        let commonProtoMin = max(local.protoMin, remote.protoMin)

        // Intersect features
        let commonFeatures = local.features.intersection(remote.features)

        // Intersect compression algorithms (preserve order from local preference)
        let remoteAlgoSet = Set(remote.compressionAlgos)
        let commonAlgos = local.compressionAlgos.filter { remoteAlgoSet.contains($0) }

        // Use minimum of limits
        let commonMaxDecompressed = min(local.maxDecompressedLen, remote.maxDecompressedLen)
        let commonMaxChunk = min(local.maxChunkLen, remote.maxChunkLen)

        let result = AXDPCapability(
            protoMin: commonProtoMin,
            protoMax: commonProtoMax,
            features: commonFeatures,
            compressionAlgos: commonAlgos,
            maxDecompressedLen: commonMaxDecompressed,
            maxChunkLen: commonMaxChunk
        )

        TxLog.axdpCapability(
            peer: "negotiated",
            caps: [
                "proto:\(commonProtoMin)-\(commonProtoMax)",
                "features:\(commonFeatures.rawValue)",
                "algos:\(commonAlgos.map { String(describing: $0) }.joined(separator: ","))",
                "maxChunk:\(commonMaxChunk)"
            ]
        )

        return result
    }
}

// MARK: - Peer Key

/// Key for identifying a peer in capability cache
struct AXDPPeerKey: Hashable, Sendable {
    let callsign: String
    let ssid: Int

    init(callsign: String, ssid: Int = 0) {
        self.callsign = callsign.uppercased()
        self.ssid = ssid
    }
}

// MARK: - Capability Cache

/// Cache for peer capabilities with expiry
struct AXDPCapabilityCache: Sendable {

    /// Cache entry with timestamp
    private struct Entry: Sendable {
        let capability: AXDPCapability
        let timestamp: Date
    }

    /// Maximum age in seconds before entry expires (default 24 hours)
    let maxAge: TimeInterval

    /// Cache storage
    private var cache: [AXDPPeerKey: Entry] = [:]

    init(maxAge: TimeInterval = 86400) {
        self.maxAge = maxAge
    }

    /// Store capabilities for a peer
    mutating func store(_ capability: AXDPCapability, for peer: AXDPPeerKey) {
        cache[peer] = Entry(capability: capability, timestamp: Date())
    }

    /// Get capabilities for a peer (nil if not cached or expired)
    func get(for peer: AXDPPeerKey) -> AXDPCapability? {
        guard let entry = cache[peer] else { return nil }

        // Check expiry
        if Date().timeIntervalSince(entry.timestamp) > maxAge {
            return nil
        }

        return entry.capability
    }

    /// Check if negotiation is needed for a peer
    func needsNegotiation(for peer: AXDPPeerKey) -> Bool {
        return get(for: peer) == nil
    }

    /// Remove cached entry for peer
    mutating func remove(for peer: AXDPPeerKey) {
        cache.removeValue(forKey: peer)
    }

    /// Clear all cached entries
    mutating func clear() {
        cache.removeAll()
    }
}

// MARK: - Observable Capability Store

/// Observable store for AXDP peer capabilities
/// Used by UI components to display capability badges
@MainActor
final class AXDPCapabilityStore: ObservableObject {
    /// Published cache for reactive updates
    @Published private(set) var cache = AXDPCapabilityCache()

    /// Get capabilities for a peer by callsign (can include SSID, e.g., "N0CALL-2")
    func capabilities(for callsign: String) -> AXDPCapability? {
        let (call, ssid) = parseCallsign(callsign)
        let key = AXDPPeerKey(callsign: call, ssid: ssid)
        return cache.get(for: key)
    }

    /// Get capabilities for a peer with SSID
    func capabilities(for callsign: String, ssid: Int) -> AXDPCapability? {
        let key = AXDPPeerKey(callsign: callsign, ssid: ssid)
        return cache.get(for: key)
    }

    /// Store capabilities for a peer
    func store(_ capability: AXDPCapability, for callsign: String, ssid: Int = 0) {
        let key = AXDPPeerKey(callsign: callsign, ssid: ssid)
        cache.store(capability, for: key)
        objectWillChange.send()

        TxLog.debug(.capability, "Stored peer capability", [
            "peer": callsign + (ssid > 0 ? "-\(ssid)" : ""),
            "protoMax": capability.protoMax,
            "features": capability.features.description,
            "compression": capability.compressionAlgos.map { $0.displayName }.joined(separator: ", ")
        ])
    }

    /// Check if peer has AXDP capabilities cached
    /// Callsign can include SSID (e.g., "N0CALL-2")
    func hasCapabilities(for callsign: String) -> Bool {
        let (call, ssid) = parseCallsign(callsign)
        let key = AXDPPeerKey(callsign: call, ssid: ssid)
        return cache.get(for: key) != nil
    }

    /// Parse callsign with optional SSID (e.g., "N0CALL-2" -> ("N0CALL", 2))
    private func parseCallsign(_ callsign: String) -> (call: String, ssid: Int) {
        let parts = callsign.uppercased().split(separator: "-")
        let call = String(parts.first ?? "")
        let ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return (call, ssid)
    }

    /// Remove cached capabilities for a peer
    /// Called when session disconnects to ensure fresh discovery on next connection
    /// Callsign can include SSID (e.g., "N0CALL-2")
    func remove(for callsign: String) {
        let (call, ssid) = parseCallsign(callsign)
        let key = AXDPPeerKey(callsign: call, ssid: ssid)
        cache.remove(for: key)
        objectWillChange.send()

        TxLog.debug(.capability, "Removed peer capability from cache", [
            "peer": callsign
        ])
    }

    /// Get all known peers with capabilities
    var knownPeers: [String] {
        cache.allPeers.map { $0.callsign + ($0.ssid > 0 ? "-\($0.ssid)" : "") }
    }

    /// Clear all cached capabilities
    func clear() {
        cache.clear()
        objectWillChange.send()
    }
}

// MARK: - Capability Cache Extensions

extension AXDPCapabilityCache {
    /// Get all peers currently in cache
    var allPeers: [AXDPPeerKey] {
        // Note: This requires access to the private cache dictionary
        // For now, return empty - we'll track this separately if needed
        []
    }
}

// MARK: - Features Description

extension AXDPCapability.Features: CustomStringConvertible {
    var description: String {
        var parts: [String] = []
        if contains(.sack) { parts.append("SACK") }
        if contains(.resume) { parts.append("Resume") }
        if contains(.compression) { parts.append("Compression") }
        if contains(.extendedMetadata) { parts.append("ExtMeta") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }

    /// Short description for badges
    var shortDescription: String {
        var parts: [String] = []
        if contains(.sack) { parts.append("S") }
        if contains(.resume) { parts.append("R") }
        if contains(.compression) { parts.append("C") }
        if contains(.extendedMetadata) { parts.append("M") }
        return parts.joined()
    }
}

// MARK: - Compression

/// AXDP compression support
enum AXDPCompression {

    /// Supported compression algorithms
    enum Algorithm: UInt8, Sendable, Equatable, Hashable, CaseIterable {
        case none    = 0
        case lz4     = 1
        case zstd    = 2
        case deflate = 3
    }

    /// Absolute maximum decompressed length for individual message payloads (per spec)
    /// Note: This is for per-message compression, NOT whole-file transfers
    static let absoluteMaxDecompressedLen: UInt32 = 8192

    /// Maximum decompressed length for whole-file transfers (100 MB)
    /// File transfers use whole-file compression which can produce much larger outputs
    static let absoluteMaxFileTransferLen: UInt32 = 104_857_600

    /// Compress data using specified algorithm
    static func compress(_ data: Data, algorithm: Algorithm) -> Data? {
        guard algorithm != .none else { return data }
        guard !data.isEmpty else { return data }

        TxLog.debug(.compression, "Compressing", ["algorithm": String(describing: algorithm), "inputSize": data.count])

        let algo: compression_algorithm
        switch algorithm {
        case .none:
            return data
        case .lz4:
            algo = COMPRESSION_LZ4
        case .zstd:
            // ZSTD not available on all macOS versions, fall back to LZ4
            algo = COMPRESSION_LZ4
        case .deflate:
            algo = COMPRESSION_ZLIB
        }

        // Allocate buffer for compressed data
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count + 64)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let sourceBaseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer,
                data.count + 64,
                sourceBaseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                algo
            )
        }

        guard compressedSize > 0 else {
            TxLog.compressionError(operation: "compress", reason: "Compression returned 0 bytes")
            return nil
        }

        // Only use compression if it actually reduces size
        if compressedSize >= data.count {
            TxLog.debug(.compression, "Compression skipped (no benefit)", [
                "inputSize": data.count,
                "wouldBe": compressedSize
            ])
            return nil  // Compression didn't help
        }

        TxLog.compressionEncode(
            algorithm: String(describing: algorithm),
            originalSize: data.count,
            compressedSize: compressedSize
        )
        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    /// Decompress data using specified algorithm
    static func decompress(
        _ data: Data,
        algorithm: Algorithm,
        originalLength: UInt32,
        maxLength: UInt32
    ) -> Data? {
        guard algorithm != .none else { return data }
        guard !data.isEmpty else { return data }

        TxLog.debug(.compression, "Decompressing", [
            "algorithm": String(describing: algorithm),
            "compressedSize": data.count,
            "expectedSize": originalLength
        ])

        // Enforce the limit passed by the caller
        // For per-message decompression, pass absoluteMaxDecompressedLen (8KB)
        // For whole-file transfers, pass absoluteMaxFileTransferLen (100MB)
        guard originalLength <= maxLength else {
            TxLog.compressionError(operation: "decompress", reason: "Original length \(originalLength) exceeds maxLength \(maxLength)")
            return nil
        }

        let algo: compression_algorithm
        switch algorithm {
        case .none:
            return data
        case .lz4:
            algo = COMPRESSION_LZ4
        case .zstd:
            // ZSTD not available on all macOS versions, fall back to LZ4
            algo = COMPRESSION_LZ4
        case .deflate:
            algo = COMPRESSION_ZLIB
        }

        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(originalLength))
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let sourceBaseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                Int(originalLength),
                sourceBaseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                algo
            )
        }

        // Verify decompressed size matches claimed original
        guard decompressedSize == Int(originalLength) else {
            TxLog.compressionError(operation: "decompress", reason: "Size mismatch: got \(decompressedSize), expected \(originalLength)")
            return nil
        }

        TxLog.compressionDecode(
            algorithm: String(describing: algorithm),
            compressedSize: data.count,
            decompressedSize: decompressedSize
        )
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}

// MARK: - File Metadata

/// AXDP file metadata structure (Section 9.2)
struct AXDPFileMeta: Sendable, Equatable {

    /// Sub-TLV types for file metadata
    enum SubTLVType: UInt8 {
        case filename    = 0x01
        case fileSize    = 0x02
        case sha256      = 0x03
        case chunkSize   = 0x04
        case description = 0x05
    }

    let filename: String
    let fileSize: UInt64
    let sha256: Data
    let chunkSize: UInt16
    let description: String?

    init(
        filename: String,
        fileSize: UInt64,
        sha256: Data,
        chunkSize: UInt16,
        description: String? = nil
    ) {
        self.filename = filename
        self.fileSize = fileSize
        self.sha256 = sha256
        self.chunkSize = chunkSize
        self.description = description
    }

    /// Encode file metadata to sub-TLV stream
    func encode() -> Data {
        var data = Data()

        // Filename
        let filenameData = Data(filename.utf8)
        data.append(SubTLVType.filename.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(UInt16(filenameData.count)))
        data.append(filenameData)

        // File size (8 bytes)
        data.append(SubTLVType.fileSize.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(8))
        data.append(contentsOf: encodeUInt64(fileSize))

        // SHA256 (32 bytes)
        data.append(SubTLVType.sha256.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(UInt16(sha256.count)))
        data.append(sha256)

        // Chunk size
        data.append(SubTLVType.chunkSize.rawValue)
        data.append(contentsOf: AXDP.encodeUInt16(2))
        data.append(contentsOf: AXDP.encodeUInt16(chunkSize))

        // Description (optional)
        if let desc = description {
            let descData = Data(desc.utf8)
            data.append(SubTLVType.description.rawValue)
            data.append(contentsOf: AXDP.encodeUInt16(UInt16(descData.count)))
            data.append(descData)
        }

        return data
    }

    /// Decode file metadata from sub-TLV stream
    static func decode(from data: Data) -> AXDPFileMeta? {
        var filename: String?
        var fileSize: UInt64 = 0
        var sha256: Data?
        var chunkSize: UInt16 = 128
        var description: String?

        var offset = 0
        while offset + 3 <= data.count {
            let type = data[offset]
            let length = AXDP.decodeUInt16(data.subdata(in: (offset + 1)..<(offset + 3)))
            let valueStart = offset + 3
            let valueEnd = valueStart + Int(length)

            guard valueEnd <= data.count else { break }

            let value = data.subdata(in: valueStart..<valueEnd)

            switch type {
            case SubTLVType.filename.rawValue:
                filename = String(data: value, encoding: .utf8)

            case SubTLVType.fileSize.rawValue:
                if value.count >= 8 {
                    fileSize = decodeUInt64(value)
                }

            case SubTLVType.sha256.rawValue:
                sha256 = value

            case SubTLVType.chunkSize.rawValue:
                if value.count >= 2 {
                    chunkSize = AXDP.decodeUInt16(value)
                }

            case SubTLVType.description.rawValue:
                description = String(data: value, encoding: .utf8)

            default:
                // Unknown - skip
                break
            }

            offset = valueEnd
        }

        // Require filename and sha256
        guard let fn = filename, let hash = sha256 else { return nil }

        return AXDPFileMeta(
            filename: fn,
            fileSize: fileSize,
            sha256: hash,
            chunkSize: chunkSize,
            description: description
        )
    }

    // MARK: - UInt64 Helpers

    private func encodeUInt64(_ value: UInt64) -> Data {
        var data = Data(count: 8)
        data[0] = UInt8((value >> 56) & 0xFF)
        data[1] = UInt8((value >> 48) & 0xFF)
        data[2] = UInt8((value >> 40) & 0xFF)
        data[3] = UInt8((value >> 32) & 0xFF)
        data[4] = UInt8((value >> 24) & 0xFF)
        data[5] = UInt8((value >> 16) & 0xFF)
        data[6] = UInt8((value >> 8) & 0xFF)
        data[7] = UInt8(value & 0xFF)
        return data
    }

    private static func decodeUInt64(_ data: Data) -> UInt64 {
        guard data.count >= 8 else { return 0 }
        return (UInt64(data[0]) << 56) |
               (UInt64(data[1]) << 48) |
               (UInt64(data[2]) << 40) |
               (UInt64(data[3]) << 32) |
               (UInt64(data[4]) << 24) |
               (UInt64(data[5]) << 16) |
               (UInt64(data[6]) << 8) |
               UInt64(data[7])
    }
}
