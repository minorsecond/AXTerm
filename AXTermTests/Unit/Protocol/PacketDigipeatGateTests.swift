//
//  PacketDigipeatGateTests.swift
//  AXTermTests
//
//  Locks in Packet.isFullyDigipeated — the gate that keeps the session layer
//  from acting on frames still in a digipeater's custody.
//
//  Field capture 2026-08-22 (KB5YZB-7 via DRLNOD): on a TCP KISS attachment to
//  the digipeater's own TNC, both copies of every digipeated frame are heard —
//  the original in transit toward the digi (H bit clear) and the repeated copy
//  (H bit set). The pre-digipeat UA was processed two seconds before the real
//  delivered copy, double-processing the exchange.
//

import XCTest
@testable import AXTerm

final class PacketDigipeatGateTests: XCTestCase {

    private func packet(via: [AX25Address]) -> Packet {
        Packet(
            from: AX25Address(call: "KB5YZB", ssid: 7),
            to: AX25Address(call: "K0EPI", ssid: 7),
            via: via,
            frameType: .u,
            control: 0x73
        )
    }

    /// A direct frame (no digis) is always deliverable.
    func testDirectFrameIsFullyDigipeated() {
        XCTAssertTrue(packet(via: []).isFullyDigipeated)
    }

    /// A frame whose single digi has repeated it (H=1) is deliverable.
    func testRepeatedSingleDigiIsFullyDigipeated() {
        let p = packet(via: [AX25Address(call: "DRLNOD", ssid: 0, repeated: true)])
        XCTAssertTrue(p.isFullyDigipeated)
    }

    /// The in-transit copy (H=0) is NOT ours to act on — it is still in the
    /// digipeater's custody.
    func testInTransitSingleDigiIsNotFullyDigipeated() {
        let p = packet(via: [AX25Address(call: "DRLNOD", ssid: 0, repeated: false)])
        XCTAssertFalse(p.isFullyDigipeated)
    }

    /// Multi-hop: every digi must have actioned the frame.
    func testPartiallyRepeatedMultiHopIsNotFullyDigipeated() {
        let p = packet(via: [
            AX25Address(call: "DRLNOD", ssid: 0, repeated: true),
            AX25Address(call: "FNKTWN", ssid: 0, repeated: false)
        ])
        XCTAssertFalse(p.isFullyDigipeated)
    }

    /// Multi-hop, fully actioned.
    func testFullyRepeatedMultiHopIsFullyDigipeated() {
        let p = packet(via: [
            AX25Address(call: "DRLNOD", ssid: 0, repeated: true),
            AX25Address(call: "FNKTWN", ssid: 0, repeated: true)
        ])
        XCTAssertTrue(p.isFullyDigipeated)
    }
}
