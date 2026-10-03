//
//  AXDPFileChunkSizingTests.swift
//  AXTermTests
//
//  An AXDP file transfer fills its I-frames.
//
//  Smoke run 2026-10-03-1, issue 9: a 20 KB transfer from A (705) went out
//  as 167 frames of 128 bytes and 166 of 46. Each 128-byte chunk became a
//  174-byte message, cut on its own at paclen 128. Chunks are now sized so a
//  message is 768 bytes, which every rung of the paclen ladder divides, so
//  every frame of a chunk is full and each message still ends where a frame
//  ends. AXDP carries no message length; the receiver relies on that last
//  point (packing chunks across frames instead lost data, 2026-10-03).
//

import XCTest
@testable import AXTerm

final class AXDPFileChunkSizingTests: XCTestCase {

    func testAFileChunkMessageIs768Bytes() {
        let chunk = AXDP.Message(type: .fileChunk, sessionId: 0xFFFF_FFFF, messageId: 0xFFFF_FFFF,
                                 chunkIndex: 0xFFFF_FFFF, totalChunks: 0xFFFF_FFFF,
                                 payload: Data(repeating: 0xAA, count: SessionCoordinator.axdpFileChunkSize),
                                 payloadCRC32: 0xFFFF_FFFF, compression: .none)
        XCTAssertEqual(chunk.encode().count, 768)
    }

    func testEveryPaclenOnTheLadderDividesAMessage() {
        for paclen in [64, 128, 192, 256] {
            XCTAssertEqual(768 % paclen, 0, "paclen \(paclen)")
        }
    }

    /// No cut at those paclens lands on a TLV boundary inside a message,
    /// where the receiver could take the first part for a whole message.
    func testNoFrameEndsOnATLVBoundaryInsideAMessage() {
        // Ends of the header, the five fixed TLVs, the payload header, the payload.
        let boundaries = [6, 10, 17, 24, 31, 38, 41, 41 + SessionCoordinator.axdpFileChunkSize]
        for paclen in [64, 128, 192, 256] {
            for cut in stride(from: paclen, to: 768, by: paclen) {
                XCTAssertFalse(boundaries.contains(cut), "paclen \(paclen) cuts at \(cut)")
            }
        }
    }

    /// A transfer's chunks never go out as UI frames when the link is gone,
    /// and no AXDP UI frame exceeds the AX.25 default N1 of 256 bytes.
    @MainActor
    func testATransferChunkIsNotSentAsUIWithoutALink() {
        let station = FuzzStation(callsign: "K0AAA-1", seed: 1)
        defer { station.tearDown() }
        let peer = AX25Address(call: "K0BBB", ssid: 2)
        let before = station.link.framesSent

        XCTAssertFalse(station.coordinator.sendAXDPPayload(Data(repeating: 1, count: 100), to: peer,
                                                           path: DigiPath(), displayInfo: nil,
                                                           transferStream: true))
        XCTAssertFalse(station.coordinator.sendAXDPPayload(Data(repeating: 1, count: 300), to: peer,
                                                           path: DigiPath(), displayInfo: nil))
        XCTAssertEqual(station.link.framesSent, before)
    }

    @MainActor
    func testATransferSendsFullFrames() async {
        let a = FuzzStation(callsign: "K0AAA-1", seed: 1)
        let b = FuzzStation(callsign: "K0BBB-2", seed: 2)
        defer { a.tearDown(); b.tearDown() }
        a.link.traceLimit = 10_000
        a.connectLink(to: b)
        b.connectLink(to: a)
        if let sabm = a.coordinator.sessionManager.connect(to: b.address, path: DigiPath(),
                                                           radio: a.coordinator.primaryRadioID) {
            a.coordinator.sendFrame(sabm)
        }
        let up = await FullStackFuzz.wait(10) { a.session != nil && b.session != nil }
        XCTAssertTrue(up, "the link did not come up")
        a.coordinator.markImplicitlyConfirmedAXDP(for: b.callsign)
        b.coordinator.markImplicitlyConfirmedAXDP(for: a.callsign)

        var rng = PropertyRNG(seed: 9)
        let data = Data((0..<6000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "FULL.BIN", data: data,
                                                 transferProtocol: .axdp, compressionSettings: .disabled))
        let offered = await FullStackFuzz.wait(10) {
            b.coordinator.pendingIncomingTransfers.contains { $0.fileName == "FULL.BIN" }
        }
        XCTAssertTrue(offered)
        if let offer = b.coordinator.pendingIncomingTransfers.first(where: { $0.fileName == "FULL.BIN" }) {
            b.coordinator.acceptIncomingTransfer(offer.id)
        }
        let done = await FullStackFuzz.wait(60) {
            b.transfer(named: "FULL.BIN")?.status == .completed && a.transfer(named: "FULL.BIN")?.status == .completed
        }
        XCTAssertTrue(done, "the transfer did not complete")
        XCTAssertEqual(b.savedData(b.transfer(named: "FULL.BIN")), data)

        let sizes: [Int] = a.link.trace.compactMap { entry in
            guard entry.line.contains("> I s"),
                  let token = entry.line.split(separator: " ").last(where: { $0.hasSuffix("B") }) else { return nil }
            return Int(token.dropLast())
        }
        // 6000 bytes is 8 full chunks (64 full frames) and a short last one;
        // FILE_META and the completion exchange are short too. Nothing is
        // sent twice on a clean link.
        let short = sizes.filter { $0 < 128 }
        XCTAssertLessThanOrEqual(short.count, 6, "short frames: \(short)")
        XCTAssertLessThanOrEqual(sizes.count, 64 + 6 + 6, "frames: \(sizes.count)")
    }
}
