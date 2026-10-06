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

    /// A broadcast is plain text whatever the AXDP setting: it reaches every
    /// station on the channel, and only AXTerm reads AXDP. Others saw "AXT1"
    /// and binary instead of the message (smoke run 2026-10-03-1, issue 2;
    /// operator 2026-10-06: plain text broadcasts, AXDP only to connected
    /// stations that have proven they speak it).
    func testABroadcastIsPlainTextEvenWithAXDPOn() {
        let frames = broadcast("hello from K0EPI-3", axdp: true).buildOutboundFrames(paclen: 128)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameType, "ui")
        XCTAssertFalse(AXDP.hasMagic(frames[0].payload))
        XCTAssertEqual(String(data: frames[0].payload, encoding: .utf8), "hello from K0EPI-3")
    }

    func testALongBroadcastIsSplitAtPaclenAsPlainText() {
        for axdp in [true, false] {
            let frames = broadcast(longText, axdp: axdp).buildOutboundFrames(paclen: 128)

            XCTAssertEqual(frames.count, (longText.utf8.count + 127) / 128, "axdp=\(axdp)")
            XCTAssertTrue(frames.allSatisfy { $0.payload.count <= 128 && !AXDP.hasMagic($0.payload) })
            XCTAssertEqual(String(data: frames.map(\.payload).reduce(Data(), +), encoding: .utf8), longText)
        }
    }

    func testACharacterIsNeverCutBetweenFrames() {
        let text = String(repeating: "é", count: 200)  // two bytes each
        let frames = broadcast(text).buildOutboundFrames(paclen: 128)
        XCTAssertTrue(frames.allSatisfy { String(data: $0.payload, encoding: .utf8) != nil })
        XCTAssertEqual(String(data: frames.map(\.payload).reduce(Data(), +), encoding: .utf8), text)
    }

    /// AXDP stays for a connected session, where the terminal sends it only
    /// once the station has proven it speaks AXDP.
    func testAConnectedMessageWithAXDPOnIsStillAXDP() throws {
        var vm = broadcast("hello", axdp: true)
        vm.connectionMode = .connected
        vm.destinationCall = "K0EPI-2"

        let frame = try XCTUnwrap(vm.buildOutboundFrame())
        XCTAssertTrue(AXDP.hasMagic(frame.payload))
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
