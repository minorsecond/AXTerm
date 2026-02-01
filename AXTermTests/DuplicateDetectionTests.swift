//
//  DuplicateDetectionTests.swift
//  AXTermTests
//
//  Tests for packet duplicate detection and KISS/AGWPE dedup behavior.
//

import XCTest
@testable import AXTerm

@MainActor
final class DuplicateDetectionTests: XCTestCase {
    private func makeIFrame(from: String, to: String, ns: UInt8, payload: [UInt8], timestamp: Date) -> Packet {
        let control = (ns << 1) & 0x0E
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .i,
            control: control,
            controlByte1: 0x00,
            pid: 0xF0,
            info: Data(payload),
            rawAx25: Data(payload)
        )
    }

    func testKissIngestionDedupIgnoresImmediateDuplicates() {
        var tracker = PacketDuplicateTracker(source: .kiss, ingestionDedupWindow: 0.25, retryDuplicateWindow: 2.0)
        let base = Date(timeIntervalSince1970: 1_700_300_000)
        let packet = makeIFrame(from: "W0ABC", to: "N0CALL", ns: 1, payload: [0x41], timestamp: base)

        let first = tracker.status(for: packet, at: base)
        let second = tracker.status(for: packet, at: base.addingTimeInterval(0.1))

        XCTAssertEqual(first, .unique)
        XCTAssertEqual(second, .ingestionDedup, "KISS duplicates within ingestion window should be ignored.")
    }

    func testAgwpeTreatsDuplicatesAsRetries() {
        var tracker = PacketDuplicateTracker(source: .agwpe, ingestionDedupWindow: 0.0, retryDuplicateWindow: 2.0)
        let base = Date(timeIntervalSince1970: 1_700_300_100)
        let packet = makeIFrame(from: "W0ABC", to: "N0CALL", ns: 1, payload: [0x41], timestamp: base)

        let first = tracker.status(for: packet, at: base)
        let second = tracker.status(for: packet, at: base.addingTimeInterval(0.5))

        XCTAssertEqual(first, .unique)
        XCTAssertEqual(second, .retryDuplicate, "AGWPE duplicates should be treated as retry evidence.")
    }

    func testSignatureDistinguishesDifferentPayloads() {
        var tracker = PacketDuplicateTracker(source: .kiss, ingestionDedupWindow: 0.25, retryDuplicateWindow: 2.0)
        let base = Date(timeIntervalSince1970: 1_700_300_200)
        let packetA = makeIFrame(from: "W0ABC", to: "N0CALL", ns: 1, payload: [0x41], timestamp: base)
        let packetB = makeIFrame(from: "W0ABC", to: "N0CALL", ns: 1, payload: [0x42], timestamp: base)

        _ = tracker.status(for: packetA, at: base)
        let status = tracker.status(for: packetB, at: base.addingTimeInterval(0.1))

        XCTAssertEqual(status, .unique, "Different payloads should not be treated as duplicates.")
    }
}
