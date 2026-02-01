//
//  NetRomFreshnessTests.swift
//  AXTermTests
//
//  TDD tests for the Freshness model (plateau + smoothstep curve).
//
//  Freshness replaces the linear decay model with a gentler curve:
//  - Plateau phase (0-5 minutes): stays near 100% with gentle 5% decline
//  - Decay phase (5-30 minutes): smoothstep easing to 0%
//
//  This provides better UX for packet radio where nodes are still
//  viable even if not seen for 5-10 minutes.
//

import XCTest
@testable import AXTerm

final class NetRomFreshnessTests: XCTestCase {

    // MARK: - Constants (matching production values)

    /// Default TTL for freshness: 30 minutes
    let ttl: TimeInterval = 30 * 60

    /// Default plateau duration: 5 minutes
    let plateau: TimeInterval = 5 * 60

    // MARK: - Test Fixtures

    private var baseTime: Date!

    override func setUp() {
        super.setUp()
        // Fixed reference time for deterministic tests
        baseTime = Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func tearDown() {
        baseTime = nil
        super.tearDown()
    }

    // MARK: - Helper Functions

    private func makeNeighbor(call: String, quality: Int, lastSeen: Date, sourceType: String = "classic") -> NeighborInfo {
        NeighborInfo(call: call, quality: quality, lastSeen: lastSeen, obsolescenceCount: 1, sourceType: sourceType)
    }

    private func makeRoute(destination: String, origin: String, quality: Int, path: [String] = [], lastUpdated: Date, sourceType: String = "broadcast") -> RouteInfo {
        RouteInfo(destination: destination, origin: origin, quality: quality, path: path, lastUpdated: lastUpdated, sourceType: sourceType)
    }

    private func makeLinkStat(from: String, to: String, quality: Int, lastUpdated: Date, obsCount: Int = 10) -> LinkStatRecord {
        LinkStatRecord(
            fromCall: from,
            toCall: to,
            quality: quality,
            lastUpdated: lastUpdated,
            dfEstimate: 0.9,
            drEstimate: nil,
            duplicateCount: 0,
            observationCount: obsCount
        )
    }

    // MARK: - TEST: Smoothstep Function

    /// Test that the smoothstep function works correctly.
    func testSmoothstepFunction() {
        // At t=0, smoothstep should return 0
        XCTAssertEqual(FreshnessCalculator.smoothstep(0.0), 0.0, accuracy: 0.001,
            "smoothstep(0) should be 0")

        // At t=0.5, smoothstep should return 0.5
        XCTAssertEqual(FreshnessCalculator.smoothstep(0.5), 0.5, accuracy: 0.001,
            "smoothstep(0.5) should be 0.5")

        // At t=1, smoothstep should return 1
        XCTAssertEqual(FreshnessCalculator.smoothstep(1.0), 1.0, accuracy: 0.001,
            "smoothstep(1) should be 1")

        // Verify it's S-shaped: value at 0.25 should be less than 0.25
        let at25 = FreshnessCalculator.smoothstep(0.25)
        XCTAssertLessThan(at25, 0.25,
            "smoothstep(0.25) should be less than 0.25 (S-curve)")

        // Verify it's S-shaped: value at 0.75 should be greater than 0.75
        let at75 = FreshnessCalculator.smoothstep(0.75)
        XCTAssertGreaterThan(at75, 0.75,
            "smoothstep(0.75) should be greater than 0.75 (S-curve)")
    }

    // MARK: - TEST: Plateau Phase

    /// Test that freshness stays near 100% during the plateau phase.
    func testFreshnessDuringPlateauPhase() {
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)

        // At T0: should be exactly 100%
        let freshnessAtT0 = neighbor.freshness(now: baseTime, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAtT0, 1.0, accuracy: 0.001,
            "At T0, freshness should be 100%")

        // At 1 minute: should be ~99% (1/5 of 5% decline)
        let at1min = baseTime.addingTimeInterval(60)
        let freshnessAt1min = neighbor.freshness(now: at1min, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAt1min, 0.99, accuracy: 0.01,
            "At 1 minute, freshness should be ~99%")

        // At 2.5 minutes: should be ~97.5% (halfway through plateau)
        let at2_5min = baseTime.addingTimeInterval(150)
        let freshnessAt2_5min = neighbor.freshness(now: at2_5min, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAt2_5min, 0.975, accuracy: 0.01,
            "At 2.5 minutes, freshness should be ~97.5%")

        // At 5 minutes (end of plateau): should be 95%
        let at5min = baseTime.addingTimeInterval(300)
        let freshnessAt5min = neighbor.freshness(now: at5min, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAt5min, 0.95, accuracy: 0.01,
            "At 5 minutes, freshness should be ~95%")
    }

    // MARK: - TEST: Decay Phase (Smoothstep)

    /// Test that freshness uses smoothstep easing during the decay phase.
    func testFreshnessDuringDecayPhase() {
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)

        // At 5 minutes (start of decay phase): should be 95%
        let at5min = baseTime.addingTimeInterval(300)
        let freshnessAt5min = neighbor.freshness(now: at5min, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAt5min, 0.95, accuracy: 0.01,
            "At start of decay phase, freshness should be ~95%")

        // At 17.5 minutes (midpoint of decay phase, 12.5 min into 25 min decay):
        // t = 0.5, smoothstep(0.5) = 0.5, freshness = 0.95 * (1 - 0.5) = 0.475
        let at17_5min = baseTime.addingTimeInterval(17.5 * 60)
        let freshnessAtMid = neighbor.freshness(now: at17_5min, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAtMid, 0.475, accuracy: 0.02,
            "At midpoint of decay phase, freshness should be ~47.5%")

        // At 30 minutes (TTL): should be 0%
        let at30min = baseTime.addingTimeInterval(1800)
        let freshnessAt30min = neighbor.freshness(now: at30min, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAt30min, 0.0, accuracy: 0.001,
            "At TTL, freshness should be 0%")
    }

    // MARK: - TEST: Key Time Points

    /// Test freshness at key time points that operators care about.
    func testFreshnessAtKeyTimePoints() {
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)

        // At 7 minutes: should still be quite fresh (~90%)
        let at7min = baseTime.addingTimeInterval(7 * 60)
        let freshnessAt7min = neighbor.freshness(now: at7min, ttl: ttl, plateau: plateau)
        XCTAssertGreaterThan(freshnessAt7min, 0.85,
            "At 7 minutes, freshness should be >85% (was the problem with linear decay)")

        // At 10 minutes: should be reasonably fresh (~75-80%)
        let at10min = baseTime.addingTimeInterval(10 * 60)
        let freshnessAt10min = neighbor.freshness(now: at10min, ttl: ttl, plateau: plateau)
        XCTAssertGreaterThan(freshnessAt10min, 0.70,
            "At 10 minutes, freshness should be >70%")

        // At 15 minutes: should be moderate (~50-60%)
        let at15min = baseTime.addingTimeInterval(15 * 60)
        let freshnessAt15min = neighbor.freshness(now: at15min, ttl: ttl, plateau: plateau)
        XCTAssertGreaterThan(freshnessAt15min, 0.45,
            "At 15 minutes, freshness should be >45%")
        XCTAssertLessThan(freshnessAt15min, 0.65,
            "At 15 minutes, freshness should be <65%")

        // At 20 minutes: should be getting stale (~25-35%)
        let at20min = baseTime.addingTimeInterval(20 * 60)
        let freshnessAt20min = neighbor.freshness(now: at20min, ttl: ttl, plateau: plateau)
        XCTAssertLessThan(freshnessAt20min, 0.40,
            "At 20 minutes, freshness should be <40%")
    }

    // MARK: - TEST: Comparison with Old Linear Decay

    /// Test that new freshness is gentler than old linear decay in first 10-15 minutes.
    func testFreshnessIsGentlerThanLinearDecay() {
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)
        let linearTTL: TimeInterval = 15 * 60 // Old linear decay used 15 min TTL

        // At 5 minutes with old linear decay (15 min TTL): 66.7%
        // At 5 minutes with new freshness (30 min TTL + plateau): 95%
        let at5min = baseTime.addingTimeInterval(300)
        let linearDecay = max(0, min(1, (linearTTL - 300) / linearTTL))
        let newFreshness = neighbor.freshness(now: at5min, ttl: ttl, plateau: plateau)

        XCTAssertGreaterThan(newFreshness, linearDecay,
            "New freshness at 5 min should be higher than old linear decay")

        // At 10 minutes with old linear decay: 33.3%
        // At 10 minutes with new freshness: should be much higher
        let at10min = baseTime.addingTimeInterval(600)
        let linearDecay10 = max(0, min(1, (linearTTL - 600) / linearTTL))
        let newFreshness10 = neighbor.freshness(now: at10min, ttl: ttl, plateau: plateau)

        XCTAssertGreaterThan(newFreshness10, linearDecay10,
            "New freshness at 10 min should be higher than old linear decay")
        XCTAssertGreaterThan(newFreshness10, 0.7,
            "New freshness at 10 min should be >70% (old linear was 33%)")
    }

    // MARK: - TEST: Status Labels

    /// Test that freshness status labels are assigned correctly.
    func testFreshnessStatusLabels() {
        // Fresh: 90-100%
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 1.0), "Fresh")
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 0.95), "Fresh")
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 0.90), "Fresh")

        // Recent: 50-89%
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 0.89), "Recent")
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 0.70), "Recent")
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 0.50), "Recent")

        // Stale: 1-49%
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 0.49), "Stale")
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 0.25), "Stale")
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 0.01), "Stale")

        // Expired: 0%
        XCTAssertEqual(FreshnessCalculator.freshnessStatus(fraction: 0.0), "Expired")
    }

    // MARK: - TEST: Freshness255 Mapping

    /// Test that freshness maps correctly to 0-255 scale.
    func testFreshness255Mapping() {
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)

        // At T0: should map to 255
        let fresh255AtT0 = neighbor.freshness255(now: baseTime, ttl: ttl, plateau: plateau)
        XCTAssertEqual(fresh255AtT0, 255, "At T0, freshness255 should be 255")

        // At TTL: should map to 0
        let atTTL = baseTime.addingTimeInterval(ttl)
        let fresh255AtTTL = neighbor.freshness255(now: atTTL, ttl: ttl, plateau: plateau)
        XCTAssertEqual(fresh255AtTTL, 0, "At TTL, freshness255 should be 0")
    }

    // MARK: - TEST: Display Strings

    /// Test that freshness display strings are correctly formatted.
    func testFreshnessDisplayString() {
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)

        // At 100%
        let displayAtT0 = neighbor.freshnessDisplayString(now: baseTime, ttl: ttl, plateau: plateau)
        XCTAssertEqual(displayAtT0, "100%", "At T0, display should be '100%'")

        // At 95% (end of plateau)
        let at5min = baseTime.addingTimeInterval(300)
        let displayAt5min = neighbor.freshnessDisplayString(now: at5min, ttl: ttl, plateau: plateau)
        XCTAssertEqual(displayAt5min, "95%", "At 5 min, display should be '95%'")

        // At 0%
        let atTTL = baseTime.addingTimeInterval(ttl)
        let displayAtTTL = neighbor.freshnessDisplayString(now: atTTL, ttl: ttl, plateau: plateau)
        XCTAssertEqual(displayAtTTL, "0%", "At TTL, display should be '0%'")
    }

    // MARK: - TEST: Route Freshness

    /// Test that routes use the freshness model correctly.
    func testRouteFreshness() {
        let route = makeRoute(destination: "N0DEST", origin: "W1ABC", quality: 200, path: ["W1ABC"], lastUpdated: baseTime)

        // At T0
        let freshnessAtT0 = route.freshness(now: baseTime, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAtT0, 1.0, accuracy: 0.001, "Route at T0 should be 100% fresh")

        // At 5 minutes
        let at5min = baseTime.addingTimeInterval(300)
        let freshnessAt5min = route.freshness(now: at5min, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAt5min, 0.95, accuracy: 0.01, "Route at 5 min should be ~95% fresh")

        // At TTL
        let atTTL = baseTime.addingTimeInterval(ttl)
        let freshnessAtTTL = route.freshness(now: atTTL, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAtTTL, 0.0, accuracy: 0.001, "Route at TTL should be 0% fresh")
    }

    // MARK: - TEST: LinkStat Freshness

    /// Test that link stats use the freshness model correctly.
    func testLinkStatFreshness() {
        let stat = makeLinkStat(from: "W1ABC", to: "N0CAL", quality: 200, lastUpdated: baseTime)

        // At T0
        let freshnessAtT0 = stat.freshness(now: baseTime, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAtT0, 1.0, accuracy: 0.001, "LinkStat at T0 should be 100% fresh")

        // At 5 minutes
        let at5min = baseTime.addingTimeInterval(300)
        let freshnessAt5min = stat.freshness(now: at5min, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAt5min, 0.95, accuracy: 0.01, "LinkStat at 5 min should be ~95% fresh")

        // At TTL
        let atTTL = baseTime.addingTimeInterval(ttl)
        let freshnessAtTTL = stat.freshness(now: atTTL, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshnessAtTTL, 0.0, accuracy: 0.001, "LinkStat at TTL should be 0% fresh")
    }

    // MARK: - TEST: FreshnessConfig

    /// Test that FreshnessConfig provides correct values.
    func testFreshnessConfig() {
        let defaultConfig = FreshnessConfig.default
        let kissConfig = FreshnessConfig.kiss
        let agwpeConfig = FreshnessConfig.agwpe

        // All configs should have 30-minute TTL
        XCTAssertEqual(defaultConfig.neighborTTL, 30 * 60, "Default neighbor TTL should be 30 minutes")
        XCTAssertEqual(defaultConfig.routeTTL, 30 * 60, "Default route TTL should be 30 minutes")
        XCTAssertEqual(defaultConfig.linkStatTTL, 30 * 60, "Default linkStat TTL should be 30 minutes")

        // All configs should have 5-minute plateau
        XCTAssertEqual(defaultConfig.plateauDuration, 5 * 60, "Default plateau should be 5 minutes")
        XCTAssertEqual(kissConfig.plateauDuration, 5 * 60, "KISS plateau should be 5 minutes")
        XCTAssertEqual(agwpeConfig.plateauDuration, 5 * 60, "AGWPE plateau should be 5 minutes")

        // KISS should have ingestion dedup window
        XCTAssertEqual(kissConfig.ingestionDedupWindow, 0.25, "KISS should have 0.25s ingestion dedup")

        // AGWPE should have no ingestion dedup window
        XCTAssertEqual(agwpeConfig.ingestionDedupWindow, 0.0, "AGWPE should have 0s ingestion dedup")
    }

    // MARK: - TEST: Edge Cases

    /// Test freshness with future timestamps.
    func testFreshnessWithFutureTimestamp() {
        let neighbor = makeNeighbor(call: "W1FUTURE", quality: 200, lastSeen: baseTime.addingTimeInterval(60))

        // Query at baseTime (before lastSeen)
        let freshness = neighbor.freshness(now: baseTime, ttl: ttl, plateau: plateau)

        // Future timestamps should return 100%
        XCTAssertEqual(freshness, 1.0, accuracy: 0.001,
            "Future lastSeen timestamps should return 100% freshness")
    }

    /// Test freshness with very old timestamps.
    func testFreshnessWithVeryOldTimestamp() {
        let veryOld = baseTime.addingTimeInterval(-365 * 24 * 60 * 60) // 1 year ago
        let neighbor = makeNeighbor(call: "W1OLD", quality: 200, lastSeen: veryOld)

        let freshness = neighbor.freshness(now: baseTime, ttl: ttl, plateau: plateau)

        XCTAssertEqual(freshness, 0.0, accuracy: 0.001,
            "Very old timestamps should return 0% freshness")
    }

    /// Test freshness beyond TTL is clamped to 0.
    func testFreshnessBeyondTTL() {
        let neighbor = makeNeighbor(call: "W1TEST", quality: 200, lastSeen: baseTime)

        let beyondTTL = baseTime.addingTimeInterval(ttl * 2)
        let freshness = neighbor.freshness(now: beyondTTL, ttl: ttl, plateau: plateau)

        XCTAssertEqual(freshness, 0.0, accuracy: 0.001,
            "Beyond TTL, freshness should clamp to 0%")
    }
}
