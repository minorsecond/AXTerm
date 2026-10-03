//
//  BroadcastPaclenSplitTests.swift
//  AXTermTests
//
//  A broadcast longer than paclen goes out as several UI frames, each within
//  paclen (spec §6.3). Smoke run 2026-10-03-1, issue 3: a 293-byte broadcast
//  went out as one UI frame.
//

import XCTest
@testable import AXTerm

final class BroadcastPaclenSplitTests: XCTestCase {

    private func broadcast(_ text: String, axdp: Bool = true) -> TerminalTxViewModel {
        var vm = TerminalTxViewModel()
        vm.sourceCall = "K0EPI-3"
        vm.connectionMode = .datagram
        vm.useAXDP = axdp
        vm.composeText = text
        return vm
    }

    private let longText = String(repeating: "the quick brown fox jumps over the lazy dog 0123456789 ", count: 5)

    func testALongAXDPBroadcastIsSplitIntoChunksWithinPaclen() throws {
        let frames = broadcast(longText).buildOutboundFrames(paclen: 128)

        XCTAssertGreaterThan(frames.count, 1)
        let messages = try frames.map { frame -> AXDP.Message in
            XCTAssertLessThanOrEqual(frame.payload.count, 128)
            XCTAssertEqual(frame.frameType, "ui")
            return try XCTUnwrap(AXDP.Message.decodeMessage(from: frame.payload))
        }
        XCTAssertEqual(Set(messages.map(\.messageId)).count, 1, "the parts of one message share its id")
        XCTAssertEqual(messages.map(\.chunkIndex), (0..<frames.count).map { UInt32($0) })
        XCTAssertTrue(messages.allSatisfy { $0.totalChunks == UInt32(frames.count) })
        let joined = messages.compactMap(\.payload).reduce(Data(), +)
        XCTAssertEqual(String(data: joined, encoding: .utf8), longText)
    }

    func testAShortBroadcastIsOneFrameWithoutChunkFields() throws {
        let frames = broadcast("hello").buildOutboundFrames(paclen: 128)

        XCTAssertEqual(frames.count, 1)
        let message = try XCTUnwrap(AXDP.Message.decodeMessage(from: frames[0].payload))
        XCTAssertNil(message.chunkIndex)
        XCTAssertNil(message.totalChunks)
    }

    func testAPlainTextBroadcastIsSplitAtPaclen() {
        let frames = broadcast(longText, axdp: false).buildOutboundFrames(paclen: 128)

        XCTAssertEqual(frames.count, (longText.utf8.count + 127) / 128)
        XCTAssertTrue(frames.allSatisfy { $0.payload.count <= 128 })
        XCTAssertEqual(String(data: frames.map(\.payload).reduce(Data(), +), encoding: .utf8), longText)
    }

    func testACharacterIsNeverCutBetweenFrames() {
        let text = String(repeating: "é", count: 200)  // two bytes each
        for axdp in [true, false] {
            let frames = broadcast(text, axdp: axdp).buildOutboundFrames(paclen: 128)
            let parts: [Data] = frames.map { frame in
                axdp ? (AXDP.Message.decodeMessage(from: frame.payload)?.payload ?? Data()) : frame.payload
            }
            XCTAssertTrue(parts.allSatisfy { String(data: $0, encoding: .utf8) != nil }, "axdp=\(axdp)")
            XCTAssertEqual(String(data: parts.reduce(Data(), +), encoding: .utf8), text)
        }
    }

    /// The session cuts connected-mode data into I-frames itself.
    func testConnectedModeStaysOneFrame() {
        var vm = broadcast(longText)
        vm.connectionMode = .connected
        vm.destinationCall = "K0EPI-2"

        XCTAssertEqual(vm.buildOutboundFrames(paclen: 128).count, 1)
    }

    func testEnqueueingQueuesEveryPart() {
        var vm = broadcast(longText)
        let expected = vm.buildOutboundFrames(paclen: 128).count

        let ids = vm.enqueueCurrentMessageParts(paclen: 128)

        XCTAssertEqual(ids.count, expected)
        XCTAssertEqual(vm.queueEntries.count, expected)
        XCTAssertTrue(vm.composeText.isEmpty)
    }
}
