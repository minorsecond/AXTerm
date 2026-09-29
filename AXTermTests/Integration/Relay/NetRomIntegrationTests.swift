//
//  NetRomIntegrationTests.swift
//  AXTermTests
//
//  Created by Codex on 1/30/26.
//

import XCTest

/// Tests for NetRomIntegration which combines the router, passive inference,
/// and link quality estimator into a unified routing system.
@testable import AXTerm

final class NetRomIntegrationTests: XCTestCase {

    private func makePacket(
        from: String,
        to: String,
        via: [String] = [],
        frameType: FrameType = .ui,
        timestamp: Date
    ) -> Packet {
        let info = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0, repeated: true) },
            frameType: frameType,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
    }

    // MARK: - Routing Mode Tests

    func testClassicModeOnlyUsesExplicitBroadcasts() async {
        let integration = await NetRomIntegration(localCallsign: "N0CALL", mode: .classic)
        let now = Date(timeIntervalSince1970: 1_700_005_000)

        // Observe some direct packets
        await integration.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: now), timestamp: now)

        // In classic mode, we should have a neighbor from direct observation
        let neighbors = await integration.currentNeighbors()
        XCTAssertEqual(neighbors.count, 1)
        XCTAssertEqual(neighbors.first?.call, "W0ABC")

        // But no routes until explicit broadcast arrives
        let routes = await integration.currentRoutes()
        XCTAssertTrue(routes.isEmpty, "Classic mode should not infer routes without broadcasts.")
    }

    func testInferenceModeUsesPassiveObservations() async {
        let integration = await NetRomIntegration(localCallsign: "N0CALL", mode: .inference)
        let now = Date(timeIntervalSince1970: 1_700_005_100)

        // Observe packet via digipeater (W0ABC -> DIGI -> N0CALL)
        await integration.observePacket(
            makePacket(from: "W0ABC", to: "N0CALL", via: ["K1DIGI"], timestamp: now),
            timestamp: now
        )

        // Inference mode should create neighbor for digipeater
        let neighbors = await integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "K1DIGI" }, "Should infer neighbor from via path.")

        // And infer route to sender
        let routes = await integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "W0ABC" }, "Should infer route to sender.")
    }

    func testHybridModeUsesAllSources() async {
        let integration = await NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        let now = Date(timeIntervalSince1970: 1_700_005_200)

        // Direct observation
        await integration.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: now), timestamp: now)

        // Via observation
        await integration.observePacket(
            makePacket(from: "W1XYZ", to: "N0CALL", via: ["K1DIGI"], timestamp: now.addingTimeInterval(1)),
            timestamp: now.addingTimeInterval(1)
        )

        let neighbors = await integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "W0ABC" }, "Should have direct neighbor.")
        XCTAssertTrue(neighbors.contains { $0.call == "K1DIGI" }, "Should have inferred neighbor from via path.")
    }

    // MARK: - Link Quality Integration Tests

    func testLinkQualityIntegration() async {
        let integration = await NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        let now = Date(timeIntervalSince1970: 1_700_005_300)

        // Send multiple packets to build link quality
        for offset in 0..<10 {
            let ts = now.addingTimeInterval(Double(offset))
            await integration.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        // Link quality should be tracked
        let quality = await integration.linkQuality(from: "W0ABC", to: "N0CALL")
        XCTAssertGreaterThan(quality, 0, "Link quality should be tracked.")
    }

    func testNeighborQualityInfluencedByLinkQuality() async {
        let integration = await NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        let now = Date(timeIntervalSince1970: 1_700_005_400)

        // Build up link quality with many consistent packets
        for offset in 0..<20 {
            let ts = now.addingTimeInterval(Double(offset) * 2)
            await integration.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let neighbors = await integration.currentNeighbors()
        guard let neighbor = neighbors.first(where: { $0.call == "W0ABC" }) else {
            XCTFail("Should have neighbor W0ABC")
            return
        }

        // Neighbor quality should be boosted by good link quality
        XCTAssertGreaterThan(neighbor.quality, 80, "Neighbor quality should benefit from link quality observations.")
    }

    // MARK: - Mode Switching Tests

    func testModeSwitching() async {
        let integration = await NetRomIntegration(localCallsign: "N0CALL", mode: .classic)
        let now = Date(timeIntervalSince1970: 1_700_005_500)

        // Observe via packet in classic mode
        await integration.observePacket(
            makePacket(from: "W0ABC", to: "N0CALL", via: ["K1DIGI"], timestamp: now),
            timestamp: now
        )

        // Classic mode should not infer routes from via paths
        var routes = await integration.currentRoutes()
        XCTAssertTrue(routes.isEmpty)

        // Switch to hybrid mode
        await integration.setMode(.hybrid)

        // Now observe another via packet
        await integration.observePacket(
            makePacket(from: "W1XYZ", to: "N0CALL", via: ["K2DIGI"], timestamp: now.addingTimeInterval(1)),
            timestamp: now.addingTimeInterval(1)
        )

        // Should now infer routes
        routes = await integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "W1XYZ" }, "Hybrid mode should infer routes.")
    }

    // MARK: - Export/Import Tests

    func testExportLinkStats() async {
        let integration = await NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
        let now = Date(timeIntervalSince1970: 1_700_005_600)

        for offset in 0..<5 {
            let ts = now.addingTimeInterval(Double(offset))
            await integration.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
        }

        let stats = await integration.exportLinkStats()
        XCTAssertFalse(stats.isEmpty, "Should export link stats.")
        XCTAssertTrue(stats.contains { $0.fromCall == "W0ABC" && $0.toCall == "N0CALL" })
    }

    // MARK: - Determinism Tests

    func testDeterministicBehavior() async {
        func runIntegration() async -> [NeighborInfo] {
            let integration = await NetRomIntegration(localCallsign: "N0CALL", mode: .hybrid)
            let now = Date(timeIntervalSince1970: 1_700_005_700)

            for offset in 0..<5 {
                let ts = now.addingTimeInterval(Double(offset))
                await integration.observePacket(makePacket(from: "W0ABC", to: "N0CALL", timestamp: ts), timestamp: ts)
            }

            return await integration.currentNeighbors()
        }

        let first = await runIntegration()
        let second = await runIntegration()
        XCTAssertEqual(first.count, second.count, "Should produce deterministic results.")
        XCTAssertEqual(first.first?.call, second.first?.call)
        XCTAssertEqual(first.first?.quality, second.first?.quality)
    }
}
