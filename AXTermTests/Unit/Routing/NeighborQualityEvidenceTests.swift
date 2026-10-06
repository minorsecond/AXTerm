//
//  NeighborQualityEvidenceTests.swift
//  AXTermTests
//
//  CLAUDE.md §8: routing metrics are evidence-based. A neighbor's quality
//  read 162 beside links of 229 and 169 (smoke run 2026-10-03-1, issue 97):
//  in hybrid mode each direct frame moved it toward the measured link
//  quality, and passive inference then moved it again toward a fixed 60.
//  After that was fixed it still trailed the link (145 beside 167 and 205),
//  because it was a second running average sampled only on some frame
//  types. The operator asked for it to follow the science: like ETX
//  routing (De Couto et al., 2003), the neighbor's quality is now read from
//  the link estimator, 255 / ETX of the link from us to it.
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
        // B's RRs moving N(R) on measure the link from us to B (issue 93).
        let toNeighbor = integration.linkQuality(from: "K0EPI-2", to: "K0EPI-3")
        XCTAssertGreaterThan(toNeighbor, 150, "the link itself is healthy")
        let neighbor = try XCTUnwrap(integration.currentNeighbors().first { $0.call == "K0EPI-3" })
        XCTAssertEqual(neighbor.quality, toNeighbor,
                       "255 / ETX of the link traffic to the neighbor would use, with no second average")
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
        // Nothing was ever sent to W0ARP-1, so the link from it stands in,
        // on the assumption that the path is symmetric.
        XCTAssertEqual(integration.linkQuality(from: "K0EPI-2", to: "W0ARP-1"), 0)
        let fromNeighbor = integration.linkQuality(from: "W0ARP-1", to: "K0EPI-2")
        XCTAssertGreaterThan(fromNeighbor, 150)
        let neighbor = try XCTUnwrap(integration.currentNeighbors().first { $0.call == "W0ARP-1" })
        XCTAssertEqual(neighbor.quality, fromNeighbor)
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

    /// The Quality tooltip only defined the term; it now gives the
    /// derivation of the number shown.
    func testTheQualityTooltipGivesTheDerivation() {
        let toB = LinkStatRecord(fromCall: "K0EPI-2", toCall: "K0EPI-3", quality: 229, lastUpdated: Date(),
                                 dfEstimate: 0.95, drEstimate: 0.94, observationCount: 132)
        let fromB = LinkStatRecord(fromCall: "K0EPI-3", toCall: "K0EPI-2", quality: 169, lastUpdated: Date(),
                                   dfEstimate: 0.67, observationCount: 40)
        let tip = NeighborDisplayInfo.qualityTooltip(
            call: "K0EPI-3", quality: 229, sourceType: "classic", localCallsign: "K0EPI-2",
            toNeighbor: toB, fromNeighbor: fromB)
        XCTAssertTrue(tip.hasPrefix("Quality: 229 (90%)"), tip)
        XCTAssertTrue(tip.contains("255 / ETX of the link K0EPI-2 → K0EPI-3"), tip)
        XCTAssertTrue(tip.contains("df 0.95 × dr 0.94 → ETX 1.12, from 132 observations"), tip)
        XCTAssertTrue(tip.contains("K0EPI-3 → K0EPI-2: 169"), tip)

        let heardOnly = NeighborDisplayInfo.qualityTooltip(
            call: "K0EPI-3", quality: 169, sourceType: "classic", localCallsign: "K0EPI-2",
            toNeighbor: nil, fromNeighbor: fromB)
        XCTAssertTrue(heardOnly.contains("Nothing has been sent to K0EPI-3 yet"), heardOnly)
        XCTAssertTrue(heardOnly.contains("dr unobserved (0.99 assumed)"), heardOnly)

        let tentative = NeighborDisplayInfo.qualityTooltip(
            call: "K0EPI-3", quality: 191, sourceType: "classic", localCallsign: "K0EPI-2",
            toNeighbor: LinkStatRecord(fromCall: "K0EPI-2", toCall: "K0EPI-3", quality: 191, lastUpdated: Date(),
                                       dfEstimate: 0.75, observationCount: 3),
            fromNeighbor: nil)
        XCTAssertTrue(tentative.contains("tentative"), tentative)

        let unmeasured = NeighborDisplayInfo.qualityTooltip(
            call: "W0ARP-1", quality: 62, sourceType: "inferred", localCallsign: "K0EPI-2",
            toNeighbor: nil, fromNeighbor: nil)
        XCTAssertTrue(unmeasured.contains("No link to W0ARP-1 measured yet"), unmeasured)
    }
}
