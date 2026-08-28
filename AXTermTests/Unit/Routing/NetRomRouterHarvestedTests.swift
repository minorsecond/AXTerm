//
//  NetRomRouterHarvestedTests.swift
//  AXTermTests
//
//  Pins the three-tier route trust model (broadcast/classic > harvested >
//  inferred) and the candidateRoutes TTL fix. The tiers exist because
//  quality numbers are not comparable across sources: a broadcast figure is
//  the protocol's own computation, a harvested figure is scaled hearsay
//  from a scraped ROUTES table, an inferred figure is a traffic-pattern
//  guess. On the operator's home channel nobody broadcasts NODES at all,
//  so the lower tiers are the only routing knowledge there is — but the
//  moment a real broadcast appears it must win outright.
//

import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class NetRomRouterHarvestedTests: XCTestCase {
    private let localCallsign = "N0CALL"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRouter(routeTTLSeconds: TimeInterval = 1800,
                            hysteresisMargin: Double = 0.12) -> NetRomRouter {
        let config = NetRomConfig(
            neighborBaseQuality: 80,
            neighborIncrement: 40,
            minimumRouteQuality: 32,
            maxRoutesPerDestination: 3,
            neighborTTLSeconds: 1800,
            routeTTLSeconds: routeTTLSeconds,
            routingPolicy: .default,
            hysteresisMargin: hysteresisMargin,
            hysteresisHoldSeconds: 120.0
        )
        return NetRomRouter(localCallsign: localCallsign, config: config)
    }

    /// Direct packet from `call` so the router records it as a classic
    /// neighbor — broadcastRoutes refuses claims from strangers.
    private func makeNeighbor(_ call: String, on router: NetRomRouter, quality: Int = 200) {
        let info = "HELLO".data(using: .ascii) ?? Data()
        let packet = Packet(
            timestamp: now,
            from: AX25Address(call: call),
            to: AX25Address(call: localCallsign),
            via: [],
            frameType: .ui,
            info: info,
            rawAx25: info,
            infoText: "HELLO"
        )
        router.observePacket(packet, observedQuality: quality, direction: .incoming, timestamp: now)
    }

    private func route(_ destination: String, via origin: String, quality: Int,
                       source: String, at date: Date? = nil) -> RouteInfo {
        RouteInfo(
            destination: destination,
            origin: origin,
            quality: quality,
            path: [origin, destination],
            lastUpdated: date ?? now,
            sourceType: source
        )
    }

    // MARK: - Tier vocabulary

    func testSourceTierOrdersBroadcastAboveHarvestedAboveInferred() {
        XCTAssertEqual(NetRomRouter.sourceTier("broadcast"), 2)
        XCTAssertEqual(NetRomRouter.sourceTier("classic"), 2)
        XCTAssertEqual(NetRomRouter.sourceTier("harvested"), 1)
        XCTAssertEqual(NetRomRouter.sourceTier("inferred"), 0)
        XCTAssertEqual(NetRomRouter.sourceTier("anything-else"), 0)
    }

    // MARK: - candidateRoutes: the TTL regression and tier ranking

    /// candidateRoutes accepted a currentDate and never used it, so auto-try
    /// walked routes the rest of the router had already declared dead —
    /// spending a full attempt timeout per expired entry.
    func testCandidateRoutesExcludeExpiredEntries() {
        let router = makeRouter(routeTTLSeconds: 1800)
        let stale = now.addingTimeInterval(-3600)
        router.importRoutes([
            route("DEST", via: "FRESH", quality: 100, source: "broadcast"),
            route("DEST", via: "STALE", quality: 250, source: "broadcast", at: stale)
        ])

        let candidates = router.candidateRoutes(to: "DEST", currentDate: now)
        XCTAssertEqual(candidates.map(\.origin), ["FRESH"],
                       "an expired route must not be offered as an attempt candidate")
    }

    /// A live broadcast route is attempted before scraped or guessed routes
    /// of any quality — quality only ranks within a tier.
    func testCandidateRoutesRankTierBeforeQuality() {
        let router = makeRouter()
        router.importRoutes([
            route("DEST", via: "GUESS", quality: 250, source: "inferred"),
            route("DEST", via: "SCRAPE", quality: 150, source: "harvested"),
            route("DEST", via: "REAL", quality: 100, source: "broadcast")
        ])

        let candidates = router.candidateRoutes(to: "DEST", currentDate: now)
        XCTAssertEqual(candidates.map(\.origin), ["REAL", "SCRAPE", "GUESS"])
    }

    // MARK: - storeRoute tier precedence (through the broadcastRoutes funnel)

    /// Lower-tier evidence may only corroborate (raise) a higher-tier figure
    /// — never lower it, never rewrite the path, never adopt the sourceType.
    func testHarvestedOnlyCorroboratesABroadcastRoute() {
        let router = makeRouter()
        makeNeighbor("ANCHOR", on: router)

        router.broadcastRoutes(
            from: "ANCHOR", quality: 255,
            destinations: [route("DEST", via: "ANCHOR", quality: 200, source: "broadcast")],
            timestamp: now)
        let broadcastQuality = router.currentRoutes().first?.quality ?? 0
        XCTAssertGreaterThan(broadcastQuality, 0)

        // A weaker harvested claim for the same (destination, origin) must
        // not drag the broadcast figure down or take over the record.
        router.broadcastRoutes(
            from: "ANCHOR", quality: 255,
            destinations: [route("DEST", via: "ANCHOR", quality: 40, source: "harvested")],
            timestamp: now.addingTimeInterval(60))

        let after = router.currentRoutes().first
        XCTAssertEqual(after?.sourceType, "broadcast", "the better claim keeps the record")
        XCTAssertEqual(after?.quality, broadcastQuality, "weaker lower-tier claim must not degrade quality")
    }

    /// A real broadcast arriving on top of a harvested row replaces it in
    /// place — quality, path, and sourceType all adopt the higher tier.
    func testBroadcastUpgradesAHarvestedRoute() {
        let router = makeRouter()
        makeNeighbor("ANCHOR", on: router)

        router.broadcastRoutes(
            from: "ANCHOR", quality: 255,
            destinations: [route("DEST", via: "ANCHOR", quality: 180, source: "harvested")],
            timestamp: now)
        XCTAssertEqual(router.currentRoutes().first?.sourceType, "harvested")

        router.broadcastRoutes(
            from: "ANCHOR", quality: 255,
            destinations: [route("DEST", via: "ANCHOR", quality: 90, source: "broadcast")],
            timestamp: now.addingTimeInterval(60))

        let after = router.currentRoutes().first
        XCTAssertEqual(after?.sourceType, "broadcast", "higher tier takes the record over")
        XCTAssertLessThan(after?.quality ?? 999, 180,
                          "the broadcast's own (lower) figure replaces the harvested one — no high-water mark")
    }

    /// The 3-route bucket must never evict a broadcast route to make room
    /// for harvested ones: eviction order is tier-aware.
    func testBucketEvictionKeepsTheBroadcastRoute() {
        let router = makeRouter()
        router.importRoutes([route("DEST", via: "REAL", quality: 40, source: "broadcast")])
        // A route's origin is always the node that claimed it, so three next
        // hops to one destination require three separate anchors.
        for (index, quality) in [250, 240, 230].enumerated() {
            let anchor = "HOP-\(index + 1)"
            makeNeighbor(anchor, on: router)
            router.broadcastRoutes(
                from: anchor, quality: 255,
                destinations: [route("DEST", via: anchor, quality: quality, source: "harvested")],
                timestamp: now)
        }

        let sources = router.candidateRoutes(to: "DEST", currentDate: now)
        XCTAssertEqual(sources.count, 3, "bucket stays capped at maxRoutesPerDestination")
        XCTAssertEqual(sources.first?.origin, "REAL",
                       "the weak broadcast route outranks and outlives every harvested one")
        XCTAssertFalse(sources.contains { $0.origin == "HOP-3" },
                       "the weakest harvested route is the one evicted")
    }

    // MARK: - Acceptance gate

    /// On a NODES-silent channel a weak harvested route is the only route
    /// there is; the classic minimumRouteQuality gate applies to broadcast
    /// claims only.
    func testHarvestedRoutesSkipTheMinimumQualityGate() {
        let router = makeRouter()
        makeNeighbor("ANCHOR", on: router, quality: 30)

        // combined = (q * neighborQuality + 128) / 256 — tiny on both counts.
        router.broadcastRoutes(
            from: "ANCHOR", quality: 255,
            destinations: [
                route("WEAK-H", via: "ANCHOR", quality: 20, source: "harvested"),
                route("WEAK-B", via: "ANCHOR", quality: 20, source: "broadcast")
            ],
            timestamp: now)

        let destinations = Set(router.currentRoutes().map(\.destination))
        XCTAssertTrue(destinations.contains("WEAK-H"),
                      "the honest small harvested figure is stored, not discarded")
        XCTAssertFalse(destinations.contains("WEAK-B"),
                       "broadcast claims below minimumRouteQuality stay rejected")
    }

    // MARK: - bestRouteTo tier preemption vs within-tier hysteresis

    /// Hysteresis stops flapping between comparable measurements. A real
    /// broadcast appearing on top of a harvested pick is not comparable —
    /// it preempts immediately, margin and hold time notwithstanding.
    func testHigherTierPreemptsThePreferredRouteImmediately() {
        let router = makeRouter()
        router.importRoutes([route("DEST", via: "SCRAPE", quality: 200, source: "harvested")])

        XCTAssertEqual(router.bestRouteTo("DEST", currentDate: now)?.origin, "SCRAPE")

        // New broadcast route: quality 190 does NOT clear the 12% margin over
        // 200, and only 10s elapsed — within-tier rules would hold SCRAPE.
        router.importRoutes([
            route("DEST", via: "SCRAPE", quality: 200, source: "harvested"),
            route("DEST", via: "REAL", quality: 190, source: "broadcast")
        ])
        let after = router.bestRouteTo("DEST", currentDate: now.addingTimeInterval(10))
        XCTAssertEqual(after?.origin, "REAL", "tier preempts without waiting out margin or hold time")
    }

    /// Within one tier nothing changed: a marginally better same-tier
    /// alternative still respects the hold.
    func testWithinTierHysteresisStillHolds() {
        let router = makeRouter()
        router.importRoutes([route("DEST", via: "HOP-A", quality: 200, source: "harvested")])
        XCTAssertEqual(router.bestRouteTo("DEST", currentDate: now)?.origin, "HOP-A")

        router.importRoutes([
            route("DEST", via: "HOP-A", quality: 200, source: "harvested"),
            route("DEST", via: "HOP-B", quality: 205, source: "harvested")
        ])
        let after = router.bestRouteTo("DEST", currentDate: now.addingTimeInterval(10))
        XCTAssertEqual(after?.origin, "HOP-A",
                       "2.5% better within the same tier does not clear the 12% margin")
    }

    // MARK: - Persistence round-trip

    /// "harvested" is a new string through an existing text column — it must
    /// survive save/load unchanged so scraped knowledge outlives a restart.
    func testHarvestedSourceTypeSurvivesSnapshotRoundTrip() throws {
        let dbQueue = try DatabaseQueue()
        let persistence = try NetRomPersistence(database: dbQueue)
        let harvested = route("DEST", via: "ANCHOR", quality: 120, source: "harvested")

        try persistence.saveSnapshot(
            neighbors: [],
            routes: [harvested],
            linkStats: [],
            lastPacketID: 1,
            configHash: "test",
            snapshotTimestamp: now
        )
        let loaded = try persistence.load(now: now, expectedConfigHash: "test")

        XCTAssertEqual(loaded?.routes.count, 1)
        XCTAssertEqual(loaded?.routes.first?.sourceType, "harvested")
        XCTAssertEqual(loaded?.routes.first?.quality, 120)
    }
}
