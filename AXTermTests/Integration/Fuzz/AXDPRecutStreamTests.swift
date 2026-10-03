//
//  AXDPRecutStreamTests.swift
//  AXTermTests
//
//  AXDP arrives whole when the frames it rode in were cut somewhere else.
//
//  A NET/ROM node or a BPQ switch between two stations re-cuts the byte
//  stream into frames of its own, so the far station's I-frames no longer
//  begin and end with AXDP messages. Before AXDP carried its own length
//  (2026-10-03), a frame ending on a TLV boundary inside a message looked
//  like a whole message, and what followed was dropped until a frame
//  happened to start with a magic.
//
//  Two complete stations over a clean link; A hands its session AXDP bytes
//  cut at random places, including every TLV boundary of the first message.
//

import XCTest
@testable import AXTerm

@MainActor
final class AXDPRecutStreamTests: XCTestCase {

    func testChatCutAnywhereArrivesWholeAndInOrder() async {
        let a = FuzzStation(callsign: "K0AAA-1", seed: 1)
        let b = FuzzStation(callsign: "K0BBB-2", seed: 2)
        defer { a.tearDown(); b.tearDown() }
        a.connectLink(to: b)
        b.connectLink(to: a)
        if let sabm = a.coordinator.sessionManager.connect(to: b.address, path: DigiPath(),
                                                           radio: a.coordinator.primaryRadioID) {
            a.coordinator.sendFrame(sabm)
        }
        let up = await FullStackFuzz.wait(10) { a.session != nil && b.session != nil }
        XCTAssertTrue(up, "the link did not come up")

        var received: [String] = []
        b.coordinator.onAXDPChatReceived = { _, text in received.append(text) }

        let lines = (1...12).map { "line \($0): " + String(repeating: "x", count: $0 * 37) }
        let stream = lines.enumerated().reduce(Data()) { stream, item in
            stream + AXDP.Message(type: .chat, sessionId: 0, messageId: UInt32(item.offset + 1),
                                  payload: Data(item.element.utf8)).encode()
        }

        // Cuts after the first message's header and each of its TLVs, then
        // at random places through the rest.
        var cuts = [6, 10, 17, 24]
        var rng = PropertyRNG(seed: 42)
        var at = 24
        while at < stream.count {
            at += rng.int(in: 1...97)
            cuts.append(min(at, stream.count))
        }
        var start = 0
        for cut in cuts where cut > start {
            let piece = stream.subdata(in: start..<cut)
            for frame in a.coordinator.sessionManager.sendData(piece, to: b.address, radio: a.coordinator.primaryRadioID) {
                a.coordinator.sendFrame(frame)
            }
            start = cut
        }

        let done = await FullStackFuzz.wait(20) { received.count == lines.count }
        XCTAssertTrue(done, "\(received.count) of \(lines.count) lines arrived")
        XCTAssertEqual(received, lines)
    }
}
