import XCTest
@testable import AXTerm

/// LZHUF codec tests for the Winlink B2F payload compression.
///
/// Interop fixtures come from la5nta/wl2k-go, which is itself validated
/// against live Winlink CMS/RMS traffic. A pure round-trip test cannot
/// catch a self-consistent-but-wrong port, so byte-exact comparison
/// against those fixtures is the load-bearing part of this suite.
final class LZHUFTests: XCTestCase {

    // MARK: - Known small vector (from wl2k-go lzhuf_test.go samples[0])

    func testCompressSingleNewlineMatchesKnownVector() throws {
        let compressed = LZHUF.encodeB2F(Data("\n".utf8))
        XCTAssertEqual(compressed, Data([0x0e, 0x8f, 0x01, 0x00, 0x00, 0x00, 0xcb, 0x00]))
    }

    func testDecompressSingleNewlineKnownVector() throws {
        let plain = try LZHUF.decodeB2F(Data([0x0e, 0x8f, 0x01, 0x00, 0x00, 0x00, 0xcb, 0x00]))
        XCTAssertEqual(plain, Data("\n".utf8))
    }

    // MARK: - Interop fixtures (byte-exact against wl2k-go)

    func testCompressGettysburgMatchesFixture() throws {
        XCTAssertEqual(LZHUF.encodeB2F(LZHUFFixtures.gettysburg), LZHUFFixtures.gettysburgLZH)
    }

    func testDecompressGettysburgFixture() throws {
        XCTAssertEqual(try LZHUF.decodeB2F(LZHUFFixtures.gettysburgLZH), LZHUFFixtures.gettysburg)
    }

    func testCompressRealB2FMessageMatchesFixture() throws {
        XCTAssertEqual(LZHUF.encodeB2F(LZHUFFixtures.b2fMessage), LZHUFFixtures.b2fMessageLZH)
    }

    func testDecompressRealB2FMessageFixture() throws {
        XCTAssertEqual(try LZHUF.decodeB2F(LZHUFFixtures.b2fMessageLZH), LZHUFFixtures.b2fMessage)
    }

    // MARK: - Round trips

    func testRoundTripEmpty() throws {
        let compressed = LZHUF.encodeB2F(Data())
        XCTAssertGreaterThanOrEqual(compressed.count, 6, "minimum valid B2F stream is 6 bytes")
        XCTAssertEqual(try LZHUF.decodeB2F(compressed), Data())
    }

    func testRoundTripSingleByte() throws {
        let plain = Data([0x41])
        XCTAssertEqual(try LZHUF.decodeB2F(LZHUF.encodeB2F(plain)), plain)
    }

    func testRoundTripAllByteValues() throws {
        let plain = Data((0...255).map { UInt8($0) })
        XCTAssertEqual(try LZHUF.decodeB2F(LZHUF.encodeB2F(plain)), plain)
    }

    func testRoundTripHighlyRepetitive() throws {
        let plain = Data(repeating: 0x55, count: 10_000)
        let compressed = LZHUF.encodeB2F(plain)
        XCTAssertLessThan(compressed.count, plain.count / 4, "repetitive data should compress well")
        XCTAssertEqual(try LZHUF.decodeB2F(compressed), plain)
    }

    func testRoundTripIncompressibleDeterministicNoise() throws {
        // Deterministic PRNG (xorshift) so the test never flakes.
        var state: UInt64 = 0x9E3779B97F4A7C15
        var bytes = [UInt8]()
        bytes.reserveCapacity(50_000)
        for _ in 0..<50_000 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes.append(UInt8(truncatingIfNeeded: state))
        }
        let plain = Data(bytes)
        XCTAssertEqual(try LZHUF.decodeB2F(LZHUF.encodeB2F(plain)), plain)
    }

    func testRoundTripAroundBufferBoundarySizes() throws {
        // Sizes straddling the 2048-byte ring buffer and the 60-byte lookahead.
        for size in [59, 60, 61, 2047, 2048, 2049, 4096] {
            let plain = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            XCTAssertEqual(try LZHUF.decodeB2F(LZHUF.encodeB2F(plain)), plain, "size \(size)")
        }
    }

    // MARK: - Corruption handling

    func testDecodeRejectsCorruptChecksum() throws {
        var corrupted = LZHUF.encodeB2F(Data("hello world".utf8))
        corrupted[0] ^= 0x01
        XCTAssertThrowsError(try LZHUF.decodeB2F(corrupted)) { error in
            XCTAssertEqual(error as? LZHUF.DecodeError, .checksumMismatch)
        }
    }

    func testDecodeRejectsTruncatedStream() throws {
        let compressed = LZHUF.encodeB2F(LZHUFFixtures.gettysburg)
        let truncated = compressed.prefix(10)
        XCTAssertThrowsError(try LZHUF.decodeB2F(Data(truncated)))
    }

    func testDecodeRejectsTooShortInput() throws {
        XCTAssertThrowsError(try LZHUF.decodeB2F(Data([0x00])))
        XCTAssertThrowsError(try LZHUF.decodeB2F(Data([0x00, 0x00, 0x00, 0x00, 0x00])))
    }
}
