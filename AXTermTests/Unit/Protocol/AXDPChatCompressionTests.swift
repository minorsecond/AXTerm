import XCTest
@testable import AXTerm

/// AXDP chat is compressed when the other station can read it (retest
/// 2026-10-10, finding 11). The 26.8 KB constitution went uncompressed: about
/// 14 minutes at the link's 32 B/s, where deflate makes it 9.4 KB.
final class AXDPChatCompressionTests: XCTestCase {

    private func caps(_ algos: [AXDPCompression.Algorithm], features: AXDPCapability.Features = [.compression]) -> AXDPCapability {
        AXDPCapability(protoMin: 1, protoMax: AXDP.version, features: features,
                       compressionAlgos: algos, maxDecompressedLen: 262_144, maxChunkLen: 128)
    }

    /// Deflate shrinks text furthest, and the link is slow enough that size
    /// is all that matters.
    func testDeflateIsChosenWhenThePeerHasIt() {
        XCTAssertEqual(AXDPChatEncoder.algorithm(for: caps([.lz4, .deflate])), .deflate)
        XCTAssertEqual(AXDPChatEncoder.algorithm(for: caps([.lz4])), .lz4)
        XCTAssertEqual(AXDPChatEncoder.algorithm(for: caps([])), AXDPCompression.Algorithm.none)
        XCTAssertEqual(AXDPChatEncoder.algorithm(for: caps([.deflate], features: [])), AXDPCompression.Algorithm.none,
                       "a peer that does not claim compression gets none")
        XCTAssertEqual(AXDPChatEncoder.algorithm(for: nil), AXDPCompression.Algorithm.none,
                       "capabilities unknown: send it plain")
    }

    /// A long message goes compressed and comes back whole.
    func testALongMessageGoesCompressedAndComesBackWhole() throws {
        let line = "We the People of the United States, in Order to form a more perfect Union, establish Justice.\n"
        let text = String(repeating: line, count: 290)   // about 27 KB
        let wire = AXDPChatEncoder.encode(text: text, messageId: 7, peer: caps([.deflate, .lz4]))
        XCTAssertLessThan(wire.count, text.utf8.count / 2, "compressed on the air")

        guard case .message(let message, _) = AXDP.Message.frame(wire) else { return XCTFail("not a message") }
        XCTAssertEqual(message.type, .chat)
        XCTAssertEqual(message.payload.map { String(decoding: $0, as: UTF8.self) }, text)
    }

    /// A short line that would not shrink goes as it is.
    func testAShortLineGoesPlain() throws {
        let wire = AXDPChatEncoder.encode(text: "73", messageId: 1, peer: caps([.deflate]))
        guard case .message(let message, _) = AXDP.Message.frame(wire) else { return XCTFail("not a message") }
        XCTAssertEqual(message.payload, Data("73".utf8))
    }

    /// What this station tells others it can read.
    func testWeAdvertiseDeflateAndRoomForALongMessage() {
        let local = AXDPCapability.defaultLocal()
        XCTAssertTrue(local.compressionAlgos.contains(.deflate))
        XCTAssertGreaterThanOrEqual(local.maxDecompressedLen, 262_144)
        XCTAssertGreaterThanOrEqual(AXDPCompression.absoluteMaxDecompressedLen, 262_144)
    }
}
