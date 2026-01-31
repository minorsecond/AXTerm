//
//  NetRomRoutesPagesModeTests.swift
//  AXTermTests
//
//  TDD tests for mode consistency across Neighbors/Routes/Link Quality pages.
//
//  AUDIT NOTES:
//  - NetRomRoutesViewModel has routingMode but does NOT filter by sourceType.
//  - currentNeighbors(), currentRoutes() return ALL data regardless of mode.
//  - Mode picker is shared across all tabs but has no filtering effect.
//
//  TARGET BEHAVIOR:
//  - Classic: Show only classic-sourced data
//  - Inferred: Show only inferred-sourced data
//  - Hybrid: Show all data (union)
//

import XCTest

@testable import AXTerm

@MainActor
final class NetRomRoutesPagesModeTests: XCTestCase {

    private let localCallsign = "K0EPI"

    // MARK: - Test Helpers

    private func makePacket(
        from: String,
        to: String,
        via: [String] = [],
        infoText: String = "TEST",
        timestamp: Date
    ) -> Packet {
        let info = infoText.data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: .ui,
            control: 0,
            pid: nil,
            info: info,
            rawAx25: info,
            kissEndpoint: nil,
            infoText: infoText
        )
    }

    private func makeIntegrationWithMixedData() -> NetRomIntegration {
        let integration = NetRomIntegration(
            localCallsign: localCallsign,
            mode: .hybrid,
            routerConfig: NetRomConfig.default,
            inferenceConfig: NetRomInferenceConfig(
                evidenceWindowSeconds: 60,
                inferredRouteHalfLifeSeconds: 30,
                inferredBaseQuality: 120,
                reinforcementIncrement: 20,
                inferredMinimumQuality: 50,
                maxInferredRoutesPerDestination: 5
            ),
            linkConfig: LinkQualityConfig.default
        )

        let baseTime = Date(timeIntervalSince1970: 1_700_002_000)

        // 1. Create classic neighbor via direct packet
        let classicDirectPacket = makePacket(
            from: "W0ABC",
            to: localCallsign,
            via: [],
            timestamp: baseTime
        )
        integration.observePacket(classicDirectPacket, timestamp: baseTime)

        // 2. Create inferred neighbor via third-party digipeated packet
        let inferredPacket = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime.addingTimeInterval(1)
        )
        for i in 0..<3 {
            integration.observePacket(inferredPacket, timestamp: baseTime.addingTimeInterval(Double(i) + 1))
        }

        // 3. Create classic route via broadcast
        integration.broadcastRoutes(
            from: "W0ABC",
            quality: 200,
            destinations: [
                RouteInfo(destination: "W1XYZ", origin: "W0ABC", quality: 200, path: ["W0ABC"], lastUpdated: baseTime.addingTimeInterval(5), sourceType: "broadcast")
            ],
            timestamp: baseTime.addingTimeInterval(5)
        )

        // 4. Inferred route should already exist from step 2 (K1AAA via K2BBB)

        return integration
    }

    // MARK: - Neighbors Tab Mode Filtering Tests

    func testNeighborsTab_ClassicMode_ShowsOnlyClassicNeighbors() {
        // Given: Integration with mixed data
        let integration = makeIntegrationWithMixedData()

        // When: Query with classic mode filter
        integration.setMode(.classic)
        let neighbors = integration.currentNeighbors(forMode: .classic)

        // Then: Should only show classic neighbors
        XCTAssertTrue(neighbors.allSatisfy { $0.sourceType == "classic" },
                      "Classic mode should only show classic neighbors")
        XCTAssertTrue(neighbors.contains { $0.call == "W0ABC" },
                      "Should include classic neighbor W0ABC")
        XCTAssertFalse(neighbors.contains { $0.call == "K2BBB" },
                       "Should NOT include inferred neighbor K2BBB")
    }

    func testNeighborsTab_InferredMode_ShowsOnlyInferredNeighbors() {
        // Given: Integration with mixed data
        let integration = makeIntegrationWithMixedData()

        // When: Query with inferred mode filter
        integration.setMode(.inference)
        let neighbors = integration.currentNeighbors(forMode: .inference)

        // Then: Should only show inferred neighbors
        XCTAssertTrue(neighbors.allSatisfy { $0.sourceType == "inferred" },
                      "Inferred mode should only show inferred neighbors")
        XCTAssertTrue(neighbors.contains { $0.call == "K2BBB" },
                      "Should include inferred neighbor K2BBB")
        XCTAssertFalse(neighbors.contains { $0.call == "W0ABC" },
                       "Should NOT include classic neighbor W0ABC")
    }

    func testNeighborsTab_HybridMode_ShowsAllNeighbors() {
        // Given: Integration with mixed data
        let integration = makeIntegrationWithMixedData()

        // When: Query with hybrid mode
        integration.setMode(.hybrid)
        let neighbors = integration.currentNeighbors(forMode: .hybrid)

        // Then: Should show both classic and inferred
        XCTAssertTrue(neighbors.contains { $0.call == "W0ABC" },
                      "Hybrid mode should include classic neighbor")
        XCTAssertTrue(neighbors.contains { $0.call == "K2BBB" },
                      "Hybrid mode should include inferred neighbor")
    }

    // MARK: - Routes Tab Mode Filtering Tests

    func testRoutesTab_ClassicMode_ShowsOnlyClassicRoutes() {
        // Given: Integration with mixed data
        let integration = makeIntegrationWithMixedData()

        // When: Query with classic mode filter
        integration.setMode(.classic)
        let routes = integration.currentRoutes(forMode: .classic)

        // Then: Should only show classic/broadcast routes
        XCTAssertTrue(routes.allSatisfy { $0.sourceType == "classic" || $0.sourceType == "broadcast" },
                      "Classic mode should only show classic routes")
        XCTAssertTrue(routes.contains { $0.destination == "W1XYZ" },
                      "Should include classic route to W1XYZ")
        XCTAssertFalse(routes.contains { $0.destination == "K1AAA" },
                       "Should NOT include inferred route to K1AAA")
    }

    func testRoutesTab_InferredMode_ShowsOnlyInferredRoutes() {
        // Given: Integration with mixed data
        let integration = makeIntegrationWithMixedData()

        // When: Query with inferred mode filter
        integration.setMode(.inference)
        let routes = integration.currentRoutes(forMode: .inference)

        // Then: Should only show inferred routes
        XCTAssertTrue(routes.allSatisfy { $0.sourceType == "inferred" },
                      "Inferred mode should only show inferred routes")
        XCTAssertTrue(routes.contains { $0.destination == "K1AAA" },
                      "Should include inferred route to K1AAA")
        XCTAssertFalse(routes.contains { $0.destination == "W1XYZ" },
                       "Should NOT include classic route to W1XYZ")
    }

    func testRoutesTab_HybridMode_ShowsAllRoutes() {
        // Given: Integration with mixed data
        let integration = makeIntegrationWithMixedData()

        // When: Query with hybrid mode
        integration.setMode(.hybrid)
        let routes = integration.currentRoutes(forMode: .hybrid)

        // Then: Should show both
        XCTAssertTrue(routes.contains { $0.destination == "W1XYZ" },
                      "Hybrid should include classic route")
        XCTAssertTrue(routes.contains { $0.destination == "K1AAA" },
                      "Hybrid should include inferred route")
    }

    // MARK: - Link Quality Tab Mode Filtering Tests

    func testLinkQualityTab_ClassicMode_ShowsOnlyClassicLinks() {
        // Given: Integration with mixed data
        let integration = makeIntegrationWithMixedData()

        // When: Query with classic mode filter
        integration.setMode(.classic)
        let classicNeighbors = Set(integration.currentNeighbors(forMode: .classic).map { $0.call })
        let linkStats = integration.exportLinkStats(forMode: .classic)

        // Then: Should only show links involving classic neighbors
        for stat in linkStats {
            let involvesClassicNeighbor = classicNeighbors.contains(stat.fromCall) ||
                                          classicNeighbors.contains(stat.toCall) ||
                                          stat.fromCall == localCallsign ||
                                          stat.toCall == localCallsign
            XCTAssertTrue(involvesClassicNeighbor,
                          "Link \(stat.fromCall)->\(stat.toCall) should involve classic neighbor or local")
        }
    }

    func testLinkQualityTab_InferredMode_ShowsOnlyInferredLinks() {
        // Given: Integration with mixed data
        let integration = makeIntegrationWithMixedData()

        // When: Query with inferred mode filter
        integration.setMode(.inference)
        let inferredNeighbors = Set(integration.currentNeighbors(forMode: .inference).map { $0.call })
        let linkStats = integration.exportLinkStats(forMode: .inference)

        // Then: Should only show links involving inferred neighbors
        for stat in linkStats {
            let involvesInferredNeighbor = inferredNeighbors.contains(stat.fromCall) ||
                                           inferredNeighbors.contains(stat.toCall)
            XCTAssertTrue(involvesInferredNeighbor,
                          "Link \(stat.fromCall)->\(stat.toCall) should involve inferred neighbor")
        }
    }

    func testLinkQualityTab_HybridMode_ShowsAllLinks() {
        // Given: Integration with mixed data
        let integration = makeIntegrationWithMixedData()

        // When: Query with hybrid mode
        let allStats = integration.exportLinkStats(forMode: .hybrid)

        // Then: Should have some link stats
        XCTAssertFalse(allStats.isEmpty, "Hybrid mode should show link stats")
    }

    // MARK: - ViewModel Mode Binding Tests

    func testViewModel_ModeChangeTriggersRefresh() {
        // Given: ViewModel
        let integration = makeIntegrationWithMixedData()
        let viewModel = NetRomRoutesViewModel(integration: integration, settings: nil)

        // When: Change mode
        let initialRoutes = viewModel.routes.count
        viewModel.setMode(.classic)

        // Then: Data should be refreshed
        // Note: This may need async handling in real implementation
        XCTAssertNotNil(viewModel.lastRefresh, "Setting mode should trigger refresh")
    }

    func testViewModel_ModeAffectsAllTabs() {
        // Given: ViewModel in hybrid mode with mixed data
        let integration = makeIntegrationWithMixedData()
        let viewModel = NetRomRoutesViewModel(integration: integration, settings: nil)
        viewModel.setMode(.hybrid)

        // Capture hybrid counts
        let hybridNeighborsCount = viewModel.neighbors.count
        let hybridRoutesCount = viewModel.routes.count

        // When: Switch to classic mode
        viewModel.setMode(.classic)

        // Then: Both neighbors and routes should be filtered
        // (They should have fewer items since inferred items are excluded)
        let classicNeighbors = viewModel.neighbors.filter { $0.sourceType == "classic" }
        let classicRoutes = viewModel.routes.filter {
            $0.sourceType == "classic" || $0.sourceType == "broadcast"
        }

        XCTAssertEqual(viewModel.neighbors.count, classicNeighbors.count,
                       "Neighbors should be filtered to classic only")
        XCTAssertEqual(viewModel.routes.count, classicRoutes.count,
                       "Routes should be filtered to classic only")
    }

    // MARK: - Ordering Tests

    func testNeighbors_OrderedByQualityDescThenCallsign() {
        // Given: Integration with multiple neighbors
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_003_000)

        // Add neighbors in random order
        let calls = ["Z0ZZZ", "A0AAA", "M0MMM"]
        for (i, call) in calls.enumerated() {
            for j in 0..<(3 - i) {  // Different number of packets = different quality
                let packet = makePacket(
                    from: call,
                    to: localCallsign,
                    via: [],
                    timestamp: baseTime.addingTimeInterval(Double(i * 10 + j))
                )
                integration.observePacket(packet, timestamp: packet.timestamp)
            }
        }

        // When: Get neighbors
        let neighbors = integration.currentNeighbors()

        // Then: Should be ordered by quality desc, then callsign
        var previousQuality = Int.max
        for neighbor in neighbors {
            XCTAssertLessThanOrEqual(neighbor.quality, previousQuality,
                                     "Neighbors should be ordered by quality descending")
            previousQuality = neighbor.quality
        }
    }

    func testRoutes_OrderedByDestinationThenQualityDesc() {
        // Given: Integration with classic neighbor for broadcast
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_003_100)

        // Create neighbor
        let directPacket = makePacket(from: "W0ABC", to: localCallsign, via: [], timestamp: baseTime)
        integration.observePacket(directPacket, timestamp: baseTime)

        // Add multiple routes via broadcast
        integration.broadcastRoutes(
            from: "W0ABC",
            quality: 200,
            destinations: [
                RouteInfo(destination: "Z0ZZZ", origin: "W0ABC", quality: 200, path: ["W0ABC"], lastUpdated: baseTime.addingTimeInterval(1), sourceType: "broadcast"),
                RouteInfo(destination: "A0AAA", origin: "W0ABC", quality: 150, path: ["W0ABC"], lastUpdated: baseTime.addingTimeInterval(1), sourceType: "broadcast"),
                RouteInfo(destination: "M0MMM", origin: "W0ABC", quality: 180, path: ["W0ABC"], lastUpdated: baseTime.addingTimeInterval(1), sourceType: "broadcast")
            ],
            timestamp: baseTime.addingTimeInterval(1)
        )

        // When: Get routes
        let routes = integration.currentRoutes()

        // Then: Should be ordered by destination
        var previousDest = ""
        for route in routes {
            XCTAssertGreaterThanOrEqual(route.destination, previousDest,
                                        "Routes should be ordered by destination")
            previousDest = route.destination
        }
    }
}
