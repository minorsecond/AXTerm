//
//  AX25AddressCorpusTests.swift
//  AXTermTests
//
//  Real frames that must survive the strict address rules unchanged.
//
//  ax25-address-corpus.json holds every distinct frame from the AXTerm test
//  database (an overnight capture off the air, 2026-09-29), every frame_hex in
//  the other fixtures, and constructed frames for the shapes that capture has
//  none of: connected-mode I/S/U frames with digipeaters, NET/ROM, all sixteen
//  SSIDs, eight-digi paths, reserved SSID bits sent as zero. The expected
//  fields were produced by the decoder as it stood before the address rules,
//  so a pass here means the rules changed nothing a real station sends.
//
//  TestRig/scripts/ax25_address_corpus.py builds it. It transcribes the old
//  decoder and sets aside any frame the new rules would reject, which is how
//  the one frame under "rejected" (the overnight noise burst) was found.
//

import XCTest
@testable import AXTerm

final class AX25AddressCorpusTests: XCTestCase {

    struct Expect: Decodable {
        let to: String
        let from: String
        let via: [String]
        let control: UInt8
        let pid: UInt8?
        let frameType: String
        let infoHex: String

        enum CodingKeys: String, CodingKey {
            case to, from, via, control, pid
            case frameType = "frame_type"
            case infoHex = "info_hex"
        }
    }

    struct Frame: Decodable {
        let name: String
        let provenance: String
        let frameHex: String
        let expect: Expect

        enum CodingKeys: String, CodingKey {
            case name, provenance, expect
            case frameHex = "frame_hex"
        }
    }

    struct Rejected: Decodable {
        let name: String
        let frameHex: String

        enum CodingKeys: String, CodingKey {
            case name
            case frameHex = "frame_hex"
        }
    }

    struct Corpus: Decodable {
        let frames: [Frame]
        let rejected: [Rejected]
    }

    static let corpus: Corpus? = {
        guard let url = Bundle(for: AX25AddressCorpusTests.self)
                .url(forResource: "ax25-address-corpus", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Corpus.self, from: data)
    }()

    /// The raw bytes of every corpus frame, for the fuzz tests to mutate.
    static var corpusFrames: [Data] {
        (corpus?.frames ?? []).compactMap { Data(hexString: $0.frameHex) }
    }

    private func loadCorpus() throws -> Corpus {
        try XCTUnwrap(Self.corpus, "ax25-address-corpus.json is missing from the test bundle")
    }

    private static func show(_ address: AX25Address, markRepeated: Bool) -> String {
        address.display + (markRepeated && address.repeated ? "*" : "")
    }

    func testCorpusIsLargeAndVaried() throws {
        let corpus = try loadCorpus()
        XCTAssertGreaterThanOrEqual(corpus.frames.count, 140)
        let types = Set(corpus.frames.map(\.expect.frameType))
        XCTAssertEqual(types, ["UI", "I", "S", "U"])
        XCTAssertTrue(corpus.frames.contains { $0.expect.via.count == 8 })
        XCTAssertTrue(corpus.frames.contains { $0.expect.pid == 0xCF })
        XCTAssertTrue(corpus.frames.contains { $0.provenance.contains("off the air") })
    }

    func testEveryRealFrameDecodesExactlyAsBefore() throws {
        let corpus = try loadCorpus()
        for frame in corpus.frames {
            let raw = try XCTUnwrap(Data(hexString: frame.frameHex), frame.name)
            guard let decoded = AX25.decodeFrame(ax25: raw) else {
                XCTFail("\(frame.name) no longer decodes: \(AX25.decodeFailureReason(ax25: raw))")
                continue
            }
            let e = frame.expect
            XCTAssertEqual(decoded.to?.display, e.to, frame.name)
            XCTAssertEqual(decoded.from?.display, e.from, frame.name)
            XCTAssertEqual(decoded.via.map { Self.show($0, markRepeated: true) }, e.via, frame.name)
            XCTAssertEqual(decoded.control, e.control, frame.name)
            XCTAssertEqual(decoded.pid, e.pid, frame.name)
            XCTAssertEqual(decoded.frameType.rawValue, e.frameType, frame.name)
            XCTAssertEqual(decoded.info, Data(hexString: e.infoHex), frame.name)
        }
    }

    func testEveryRealFrameStillPassesTheDigipeaterGate() throws {
        // The digipeater refuses frames the decoder refuses. None of these
        // should be refused for that reason: a frame addressed via a call in
        // its own path must still be repeated.
        let corpus = try loadCorpus()
        for frame in corpus.frames where !frame.expect.via.isEmpty {
            let raw = try XCTUnwrap(Data(hexString: frame.frameHex))
            guard let firstUnused = frame.expect.via.first(where: { !$0.hasSuffix("*") }) else { continue }
            XCTAssertNotNil(AX25Digipeater.repeatFrame(raw, myAddresses: [firstUnused]),
                            "\(frame.name) should be repeated by \(firstUnused)")
        }
    }

    func testRecordedNoiseIsRefused() throws {
        let corpus = try loadCorpus()
        XCTAssertFalse(corpus.rejected.isEmpty)
        for bad in corpus.rejected {
            let raw = try XCTUnwrap(Data(hexString: bad.frameHex))
            XCTAssertNil(AX25.decodeFrame(ax25: raw), bad.name)
        }
    }
}
