//
//  ZipArchive.swift
//  AXTerm
//
//  A one-file .zip, for sending a file to a station without AXTerm by YAPP
//  (retest 2026-10-10, finding 12). AX.25 has no compression other packet
//  software decodes, but every desktop and phone opens a zip without extra
//  software. The format is PKWARE's APPNOTE: a local file header, the data,
//  a central directory header and the end record, deflate or stored.
//

import Foundation
import Compression

nonisolated enum ZipArchive {

    /// An archive holding `data` as `name`, deflated when that makes it
    /// smaller and stored as it is otherwise (a photo, say).
    static func single(name: String, data: Data, modified: Date) -> Data {
        let deflated = deflate(data)
        let useDeflate = deflated.map { $0.count < data.count } ?? false
        let body = useDeflate ? deflated! : data
        let method: UInt16 = useDeflate ? 8 : 0
        let crc = AXDP.crc32(data)
        let nameBytes = Data(name.utf8)
        let (time, date) = dosTimeAndDate(modified)
        // Bit 11: the name is UTF-8.
        let flags: UInt16 = 1 << 11

        var local = Data()
        local.append(le32(0x04034B50))
        local.append(le16(20))                     // version needed: 2.0
        local.append(le16(flags))
        local.append(le16(method))
        local.append(le16(time)); local.append(le16(date))
        local.append(le32(crc))
        local.append(le32(UInt32(body.count))); local.append(le32(UInt32(data.count)))
        local.append(le16(UInt16(nameBytes.count))); local.append(le16(0))
        local.append(nameBytes)

        var central = Data()
        central.append(le32(0x02014B50))
        central.append(le16(20)); central.append(le16(20))   // made by, needed
        central.append(le16(flags))
        central.append(le16(method))
        central.append(le16(time)); central.append(le16(date))
        central.append(le32(crc))
        central.append(le32(UInt32(body.count))); central.append(le32(UInt32(data.count)))
        central.append(le16(UInt16(nameBytes.count)))
        central.append(le16(0)); central.append(le16(0))     // extra, comment
        central.append(le16(0)); central.append(le16(0))     // disk, internal attributes
        central.append(le32(0))                              // external attributes
        central.append(le32(0))                              // local header at offset 0
        central.append(nameBytes)

        var end = Data()
        end.append(le32(0x06054B50))
        end.append(le16(0)); end.append(le16(0))             // this disk, directory's disk
        end.append(le16(1)); end.append(le16(1))             // entries here, entries in all
        end.append(le32(UInt32(central.count)))
        end.append(le32(UInt32(local.count + body.count)))
        end.append(le16(0))                                  // comment

        return local + body + central + end
    }

    /// "constitution.txt" becomes "constitution.zip".
    static func archiveName(for name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return (stem.isEmpty ? name : stem) + ".zip"
    }

    /// Whether Send File offers to zip: only where AXDP's own compression
    /// cannot reach, sending by YAPP to a station not confirmed as AXTerm,
    /// and only for a file that shrinks.
    static func isOffered(protocol transferProtocol: TransferProtocolType, peerIsAXTerm: Bool,
                          fileShrinks: Bool) -> Bool {
        transferProtocol == .yapp && !peerIsAXTerm && fileShrinks
    }

    // MARK: Private

    /// Raw DEFLATE (RFC 1951), which is what COMPRESSION_ZLIB writes and
    /// what a zip entry with method 8 holds.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? out.prefix(written) : nil
    }

    private static func dosTimeAndDate(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
