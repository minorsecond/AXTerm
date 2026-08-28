//
//  OutboundDeliveryPhaseTests.swift
//  AXTermTests
//
//  The delivery indicator's core promise: "Delivered" means the remote node
//  acknowledged, and nothing weaker. A digipeater retransmission is hop
//  evidence (digipeating is fire-and-forget — the digi doesn't ack, retry,
//  or know if anyone heard it), so it may advance the indicator only to
//  "Relayed".
//

import XCTest
@testable import AXTerm

final class OutboundDeliveryPhaseTests: XCTestCase {

    private func makeProgress(
        hasAcks: Bool = true,
        totalBytes: Int = 100,
        bytesSent: Int = 0,
        bytesAcked: Int = 0
    ) -> OutboundMessageProgress {
        OutboundMessageProgress(
            id: UUID(),
            text: String(repeating: "x", count: totalBytes),
            totalBytes: totalBytes,
            bytesSent: bytesSent,
            bytesAcked: bytesAcked,
            destination: "KB5YZB-7",
            ackPeer: "KB5YZB-7",
            timestamp: Date(),
            hasAcks: hasAcks,
            startingVs: 0,
            totalChunks: 1,
            paclen: 128,
            lastKnownVa: 0,
            chunksAcked: 0
        )
    }

    // MARK: - Connected-mode phase ladder

    func testPhaseLadderForConnectedMode() {
        var p = makeProgress()
        XCTAssertEqual(p.deliveryPhase, .queued)

        p.bytesSent = 50
        XCTAssertEqual(p.deliveryPhase, .sending)

        p.recordRelay(digis: ["DRLNOD"], at: Date())
        XCTAssertEqual(p.deliveryPhase, .relayed,
                       "a heard digi echo advances to relayed, not delivered")

        p.bytesAcked = 50
        XCTAssertEqual(p.deliveryPhase, .partiallyAcked,
                       "real ack progress outranks relay evidence")

        p.bytesAcked = 100
        XCTAssertEqual(p.deliveryPhase, .delivered)
    }

    func testRelayNeverClaimsDelivery() {
        var p = makeProgress(bytesSent: 100)
        p.recordRelay(digis: ["DRLNOD", "FNKTWN"], at: Date())
        XCTAssertEqual(p.deliveryPhase, .relayed)
        XCTAssertFalse(p.isComplete,
                       "every frame fully transmitted and relayed is still NOT delivered without the peer's ack")
    }

    // MARK: - Datagram (fire-and-forget) semantics

    func testDatagramNeverClaimsDelivered() {
        var p = makeProgress(hasAcks: false, bytesSent: 100)
        XCTAssertEqual(p.deliveryPhase, .sentDatagram,
                       "no ack exists for UI frames, so the terminal state is Sent")

        p.recordRelay(digis: ["DRLNOD"], at: Date())
        XCTAssertEqual(p.deliveryPhase, .relayed,
                       "for datagrams the digi echo is the strongest evidence that will ever exist")
    }

    // MARK: - Relay recording

    func testRecordRelayDedupsAndPreservesFirstHeardOrder() {
        var p = makeProgress(bytesSent: 10)
        p.recordRelay(digis: ["DRLNOD"], at: Date())
        p.recordRelay(digis: ["DRLNOD"], at: Date())          // duplicate echo copy
        p.recordRelay(digis: ["FNKTWN", "DRLNOD"], at: Date()) // second hop heard later
        XCTAssertEqual(p.relayedDigis, ["DRLNOD", "FNKTWN"],
                       "multi-hop paths accumulate digis in first-heard order, once each")
    }
}
