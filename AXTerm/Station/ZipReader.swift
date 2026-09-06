import Foundation
import Compression

/// Reads a zip archive.
///
/// The counterpart to `ZipWriter`, and needed for a different reason: an
/// agency sending a shapefile sends a `.zip`, because a shapefile is four
/// files that only work together. Receiving one over Winlink and being unable
/// to open it would make the whole receive path useless for the format the
/// senders actually use.
///
/// Reads the central directory rather than scanning for local headers. The
/// directory is authoritative — a local header may carry zeroes with the real
/// sizes in a trailing data descriptor, which is exactly what streaming
/// writers produce and what a naive scanner gets wrong.
///
/// Handles stored and deflated entries. Deflate goes through the Compression
/// framework's raw zlib codec, which is what a zip member is: a raw deflate
/// stream with no zlib header.
nonisolated enum ZipReader {

    enum ReadError: Error, Equatable {
        case notAZip
        case unsupportedCompression(UInt16, entry: String)
        case corrupt(String)
        /// The archive claims more data than it contains.
        case truncated
        case checksumMismatch(entry: String)

        var explanation: String {
            switch self {
            case .notAZip:
                "That file is not a zip archive."
            case .unsupportedCompression(let method, let entry):
                "\(entry) uses compression method \(method), which AXTerm cannot decompress. Stored and deflated entries are supported."
            case .corrupt(let detail):
                "The archive is damaged: \(detail)"
            case .truncated:
                "The archive ends early — it was probably cut short in transfer."
            case .checksumMismatch(let entry):
                "\(entry) failed its checksum. The archive arrived damaged; ask for it again."
            }
        }
    }

    struct Entry: Equatable, Sendable {
        let name: String
        let data: Data
    }

    private static let endOfDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let methodStored: UInt16 = 0
    private static let methodDeflate: UInt16 = 8

    /// Refuses anything larger than this after decompression.
    ///
    /// A zip bomb is a small archive that expands to gigabytes. This is data
    /// from a third party over the air, so the ceiling is deliberate rather
    /// than incidental — 64 MB is far more than any boundary layer needs and
    /// far less than enough to exhaust a handheld.
    static let maximumDecompressedBytes = 64 * 1024 * 1024

    static func entries(in archive: Data) throws -> [Entry] {
        // An archive with no entries is exactly the 22-byte end-of-directory
        // record — a legal, if useless, zip. `>` here rejected it.
        guard archive.count >= 22 else { throw ReadError.notAZip }

        // The end-of-directory record is at the end, but may be followed by a
        // comment, so it is searched for backwards.
        guard let endOffset = findEndOfDirectory(archive) else { throw ReadError.notAZip }

        let entryCount = Int(archive.u16(at: endOffset + 10))
        let directoryOffset = Int(archive.u32(at: endOffset + 16))
        guard directoryOffset < archive.count else { throw ReadError.truncated }

        var results: [Entry] = []
        var cursor = directoryOffset
        var total = 0

        for _ in 0..<entryCount {
            guard cursor + 46 <= archive.count,
                  archive.u32(at: cursor) == centralHeaderSignature else {
                throw ReadError.corrupt("central directory entry is malformed")
            }

            let method = archive.u16(at: cursor + 10)
            let crc = archive.u32(at: cursor + 16)
            let compressedSize = Int(archive.u32(at: cursor + 20))
            let uncompressedSize = Int(archive.u32(at: cursor + 24))
            let nameLength = Int(archive.u16(at: cursor + 28))
            let extraLength = Int(archive.u16(at: cursor + 30))
            let commentLength = Int(archive.u16(at: cursor + 32))
            let localOffset = Int(archive.u32(at: cursor + 42))

            guard cursor + 46 + nameLength <= archive.count else { throw ReadError.truncated }
            let name = String(decoding: archive.slice(cursor + 46, nameLength), as: UTF8.self)

            total += uncompressedSize
            guard total <= maximumDecompressedBytes else {
                throw ReadError.corrupt("the archive expands to more than \(maximumDecompressedBytes / 1_048_576) MB")
            }

            // Directory entries are zero-length names ending in a separator.
            if !name.hasSuffix("/") {
                let payload = try read(archive, localOffset: localOffset,
                                       method: method, name: name,
                                       compressedSize: compressedSize,
                                       uncompressedSize: uncompressedSize)
                guard ZipWriter.crc32(payload) == crc else {
                    throw ReadError.checksumMismatch(entry: name)
                }
                results.append(Entry(name: name, data: payload))
            }

            cursor += 46 + nameLength + extraLength + commentLength
        }

        return results
    }

    /// Finds one entry by extension, case-insensitively.
    static func entry(in archive: Data, withExtension ext: String) throws -> Entry? {
        try entries(in: archive).first {
            ($0.name as NSString).pathExtension.lowercased() == ext.lowercased()
        }
    }

    // MARK: - Internals

    private static func findEndOfDirectory(_ archive: Data) -> Int? {
        // The record is 22 bytes plus up to 64 KB of comment.
        let lowest = max(0, archive.count - 22 - 65_535)
        var offset = archive.count - 22
        while offset >= lowest {
            if archive.u32(at: offset) == endOfDirectorySignature { return offset }
            offset -= 1
        }
        return nil
    }

    private static func read(_ archive: Data, localOffset: Int, method: UInt16,
                             name: String, compressedSize: Int,
                             uncompressedSize: Int) throws -> Data {
        guard localOffset + 30 <= archive.count,
              archive.u32(at: localOffset) == localHeaderSignature else {
            throw ReadError.corrupt("\(name) has no local header")
        }
        // Name and extra lengths come from the *local* header: they routinely
        // differ from the central directory's, because writers add extra
        // fields in one and not the other.
        let nameLength = Int(archive.u16(at: localOffset + 26))
        let extraLength = Int(archive.u16(at: localOffset + 28))
        let start = localOffset + 30 + nameLength + extraLength

        guard start + compressedSize <= archive.count else { throw ReadError.truncated }
        let payload = archive.slice(start, compressedSize)

        switch method {
        case methodStored:
            return payload
        case methodDeflate:
            guard let inflated = inflate(payload, expecting: uncompressedSize) else {
                throw ReadError.corrupt("\(name) could not be decompressed")
            }
            return inflated
        default:
            throw ReadError.unsupportedCompression(method, entry: name)
        }
    }

    /// Raw deflate, which is what a zip member holds — no zlib header, so
    /// `COMPRESSION_ZLIB` is the right algorithm despite the name.
    static func inflate(_ data: Data, expecting size: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        // A zero declared size is legal for an empty file; anything else with
        // no expectation gets a generous ceiling rather than an unbounded one.
        let capacity = size > 0 ? size : min(maximumDecompressedBytes, data.count * 64)
        guard capacity > 0 else { return Data() }

        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }
}

// MARK: - Byte reading

// Byte arithmetic on a `Data`, which belongs to no actor. The project
// defaults un-annotated declarations to the main actor, which put these
// helpers there and made every parser that calls them a warning.
nonisolated private extension Data {
    /// Reads without assuming the buffer starts at zero — `Data` slices keep
    /// their parent's indices, which has broken more binary parsers than any
    /// other single thing.
    func u16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let start = startIndex + offset
        return UInt16(littleEndian: self[start..<start + 2]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
    }

    func u32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let start = startIndex + offset
        return UInt32(littleEndian: self[start..<start + 4]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }

    func slice(_ offset: Int, _ length: Int) -> Data {
        let start = startIndex + offset
        return Data(self[start..<start + length])
    }
}
