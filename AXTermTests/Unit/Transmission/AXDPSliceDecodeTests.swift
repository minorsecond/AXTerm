//
//  AXDPSliceDecodeTests.swift
//  AXTermTests
//
//  AXDP decodes from any Data, including a slice whose indices do not start
//  at zero.
//
//  The receive buffer drops each decoded message from its front, which can
//  leave the next message in a Data whose startIndex is past zero. The
//  decoder read bytes by absolute offset from zero and crashed. Before the
//  sender packed chunks into full frames (smoke run 2026-10-03-1, issue 9) a
//  message rarely shared a frame with the start of the next, so this went
//  unseen.
//

import XCTest
@testable import AXTerm

final class AXDPSliceDecodeTests: XCTestCase {

    private let message = AXDP.Message(type: .fileChunk, sessionId: 7, messageId: 3, chunkIndex: 2,
                                       totalChunks: 9, payload: Data((0..<200).map { UInt8($0) }),
                                       payloadCRC32: 0x1234_5678)

    func testAMessageInASliceDecodes() throws {
        let slice = (Data(repeating: 0xEE, count: 37) + message.encode()).dropFirst(37)
        XCTAssertNotEqual(slice.startIndex, 0, "precondition: a slice past zero")

        let decoded = try XCTUnwrap(AXDP.Message.decode(from: slice))
        XCTAssertEqual(decoded.0.payload, message.payload)
        XCTAssertEqual(decoded.0.chunkIndex, 2)
        XCTAssertEqual(decoded.1, message.encode().count)
    }

    func testTwoMessagesBackToBackDecodeInTurn() throws {
        var buffer = message.encode() + message.encode()
        let first = try XCTUnwrap(AXDP.Message.decode(from: buffer))
        buffer.removeFirst(first.1)
        let second = try XCTUnwrap(AXDP.Message.decode(from: buffer))
        XCTAssertEqual(second.0.payload, message.payload)
        XCTAssertEqual(second.1, buffer.count)
    }

    func testAPartialMessageInASliceWaitsForMore() {
        let encoded = message.encode()
        let slice = (Data(repeating: 0xEE, count: 5) + encoded.prefix(100)).dropFirst(5)
        XCTAssertNil(AXDP.Message.decode(from: slice))
    }
}
