//
//  NetRomDecayTests.swift
//  AXTermTests
//
//  TDD tests for time-based TTL/decay model for NET/ROM neighbors, routes, and link stats.
//
//  Decay replaces the obsolescenceCount tick-based model with proper time-based TTL.
//  All tests use injectable clocks for determinism.
//

import XCTest
@testable import AXTerm

final class NetRomDecayTests: XCTestCase {

    // MARK: - TTL Constants (matching production values)

    /// Default TTL for neighbors: 15 minutes
    let neighborTTL: TimeInterval = 15 * 60

    /// Default TTL for routes: 15 minutes
    let routeTTL: TimeInterval = 15 * 60

    /// Default TTL for link stats: 15 minutes
    let linkStatTTL: TimeInterval = 15 * 60

    // MARK: - Test Fixtures

    private var baseTime: Date!
    private var testClock: Date!

    override func setUp() {
        super.setUp()
        // Fixed reference time for deterministic tests
        baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        testClock = baseTime
    }

    override func tearDown() {
        baseTime = nil
        testClock = nil
        super.tearDown()
    }

    // MARK: - Helper Functions

    /// Create a neighbor with specified lastSeen timestamp.
    private func makeNeighbor(call: String, quality: Int, lastSeen: Date, sourceType: String = "classic") -> NeighborInfo {
        NeighborInfo(call: call, quality: quality, lastSeen: lastSeen, obsolescenceCount: 1, sourceType: sourceType)
    }

    /// Create a route with specified lastUpdated timestamp.
    private func makeRoute(destination: String, origin: String, quality: Int, path: [String] = [], sourceType: String = "broadcast") -> RouteInfo {
        RouteInfo(destination: destination, origin: origin, quality: quality, path: path, sourceType: sourceType)
    }

    // MARK: - TEST GROUP A: Neighbor Time-Based Decay

    /// Test that neighbor decay is computed correctly based on time elapsed since lastSeen.
    ///
    /// Tooltip expectation:
    /// "Freshness indicates how recently this neighbor was heard.
    /// 100% means heard within the TTL window; 0% means aged out."
    func testNeighborTimeBasedDecay() {
        // Arrange: Create a neighbor at time T0
        let neighbor = makeNeighbor(call: "W1ABC", quality: 200, lastSeen: baseTime)

        // Act & Assert: At T0, decay should be ~1.0 (100%)
        let decayAtT0 = neighbor.decayFraction(now: baseTime, ttl: neighborTTL)
        XCTAssertEqual(decayAtT0, 1.0, accuracy: 0.01,
            "At T0 (just seen), decay should be 100%")

        // Act & Assert: At T0 + TTL/2, decay should be ~0.5 (50%)
        let halfTTL = baseTime.addingTimeInterval(neighborTTL / 2)
        let decayAtHalf = neighbor.decayFraction(now: halfTTL, ttl: neighborTTL)
        XCTAssertEqual(decayAtHalf, 0.5, accuracy: 0.05,
            "At T0 + TTL/2, decay should be ~50%")

        // Act & Assert: At T0 + TTL, decay should be 0.0 (expired)
        let atTTL = baseTime.addingTimeInterval(neighborTTL)
        let decayAtTTL = neighbor.decayFraction(now: atTTL, ttl: neighborTTL)
        XCTAssertEqual(decayAtTTL, 0.0, accuracy: 0.01,
            "At T0 + TTL, decay should be 0% (expired)")

        // Act & Assert: Beyond TTL, decay should clamp to 0
        let beyondTTL = baseTime.addingTimeInterval(neighborTTL * 2)
        let decayBeyond = neighbor.decayFraction(now: beyondTTL, ttl: neighborTTL)
        XCTAssertEqual(decayBeyond, 0.0, accuracy: 0.01,
            "Beyond TTL, decay should clamp to 0%")
    }

    /// Test decay with multiple neighbors at different ages.
    func testMultipleNeighborsDecayIndependently() {
        // Create neighbors at different times
        let fresh = makeNeighbor(call: "W1FRESH", quality: 200, lastSeen: baseTime)
        let halfStale = makeNeighbor(call: "W2HALF", quality: 180, lastSeen: baseTime.addingTimeInterval(-neighborTTL / 2))
        let almostExpired = makeNeighbor(call: "W3ALMOST", quality: 160, lastSeen: baseTime.addingTimeInterval(-neighborTTL * 0.9))

        // Query at baseTime
        let now = baseTime!

        let freshDecay = fresh.decayFraction(now: now, ttl: neighborTTL)
        let halfDecay = halfStale.decayFraction(now: now, ttl: neighborTTL)
        let almostDecay = almostExpired.decayFraction(now: now, ttl: neighborTTL)

        XCTAssertEqual(freshDecay, 1.0, accuracy: 0.01, "Fresh neighbor should be at 100%")
        XCTAssertEqual(halfDecay, 0.5, accuracy: 0.05, "Half-stale neighbor should be at ~50%")
        XCTAssertEqual(almostDecay, 0.1, accuracy: 0.05, "Almost expired neighbor should be at ~10%")
    }

    /// Test that decay fraction maps correctly to 0-255 quality display.
    func testNeighborDecay255Mapping() {
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)

        // At T0: should map to 255
        let decay255AtT0 = neighbor.decay255(now: baseTime, ttl: neighborTTL)
        XCTAssertEqual(decay255AtT0, 255, "At T0, decay255 should be 255")

        // At TTL/2: should map to ~127
        let halfTime = baseTime.addingTimeInterval(neighborTTL / 2)
        let decay255AtHalf = neighbor.decay255(now: halfTime, ttl: neighborTTL)
        XCTAssertTrue(abs(decay255AtHalf - 127) <= 5, "At TTL/2, decay255 should be ~127, got \(decay255AtHalf)")

        // At TTL: should map to 0
        let atTTL = baseTime.addingTimeInterval(neighborTTL)
        let decay255AtTTL = neighbor.decay255(now: atTTL, ttl: neighborTTL)
        XCTAssertEqual(decay255AtTTL, 0, "At TTL, decay255 should be 0")
    }

    // MARK: - TEST GROUP A: Route Time-Based Decay

    /// Test that route decay is computed correctly based on time elapsed since lastUpdated.
    ///
    /// Tooltip expectation:
    /// "Route freshness is based on the last time this path was reinforced.
    /// Older evidence yields lower freshness."
    func testRouteTimeBasedDecay() {
        // For routes, we need to use a RouteDecayInfo wrapper since RouteInfo doesn't have lastUpdated
        let route = makeRoute(destination: "N0DEST", origin: "W1ABC", quality: 200, path: ["W1ABC"])

        // Create a route decay info with timestamp
        let routeDecay = RouteDecayInfo(route: route, lastUpdated: baseTime)

        // At T0: decay should be 100%
        let decayAtT0 = routeDecay.decayFraction(now: baseTime, ttl: routeTTL)
        XCTAssertEqual(decayAtT0, 1.0, accuracy: 0.01, "At T0, route decay should be 100%")

        // At TTL/2: decay should be ~50%
        let halfTime = baseTime.addingTimeInterval(routeTTL / 2)
        let decayAtHalf = routeDecay.decayFraction(now: halfTime, ttl: routeTTL)
        XCTAssertEqual(decayAtHalf, 0.5, accuracy: 0.05, "At TTL/2, route decay should be ~50%")

        // At TTL: decay should be 0%
        let atTTL = baseTime.addingTimeInterval(routeTTL)
        let decayAtTTL = routeDecay.decayFraction(now: atTTL, ttl: routeTTL)
        XCTAssertEqual(decayAtTTL, 0.0, accuracy: 0.01, "At TTL, route decay should be 0%")
    }

    /// Test that inferred and classic routes can have different TTLs.
    func testRouteDecayWithDifferentTTLsBySourceType() {
        let classicTTL: TimeInterval = 15 * 60  // 15 minutes
        let inferredTTL: TimeInterval = 10 * 60  // 10 minutes (shorter for inferred)

        let classicRoute = RouteDecayInfo(
            route: makeRoute(destination: "N0DEST", origin: "W1ABC", quality: 200, sourceType: "broadcast"),
            lastUpdated: baseTime
        )
        let inferredRoute = RouteDecayInfo(
            route: makeRoute(destination: "N0DEST", origin: "W2XYZ", quality: 180, sourceType: "inferred"),
            lastUpdated: baseTime
        )

        // At 10 minutes: inferred should be expired, classic should be at ~33%
        let at10min = baseTime.addingTimeInterval(10 * 60)

        let classicDecay = classicRoute.decayFraction(now: at10min, ttl: classicTTL)
        let inferredDecay = inferredRoute.decayFraction(now: at10min, ttl: inferredTTL)

        XCTAssertEqual(classicDecay, 0.333, accuracy: 0.05,
            "Classic route at 10min with 15min TTL should be ~33%")
        XCTAssertEqual(inferredDecay, 0.0, accuracy: 0.01,
            "Inferred route at 10min with 10min TTL should be 0% (expired)")
    }

    // MARK: - TEST GROUP A: LinkStat Time-Based Decay

    /// Test that linkStats decay is computed correctly based on lastUpdated timestamp.
    func testLinkStatTimeBasedDecay() {
        // Create a LinkStatRecord with known timestamp
        let linkStat = LinkStatRecord(
            fromCall: "W1ABC",
            toCall: "N0CAL",
            quality: 200,
            lastUpdated: baseTime,
            dfEstimate: 0.9,
            drEstimate: nil,
            duplicateCount: 2,
            observationCount: 10
        )

        // At T0: decay should be 100%
        let decayAtT0 = linkStat.decayFraction(now: baseTime, ttl: linkStatTTL)
        XCTAssertEqual(decayAtT0, 1.0, accuracy: 0.01, "At T0, linkStat decay should be 100%")

        // At TTL/2: decay should be ~50%
        let halfTime = baseTime.addingTimeInterval(linkStatTTL / 2)
        let decayAtHalf = linkStat.decayFraction(now: halfTime, ttl: linkStatTTL)
        XCTAssertEqual(decayAtHalf, 0.5, accuracy: 0.05, "At TTL/2, linkStat decay should be ~50%")

        // At TTL: decay should be 0%
        let atTTL = baseTime.addingTimeInterval(linkStatTTL)
        let decayAtTTL = linkStat.decayFraction(now: atTTL, ttl: linkStatTTL)
        XCTAssertEqual(decayAtTTL, 0.0, accuracy: 0.01, "At TTL, linkStat decay should be 0%")
    }

    /// Test linkStat decay255 mapping (0.0-1.0 to 0-255).
    func testLinkStatDecay255Mapping() {
        let linkStat = LinkStatRecord(
            fromCall: "W1ABC",
            toCall: "N0CAL",
            quality: 200,
            lastUpdated: baseTime,
            dfEstimate: 0.9,
            drEstimate: nil,
            duplicateCount: 0,
            observationCount: 10
        )

        let decay255AtT0 = linkStat.decay255(now: baseTime, ttl: linkStatTTL)
        XCTAssertEqual(decay255AtT0, 255, "At T0, decay255 should be 255")

        let halfTime = baseTime.addingTimeInterval(linkStatTTL / 2)
        let decay255AtHalf = linkStat.decay255(now: halfTime, ttl: linkStatTTL)
        XCTAssertTrue(abs(decay255AtHalf - 127) <= 5, "At TTL/2, decay255 should be ~127, got \(decay255AtHalf)")

        let atTTL = baseTime.addingTimeInterval(linkStatTTL)
        let decay255AtTTL = linkStat.decay255(now: atTTL, ttl: linkStatTTL)
        XCTAssertEqual(decay255AtTTL, 0, "At TTL, decay255 should be 0")
    }

    // MARK: - TEST GROUP D: Decay Applies to All Modes

    /// Test that decay applies correctly in Classic mode.
    func testDecayAppliesToClassicOnly() {
        let classicNeighbor = makeNeighbor(call: "W1CLS", quality: 200, lastSeen: baseTime, sourceType: "classic")
        let inferredNeighbor = makeNeighbor(call: "W2INF", quality: 180, lastSeen: baseTime, sourceType: "inferred")

        let now = baseTime.addingTimeInterval(neighborTTL / 2)

        // In Classic mode, only classic neighbors should be relevant
        // but decay computation should work the same for both
        let classicDecay = classicNeighbor.decayFraction(now: now, ttl: neighborTTL)
        let inferredDecay = inferredNeighbor.decayFraction(now: now, ttl: neighborTTL)

        XCTAssertEqual(classicDecay, 0.5, accuracy: 0.05, "Classic neighbor decay should compute correctly")
        XCTAssertEqual(inferredDecay, 0.5, accuracy: 0.05, "Inferred neighbor decay should compute correctly")
    }

    /// Test that decay applies correctly in Inference mode.
    func testDecayAppliesToInferredOnly() {
        let inferredNeighbor = makeNeighbor(call: "W1INF", quality: 180, lastSeen: baseTime, sourceType: "inferred")

        let now = baseTime.addingTimeInterval(neighborTTL / 4)
        let decay = inferredNeighbor.decayFraction(now: now, ttl: neighborTTL)

        XCTAssertEqual(decay, 0.75, accuracy: 0.05, "Inferred neighbor at 1/4 TTL should be at 75%")
    }

    /// Test that decay applies correctly in Hybrid mode (both source types).
    func testDecayAppliesToHybrid() {
        let classicNeighbor = makeNeighbor(call: "W1CLS", quality: 200, lastSeen: baseTime, sourceType: "classic")
        let inferredNeighbor = makeNeighbor(call: "W2INF", quality: 180, lastSeen: baseTime.addingTimeInterval(-neighborTTL / 4), sourceType: "inferred")

        let now = baseTime!

        let classicDecay = classicNeighbor.decayFraction(now: now, ttl: neighborTTL)
        let inferredDecay = inferredNeighbor.decayFraction(now: now, ttl: neighborTTL)

        XCTAssertEqual(classicDecay, 1.0, accuracy: 0.01, "Fresh classic neighbor should be at 100%")
        XCTAssertEqual(inferredDecay, 0.75, accuracy: 0.05, "Inferred neighbor at 1/4 TTL should be at 75%")
    }

    // MARK: - KISS vs AGWPE Config Differences

    /// Test that KISS and AGWPE configurations differ for ingestion dedup window.
    func testKISSvsAGWPEConfigDifferences() {
        let kissConfig = DecayConfig.kiss
        let agwpeConfig = DecayConfig.agwpe

        // KISS should have ingestion dedup window (Direwolf already dedupes)
        XCTAssertEqual(kissConfig.ingestionDedupWindow, 0.25,
            "KISS should have 0.25s ingestion dedup window")

        // AGWPE should have no ingestion dedup window (needs app-level dedup)
        XCTAssertEqual(agwpeConfig.ingestionDedupWindow, 0.0,
            "AGWPE should have 0s ingestion dedup window")

        // Decay logic should remain equal for both
        XCTAssertEqual(kissConfig.neighborTTL, agwpeConfig.neighborTTL,
            "Neighbor TTL should be the same for KISS and AGWPE")
        XCTAssertEqual(kissConfig.routeTTL, agwpeConfig.routeTTL,
            "Route TTL should be the same for KISS and AGWPE")
        XCTAssertEqual(kissConfig.linkStatTTL, agwpeConfig.linkStatTTL,
            "LinkStat TTL should be the same for KISS and AGWPE")
    }

    // MARK: - Edge Cases

    /// Test decay with future timestamps (should clamp to 1.0).
    func testDecayWithFutureTimestamp() {
        let neighbor = makeNeighbor(call: "W1FUTURE", quality: 200, lastSeen: baseTime.addingTimeInterval(60))

        // Query at baseTime (before lastSeen)
        let decay = neighbor.decayFraction(now: baseTime, ttl: neighborTTL)

        // Future timestamps should still return 1.0 (100% fresh)
        XCTAssertEqual(decay, 1.0, accuracy: 0.01,
            "Future lastSeen timestamps should return 100% decay")
    }

    /// Test decay with very old timestamps.
    func testDecayWithVeryOldTimestamp() {
        let veryOld = baseTime.addingTimeInterval(-365 * 24 * 60 * 60) // 1 year ago
        let neighbor = makeNeighbor(call: "W1OLD", quality: 200, lastSeen: veryOld)

        let decay = neighbor.decayFraction(now: baseTime, ttl: neighborTTL)

        XCTAssertEqual(decay, 0.0, accuracy: 0.01,
            "Very old timestamps should return 0% decay")
    }

    /// Test that decay percentage display is correctly formatted.
    func testDecayDisplayString() {
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)

        // At 100%
        let displayAtT0 = neighbor.decayDisplayString(now: baseTime, ttl: neighborTTL)
        XCTAssertEqual(displayAtT0, "100%", "At T0, display should be '100%'")

        // At ~50%
        let halfTime = baseTime.addingTimeInterval(neighborTTL / 2)
        let displayAtHalf = neighbor.decayDisplayString(now: halfTime, ttl: neighborTTL)
        XCTAssertEqual(displayAtHalf, "50%", "At TTL/2, display should be '50%'")

        // At 0%
        let atTTL = baseTime.addingTimeInterval(neighborTTL)
        let displayAtTTL = neighbor.decayDisplayString(now: atTTL, ttl: neighborTTL)
        XCTAssertEqual(displayAtTTL, "0%", "At TTL, display should be '0%'")
    }
}
