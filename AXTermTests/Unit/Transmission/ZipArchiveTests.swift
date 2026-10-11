import XCTest
import Compression
@testable import AXTerm

/// A file sent to a station without AXTerm can go as a .zip by YAPP (retest
/// 2026-10-10, finding 12): AX.25 has no compression other software decodes,
/// but every desktop and phone opens a zip. One file per archive.
final class ZipArchiveTests: XCTestCase {

    private let date = Date(timeIntervalSince1970: 1_791_700_000)

    /// Reads back the one entry of an archive this writer made: enough of
    /// the format to check every field a reader relies on.
    private func readEntry(_ zip: Data) throws -> (name: String, method: UInt16, crc: UInt32, data: Data) {
        func u16(_ at: Int) -> UInt16 { UInt16(zip[at]) | UInt16(zip[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        XCTAssertEqual(u32(0), 0x04034B50, "local file header")
        let method = u16(8), crc = u32(14), compressed = Int(u32(18)), size = Int(u32(22))
        let nameLength = Int(u16(26)), extra = Int(u16(28))
        let name = String(decoding: zip[30..<(30 + nameLength)], as: UTF8.self)
        let start = 30 + nameLength + extra
        let body = zip[start..<(start + compressed)]
        // The central directory and its end record follow.
        XCTAssertEqual(u32(start + compressed), 0x02014B50, "central directory header")
        let end = zip.count - 22
        XCTAssertEqual(u32(end), 0x06054B50, "end of central directory")
        XCTAssertEqual(u16(end + 10), 1, "one entry")
        var out: Data
        if method == 8 {
            out = Data(count: size)
            let written = out.withUnsafeMutableBytes { dst in
                Data(body).withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            out = out.prefix(written)
        } else {
            out = Data(body)
        }
        return (name, method, crc, out)
    }

    func testTextIsDeflatedAndComesBackWhole() throws {
        let text = Data(String(repeating: "We the People of the United States, in Order to form a more perfect Union.\n",
                               count: 200).utf8)
        let zip = ZipArchive.single(name: "constitution.txt", data: text, modified: date)
        XCTAssertLessThan(zip.count, text.count / 3)

        let entry = try readEntry(zip)
        XCTAssertEqual(entry.name, "constitution.txt")
        XCTAssertEqual(entry.method, 8, "deflate")
        XCTAssertEqual(entry.crc, AXDP.crc32(text))
        XCTAssertEqual(entry.data, text)
    }

    /// Data deflate cannot shrink (a photo) is stored as it is.
    func testDataThatWillNotShrinkIsStored() throws {
        var random = SystemRandomNumberGenerator()
        let noise = Data((0..<2_000).map { _ in UInt8.random(in: 0...255, using: &random) })
        let entry = try readEntry(ZipArchive.single(name: "photo.jpg", data: noise, modified: date))
        XCTAssertEqual(entry.method, 0, "stored")
        XCTAssertEqual(entry.data, noise)
    }

    func testTheArchiveIsNamedForTheFile() {
        XCTAssertEqual(ZipArchive.archiveName(for: "constitution.txt"), "constitution.zip")
        XCTAssertEqual(ZipArchive.archiveName(for: "README"), "README.zip")
    }

    /// Offered only where AXDP's own compression cannot reach: YAPP, to a
    /// station not confirmed as AXTerm, for a file that shrinks.
    func testTheSheetOffersItOnlyWhereItHelps() {
        XCTAssertTrue(ZipArchive.isOffered(protocol: .yapp, peerIsAXTerm: false, fileShrinks: true))
        XCTAssertFalse(ZipArchive.isOffered(protocol: .axdp, peerIsAXTerm: true, fileShrinks: true))
        XCTAssertFalse(ZipArchive.isOffered(protocol: .yapp, peerIsAXTerm: true, fileShrinks: true),
                       "an AXTerm station gets AXDP, which compresses on its own")
        XCTAssertFalse(ZipArchive.isOffered(protocol: .yapp, peerIsAXTerm: false, fileShrinks: false))
    }
}
