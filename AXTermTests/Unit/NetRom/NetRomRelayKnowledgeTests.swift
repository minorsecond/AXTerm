//
//  NetRomRelayKnowledgeTests.swift
//  AXTermTests
//
//  One walk for three consumers: the relay call sites, the pre-connect
//  preview, and the profile resolver all resolve through
//  NetRomRelayKnowledge, so these tests pin the walk once. Fixtures are the
//  live topology of 2026-08-28: SOLBPQ behind DRLNOD → KB5YZB-7 → COSCO,
//  its scraped table listing W9GM-7.
//

import XCTest
@testable import AXTerm

@MainActor
final class NetRomRelayKnowledgeTests: XCTestCase {

    private func fieldKnowledge(
        freshRoutes: [String: String] = ["KE0GB-7": "KB5YZB-7", "KB5YZB-7": "DRLNOD"],
        staleRoutes: [String: String] = [:],
        aliases: [String: String] = ["COSCO": "KE0GB-7"],
        claims: [String: [(teller: String, claimedAt: Date)]] = [
            "SOLBPQ": [(teller: "COSCO", claimedAt: Date())],
            "W9GM-7": [(teller: "SOLBPQ", claimedAt: Date())]
        ],
        capability: [String: Bool] = ["DRLNOD": false]
    ) -> NetRomRelayKnowledge {
        NetRomRelayKnowledge(
            freshRouteOrigin: { freshRoutes[$0.uppercased()] },
            anyRouteOrigin: { staleRoutes[$0] },
            aliasCallsign: { aliases[$0.uppercased()] },
            tellerClaims: { claims[$0.uppercased()] ?? [] },
            canRouteNetRom: { capability[$0.uppercased()] })
    }

    // MARK: - Resolution order

    func testAFreshRouteBeatsEverything() async {
        let knowledge = fieldKnowledge(
            staleRoutes: ["KB5YZB-7": "WRONG"],
            claims: ["KB5YZB-7": [(teller: "ALSOWRONG", claimedAt: Date())]])
        let hit = knowledge.resolve("KB5YZB-7")
        XCTAssertEqual(hit?.origin, "DRLNOD")
        XCTAssertTrue(hit?.evidence.contains("measured") ?? false)
    }

    func testAStaleRouteBeatsHearsay() async {
        let knowledge = fieldKnowledge(
            freshRoutes: [:],
            staleRoutes: ["KB5YZB-7": "DRLNOD"],
            claims: ["KB5YZB-7": [(teller: "WRONG", claimedAt: Date())]])
        let hit = knowledge.resolve("KB5YZB-7")
        XCTAssertEqual(hit?.origin, "DRLNOD")
        XCTAssertTrue(hit?.evidence.contains("stale") ?? false,
                      "the evidence admits the route's age")
    }

    func testARouteFiledUnderTheCallsignIsFoundByName() async {
        let hit = fieldKnowledge().resolve("COSCO")
        XCTAssertEqual(hit?.origin, "KB5YZB-7",
                       "COSCO's route lives under KE0GB-7")
    }

    func testHearsayComesLastAndFiltered() async {
        let knowledge = fieldKnowledge(claims: [
            "SOLBPQ": [
                (teller: "DRLNOD", claimedAt: Date()),           // KA-Node — mis-attribution
                (teller: "COSCO", claimedAt: Date(timeIntervalSinceNow: -60))
            ]
        ])
        let hit = knowledge.resolve("SOLBPQ")
        XCTAssertEqual(hit?.origin, "COSCO")
        XCTAssertTrue(hit?.evidence.contains("lists") ?? false)
        XCTAssertTrue(hit?.evidence.contains("hearsay") ?? false,
                      "the tooltip must not oversell a directory claim")
    }

    func testAnUnknownStationResolvesToNothing() async {
        XCTAssertNil(fieldKnowledge().resolve("N0SUCH-1"))
    }

    // MARK: - The planned path preview

    /// The whole point: W9GM-7, known only from SOLBPQ's scraped table,
    /// previews the full four-node walk with per-hop evidence.
    func testTheDeepChainPreviewsInFullWithEvidence() async {
        let hops = fieldKnowledge().plannedPath(to: "W9GM-7")
        XCTAssertEqual(hops.map(\.name), ["DRLNOD", "KB5YZB-7", "COSCO", "SOLBPQ"])
        for hop in hops {
            XCTAssertFalse(hop.evidence.isEmpty, hop.name)
        }
        XCTAssertTrue(hops[0].evidence.contains("measured"), hops[0].evidence)
        XCTAssertTrue(hops[3].evidence.contains("SOLBPQ lists W9GM-7"), hops[3].evidence)
    }

    func testAnUnknownDestinationPreviewsNothing() async {
        XCTAssertTrue(fieldKnowledge().plannedPath(to: "N0SUCH-1").isEmpty)
        XCTAssertTrue(fieldKnowledge().plannedPath(to: "  ").isEmpty)
    }

    /// A destination one hop behind a directly-heard node stays one hop.
    func testAOneHopDestinationPreviewsOneHop() async {
        let knowledge = fieldKnowledge(claims: [
            "EVANS": [(teller: "KB5YZB-7", claimedAt: Date())]
        ])
        let hops = knowledge.plannedPath(to: "EVANS")
        XCTAssertEqual(hops.map(\.name), ["DRLNOD", "KB5YZB-7"])
    }

    /// The preview and the relay's own plan are the same walk: seeding the
    /// plan with the preview's first resolution yields the preview's chain.
    func testPreviewAndPlanAgree() async {
        let knowledge = fieldKnowledge()
        let preview = knowledge.plannedPath(to: "W9GM-7")
        let plan = NetRomRelayPlan.plan(
            destination: "W9GM-7",
            teller: knowledge.resolve("W9GM-7")?.origin,
            routeLookup: { knowledge.routeLookup($0) },
            aliasResolve: { knowledge.aliasCallsign($0) })
        XCTAssertEqual(preview.map(\.name), plan.chain)
    }
}
