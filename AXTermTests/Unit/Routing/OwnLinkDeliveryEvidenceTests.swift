//
//  OwnLinkDeliveryEvidenceTests.swift
//  AXTermTests
//
//  The estimator learns only from frames this station hears, so for our own
//  outbound link the evidence that our I-frames arrived is the peer's N(R)
//  advancing. That proves both halves of ETX: our frame reached the peer
//  (df) and the peer's acknowledgment reached us (dr). It was credited to dr
//  only, so after a 20 KB transfer with 4 resends in 176 frames (delivery
//  about 0.98) A→B read df 0.32, dr 0.43, quality 35 (smoke run 2026-10-03-1,
//  issue 93, test 13.2).
//

import XCTest
@testable import AXTerm

@MainActor
final class OwnLinkDeliveryEvidenceTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_300_000)
    private let me = "K0EPI-2", peer = "K0EPI-3"

    private func estimator() -> LinkQualityEstimator {
        LinkQualityEstimator(config: .default, clock: { [self] in self.clock })
    }

    private func frame(control: UInt8, type: FrameType) -> Packet {
        Packet(timestamp: clock, from: AX25Address(call: "K0EPI", ssid: 3),
               to: AX25Address(call: "K0EPI", ssid: 2), frameType: type, control: control,
               info: Data(), rawAx25: Data())
    }

    private func rr(_ nr: Int) -> Packet { frame(control: UInt8(0x01 | ((nr & 7) << 5)), type: .s) }
    private func srej(_ nr: Int) -> Packet { frame(control: UInt8(0x0D | ((nr & 7) << 5)), type: .s) }
    private var ua: Packet { frame(control: 0x73, type: .u) }

    private func hear(_ packet: Packet, into e: inout LinkQualityEstimator, after seconds: Double = 4) {
        clock = clock.addingTimeInterval(seconds)
        e.observePacket(packet, timestamp: clock)
    }

    /// What A hears from B during a clean transfer: the UA, then an RR every
    /// couple of frames with N(R) moving on, and two SREJs along the way.
    func testAPeerAcknowledgingOurFramesShowsOurLinkDelivering() throws {
        var e = estimator()
        hear(ua, into: &e)
        var nr = 0
        for step in 0..<88 {
            nr = (nr + 2) % 8
            hear(rr(nr), into: &e)
            if step == 30 || step == 60 { hear(srej(nr), into: &e, after: 1) }
        }
        let stats = e.linkStats(from: me, to: peer)
        let df = try XCTUnwrap(stats.dfEstimate)
        XCTAssertGreaterThan(df, 0.85, "our frames were acknowledged nearly every time")
        XCTAssertGreaterThan(try XCTUnwrap(stats.drEstimate), 0.85)
        XCTAssertGreaterThan(e.linkQuality(from: me, to: peer), 150)
    }

    /// The other side of it: a peer that keeps answering without
    /// acknowledging anything new, and asks for frames again, is not
    /// evidence of delivery.
    func testAPeerThatStopsAcknowledgingDoesNotLookLikeDelivery() throws {
        var e = estimator()
        hear(ua, into: &e)
        for _ in 0..<20 {
            hear(rr(3), into: &e)
            hear(srej(3), into: &e, after: 1)
        }
        let df = try XCTUnwrap(e.linkStats(from: me, to: peer).dfEstimate)
        XCTAssertLessThan(df, 0.5)
    }

    /// Beacons cannot report a loss, so once connected-mode frames have
    /// measured a link, the peer's beacons on that same link must not drag
    /// the measurement down toward the 0.4 presence credit.
    func testBeaconsDoNotUndoAMeasuredLink() throws {
        var e = estimator()
        for i in 0..<30 {
            hear(frame(control: UInt8((i % 8) << 1), type: .i), into: &e)
        }
        let measured = try XCTUnwrap(e.linkStats(from: peer, to: me).dfEstimate)
        XCTAssertGreaterThan(measured, 0.85)
        for _ in 0..<12 {
            hear(frame(control: 0x03, type: .ui), into: &e, after: 600)
        }
        let after = try XCTUnwrap(e.linkStats(from: peer, to: me).dfEstimate)
        XCTAssertEqual(after, measured, accuracy: 0.001)
    }

    /// Acknowledgments are evidence about our link only, never about the
    /// peer's own forward link to us.
    func testAcknowledgmentsDoNotCreditThePeersForwardLink() {
        var e = estimator()
        var nr = 0
        for _ in 0..<20 {
            nr = (nr + 1) % 8
            hear(rr(nr), into: &e)
        }
        let back = e.linkStats(from: peer, to: me)
        XCTAssertNil(back.drEstimate, "the peer's RRs say nothing about our acks reaching it")
    }
}
