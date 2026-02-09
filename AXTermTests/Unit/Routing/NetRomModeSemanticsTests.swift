//
//  NetRomModeSemanticsTests.swift
//  AXTermTests
//
//  TDD tests for NET/ROM routing mode semantics.
//
//  AUDIT NOTES:
//  - NetRomPassiveInference.observePacket() has guard `normalizedTo == localCallsign`
//    which prevents inference from third-party traffic.
//  - Mode is used for data collection but NOT for filtering displayed data.
//  - sourceType is always "classic" or "broadcast", never "inferred".
//
//  TARGET BEHAVIOR:
//  - Classic: Only explicit NET/ROM broadcasts create routes. No inference.
//  - Inferred: Learn from ANY digipeated packet (third-party included).
//  - Hybrid: Union of Classic + Inferred.
//

import XCTest

@testable import AXTerm

@MainActor
final class NetRomModeSemanticsTests: XCTestCase {

    private let localCallsign = "K0EPI"

    // MARK: - Test Helpers

    private func makePacket(
        from: String,
        to: String,
        via: [String] = [],
        infoText: String = "TEST",
        frameType: FrameType = .ui,
        timestamp: Date
    ) -> Packet {
        let info = infoText.data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: frameType,
            control: 0,
            pid: nil,
            info: info,
            rawAx25: info,
            kissEndpoint: nil,
            infoText: infoText
        )
    }

    private func makeIntegration(mode: NetRomRoutingMode) -> NetRomIntegration {
        NetRomIntegration(
            localCallsign: localCallsign,
            mode: mode,
            routerConfig: NetRomConfig.default,
            inferenceConfig: NetRomInferenceConfig(
                evidenceWindowSeconds: 60,
                inferredRouteHalfLifeSeconds: 30,
                inferredBaseQuality: 120,
                reinforcementIncrement: 20,
                inferredMinimumQuality: 50,
                maxInferredRoutesPerDestination: 5,
                dataProgressWeight: 1.0,
                routingBroadcastWeight: 0.8,
                uiBeaconWeight: 0.4,
                ackOnlyWeight: 0.1,
                retryPenaltyMultiplier: 0.7
            ),
            linkConfig: LinkQualityConfig.default
        )
    }

    // MARK: - Classic Mode Tests

    func testClassicMode_ThirdPartyDigipeatedPacket_DoesNotCreateRoute() {
        // Given: Classic mode integration
        let integration = makeIntegration(mode: .classic)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

        // Packet A: Third-party digipeated traffic (NOT addressed to local)
        // K1AAA -> K3CCC via K2BBB
        let packetA = makePacket(
            from: "K1AAA",
            to: "K3CCC",  // NOT local callsign
            via: ["K2BBB"],
            infoText: "THIRD-PARTY DATA",
            timestamp: baseTime
        )

        // When: Observe the packet multiple times (reinforcement)
        for i in 0..<5 {
            integration.observePacket(packetA, timestamp: baseTime.addingTimeInterval(Double(i)))
        }

        // Then: No routes should be created in classic mode
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.isEmpty, "Classic mode should NOT create routes from third-party traffic")

        // And: No neighbors should be created from third-party via path
        let neighbors = integration.currentNeighbors()
        XCTAssertFalse(neighbors.contains { $0.call == "K2BBB" },
                       "Classic mode should NOT create neighbors from third-party via paths")
    }

    func testClassicMode_ExplicitBroadcast_CreatesRoute() {
        // Given: Classic mode with an established neighbor
        let integration = makeIntegration(mode: .classic)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_100)

        // First establish K2BBB as a neighbor via direct packet
        let directPacket = makePacket(
            from: "K2BBB",
            to: localCallsign,
            via: [],
            timestamp: baseTime
        )
        integration.observePacket(directPacket, timestamp: baseTime)

        // Then: K2BBB should be a neighbor
        XCTAssertTrue(integration.currentNeighbors().contains { $0.call == "K2BBB" })

        // When: Receive explicit NET/ROM broadcast from neighbor
        integration.broadcastRoutes(
            from: "K2BBB",
            quality: 200,
            destinations: [
                RouteInfo(destination: "K1AAA", origin: "K2BBB", quality: 200, path: ["K2BBB"], lastUpdated: baseTime.addingTimeInterval(1), sourceType: "broadcast")
            ],
            timestamp: baseTime.addingTimeInterval(1)
        )

        // Then: Route to K1AAA should exist
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "K1AAA" },
                      "Classic mode should create routes from explicit broadcasts")
    }

    func testClassicMode_DirectPacket_CreatesNeighbor() {
        // Given: Classic mode
        let integration = makeIntegration(mode: .classic)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_200)

        // When: Observe direct packet (no via path)
        let directPacket = makePacket(
            from: "W0ABC",
            to: localCallsign,
            via: [],
            timestamp: baseTime
        )
        integration.observePacket(directPacket, timestamp: baseTime)

        // Then: Neighbor should be created
        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "W0ABC" },
                      "Classic mode should create neighbors from direct packets")
    }

    // MARK: - Inferred Mode Tests

    func testInferredMode_ThirdPartyDigipeatedPacket_CreatesRoute() {
        // Given: Inferred mode integration
        let integration = makeIntegration(mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_300)

        // Packet A: Third-party digipeated traffic
        // K1AAA -> K3CCC via K2BBB (neither K1AAA nor K3CCC is local)
        let packetA = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            infoText: "THIRD-PARTY DATA",
            timestamp: baseTime
        )

        // When: Observe the packet multiple times for reinforcement
        for i in 0..<3 {
            integration.observePacket(packetA, timestamp: baseTime.addingTimeInterval(Double(i) * 2))
        }

        // Then: Should infer route to K1AAA via K2BBB
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "K1AAA" },
                      "Inferred mode should create routes from third-party digipeated traffic")

        // And: Route should have correct next hop
        if let route = routes.first(where: { $0.destination == "K1AAA" }) {
            XCTAssertTrue(route.path.contains("K2BBB"),
                          "Inferred route should use digipeater as next hop")
        }
    }

    func testInferredMode_ThirdPartyDigipeatedPacket_CreatesNeighborFromVia() {
        // Given: Inferred mode
        let integration = makeIntegration(mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_400)

        // Third-party packet via K2BBB
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime
        )

        // When: Observe
        integration.observePacket(packet, timestamp: baseTime)

        // Then: K2BBB should become a neighbor (as the observed digipeater)
        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "K2BBB" },
                      "Inferred mode should create neighbor from via path in third-party traffic")
    }

    func testInferredMode_DoesNotInferReverseRoute() {
        // Given: Inferred mode
        let integration = makeIntegration(mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_500)

        // K1AAA -> K3CCC via K2BBB
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime
        )

        // When: Observe
        for i in 0..<3 {
            integration.observePacket(packet, timestamp: baseTime.addingTimeInterval(Double(i)))
        }

        // Then: Should NOT infer reverse route K2BBB via K1AAA
        let routes = integration.currentRoutes()
        XCTAssertFalse(routes.contains { $0.destination == "K2BBB" && $0.path.contains("K1AAA") },
                       "Should not infer symmetric/reverse routes")
    }

    func testInferredMode_DoesNotInferRouteToSelf() {
        // Given: Inferred mode
        let integration = makeIntegration(mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_600)

        // Packet where local callsign is the destination
        let packet = makePacket(
            from: "K1AAA",
            to: localCallsign,  // Addressed TO us
            via: ["K2BBB"],
            timestamp: baseTime
        )

        // When: Observe
        integration.observePacket(packet, timestamp: baseTime)

        // Then: Should NOT create route to self
        let routes = integration.currentRoutes()
        XCTAssertFalse(routes.contains { $0.destination == localCallsign },
                       "Should never infer route to self")
    }

    func testInferredMode_DoesNotInferWhenLocalInViaPath() {
        // Given: Inferred mode
        let integration = makeIntegration(mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_700)

        // Packet that passed through us
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: [localCallsign, "K2BBB"],  // We are in the via path
            timestamp: baseTime
        )

        // When: Observe
        integration.observePacket(packet, timestamp: baseTime)

        // Then: Should NOT infer any route (avoid learning through ourselves)
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.isEmpty,
                      "Should not infer routes from packets that passed through us")
    }

    func testInferredMode_DoesNotInferWhenNextHopEqualsDestination() {
        // Given: Inferred mode
        let integration = makeIntegration(mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_800)

        // Packet where via == from (degenerate case)
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K1AAA"],  // Via equals the source
            timestamp: baseTime
        )

        // When: Observe
        integration.observePacket(packet, timestamp: baseTime)

        // Then: Should NOT create route where nextHop == destination
        let routes = integration.currentRoutes()
        XCTAssertFalse(routes.contains { $0.destination == "K1AAA" && $0.path.first == "K1AAA" },
                       "Should not infer route where nextHop equals destination")
    }

    func testInferredMode_InferredRoutesDecay() {
        // Given: Inferred mode
        let integration = makeIntegration(mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_900)

        // Create inferred route
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime
        )
        integration.observePacket(packet, timestamp: baseTime)

        // Verify route exists
        XCTAssertFalse(integration.currentRoutes().filter { $0.destination == "K1AAA" }.isEmpty,
                       "Route should exist initially")

        // When: Time passes beyond half-life without reinforcement
        let futureTime = baseTime.addingTimeInterval(120)  // Well beyond 30s half-life
        integration.purgeStaleData(currentDate: futureTime)

        // Then: Route should still be present (kept for display) but expired.
        // Evidence is purged but the route entry remains for the UI.
        XCTAssertFalse(integration.currentRoutes().filter { $0.destination == "K1AAA" }.isEmpty,
                       "Expired inferred routes should be kept for display")
    }

    // MARK: - Hybrid Mode Tests

    func testHybridMode_CombinesClassicAndInferred() {
        // Given: Hybrid mode
        let integration = makeIntegration(mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_001_000)

        // Create classic neighbor via direct packet
        let directPacket = makePacket(
            from: "W0ABC",
            to: localCallsign,
            via: [],
            timestamp: baseTime
        )
        integration.observePacket(directPacket, timestamp: baseTime)

        // Create inferred route via third-party packet
        let thirdPartyPacket = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime.addingTimeInterval(1)
        )
        for i in 0..<3 {
            integration.observePacket(thirdPartyPacket, timestamp: baseTime.addingTimeInterval(Double(i) + 1))
        }

        // Add classic broadcast
        integration.broadcastRoutes(
            from: "W0ABC",
            quality: 200,
            destinations: [
                RouteInfo(destination: "W1XYZ", origin: "W0ABC", quality: 200, path: ["W0ABC"], lastUpdated: baseTime.addingTimeInterval(1), sourceType: "broadcast")
            ],
            timestamp: baseTime.addingTimeInterval(5)
        )

        // Then: Should have both classic neighbor
        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "W0ABC" }, "Should have classic neighbor")

        // And: Should have inferred neighbor
        XCTAssertTrue(neighbors.contains { $0.call == "K2BBB" }, "Should have inferred neighbor")

        // And: Should have both classic and inferred routes
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "W1XYZ" }, "Should have classic route")
        XCTAssertTrue(routes.contains { $0.destination == "K1AAA" }, "Should have inferred route")
    }

    func testHybridMode_ClassicRoutePreferredOverInferred_SameDestination() {
        // Given: Hybrid mode
        let integration = makeIntegration(mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_001_100)

        // First: Create classic neighbor with multiple observations to boost quality
        for i in 0..<5 {
            let directPacket = makePacket(from: "W0ABC", to: localCallsign, via: [], timestamp: baseTime.addingTimeInterval(Double(i) * 0.5))
            integration.observePacket(directPacket, timestamp: directPacket.timestamp)
        }

        // Create inferred route to K1AAA via K2BBB (single observation = lower quality)
        let inferredPacket = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime.addingTimeInterval(10)
        )
        integration.observePacket(inferredPacket, timestamp: inferredPacket.timestamp)

        // Create classic route to SAME destination K1AAA via W0ABC with high advertised quality
        // Note: NET/ROM combines advertised quality with path quality, so actual stored quality will be lower
        integration.broadcastRoutes(
            from: "W0ABC",
            quality: 250,  // High advertised quality
            destinations: [
                RouteInfo(destination: "K1AAA", origin: "W0ABC", quality: 250, path: ["W0ABC"], lastUpdated: baseTime.addingTimeInterval(1), sourceType: "broadcast")
            ],
            timestamp: baseTime.addingTimeInterval(11)
        )

        // Then: Routes to K1AAA should exist
        let routes = integration.currentRoutes().filter { $0.destination == "K1AAA" }
        XCTAssertFalse(routes.isEmpty, "Should have route(s) to K1AAA")

        // Find the classic (broadcast) route and inferred route
        let classicRoute = routes.first { $0.sourceType == "broadcast" }
        let inferredRoute = routes.first { $0.sourceType == "inferred" }

        // The best route (first in sorted order by quality) should be the classic one
        // since it has higher advertised quality combined with a well-established path
        if let bestRoute = routes.first {
            // If both routes exist, the classic one should be preferred (higher quality)
            if let classic = classicRoute, let inferred = inferredRoute {
                XCTAssertGreaterThanOrEqual(classic.quality, inferred.quality,
                                            "Classic route with high advertised quality should have >= quality than single-observation inferred route")
            }
            // The best route should be classic (broadcast) type
            XCTAssertTrue(bestRoute.sourceType == "broadcast" || bestRoute.sourceType == "classic",
                          "Best route should be the classic/broadcast route")
        }
    }

    // MARK: - Determinism Tests

    func testInferredRoutes_DeterministicOrdering() {
        func runScenario() -> [RouteInfo] {
            let integration = makeIntegration(mode: .inference)
            let baseTime = Date(timeIntervalSince1970: 1_700_001_200)

            // Create multiple inferred routes
            let packets = [
                makePacket(from: "K1AAA", to: "K9ZZZ", via: ["K2BBB"], timestamp: baseTime),
                makePacket(from: "K3CCC", to: "K9ZZZ", via: ["K4DDD"], timestamp: baseTime.addingTimeInterval(1)),
                makePacket(from: "K5EEE", to: "K9ZZZ", via: ["K6FFF"], timestamp: baseTime.addingTimeInterval(2))
            ]

            for packet in packets {
                integration.observePacket(packet, timestamp: packet.timestamp)
            }

            return integration.currentRoutes()
        }

        let first = runScenario()
        let second = runScenario()

        XCTAssertEqual(first.count, second.count, "Route count should be deterministic")
        for (f, s) in zip(first, second) {
            XCTAssertEqual(f.destination, s.destination, "Route ordering should be deterministic")
            XCTAssertEqual(f.quality, s.quality, "Route quality should be deterministic")
        }
    }

    // MARK: - SourceType Tagging Tests

    func testInferredNeighbors_HaveCorrectSourceType() {
        // Given: Inferred mode
        let integration = makeIntegration(mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_001_300)

        // Create inferred neighbor
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime
        )
        integration.observePacket(packet, timestamp: baseTime)

        // Then: Neighbor should be tagged as inferred
        let neighbors = integration.currentNeighbors()
        if let neighbor = neighbors.first(where: { $0.call == "K2BBB" }) {
            XCTAssertEqual(neighbor.sourceType, "inferred",
                           "Neighbors created from inference should have sourceType 'inferred'")
        } else {
            XCTFail("Expected neighbor K2BBB to exist")
        }
    }

    func testInferredRoutes_HaveCorrectSourceType() {
        // Given: Inferred mode
        let integration = makeIntegration(mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_001_400)

        // Create inferred route
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime
        )
        for i in 0..<3 {
            integration.observePacket(packet, timestamp: baseTime.addingTimeInterval(Double(i)))
        }

        // Then: Route should be tagged as inferred
        let routes = integration.currentRoutes()
        if let route = routes.first(where: { $0.destination == "K1AAA" }) {
            XCTAssertEqual(route.sourceType, "inferred",
                           "Routes created from inference should have sourceType 'inferred'")
        } else {
            XCTFail("Expected route to K1AAA to exist")
        }
    }
}
