//
//  NodeProfilePlannedChainTests.swift
//  AXTermTests
//
//  The profile shows the chain a prompt-relay connect would walk, computed
//  with the relay's own planner so the picture and the behaviour cannot
//  drift. Field topology of 2026-08-28: ASHCHT is listed by COSCO, COSCO
//  (KE0GB-7) is routed via KB5YZB-7, KB5YZB-7 via DRLNOD — the picture
//  must read You → DRLNOD → KB5YZB-7 → COSCO → ASHCHT.
//

import XCTest
@testable import AXTerm

final class NodeProfilePlannedChainTests: XCTestCase {

    @MainActor
    private func makeResolver() -> NodeProfileResolver {
        var aliases = NodeAliasDirectory()
        let now = Date()
        // COSCO's table lists ASHCHT; KB5YZB-7's table lists COSCO.
        aliases.record(.init(alias: "ASHCHT", callsign: "KD8FTR-5", service: "chat"),
                       at: now, from: "COSCO")
        aliases.record(.init(alias: "COSCO", callsign: "KE0GB-7", service: "node"),
                       at: now, from: "KB5YZB-7")

        var resolver = NodeProfileResolver()
        resolver.aliases = aliases
        resolver.routes = [
            (destination: "KE0GB-7", via: "KB5YZB-7", isBroadcast: false),
            (destination: "KB5YZB-7", via: "DRLNOD", isBroadcast: false),
        ]
        return resolver
    }

    @MainActor
    func testTheAshchtChainIsPlannedInFull() async {
        let profile = makeResolver().profile(for: "ASHCHT")
        XCTAssertEqual(profile.plannedChain, ["DRLNOD", "KB5YZB-7", "COSCO"],
                       "the picture must match what the relay will actually do")
    }

    @MainActor
    func testATellerWithNoDeeperKnowledgeIsAOneHopChain() async {
        var resolver = NodeProfileResolver()
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "SOMEBBS", callsign: "N0XYZ-1", service: "bbs"),
                       at: Date(), from: "LOCALNODE")
        resolver.aliases = aliases
        let profile = resolver.profile(for: "SOMEBBS")
        XCTAssertEqual(profile.plannedChain, ["LOCALNODE"])
    }

    @MainActor
    func testADirectStationPlansNoChain() async {
        let profile = NodeProfileResolver().profile(for: "AB0VZ")
        XCTAssertTrue(profile.plannedChain.isEmpty)
    }
}
