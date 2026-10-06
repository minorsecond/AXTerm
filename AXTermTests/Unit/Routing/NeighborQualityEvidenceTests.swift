//
//  NeighborQualityEvidenceTests.swift
//  AXTermTests
//
//  CLAUDE.md §8: routing metrics are evidence-based. A neighbor's quality
//  read 162 beside links of 229 and 169 (smoke run 2026-10-03-1, issue 97):
//  in hybrid mode each direct frame moved it toward the measured link
//  quality, and passive inference then moved it again toward a fixed 60.
//

import XCTest
@testable import AXTerm

@MainActor
final class NeighborQualityEvidenceTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_791_100_000)

    override func setUp() {
        super.setUp()
        CallsignValidator.configureIgnoredServiceEndpoints([])
    }

    private func frame(from: (String, Int), to: (String, Int), control: UInt8, type: FrameType,
                       via: [AX25Address] = [], info: Int = 0) -> Packet {
        Packet(timestamp: clock, from: AX25Address(call: from.0, ssid: from.1),
               to: AX25Address(call: to.0, ssid: to.1), via: via, frameType: type, control: control,
               info: Data(count: info), rawAx25: Data())
    }

    private func hear(_ packet: Packet, into integration: NetRomIntegration, after seconds: Double = 4) {
        clock = clock.addingTimeInterval(seconds)
        integration.observePacket(packet, timestamp: clock)
    }

    private func measured(_ integration: NetRomIntegration, _ a: String, _ b: String) -> Int {
        let forward = integration.linkQuality(from: a, to: b)
        let reverse = integration.linkQuality(from: b, to: a)
        return forward > 0 && reverse > 0 ? (forward + reverse) / 2 : max(forward, reverse)
    }

    /// What A (705) hears from B (ID-50) during a transfer: B's RRs moving
    /// N(R) on, and the odd I-frame of B's own.
    func testADirectNeighborsQualityFollowsItsMeasuredLink() throws {
        let integration = NetRomIntegration(localCallsign: "K0EPI-2", mode: .hybrid)
        var nr = 0, ns = 0
        for step in 0..<80 {
            nr = (nr + 2) % 8
            hear(frame(from: ("K0EPI", 3), to: ("K0EPI", 2), control: UInt8(0x01 | (nr << 5)), type: .s),
                 into: integration)
            if step % 10 == 0 {
                hear(frame(from: ("K0EPI", 3), to: ("K0EPI", 2), control: UInt8((nr << 5) | (ns << 1)),
                           type: .i, info: 40), into: integration, after: 1)
                ns = (ns + 1) % 8
            }
        }
        let link = measured(integration, "K0EPI-3", "K0EPI-2")
        XCTAssertGreaterThan(link, 150, "the link itself is healthy")
        let neighbor = try XCTUnwrap(integration.currentNeighbors().first { $0.call == "K0EPI-3" })
        // A running average refreshed by the frames that refresh a neighbor
        // (B's 8 I-frames here, not its RRs), so it trails the link a little.
        XCTAssertEqual(Double(neighbor.quality), Double(link), accuracy: 20,
                       "the neighbor's quality is its measured link, not a blend with a constant")
    }

    /// A digipeater A also hears directly: the traffic it repeats must not
    /// pull its measured quality toward the inferred prior.
    func testRepeatedTrafficDoesNotDragAMeasuredDigipeaterTowardThePrior() throws {
        let integration = NetRomIntegration(localCallsign: "K0EPI-2", mode: .hybrid)
        let digi = AX25Address(call: "W0ARP", ssid: 1, repeated: true)
        for step in 0..<40 {
            hear(frame(from: ("W0ARP", 1), to: ("K0EPI", 2), control: UInt8((step % 8) << 1),
                       type: .i, info: 40), into: integration)
            hear(frame(from: ("N0CALL", 7), to: ("KE0GB", 7), control: UInt8((step % 8) << 1),
                       type: .i, via: [digi], info: 40), into: integration, after: 1)
        }
        let link = measured(integration, "W0ARP-1", "K0EPI-2")
        XCTAssertGreaterThan(link, 150)
        let neighbor = try XCTUnwrap(integration.currentNeighbors().first { $0.call == "W0ARP-1" })
        XCTAssertEqual(Double(neighbor.quality), Double(link), accuracy: 12)
    }

    /// With no measurement at all, an inferred neighbor still starts from
    /// the documented prior rather than from nothing.
    func testAnUnmeasuredDigipeaterKeepsTheInferredPrior() throws {
        let integration = NetRomIntegration(localCallsign: "K0EPI-2", mode: .hybrid)
        let digi = AX25Address(call: "W0ARP", ssid: 1, repeated: true)
        for step in 0..<10 {
            hear(frame(from: ("N0CALL", 7), to: ("KE0GB", 7), control: UInt8((step % 8) << 1),
                       type: .i, via: [digi], info: 40), into: integration)
        }
        let neighbor = try XCTUnwrap(integration.currentNeighbors().first { $0.call == "W0ARP-1" })
        XCTAssertLessThan(neighbor.quality, 90, "no evidence: near the prior, \(neighbor.quality)")
    }

    /// The Quality tooltip only defined the term; it now says why.
    func testTheQualityTooltipShowsTheMeasuredLinks() {
        let tip = NeighborDisplayInfo.qualityTooltip(
            call: "K0EPI-3", quality: 199, sourceType: "classic", localCallsign: "K0EPI-2",
            heardQuality: 169, sentQuality: 229)
        XCTAssertTrue(tip.hasPrefix("Quality: 199 (78%)"), tip)
        XCTAssertTrue(tip.contains("Measured now: K0EPI-3 → K0EPI-2 169, K0EPI-2 → K0EPI-3 229"), tip)
        XCTAssertTrue(tip.contains("Average of the two directions: 199"), tip)
        XCTAssertTrue(tip.contains("255 / ETX"), tip)

        let unmeasured = NeighborDisplayInfo.qualityTooltip(
            call: "W0ARP-1", quality: 62, sourceType: "inferred", localCallsign: "K0EPI-2",
            heardQuality: nil, sentQuality: nil)
        XCTAssertTrue(unmeasured.contains("No link to W0ARP-1 measured yet"), unmeasured)
        XCTAssertTrue(unmeasured.contains("Inferred"), unmeasured)
    }
}
