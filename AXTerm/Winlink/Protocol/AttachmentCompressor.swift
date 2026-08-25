//
//  AttachmentCompressor.swift
//  AXTerm
//
//  Pre-compresses outbound attachments into ordinary zip archives before
//  they enter a B2 message.
//
//  Why this wins: B2F allows exactly one compression on the wire — LZHUF,
//  1988 LZSS with a 2 KB ring buffer. Redundancy further back than 2 KB is
//  invisible to it. Deflate's 32 KB window sees it fine, so zipping a large
//  text attachment routinely halves what actually crosses a 1200-baud
//  channel; LZHUF then costs nothing on the already-dense bytes. The
//  recipient gets a plain zip any tool opens.
//
//  Why it sometimes must NOT run:
//  - Winlink form workflows key on exact attachment names
//    (RMS_Express_Form_*.xml) — renaming one to .zip breaks the consumer,
//    so xml never qualifies.
//  - Media and archives are already dense; wrapping them only adds bytes.
//  - The rename itself is a cost to the recipient. A saving under 10%
//    does not pay for it.
//

import Foundation
import Compression

nonisolated enum AttachmentCompressor {

    /// Extensions whose content is already compressed — a zip wrapper can
    /// only add bytes. xml is excluded for a different reason: form
    /// consumers key on the exact attachment name.
    private static let skippedExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "lz", "zst",
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif",
        "mp3", "m4a", "aac", "ogg", "opus", "flac",
        "mp4", "m4v", "mov", "avi", "mkv", "webm",
        "pdf", "docx", "xlsx", "pptx", "odt",
        "xml",
    ]

    /// Below this, zip container overhead swamps any plausible saving.
    private static let minimumSize = 512

    /// The saving must clear this fraction to justify renaming the file
    /// the recipient sees.
    private static let minimumSaving = 0.10

    /// Returns a zipped replacement for the attachment, or nil when
    /// compressing is not worthwhile (already dense, too small, protected
    /// name, or the saving is marginal).
    static func zipped(name: String, data: Data) -> (name: String, data: Data)? {
        guard data.count >= minimumSize else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !skippedExtensions.contains(ext) else { return nil }

        guard let deflated = deflate(data) else { return nil }
        let archive = zipArchive(entryName: name, original: data, deflated: deflated)
        guard Double(archive.count) <= Double(data.count) * (1.0 - minimumSaving) else { return nil }
        return (name: name + ".zip", data: archive)
    }

    // MARK: - Deflate

    private static func deflate(_ data: Data) -> Data? {
        // COMPRESSION_ZLIB in Apple's framework is raw deflate — exactly
        // what zip method 8 stores.
        var out = Data(count: data.count + 1024)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, data.count + 1024,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    // MARK: - Zip container

    /// One-entry zip: local header + deflated data + central directory +
    /// end record. No zip64 (Winlink's budget is 120 kB), no encryption.
    /// The timestamp is a fixed constant so identical content produces an
    /// identical archive — determinism over provenance.
    private static func zipArchive(entryName: String, original: Data, deflated: Data) -> Data {
        let nameBytes = Array(entryName.utf8)
        let crc = crc32(original)
        // 2026-01-01 00:00:00 in DOS date/time encoding.
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = UInt16((2026 - 1980) << 9 | 1 << 5 | 1)

        var out = Data()
        func le16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
        func le32(_ v: UInt32) {
            out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
        }

        // Local file header
        le32(0x0403_4B50)
        le16(20)                    // version needed
        le16(1 << 11)               // UTF-8 names
        le16(8)                     // deflate
        le16(dosTime); le16(dosDate)
        le32(crc)
        le32(UInt32(deflated.count))
        le32(UInt32(original.count))
        le16(UInt16(nameBytes.count))
        le16(0)                     // extra length
        out.append(contentsOf: nameBytes)
        out.append(deflated)

        // Central directory
        let centralOffset = UInt32(out.count)
        le32(0x0201_4B50)
        le16(20)                    // version made by
        le16(20)                    // version needed
        le16(1 << 11)
        le16(8)
        le16(dosTime); le16(dosDate)
        le32(crc)
        le32(UInt32(deflated.count))
        le32(UInt32(original.count))
        le16(UInt16(nameBytes.count))
        le16(0); le16(0)            // extra, comment
        le16(0)                     // disk number
        le16(0)                     // internal attrs
        le32(0)                     // external attrs
        le32(0)                     // local header offset
        out.append(contentsOf: nameBytes)
        let centralSize = UInt32(out.count) - centralOffset

        // End of central directory
        le32(0x0605_4B50)
        le16(0); le16(0)            // disk numbers
        le16(1); le16(1)            // entry counts
        le32(centralSize)
        le32(centralOffset)
        le16(0)                     // comment length
        return out
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
