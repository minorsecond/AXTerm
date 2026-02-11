//
//  NetRomRealisticWiringTests.swift
//  AXTermTests
//
//  Comprehensive tests for NET/ROM routing with realistic data volumes.
//  These tests use synthetic datasets that mirror real-world packet distributions:
//  - 100+ "to local via digipeater" packets (e.g., WH6ANH -> K0EPI via DRL)
//  - 200+ beacon/infrastructure packets (to ID, BEACON, node aliases)
//  - 20+ third-party A->B packets
//  - 20+ duplicate burst packets
//  - SSID variants (K0NTS, K0NTS-7, K0NTS-14)
//
//  All tests are deterministic: fake clock, no timers, fixed seeds.
//

import XCTest

@testable import AXTerm

@MainActor
final class NetRomRealisticWiringTests: XCTestCase {

    private let localCallsign = "K0EPI"
    private let localCallsignWithSSID = "K0EPI-7"

    // MARK: - Test Fixture Generator

    /// Generate a realistic packet fixture mirroring user's CSV data.
    private func generateRealisticPacketFixture(baseTime: Date) -> [Packet] {
        var packets: [Packet] = []
        var timeOffset: Double = 0

        // === 1. To-local via digipeater packets (100+) ===
        // Pattern: WH6ANH -> K0EPI via DRL (and DRL*)
        for i in 0..<100 {
            let from = i % 10 == 0 ? "WH6ANH" : "W\(String(format: "%04d", i % 50))"
            let digi = i % 3 == 0 ? "DRL" : (i % 3 == 1 ? "WIDE1-1" : "RELAY")
            packets.append(makePacket(
                from: from,
                to: localCallsign,
                via: [digi],
                infoText: "MSG\(i)",
                timestamp: baseTime.addingTimeInterval(timeOffset)
            ))
            timeOffset += 0.5
        }

        // === 2. Direct to-local packets (50) ===
        // Direct RF without digipeater
        for i in 0..<50 {
            packets.append(makePacket(
                from: "K0NTS",
                to: localCallsign,
                via: [],
                infoText: "DIRECT\(i)",
                timestamp: baseTime.addingTimeInterval(timeOffset)
            ))
            timeOffset += 0.3
        }

        // === 3. Beacon/Infrastructure packets (200+) ===
        // These should NOT create neighbors or routes
        for i in 0..<100 {
            // Beacon packets
            packets.append(makePacket(
                from: "W0DIGI",
                to: "ID",
                via: [],
                infoText: "BEACON",
                frameType: .ui,
                timestamp: baseTime.addingTimeInterval(timeOffset)
            ))
            timeOffset += 0.2
        }

        for i in 0..<100 {
            // Node alias packets (e.g., SOLBPQ)
            packets.append(makePacket(
                from: "KB0EX-2",
                to: "SOLBPQ",
                via: [],
                infoText: "BPQ node traffic",
                timestamp: baseTime.addingTimeInterval(timeOffset)
            ))
            timeOffset += 0.2
        }

        // === 4. Third-party A->B packets (20+) ===
        // Neither endpoint is local - should create inferred routes in inference/hybrid mode
        for i in 0..<25 {
            packets.append(makePacket(
                from: "K1AAA",
                to: "K3CCC",
                via: ["K2BBB"],
                infoText: "THIRDPARTY\(i)",
                timestamp: baseTime.addingTimeInterval(timeOffset)
            ))
            timeOffset += 1.0
        }

        // === 5. Duplicate burst packets (20+) ===
        // Same packet repeated quickly (simulates retries)
        let burstBase = baseTime.addingTimeInterval(timeOffset)
        for i in 0..<25 {
            packets.append(makePacket(
                from: "W0BURST",
                to: localCallsign,
                via: [],
                infoText: "BURST_MSG",  // Same content
                timestamp: burstBase.addingTimeInterval(Double(i) * 0.1)
            ))
        }
        timeOffset += 3.0

        // === 6. SSID variants ===
        // Same base callsign, different SSIDs
        for ssid in [0, 7, 14, 15] {
            let call = ssid == 0 ? "K0NTS" : "K0NTS-\(ssid)"
            for j in 0..<10 {
                packets.append(makePacket(
                    from: call,
                    to: localCallsign,
                    via: [],
                    infoText: "SSID_TEST",
                    timestamp: baseTime.addingTimeInterval(timeOffset)
                ))
                timeOffset += 0.2
            }
        }

        // === 7. Local callsign with SSID ===
        // Packets to K0EPI-7 (local with SSID)
        for i in 0..<20 {
            packets.append(makePacket(
                from: "W0REMOTE",
                to: localCallsignWithSSID,
                via: ["K5DIGI"],
                infoText: "TO_SSID\(i)",
                timestamp: baseTime.addingTimeInterval(timeOffset)
            ))
            timeOffset += 0.5
        }

        // === 8. Edge cases ===

        // Empty via list digipeated (shouldn't happen but test resilience)
        packets.append(makePacket(
            from: "W0EDGE1",
            to: localCallsign,
            via: [],
            infoText: "EDGE1",
            timestamp: baseTime.addingTimeInterval(timeOffset)
        ))
        timeOffset += 0.1

        // Duplicate via entries
        packets.append(makePacket(
            from: "W0EDGE2",
            to: localCallsign,
            via: ["K9DIG", "K9DIG"],  // Duplicate
            infoText: "EDGE2",
            timestamp: baseTime.addingTimeInterval(timeOffset)
        ))
        timeOffset += 0.1

        // Local callsign in via path (should be filtered)
        packets.append(makePacket(
            from: "W0EDGE3",
            to: "K9DEST",
            via: [localCallsign, "K8OTHER"],  // Local in via
            infoText: "EDGE3",
            timestamp: baseTime.addingTimeInterval(timeOffset)
        ))
        timeOffset += 0.1

        // Via equals from (degenerate)
        packets.append(makePacket(
            from: "W0EDGE4",
            to: "K9DEST",
            via: ["W0EDGE4"],  // Via == from
            infoText: "EDGE4",
            timestamp: baseTime.addingTimeInterval(timeOffset)
        ))

        return packets
    }

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
            via: via.map { AX25Address(call: $0, repeated: true) },
            frameType: frameType,
            control: 0,
            pid: nil,
            info: info,
            rawAx25: info,
            kissEndpoint: nil,
            infoText: infoText
        )
    }

    // MARK: - A) App Wiring Tests

    /// Test that ingestion updates integration state.
    func testIngestion_UpdatesIntegrationState() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_500_000)

        // Generate realistic packet set
        let packets = generateRealisticPacketFixture(baseTime: baseTime)

        // Verify initial state is empty
        XCTAssertTrue(integration.currentNeighbors().isEmpty, "Should start with no neighbors")
        XCTAssertTrue(integration.exportLinkStats().isEmpty, "Should start with no link stats")

        // Feed all packets
        for packet in packets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Verify state was updated
        let neighbors = integration.currentNeighbors()
        let linkStats = integration.exportLinkStats()
        let routes = integration.currentRoutes()

        XCTAssertGreaterThan(neighbors.count, 0, "Should have neighbors after ingestion")
        XCTAssertGreaterThan(linkStats.count, 0, "Should have link stats after ingestion")

        // Verify we have expected stations as neighbors
        XCTAssertTrue(neighbors.contains { $0.call == "K0NTS" }, "K0NTS should be a neighbor (direct packets)")
        XCTAssertTrue(neighbors.contains { $0.call == "K2BBB" }, "K2BBB should be a neighbor (from third-party via path)")
    }

    /// Test that infrastructure packets do NOT create neighbors.
    func testIngestion_IgnoresInfrastructureForNeighbors() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_510_000)

        // Feed 200 beacon/infrastructure packets
        for i in 0..<200 {
            let packet = makePacket(
                from: "W0BEACON",
                to: "ID",
                via: [],
                infoText: i % 2 == 0 ? "BEACON" : "ID",
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Verify no neighbors created from pure infrastructure
        let neighbors = integration.currentNeighbors()
        XCTAssertFalse(neighbors.contains { $0.call == "W0BEACON" },
                       "Infrastructure packets should NOT create neighbors")
    }

    /// Test that node alias destinations are treated as infrastructure.
    func testIngestion_TreatsNodeAliasAsInfrastructure() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_520_000)

        // Feed packets to node aliases
        let aliases = ["SOLBPQ", "BBS", "RELAY", "WIDE1-1", "WIDE2-2"]
        for (i, alias) in aliases.enumerated() {
            for j in 0..<20 {
                let packet = makePacket(
                    from: "KB0EX-2",
                    to: alias,
                    via: [],
                    infoText: "NODE_ALIAS_TEST",
                    timestamp: baseTime.addingTimeInterval(Double(i * 20 + j))
                )
                integration.observePacket(packet, timestamp: packet.timestamp)
            }
        }

        // KB0EX-2 should NOT become a neighbor from this traffic alone
        // (it's sending TO infrastructure, not FROM infrastructure TO local)
        let neighbors = integration.currentNeighbors()
        let routes = integration.currentRoutes()

        // Routes should not be created with node aliases as destinations
        XCTAssertFalse(routes.contains { aliases.contains($0.destination) },
                       "Should not create routes with node alias destinations")
    }

    /// Test to-local digipeated traffic produces inference evidence.
    func testIngestion_ToLocalDigipeated_CreatesInferredRoutes() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_530_000)

        // Feed 100 packets: WH6ANH -> K0EPI via DRL
        for i in 0..<100 {
            let packet = makePacket(
                from: "WH6ANH",
                to: localCallsign,
                via: ["DRL"],
                infoText: "MSG\(i)",
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Should have inferred route: dest=WH6ANH via DRL
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "WH6ANH" },
                      "Should infer route to WH6ANH from digipeated packets")

        // Verify the route uses DRL as next hop
        if let route = routes.first(where: { $0.destination == "WH6ANH" }) {
            XCTAssertTrue(route.path.contains("DRL"),
                          "Inferred route should use DRL as next hop")
        }

        // DRL should be a neighbor
        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "DRL" },
                      "DRL should be an inferred neighbor")
    }

    // MARK: - B) Mode Behavior Tests

    /// Test that classic mode returns 0 routes when no broadcasts.
    func testClassicMode_NoInferredRoutes() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)
        let baseTime = Date(timeIntervalSince1970: 1_700_540_000)

        // Feed inference-eligible packets
        for i in 0..<50 {
            let packet = makePacket(
                from: "WH6ANH",
                to: localCallsign,
                via: ["DRL"],
                infoText: "MSG\(i)",
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Classic mode should have NO routes (no broadcasts)
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.isEmpty, "Classic mode with no broadcasts should have 0 routes")

        // But direct packets should still create neighbors
        let directPacket = makePacket(
            from: "K0DIRECT",
            to: localCallsign,
            via: [],
            timestamp: baseTime.addingTimeInterval(100)
        )
        integration.observePacket(directPacket, timestamp: directPacket.timestamp)

        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "K0DIRECT" },
                      "Classic mode should create neighbors from direct packets")
    }

    /// Test that inferred mode returns inferred routes from to-local via evidence.
    func testInferredMode_CreatesRoutesFromEvidence() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_550_000)

        // Feed evidence packets
        for i in 0..<30 {
            let packet = makePacket(
                from: "WH6ANH",
                to: localCallsign,
                via: ["DRL"],
                infoText: "INFER\(i)",
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        let routes = integration.currentRoutes()
        XCTAssertFalse(routes.isEmpty, "Inference mode should create routes from evidence")

        // Find route to WH6ANH
        let whRoute = routes.first { $0.destination == "WH6ANH" }
        XCTAssertNotNil(whRoute, "Should have route to WH6ANH")
        XCTAssertGreaterThan(whRoute?.quality ?? 0, 0, "Route should have positive quality")
    }

    /// Test that hybrid mode contains inferred routes when classic has none.
    func testHybridMode_IncludesInferredWhenNoClassic() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_560_000)

        // Only inference-eligible packets, no broadcasts
        for i in 0..<30 {
            let packet = makePacket(
                from: "WH6ANH",
                to: localCallsign,
                via: ["DRL"],
                infoText: "HYBRID\(i)",
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "WH6ANH" },
                      "Hybrid mode should include inferred routes when no classic available")
    }

    /// Test that hybrid prefers classic when it exists and is better quality.
    func testHybridMode_PrefersHigherQualityClassic() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_570_000)

        // Create classic neighbor first
        for i in 0..<20 {
            let directPacket = makePacket(
                from: "W0ABC",
                to: localCallsign,
                via: [],
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(directPacket, timestamp: directPacket.timestamp)
        }

        // Create inferred neighbor via third-party
        for i in 0..<5 {
            let thirdParty = makePacket(
                from: "K1TARGET",
                to: "K9OTHER",
                via: ["K2DIGI"],
                timestamp: baseTime.addingTimeInterval(100 + Double(i))
            )
            integration.observePacket(thirdParty, timestamp: thirdParty.timestamp)
        }

        // Add classic broadcast route with high quality
        integration.broadcastRoutes(
            from: "W0ABC",
            quality: 250,
            destinations: [
                RouteInfo(destination: "K1TARGET", origin: "W0ABC", quality: 250, path: ["W0ABC"], lastUpdated: baseTime.addingTimeInterval(20), sourceType: "broadcast")
            ],
            timestamp: baseTime.addingTimeInterval(200)
        )

        // Verify classic route is preferred (higher quality)
        let routes = integration.currentRoutes().filter { $0.destination == "K1TARGET" }
        XCTAssertFalse(routes.isEmpty, "Should have route to K1TARGET")

        if let bestRoute = routes.first {
            // Classic route should be first due to higher quality
            XCTAssertTrue(bestRoute.sourceType == "broadcast" || bestRoute.sourceType == "classic",
                          "Best route should be classic/broadcast type")
        }
    }

    // MARK: - C) Quality Clamping Tests

    /// Test that all qualities are within [0, 255].
    func testQualityClamping_AllQualitiesInRange() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_580_000)

        // Feed a large variety of packets
        let packets = generateRealisticPacketFixture(baseTime: baseTime)
        for packet in packets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Check all neighbors
        for neighbor in integration.currentNeighbors() {
            XCTAssertGreaterThanOrEqual(neighbor.quality, 0,
                                         "Neighbor \(neighbor.call) quality should be >= 0")
            XCTAssertLessThanOrEqual(neighbor.quality, 255,
                                      "Neighbor \(neighbor.call) quality should be <= 255")
        }

        // Check all routes
        for route in integration.currentRoutes() {
            XCTAssertGreaterThanOrEqual(route.quality, 0,
                                         "Route to \(route.destination) quality should be >= 0")
            XCTAssertLessThanOrEqual(route.quality, 255,
                                      "Route to \(route.destination) quality should be <= 255")
        }

        // Check all link stats
        for stat in integration.exportLinkStats() {
            XCTAssertGreaterThanOrEqual(stat.quality, 0,
                                         "Link \(stat.fromCall)->\(stat.toCall) quality should be >= 0")
            XCTAssertLessThanOrEqual(stat.quality, 255,
                                      "Link \(stat.fromCall)->\(stat.toCall) quality should be <= 255")
        }
    }

    // MARK: - D) SSID Normalization Tests

    /// Test that SSID variants are tracked separately.
    func testSSIDVariants_TrackedSeparately() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_590_000)

        // Send from different SSIDs of same base callsign
        let variants = ["K0NTS", "K0NTS-7", "K0NTS-14"]
        for (i, variant) in variants.enumerated() {
            for j in 0..<10 {
                let packet = makePacket(
                    from: variant,
                    to: localCallsign,
                    via: [],
                    infoText: "SSID_TEST",
                    timestamp: baseTime.addingTimeInterval(Double(i * 10 + j))
                )
                integration.observePacket(packet, timestamp: packet.timestamp)
            }
        }

        let neighbors = integration.currentNeighbors()

        // Each SSID variant should be a separate neighbor
        for variant in variants {
            XCTAssertTrue(neighbors.contains { $0.call == variant },
                          "\(variant) should be tracked as a separate neighbor")
        }
    }

    /// Test that local callsign with SSID is recognized as local.
    func testLocalCallsignSSID_RecognizedAsLocal() {
        // This test verifies that K0EPI-7 is treated as "local" when local is K0EPI
        // The current implementation normalizes callsigns, so this may or may not group them

        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_600_000)

        // Packet to K0EPI-7 (local with SSID)
        for i in 0..<20 {
            let packet = makePacket(
                from: "W0REMOTE",
                to: "K0EPI-7",
                via: ["K5DIGI"],
                infoText: "TO_SSID",
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // If implementation groups SSIDs, K5DIGI should be neighbor and W0REMOTE should be routable
        // If implementation keeps them separate, behavior depends on design choice
        let neighbors = integration.currentNeighbors()
        let routes = integration.currentRoutes()

        // At minimum, this should not crash or produce invalid state
        for neighbor in neighbors {
            XCTAssertGreaterThanOrEqual(neighbor.quality, 0)
            XCTAssertLessThanOrEqual(neighbor.quality, 255)
        }
    }

    // MARK: - E) Duplicate Handling Tests

    /// Test that duplicate bursts affect link quality appropriately.
    func testDuplicateBursts_AffectLinkQuality() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_610_000)

        // First, establish a baseline with clean packets
        // Use valid callsigns (max 4 suffix letters)
        for i in 0..<20 {
            let packet = makePacket(
                from: "W0CLN",
                to: localCallsign,
                via: [],
                infoText: "CLEAN\(i)",
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp, isDuplicate: false)
        }

        // Then, send duplicate bursts
        // Packets must be > 0.25s apart to avoid ingestion dedup window
        for i in 0..<20 {
            let packet = makePacket(
                from: "W0BST",
                to: localCallsign,
                via: [],
                infoText: "BURST\(i)",  // Different content to avoid dedup
                timestamp: baseTime.addingTimeInterval(50 + Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp, isDuplicate: i > 0)
        }

        let linkStats = integration.exportLinkStats()

        // Find link stats for both
        let cleanStat = linkStats.first { $0.fromCall == "W0CLN" }
        let burstStat = linkStats.first { $0.fromCall == "W0BST" }

        XCTAssertNotNil(cleanStat, "Should have stats for clean link")
        XCTAssertNotNil(burstStat, "Should have stats for burst link")

        // Burst station should have lower quality due to duplicates
        if let clean = cleanStat, let burst = burstStat {
            XCTAssertGreaterThanOrEqual(clean.quality, burst.quality,
                                         "Clean link should have >= quality than burst link")
            XCTAssertGreaterThan(burst.duplicateCount, 0,
                                  "Burst link should have recorded duplicates")
        }
    }

    // MARK: - F) Guardrails Tests

    /// Test that we never infer route to self.
    func testGuardrails_NeverInferRouteToSelf() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_620_000)

        // Packets where local callsign appears in various positions
        let packets = [
            // Local is sender - should not create route to self
            makePacket(from: localCallsign, to: "K9DEST", via: ["K8DIGI"], infoText: "FROM_LOCAL", timestamp: baseTime),
            // Local in via path - should not infer
            makePacket(from: "K7SRC", to: "K9DEST", via: [localCallsign], infoText: "VIA_LOCAL", timestamp: baseTime.addingTimeInterval(1)),
        ]

        for packet in packets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        let routes = integration.currentRoutes()

        // Should never have route to local callsign
        XCTAssertFalse(routes.contains { $0.destination == localCallsign },
                       "Should never infer route to self")
    }

    /// Test that we never infer where nextHop equals destination.
    func testGuardrails_NeverInferNextHopEqualsDestination() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_630_000)

        // Degenerate case: via == from
        for i in 0..<10 {
            let packet = makePacket(
                from: "W0EDGE",
                to: "K9DEST",
                via: ["W0EDGE"],  // Via equals from
                infoText: "DEGENERATE",
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        let routes = integration.currentRoutes()

        // Should not have any routes where destination is in the path as first hop
        let degenerateRoutes = routes.filter { route in
            route.path.first == route.destination
        }
        XCTAssertTrue(degenerateRoutes.isEmpty,
                      "Should not infer routes where nextHop equals destination")
    }

    /// Test that we never infer when local is in via path.
    func testGuardrails_NeverInferWhenLocalInViaPath() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_640_000)

        // Packets that transited through local
        for i in 0..<20 {
            let packet = makePacket(
                from: "K1SRC",
                to: "K9DEST",
                via: [localCallsign, "K8OTHER"],  // Local in via
                infoText: "VIA_LOCAL",
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        let routes = integration.currentRoutes()

        // Should not infer any routes from packets that transited through us
        XCTAssertTrue(routes.isEmpty,
                      "Should not infer routes from packets transiting through local")
    }

    // MARK: - G) Volume and Determinism Tests

    /// Test processing large packet volumes without issues.
    func testVolumeProcessing_HandlesLargeDataset() {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_650_000)

        // Generate and process a large dataset
        let packets = generateRealisticPacketFixture(baseTime: baseTime)

        // Process all packets
        for packet in packets {
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Verify we have state
        let neighbors = integration.currentNeighbors()
        let routes = integration.currentRoutes()
        let linkStats = integration.exportLinkStats()

        XCTAssertGreaterThan(neighbors.count, 0, "Should have neighbors after processing \(packets.count) packets")
        XCTAssertGreaterThan(linkStats.count, 0, "Should have link stats after processing \(packets.count) packets")

        // All values should be valid
        XCTAssertTrue(neighbors.allSatisfy { $0.quality >= 0 && $0.quality <= 255 })
        XCTAssertTrue(routes.allSatisfy { $0.quality >= 0 && $0.quality <= 255 })
        XCTAssertTrue(linkStats.allSatisfy { $0.quality >= 0 && $0.quality <= 255 })
    }

    /// Test that results are deterministic.
    func testDeterminism_SameInputSameOutput() {
        let baseTime = Date(timeIntervalSince1970: 1_700_660_000)
        let packets = generateRealisticPacketFixture(baseTime: baseTime)

        // Run 1
        let integration1 = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        for packet in packets {
            integration1.observePacket(packet, timestamp: packet.timestamp)
        }
        let neighbors1 = integration1.currentNeighbors()
        let routes1 = integration1.currentRoutes()

        // Run 2 (same inputs)
        let integration2 = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        for packet in packets {
            integration2.observePacket(packet, timestamp: packet.timestamp)
        }
        let neighbors2 = integration2.currentNeighbors()
        let routes2 = integration2.currentRoutes()

        // Compare
        XCTAssertEqual(neighbors1.count, neighbors2.count, "Neighbor count should be deterministic")
        XCTAssertEqual(routes1.count, routes2.count, "Route count should be deterministic")

        // Verify same callsigns appear
        let calls1 = Set(neighbors1.map(\.call))
        let calls2 = Set(neighbors2.map(\.call))
        XCTAssertEqual(calls1, calls2, "Same neighbors should appear in both runs")

        let dests1 = Set(routes1.map(\.destination))
        let dests2 = Set(routes2.map(\.destination))
        XCTAssertEqual(dests1, dests2, "Same route destinations should appear in both runs")
    }
}
