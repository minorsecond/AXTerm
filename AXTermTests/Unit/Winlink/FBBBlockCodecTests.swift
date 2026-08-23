import XCTest
@testable import AXTerm

final class FBBBlockCodecTests: XCTestCase {

    // MARK: - Encoding

    func testEncodeSmallPayloadLayout() {
        let payload = Data([0x10, 0x20, 0x30])
        let framed = FBBBlockCodec.encode(title: "T", offset: 0, payload: payload)

        var expected = Data()
        expected.append(0x01)                       // SOH
        expected.append(4)                          // "T" + NUL + "0" + NUL
        expected.append(contentsOf: Array("T".utf8))
        expected.append(0x00)
        expected.append(contentsOf: Array("0".utf8))
        expected.append(0x00)
        expected.append(0x02)                       // STX
        expected.append(3)
        expected.append(contentsOf: payload)
        expected.append(0x04)                       // EOT
        expected.append(UInt8(truncatingIfNeeded: 0 - (0x10 + 0x20 + 0x30)))
        XCTAssertEqual(framed, expected)
    }

    func testEncodeSplitsIntoMax125ByteBlocks() {
        let payload = Data(repeating: 0xAA, count: 300)
        let framed = FBBBlockCodec.encode(title: "x", offset: 0, payload: payload)
        // 300 bytes → blocks of 125 + 125 + 50.
        let stxLengths = extractSTXLengths(framed)
        XCTAssertEqual(stxLengths, [125, 125, 50])
    }

    func testEncodeHonorsResumeOffset() {
        let payload = Data((0..<200).map { UInt8($0) })
        let framed = FBBBlockCodec.encode(title: "t", offset: 150, payload: payload)

        let parser = FBBBlockCodec.Parser()
        let events = parser.feed(framed)
        guard case .header(_, let offset) = events.first else { return XCTFail("no header event") }
        XCTAssertEqual(offset, 150)
        guard case .completed(let received) = events.last else { return XCTFail("no completion") }
        XCTAssertEqual(received, payload.dropFirst(150))
    }

    // MARK: - Round trip through the parser

    func testRoundTripSingleFeed() {
        let payload = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let framed = FBBBlockCodec.encode(title: "MSG title", offset: 0, payload: payload)

        let parser = FBBBlockCodec.Parser()
        let events = parser.feed(framed)

        guard case .header(let title, let offset) = events.first else { return XCTFail("no header") }
        XCTAssertEqual(title, "MSG title")
        XCTAssertEqual(offset, 0)
        guard case .completed(let received) = events.last else { return XCTFail("no completion") }
        XCTAssertEqual(received, payload)
        XCTAssertTrue(parser.isComplete)
    }

    func testRoundTripByteAtATime() {
        // Chunk boundaries must never matter — feed one byte at a time.
        let payload = Data((0..<500).map { UInt8(truncatingIfNeeded: $0) })
        let framed = FBBBlockCodec.encode(title: "t", offset: 0, payload: payload)

        let parser = FBBBlockCodec.Parser()
        var completedPayload: Data?
        for byte in framed {
            for event in parser.feed(Data([byte])) {
                if case .completed(let data) = event { completedPayload = data }
                if case .checksumFailure = event { XCTFail("unexpected checksum failure") }
                if case .protocolError(let reason) = event { XCTFail("protocol error: \(reason)") }
            }
        }
        XCTAssertEqual(completedPayload, payload)
    }

    func testRoundTripEmptyPayload() {
        let framed = FBBBlockCodec.encode(title: "empty", offset: 0, payload: Data())
        let parser = FBBBlockCodec.Parser()
        let events = parser.feed(framed)
        guard case .completed(let received) = events.last else { return XCTFail("no completion") }
        XCTAssertEqual(received, Data())
    }

    // MARK: - Receiving the 256-byte block encoding

    func testParserAcceptsLengthZeroAs256() {
        let payload = Data(repeating: 0x42, count: 256)
        var framed = Data([0x01, 3])
        framed.append(contentsOf: Array("t".utf8))
        framed.append(0x00)
        framed.append(0x00)  // empty offset field
        framed.append(0x02)
        framed.append(0x00)  // length 0 = 256 bytes
        framed.append(payload)
        framed.append(0x04)
        framed.append(B2FChecksum.negatedByteSum(of: payload))

        let parser = FBBBlockCodec.Parser()
        let events = parser.feed(framed)
        guard case .completed(let received) = events.last else { return XCTFail("no completion, got \(events)") }
        XCTAssertEqual(received, payload)
    }

    // MARK: - Corruption

    func testParserReportsChecksumFailure() {
        let payload = Data([1, 2, 3, 4])
        var framed = FBBBlockCodec.encode(title: "t", offset: 0, payload: payload)
        framed[framed.count - 1] ^= 0xff

        let parser = FBBBlockCodec.Parser()
        let events = parser.feed(framed)
        guard case .checksumFailure = events.last else { return XCTFail("expected checksum failure") }
    }

    func testParserReportsProtocolErrorOnBadStart() {
        let parser = FBBBlockCodec.Parser()
        let events = parser.feed(Data([0x99]))
        guard case .protocolError = events.first else { return XCTFail("expected protocol error") }
    }

    func testParserReportsProgress() {
        let payload = Data(repeating: 0x01, count: 250)
        let framed = FBBBlockCodec.encode(title: "t", offset: 0, payload: payload)
        let parser = FBBBlockCodec.Parser()
        let progress = parser.feed(framed).compactMap { event -> Int? in
            if case .progress(let n) = event { return n }
            return nil
        }
        XCTAssertEqual(progress, [125, 250])
    }

    // MARK: - Helpers

    private func extractSTXLengths(_ framed: Data) -> [Int] {
        var lengths = [Int]()
        let bytes = [UInt8](framed)
        var i = 0
        // Skip SOH header.
        guard bytes[i] == 0x01 else { return [] }
        i += 2 + Int(bytes[1])
        while i < bytes.count, bytes[i] == 0x02 {
            let len = bytes[i + 1] == 0 ? 256 : Int(bytes[i + 1])
            lengths.append(len)
            i += 2 + len
        }
        return lengths
    }
}
