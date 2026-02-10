//
//  RouteHysteresisTests.swift
//  AXTermTests
//
//  Tests for route selection hysteresis — sticky preferred route with
//  margin and hold time requirements before allowing route switches.
//

import XCTest
@testable import AXTerm

@MainActor
final class RouteHysteresisTests: XCTestCase {
    private let localCallsign = "N0CALL"

    private func makeRouter(
        hysteresisMargin: Double = 0.12,
        hysteresisHoldSeconds: TimeInterval = 120.0,
        routeTTLSeconds: TimeInterval = 1800
    ) -> NetRomRouter {
        let config = NetRomConfig(
            neighborBaseQuality: 80,
            neighborIncrement: 40,
            minimumRouteQuality: 32,
            maxRoutesPerDestination: 3,
            neighborTTLSeconds: 1800,
            routeTTLSeconds: routeTTLSeconds,
            routingPolicy: .default,
            hysteresisMargin: hysteresisMargin,
            hysteresisHoldSeconds: hysteresisHoldSeconds
        )
        return NetRomRouter(localCallsign: localCallsign, config: config)
    }

    private func makePacket(
        from: String,
        to: String,
        timestamp: Date
    ) -> Packet {
        let infoData = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .ui,
            info: infoData,
            rawAx25: infoData,
            infoText: "TEST"
        )
    }

    /// Import two routes for DEST0 — route A at quality 180, route B at quality 189 (5% better).
    /// With 12% hysteresis, should stay on A.
    func testNoFlipWhenMarginallyBetter() {
        let router = makeRouter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let routeA = RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 180, path: ["ORIGIN-A"], lastUpdated: now, sourceType: "broadcast")
        let routeB = RouteInfo(destination: "DEST0", origin: "ORIGIN-B", quality: 189, path: ["ORIGIN-B"], lastUpdated: now, sourceType: "broadcast")
        router.importRoutes([routeA, routeB])

        // First call selects the absolute best (B at 189)
        let first = router.bestRouteTo("DEST0", currentDate: now)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.origin, "ORIGIN-B")

        // Now update: A improves to 188, B stays at 189.
        // B is only ~0.5% better — well under 12% margin. Should stay on B.
        let later = now.addingTimeInterval(200)
        router.importRoutes([
            RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 188, path: ["ORIGIN-A"], lastUpdated: later, sourceType: "broadcast"),
            RouteInfo(destination: "DEST0", origin: "ORIGIN-B", quality: 189, path: ["ORIGIN-B"], lastUpdated: later, sourceType: "broadcast")
        ])

        // Even with hold time elapsed, A doesn't exceed B by margin so no switch
        let result = router.bestRouteTo("DEST0", currentDate: later)
        XCTAssertEqual(result?.origin, "ORIGIN-B", "Should stay on preferred route when alternative is not significantly better")
    }

    /// Route B exceeds A by >12% AND hold time has elapsed → should switch to B.
    func testFlipWhenSignificantlyBetter() {
        let router = makeRouter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let routeA = RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 150, path: ["ORIGIN-A"], lastUpdated: now, sourceType: "broadcast")
        router.importRoutes([routeA])

        // First call selects A
        let first = router.bestRouteTo("DEST0", currentDate: now)
        XCTAssertEqual(first?.origin, "ORIGIN-A")

        // 200s later (past 120s hold), B appears at 200 (33% better than 150 → exceeds 12% margin)
        let later = now.addingTimeInterval(200)
        let routeB = RouteInfo(destination: "DEST0", origin: "ORIGIN-B", quality: 200, path: ["ORIGIN-B"], lastUpdated: later, sourceType: "broadcast")
        router.importRoutes([
            RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 150, path: ["ORIGIN-A"], lastUpdated: later, sourceType: "broadcast"),
            routeB
        ])

        let result = router.bestRouteTo("DEST0", currentDate: later)
        XCTAssertEqual(result?.origin, "ORIGIN-B", "Should switch to significantly better route after hold time")
    }

    /// Route B is >12% better but only 60s since last switch (hold=120s) → stays on A.
    func testNoFlipBeforeHoldTime() {
        let router = makeRouter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let routeA = RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 150, path: ["ORIGIN-A"], lastUpdated: now, sourceType: "broadcast")
        router.importRoutes([routeA])

        // First call selects A
        _ = router.bestRouteTo("DEST0", currentDate: now)

        // 60s later (before 120s hold), B appears at 200 (>12% better)
        let tooSoon = now.addingTimeInterval(60)
        router.importRoutes([
            RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 150, path: ["ORIGIN-A"], lastUpdated: tooSoon, sourceType: "broadcast"),
            RouteInfo(destination: "DEST0", origin: "ORIGIN-B", quality: 200, path: ["ORIGIN-B"], lastUpdated: tooSoon, sourceType: "broadcast")
        ])

        let result = router.bestRouteTo("DEST0", currentDate: tooSoon)
        XCTAssertEqual(result?.origin, "ORIGIN-A", "Should NOT switch before hold time even if significantly better")
    }

    /// Preferred route expires → falls back to next best.
    func testPreferredClearedWhenExpired() {
        let router = makeRouter(routeTTLSeconds: 300)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let routeA = RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 200, path: ["ORIGIN-A"], lastUpdated: now, sourceType: "broadcast")
        let routeB = RouteInfo(destination: "DEST0", origin: "ORIGIN-B", quality: 150, path: ["ORIGIN-B"], lastUpdated: now.addingTimeInterval(250), sourceType: "broadcast")
        router.importRoutes([routeA, routeB])

        // Select A as preferred
        let first = router.bestRouteTo("DEST0", currentDate: now)
        XCTAssertEqual(first?.origin, "ORIGIN-A")

        // 400s later, A is expired (>300s TTL) but B was updated at +250 so still valid
        let later = now.addingTimeInterval(400)
        let result = router.bestRouteTo("DEST0", currentDate: later)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.origin, "ORIGIN-B", "Should fall back to next best when preferred expires")
    }

    /// All routes expire → returns nil.
    func testPreferredClearedWhenNoRoutes() {
        let router = makeRouter(routeTTLSeconds: 300)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let routeA = RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 200, path: ["ORIGIN-A"], lastUpdated: now, sourceType: "broadcast")
        router.importRoutes([routeA])

        _ = router.bestRouteTo("DEST0", currentDate: now)

        let expired = now.addingTimeInterval(600)
        let result = router.bestRouteTo("DEST0", currentDate: expired)
        XCTAssertNil(result, "Should return nil when all routes are expired")
    }

    /// Two routes with identical quality → deterministic selection (lexicographic origin).
    func testDeterministicWithEqualQuality() {
        let router = makeRouter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let routeA = RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 180, path: ["ORIGIN-A"], lastUpdated: now, sourceType: "broadcast")
        let routeB = RouteInfo(destination: "DEST0", origin: "ORIGIN-B", quality: 180, path: ["ORIGIN-B"], lastUpdated: now, sourceType: "broadcast")
        router.importRoutes([routeA, routeB])

        let first = router.bestRouteTo("DEST0", currentDate: now)
        let second = router.bestRouteTo("DEST0", currentDate: now.addingTimeInterval(1))

        XCTAssertEqual(first?.origin, second?.origin, "Same quality routes should produce deterministic selection")
        // routeSort uses lexicographic origin for ties
        XCTAssertEqual(first?.origin, "ORIGIN-A", "Lexicographic tie-break should prefer ORIGIN-A")
    }

    /// With hysteresisMargin=0.0, always returns absolute best (hysteresis disabled).
    func testHysteresisDisabledWithZeroMargin() {
        let router = makeRouter(hysteresisMargin: 0.0)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let routeA = RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 180, path: ["ORIGIN-A"], lastUpdated: now, sourceType: "broadcast")
        router.importRoutes([routeA])

        _ = router.bestRouteTo("DEST0", currentDate: now)

        // Even 1s later, any improvement should be picked immediately
        let soon = now.addingTimeInterval(1)
        router.importRoutes([
            RouteInfo(destination: "DEST0", origin: "ORIGIN-A", quality: 180, path: ["ORIGIN-A"], lastUpdated: soon, sourceType: "broadcast"),
            RouteInfo(destination: "DEST0", origin: "ORIGIN-B", quality: 181, path: ["ORIGIN-B"], lastUpdated: soon, sourceType: "broadcast")
        ])

        let result = router.bestRouteTo("DEST0", currentDate: soon)
        XCTAssertEqual(result?.origin, "ORIGIN-B", "With zero margin, should always pick absolute best")
    }
}
