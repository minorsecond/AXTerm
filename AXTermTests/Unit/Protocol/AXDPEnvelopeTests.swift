//
//  AXDPEnvelopeTests.swift
//  AXTermTests
//
//  The AXDP envelope: "AXT1", the message's own length, then TLVs.
//
//  Before the length (2026-10-03) a receiver guessed where a message ended:
//  at the next magic, or where the frame ended. A frame that ended on a TLV
//  boundary inside a message looked whole, and the data after it was lost
//  until a frame happened to start with a magic. Any path that cuts the
//  stream into frames of its own (a NET/ROM node, a BPQ switch) could do
//  that. With the length, a message is whole exactly when its last byte has
//  arrived, however the bytes were cut.
//

import XCTest
@testable import AXTerm

final class AXDPEnvelopeTests: XCTestCase {

    // MARK: - Envelope

    func testTheHeaderCarriesTheWholeMessageLength() {
        let encoded = AXDP.Message(type: .chat, sessionId: 1, messageId: 2, payload: Data("hello".utf8)).encode()
        XCTAssertEqual(encoded.prefix(4), AXDP.magic)
        XCTAssertEqual(Int(AXDP.decodeUInt16(encoded.subdata(in: 4..<6))), encoded.count)
    }

    func testAPartialMessageNeedsMore() {
        let encoded = AXDP.Message(type: .chat, sessionId: 1, messageId: 2, payload: Data("hello".utf8)).encode()
        for cut in 0..<encoded.count {
            guard case .needMore = AXDP.Message.frame(encoded.prefix(cut)) else {
                return XCTFail("a message cut at \(cut) of \(encoded.count) bytes was not waited for")
            }
        }
    }

    /// The fault the length removes: a cut on a TLV boundary inside a
    /// message, which used to decode as a whole message without its payload.
    func testACutOnATLVBoundaryIsNotAWholeMessage() {
        let chunk = AXDP.Message(type: .fileChunk, sessionId: 7, messageId: 3, chunkIndex: 2,
                                 totalChunks: 9, payload: Data(repeating: 0x55, count: 300),
                                 payloadCRC32: 0xDEAD_BEEF).encode()
        // After the header, the type, session, message, chunk index and total.
        for cut in [6, 10, 17, 24, 31, 38] {
            guard case .needMore = AXDP.Message.frame(chunk.prefix(cut)) else {
                return XCTFail("a cut at \(cut) was taken for a whole message")
            }
        }
    }

    func testOnlyTheMessagesOwnBytesAreRead() {
        let message = AXDP.Message(type: .ping, sessionId: 4, messageId: 5).encode()
        guard case let .message(decoded, consumed) = AXDP.Message.frame(message + Data("trailing text".utf8)) else {
            return XCTFail("the message was not read")
        }
        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(consumed, message.count)
    }

    func testAnImpossibleLengthSkipsOnlyTheMagic() {
        var bad = AXDP.magic
        bad.append(AXDP.encodeUInt16(3))
        guard case .invalid(let skip) = AXDP.Message.frame(bad + Data(repeating: 0, count: 20)) else {
            return XCTFail("a length of 3 was accepted")
        }
        XCTAssertEqual(skip, AXDP.magic.count)
    }

    /// TLVs that do not fill the stated length mean the header is wrong, so
    /// the length cannot be trusted to skip by.
    func testTLVsThatDoNotFillTheMessageSkipOnlyTheMagic() {
        var encoded = AXDP.Message(type: .chat, sessionId: 1, messageId: 2, payload: Data("hello".utf8)).encode()
        let stated = encoded.count + 2
        encoded.replaceSubrange(4..<6, with: AXDP.encodeUInt16(UInt16(stated)))
        guard case .invalid(let skip) = AXDP.Message.frame(encoded + Data([0x06, 0x00])) else {
            return XCTFail("a message whose TLVs overran its length was accepted")
        }
        XCTAssertEqual(skip, AXDP.magic.count)
    }

    /// A well-formed message of a type this build does not know is skipped
    /// whole, and what follows it is still read.
    func testAnUnknownMessageTypeIsSkippedWhole() {
        var body = AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([0xEE])).encode()
        body.append(AXDP.TLV(type: AXDP.TLVType.sessionId.rawValue, value: AXDP.encodeUInt32(1)).encode())
        let unknown = AXDP.magic + AXDP.encodeUInt16(UInt16(AXDP.headerLength + body.count)) + body
        guard case .invalid(let skip) = AXDP.Message.frame(unknown) else {
            return XCTFail("an unknown message type was accepted")
        }
        XCTAssertEqual(skip, unknown.count)

        var reassembler = AXDPStreamReassembler()
        let next = AXDP.Message(type: .pong, sessionId: 1, messageId: 9)
        XCTAssertEqual(reassembler.append(unknown + next.encode()).map(\.type), [.pong])
    }

    func testUnknownTLVsInsideAMessageAreKept() {
        var encoded = AXDP.Message(type: .ping, sessionId: 4, messageId: 5).encode()
        encoded.append(AXDP.TLV(type: 0x7F, value: Data([1, 2, 3])).encode())
        encoded.replaceSubrange(4..<6, with: AXDP.encodeUInt16(UInt16(encoded.count)))
        let decoded = AXDP.Message.decodeMessage(from: encoded)
        XCTAssertEqual(decoded?.type, .ping)
        XCTAssertEqual(decoded?.unknownTLVs.map(\.type), [0x7F])
    }

    // MARK: - Stream reassembly

    func testTextBeforeAMessageIsDroppedAndTheMessageRead() {
        var reassembler = AXDPStreamReassembler()
        let message = AXDP.Message(type: .chat, sessionId: 0, messageId: 1, payload: Data("hi".utf8))
        let out = reassembler.append(Data("BPQ node> ".utf8) + message.encode())
        XCTAssertEqual(out.map(\.payload), [Data("hi".utf8)])
        XCTAssertTrue(reassembler.buffered.isEmpty)
    }

    func testPlainTextIsNotHeld() {
        var reassembler = AXDPStreamReassembler()
        XCTAssertTrue(reassembler.append(Data("just a chat line\r".utf8)).isEmpty)
        XCTAssertTrue(reassembler.buffered.isEmpty)
    }

    /// "A" at the end of one delivery and "XT1…" at the start of the next.
    func testAMagicSplitAcrossDeliveriesIsFound() {
        var reassembler = AXDPStreamReassembler()
        let encoded = AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode()
        XCTAssertTrue(reassembler.append(Data("text A".utf8) + encoded.prefix(1)).isEmpty)
        XCTAssertEqual(reassembler.append(encoded.dropFirst(1)).map(\.type), [.ping])
    }

    func testAResetDropsAHalfMessageAndTheNextIsRead() {
        var reassembler = AXDPStreamReassembler()
        let first = AXDP.Message(type: .fileChunk, sessionId: 1, messageId: 1, chunkIndex: 0, totalChunks: 2,
                                 payload: Data(repeating: 1, count: 400), payloadCRC32: 1).encode()
        XCTAssertTrue(reassembler.append(first.prefix(150)).isEmpty)
        reassembler = AXDPStreamReassembler()  // what a disconnect does
        let next = AXDP.Message(type: .chat, sessionId: 0, messageId: 2, payload: Data("after".utf8))
        XCTAssertEqual(reassembler.append(next.encode()).map(\.payload), [Data("after".utf8)])
    }

    /// The property: any sequence of messages, with noise between some of
    /// them, cut into deliveries at random places (a node re-cutting the
    /// stream, frames of any paclen, one byte at a time), comes out whole
    /// and in order, and nothing is held at the end.
    func testAnyCuttingOfTheStreamReassemblesTheSameMessages() {
        for seed in UInt64(1)...300 {
            var rng = PropertyRNG(seed: seed)
            var stream = Data()
            var expected: [AXDP.Message] = []
            for index in 0..<rng.int(in: 1...12) {
                if rng.chance(0.2) {
                    // Noise with no magic in it: a node prompt, a stray byte.
                    stream.append(Data("node> \r".utf8).prefix(rng.int(in: 1...7)))
                }
                let message = Self.randomMessage(&rng, id: UInt32(index))
                expected.append(message)
                stream.append(message.encode())
            }

            var reassembler = AXDPStreamReassembler()
            var got: [AXDP.Message] = []
            var offset = 0
            let oneByteAtATime = rng.chance(0.1)
            while offset < stream.count {
                let size = oneByteAtATime ? 1 : rng.int(in: 1...300)
                let end = min(stream.count, offset + size)
                got += reassembler.append(stream.subdata(in: offset..<end))
                offset = end
            }

            XCTAssertEqual(got.count, expected.count, "seed \(seed)")
            for (a, b) in zip(got, expected) {
                XCTAssertEqual(a.type, b.type, "seed \(seed)")
                XCTAssertEqual(a.messageId, b.messageId, "seed \(seed)")
                XCTAssertEqual(a.payload, b.payload, "seed \(seed)")
                XCTAssertEqual(a.chunkIndex, b.chunkIndex, "seed \(seed)")
            }
            XCTAssertTrue(reassembler.buffered.isEmpty, "seed \(seed): \(reassembler.buffered.count) bytes held")
        }
    }

    private static func randomMessage(_ rng: inout PropertyRNG, id: UInt32) -> AXDP.Message {
        let payload = Data((0..<rng.int(in: 1...900)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        switch rng.int(3) {
        case 0:
            return AXDP.Message(type: .chat, sessionId: 0, messageId: id, payload: payload)
        case 1:
            return AXDP.Message(type: .fileChunk, sessionId: 9, messageId: id, chunkIndex: id, totalChunks: 99,
                                payload: payload, payloadCRC32: AXDP.crc32(payload))
        default:
            return AXDP.Message(type: .ack, sessionId: 9, messageId: id)
        }
    }
}
