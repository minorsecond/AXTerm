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

    /// The 05:07 field capture, 2026-08-29: one `N` at SOLBPQ made it the
    /// freshest teller for its whole 233-entry table, COSCO included — and
    /// a chain seeded from the newest teller read "You → SOLBPQ → COSCO",
    /// through a node that sits *behind* COSCO. The measured route via
    /// KB5YZB-7 must win the seed, exactly as it wins every later hop.
    @MainActor
    func testTheFreshestTellerDoesNotOutrankTheMeasuredRouteAtTheSeed() async {
        var resolver = makeResolver()
        var aliases = resolver.aliases
        aliases.record(.init(alias: "COSCO", callsign: "KE0GB-7", service: ""),
                       at: Date(), from: "SOLBPQ")  // newest teller — and wrong seed
        resolver.aliases = aliases
        let profile = resolver.profile(for: "COSCO")
        XCTAssertEqual(profile.plannedChain, ["DRLNOD", "KB5YZB-7"],
                       "seeded by the route table, not by whoever spoke last")
    }

    /// A station known only from SOLBPQ's scraped table, with SOLBPQ itself
    /// known only from a made relay hop ("COSCO connected us to it") — the
    /// profile must draw the same four-node chain the relay would walk.
    @MainActor
    func testAStationBehindTheDeepChainShowsFourNodes() async {
        var resolver = makeResolver()
        var aliases = resolver.aliases
        aliases.record(.init(alias: "SOLBPQ", callsign: "N0HI-7", service: ""),
                       at: Date(), from: "COSCO")
        aliases.record(.init(alias: "W9GM-7", callsign: "W9GM-7", service: ""),
                       at: Date(), from: "SOLBPQ")
        resolver.aliases = aliases
        let profile = resolver.profile(for: "W9GM-7")
        XCTAssertEqual(profile.plannedChain,
                       ["DRLNOD", "KB5YZB-7", "COSCO", "SOLBPQ"])
    }

    /// The 18:28 field capture, 2026-08-28: a relayed session mis-credited
    /// DRLNOD with listing COSCO (its banner rode the DRLNOD link), and the
    /// fresher hearsay shortened the chain to DRLNOD→COSCO. The measured
    /// route filed under KE0GB-7 must outrank any claim, so the poisoned
    /// directory still plans the full chain.
    @MainActor
    func testFreshMisattributedHearsayDoesNotShortenTheChain() async {
        var resolver = makeResolver()
        var aliases = resolver.aliases
        aliases.record(.init(alias: "COSCO", callsign: "KE0GB-7", service: "node"),
                       at: Date(), from: "DRLNOD")  // newest — and wrong
        resolver.aliases = aliases
        let profile = resolver.profile(for: "ASHCHT")
        XCTAssertEqual(profile.plannedChain, ["DRLNOD", "KB5YZB-7", "COSCO"],
                       "a measured route outranks freshly poisoned hearsay")
    }
}
