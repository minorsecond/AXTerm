import XCTest
@testable import AXTerm

final class B2FChecksumTests: XCTestCase {

    // MARK: - FBBCRC16 (B2F compressed-payload header)

    func testCRC16MatchesKnownVectorFromNewlineSample() {
        // From wl2k-go lzhuf_test.go samples[0]: compressing "\n" yields
        // 0e 8f | 01 00 00 00 | cb 00 — the leading 0x8f0e is the CRC16
        // over the remaining six bytes.
        let payload: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0xcb, 0x00]
        XCTAssertEqual(FBBCRC16.checksum(payload), 0x8f0e)
    }

    func testCRC16EmptyInput() {
        // CRC of nothing still folds in the two trailing zero bytes.
        XCTAssertEqual(FBBCRC16.checksum([UInt8]()), 0x0000)
    }

    func testCRC16IsOrderSensitive() {
        XCTAssertNotEqual(FBBCRC16.checksum([0x01, 0x02]), FBBCRC16.checksum([0x02, 0x01]))
    }

    // MARK: - Negated byte sum (proposal block + binary EOT)

    func testNegatedByteSumOfEmptyIsZero() {
        XCTAssertEqual(B2FChecksum.negatedByteSum(of: [UInt8]()), 0)
    }

    func testNegatedByteSumCancelsSum() {
        let samples: [[UInt8]] = [
            [0x01],
            [0xff, 0xff],
            Array("FC EM ABC123DEF456 100 90 0\r".utf8),
            (0...255).map { UInt8($0) },
        ]
        for bytes in samples {
            let checksum = B2FChecksum.negatedByteSum(of: bytes)
            XCTAssertTrue(B2FChecksum.validate(bytes: bytes, checksum: checksum))
        }
    }

    func testValidateRejectsWrongChecksum() {
        let bytes: [UInt8] = [0x10, 0x20, 0x30]
        let good = B2FChecksum.negatedByteSum(of: bytes)
        XCTAssertFalse(B2FChecksum.validate(bytes: bytes, checksum: good ^ 0x01))
    }
}
