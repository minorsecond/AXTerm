//
//  AttachmentCompressorTests.swift
//  AXTermTests
//
//  Pre-compression of outbound attachments. LZHUF (the only compression
//  B2F allows on the wire) is 1988 LZSS with a 2 KB ring buffer — any
//  redundancy further back than 2 KB is invisible to it. Deflate sees
//  32 KB, so zipping a large text attachment before it enters the message
//  routinely halves what actually crosses a 1200-baud channel. The zip is
//  a plain ordinary archive: the recipient saves the attachment and opens
//  it with anything.
//

import XCTest
import Compression
import GRDB
@testable import AXTerm

final class AttachmentCompressorTests: XCTestCase {

    /// Text with its redundancy deliberately spaced further apart than
    /// LZHUF's 2 KB window but well inside deflate's 32 KB: a ~4 KB block
    /// repeated. LZHUF can never reach the previous copy; deflate always
    /// can.
    private func longRangeRedundantText(copies: Int = 15) -> Data {
        var block = ""
        for i in 0..<40 {
            block += "Entry \(i): the catalog row describes a data product, its size, and the retrieval identifier used to request it.\r\n"
        }
        return Data(String(repeating: block, count: copies).utf8)
    }

    private func highEntropy(_ count: Int) -> Data {
        var state: UInt64 = 0x243F_6A88_85A3_08D3
        var out = Data(capacity: count)
        for _ in 0..<count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            out.append(UInt8(truncatingIfNeeded: state))
        }
        return out
    }

    // MARK: - The zip container

    func testZippedArchiveRoundTrips() throws {
        let original = longRangeRedundantText()
        let zipped = try XCTUnwrap(AttachmentCompressor.zipped(name: "catalog.txt", data: original))
        XCTAssertEqual(zipped.name, "catalog.txt.zip")

        let entry = try XCTUnwrap(IndependentZipParser.firstEntry(in: zipped.data),
                                  "the archive must parse as a plain zip")
        XCTAssertEqual(entry.name, "catalog.txt")
        XCTAssertEqual(entry.data, original, "inflating the entry must reproduce the bytes exactly")
        XCTAssertEqual(entry.crc32, IndependentZipParser.crc32(original), "stored CRC must match the content")
    }

    func testZipBeatsLZHUFOnLongRangeRedundancy() throws {
        let original = longRangeRedundantText()
        let zipped = try XCTUnwrap(AttachmentCompressor.zipped(name: "catalog.txt", data: original))

        // What actually crosses the air: the whole message LZHUF-compressed.
        let plainWire = LZHUF.encodeB2F(original)
        let zippedWire = LZHUF.encodeB2F(zipped.data)
        XCTAssertLessThan(Double(zippedWire.count), Double(plainWire.count) * 0.7,
                          "zip+LZHUF must beat LZHUF alone by ≥30% here: "
                          + "\(zippedWire.count) vs \(plainWire.count)")
    }

    // MARK: - When not to bother

    func testAlreadyCompressedExtensionsAreLeftAlone() {
        let payload = highEntropy(50_000)
        for name in ["photo.jpg", "photo.JPG", "archive.zip", "clip.mp4", "map.png", "pack.7z", "log.gz"] {
            XCTAssertNil(AttachmentCompressor.zipped(name: name, data: payload),
                         "\(name) is already compressed — wrapping it in a zip only adds bytes")
        }
    }

    func testIncompressibleDataIsLeftAlone() {
        XCTAssertNil(AttachmentCompressor.zipped(name: "noise.bin", data: highEntropy(50_000)),
                     "no meaningful saving → keep the original")
    }

    func testTinyAttachmentsAreLeftAlone() {
        XCTAssertNil(AttachmentCompressor.zipped(name: "note.txt", data: Data("hi there".utf8)),
                     "zip overhead swamps anything this small")
    }

    /// Winlink form workflows key on exact attachment names
    /// (RMS_Express_Form_*.xml); renaming one to .zip breaks the consumer.
    func testFormAttachmentsAreNeverTouched() {
        let xml = longRangeRedundantText(copies: 4)
        XCTAssertNil(AttachmentCompressor.zipped(name: "RMS_Express_Form_ICS213.xml", data: xml))
        XCTAssertNil(AttachmentCompressor.zipped(name: "report.xml", data: xml),
                     "xml is form territory — never rename it")
    }

    func testMarginalSavingIsNotWorthTheRename() {
        // Compressible, but only just: alternating structure with noise.
        var data = Data()
        for chunk in 0..<100 {
            data.append(highEntropy(400))
            data.append(Data("chunk \(chunk) separator\r\n".utf8))
        }
        if let z = AttachmentCompressor.zipped(name: "mixed.dat", data: data) {
            XCTAssertLessThanOrEqual(Double(z.data.count), Double(data.count) * 0.9,
                "if it does compress, the win must clear the 10% bar")
        }
    }
}

/// Test-side zip parser: reads the first local-header entry and inflates
/// it with the Compression framework — deliberately independent of the
/// writer so a structural bug cannot hide behind its own mirror image.
///
/// Kept separate from the app's `ZipReader` for that reason, and named
/// distinctly so it cannot shadow it inside the test module.
enum IndependentZipParser {
    struct Entry {
        let name: String
        let data: Data
        let crc32: UInt32
    }

    static func firstEntry(in archive: Data) -> Entry? {
        let b = [UInt8](archive)
        guard b.count > 30, b[0] == 0x50, b[1] == 0x4B, b[2] == 0x03, b[3] == 0x04 else { return nil }
        func le16(_ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }
        func le32(_ i: Int) -> UInt32 {
            UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
        }
        let method = le16(8)
        let crc = le32(14)
        let compSize = Int(le32(18))
        let uncompSize = Int(le32(22))
        let nameLen = le16(26)
        let extraLen = le16(28)
        let nameStart = 30
        guard b.count >= nameStart + nameLen + extraLen + compSize else { return nil }
        let name = String(bytes: b[nameStart..<nameStart + nameLen], encoding: .utf8) ?? ""
        let payload = Data(b[(nameStart + nameLen + extraLen)..<(nameStart + nameLen + extraLen + compSize)])

        let content: Data
        switch method {
        case 0:
            content = payload
        case 8:
            var out = Data(count: uncompSize + 64)
            let written = out.withUnsafeMutableBytes { dst in
                payload.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, uncompSize + 64,
                        src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written == uncompSize else { return nil }
            content = out.prefix(written)
        default:
            return nil
        }
        return Entry(name: name, data: content, crc32: crc)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Compose integration

@MainActor
final class ComposeAttachmentCompressionTests: XCTestCase {

    private func makeViewModel() throws -> WinlinkComposeViewModel {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return WinlinkComposeViewModel(
            store: SQLiteWinlinkStore(dbQueue: queue), myCallsign: "K0EPI")
    }

    private func bigText() -> Data {
        var block = ""
        for i in 0..<40 {
            block += "Entry \(i): the catalog row describes a data product and its identifier.\r\n"
        }
        return Data(String(repeating: block, count: 15).utf8)
    }

    func testAddingALargeTextAttachmentZipsIt() async throws {
        let vm = try makeViewModel()
        let original = bigText()
        vm.addAttachment(name: "catalog.txt", data: original)

        let item = vm.attachments[0]
        XCTAssertEqual(item.name, "catalog.txt.zip")
        XCTAssertTrue(item.isCompressed)
        XCTAssertLessThan(item.data.count, original.count / 2)
        XCTAssertEqual(item.original?.name, "catalog.txt")
        XCTAssertEqual(item.original?.data, original, "the exact original must be kept for undo")
    }

    func testSizeBudgetCountsTheZippedBytes() async throws {
        let vm = try makeViewModel()
        vm.addAttachment(name: "catalog.txt", data: bigText())
        XCTAssertEqual(vm.totalSizeBytes, vm.attachments[0].data.count,
                       "the budget must reflect what will actually be sent")
    }

    func testRevertRestoresTheOriginalExactly() async throws {
        let vm = try makeViewModel()
        let original = bigText()
        vm.addAttachment(name: "catalog.txt", data: original)
        vm.revertAttachmentCompression(id: vm.attachments[0].id)

        let item = vm.attachments[0]
        XCTAssertEqual(item.name, "catalog.txt")
        XCTAssertEqual(item.data, original)
        XCTAssertFalse(item.isCompressed)
    }

    func testUncompressibleAttachmentIsStoredVerbatim() async throws {
        let vm = try makeViewModel()
        var state: UInt64 = 99
        var noise = Data()
        for _ in 0..<20_000 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            noise.append(UInt8(truncatingIfNeeded: state))
        }
        vm.addAttachment(name: "noise.bin", data: noise)
        XCTAssertEqual(vm.attachments[0].name, "noise.bin")
        XCTAssertFalse(vm.attachments[0].isCompressed)
    }
}
