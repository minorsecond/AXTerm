//
//  ConnectStrategyPlannerTests.swift
//  AXTermTests
//
//  Pins the cross-family ladder: what gets tried for one destination, in
//  what order, and the exact sentence that explains each rung. Ranking is
//  evidence, so every ordering asserted here carries the why in its name.
//

import XCTest
@testable import AXTerm

final class ConnectStrategyPlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    private func evidence(
        direct: ConnectStrategyEvidence.DirectSighting? = nil,
        digiPaths: [ConnectSuggestions.DigiPath] = [],
        routes: [RouteInfo] = [],
        capability: [String: Bool] = [:],
        tellers: [ConnectStrategyEvidence.TellerClaim] = [],
        coolingDown: Bool = false,
        advertiseSelf: Bool = false
    ) -> ConnectStrategyEvidence {
        var evidence = ConnectStrategyEvidence(destination: "COSCO", now: now)
        evidence.direct = direct
        evidence.digiPaths = digiPaths
        evidence.candidateRoutes = routes
        evidence.capabilityByAnchor = capability
        evidence.tellers = tellers
        evidence.nativeCircuitCoolingDown = coolingDown
        evidence.advertiseSelfEnabled = advertiseSelf
        return evidence
    }

    private func route(via origin: String, quality: Int = 150, source: String = "broadcast",
                       ageSeconds: TimeInterval = 300) -> RouteInfo {
        RouteInfo(destination: "COSCO", origin: origin, quality: quality,
                  path: [origin, "COSCO"],
                  lastUpdated: now.addingTimeInterval(-ageSeconds), sourceType: source)
    }

    private func kinds(_ ladder: ConnectStrategyLadder) -> [ConnectStrategyKind] {
        ladder.steps.map(\.kind)
    }

    // MARK: - Ordering

    /// A station heard direct minutes ago is the cheapest, likeliest bet —
    /// it outranks any route knowledge, however official.
    func testFreshDirectSightingBeatsAStaleBroadcastRoute() {
        let ladder = ConnectStrategyPlanner.plan(evidence: evidence(
            direct: .init(lastHeard: now.addingTimeInterval(-240), heardVia: []),
            routes: [route(via: "KB5YZB-7", ageSeconds: 3 * 3600)],
            advertiseSelf: true))

        XCTAssertEqual(kinds(ladder).first, .directL2)
        XCTAssertEqual(ladder.steps.first?.reason, "Direct — heard 4 min ago with no digis.")
    }

    /// The headline case from the field: an hour-old teller claim through a
    /// live chain outranks a digi path nobody has seen work in seven hours.
    func testARecentTellerChainOutranksAStaleWeakDigiPath() {
        let staleDigi = ConnectSuggestions.DigiPath(
            digis: ["W0OLD"], score: 0.6, source: .neighborStrong)
        let ladder = ConnectStrategyPlanner.plan(evidence: evidence(
            digiPaths: [staleDigi],
            capability: ["KB5YZB-7": true],
            tellers: [.init(teller: "KB5YZB-7", claimedAt: now.addingTimeInterval(-1800))]))

        XCTAssertEqual(kinds(ladder).first, .nodePromptRelay(teller: "KB5YZB-7"),
                       "0.8 + 0.1 known-teller bonus beats 0.9 × 0.6")
    }

    /// Broadcast > harvested > inferred at equal freshness, via the tier
    /// base scores.
    func testRouteTierOrdersTheNativeRungScore() {
        func nativeScore(source: String) -> Double? {
            let ladder = ConnectStrategyPlanner.plan(evidence: evidence(
                routes: [route(via: "ANCHOR", source: source)],
                capability: ["ANCHOR": true],
                advertiseSelf: true))
            return ladder.steps.first { $0.kind == .netromCircuit(nextHopOverride: nil) }?.score
        }
        let broadcast = nativeScore(source: "broadcast")!
        let harvested = nativeScore(source: "harvested")!
        let inferred = nativeScore(source: "inferred")!
        XCTAssertGreaterThan(broadcast, harvested)
        XCTAssertGreaterThan(harvested, inferred)
    }

    // MARK: - Skips, with reasons

    func testEmptyEvidenceYieldsAnEmptyLadderWithFourSkipReasons() {
        let ladder = ConnectStrategyPlanner.plan(evidence: evidence())
        XCTAssertTrue(ladder.isEmpty)
        XCTAssertEqual(ladder.skipped.map(\.familyLabel),
                       ["direct", "digi path", "native circuit", "node relay"])
        XCTAssertEqual(ladder.skipped.first?.reason, "never heard this station direct")
    }

    func testNegativeCacheSkipsTheNativeRungAndSaysWhy() {
        let ladder = ConnectStrategyPlanner.plan(evidence: evidence(
            routes: [route(via: "KB5YZB-7")],
            capability: ["KB5YZB-7": true],
            coolingDown: true))
        XCTAssertFalse(kinds(ladder).contains { if case .netromCircuit = $0 { return true }; return false })
        XCTAssertTrue(ladder.skipped.contains {
            $0.familyLabel == "native circuit" && $0.reason.contains("failed here recently")
        })
    }

    /// DRLNOD's case: a route whose only anchor is a proven KA-Node is not
    /// a route the native family can use.
    func testKaNodeAnchorsExcludeTheNativeRung() {
        let ladder = ConnectStrategyPlanner.plan(evidence: evidence(
            routes: [route(via: "KE0NCQ")],
            capability: ["KE0NCQ": false]))
        XCTAssertFalse(kinds(ladder).contains { if case .netromCircuit = $0 { return true }; return false })
        XCTAssertTrue(ladder.skipped.contains {
            $0.reason.contains("cannot route NET/ROM")
        })
    }

    func testAStationOnlyHeardThroughDigisSkipsTheDirectRung() {
        let ladder = ConnectStrategyPlanner.plan(evidence: evidence(
            direct: .init(lastHeard: now.addingTimeInterval(-60), heardVia: ["DRLNOD"])))
        XCTAssertTrue(ladder.skipped.contains {
            $0.familyLabel == "direct" && $0.reason.contains("through digipeaters")
        })
    }

    // MARK: - Caveats in the reason

    /// Without self-advertisement the CONACK usually has no route home; the
    /// rung is dampened and its reason carries the fix.
    func testAdvertiseOffDampensTheNativeRungAndAdvises() {
        func score(advertise: Bool) -> (score: Double, reason: String)? {
            let ladder = ConnectStrategyPlanner.plan(evidence: evidence(
                routes: [route(via: "KB5YZB-7")],
                capability: ["KB5YZB-7": true],
                advertiseSelf: advertise))
            guard let step = ladder.steps.first(where: {
                if case .netromCircuit = $0.kind { return true }; return false
            }) else { return nil }
            return (step.score, step.reason)
        }
        let on = score(advertise: true)!
        let off = score(advertise: false)!
        XCTAssertGreaterThan(on.score, off.score)
        XCTAssertTrue(off.reason.contains("Announce this station"))
        XCTAssertFalse(on.reason.contains("Announce this station"))
    }

    func testUnprovenAnchorDampensButDoesNotSkip() {
        let ladder = ConnectStrategyPlanner.plan(evidence: evidence(
            routes: [route(via: "W0MYST")],
            advertiseSelf: true))
        let step = ladder.steps.first {
            if case .netromCircuit = $0.kind { return true }; return false
        }
        XCTAssertNotNil(step)
        XCTAssertTrue(step?.reason.contains("unproven") ?? false)
    }

    // MARK: - Determinism and budget

    func testTheSameEvidencePlansTheSameLadderTwice() {
        let full = evidence(
            direct: .init(lastHeard: now.addingTimeInterval(-3600), heardVia: []),
            digiPaths: [ConnectSuggestions.DigiPath(digis: ["DRLNOD"], score: 1.0, source: .observedForDestination)],
            routes: [route(via: "KB5YZB-7", source: "harvested")],
            capability: ["KB5YZB-7": true],
            tellers: [.init(teller: "KB5YZB-7", claimedAt: now.addingTimeInterval(-600))],
            advertiseSelf: true)
        XCTAssertEqual(ConnectStrategyPlanner.plan(evidence: full),
                       ConnectStrategyPlanner.plan(evidence: full))
    }

    /// Four rungs would run 25+35+30+90 plus three backoffs = 195 s; the
    /// 180 s ceiling drops the lowest-scoring rung rather than the last one
    /// chronologically.
    func testBudgetTrimmingDropsTheLowestScoringRung() {
        let full = evidence(
            direct: .init(lastHeard: now.addingTimeInterval(-60), heardVia: []),
            digiPaths: [ConnectSuggestions.DigiPath(digis: ["DRLNOD"], score: 1.0, source: .observedForDestination)],
            routes: [route(via: "KB5YZB-7", source: "inferred", ageSeconds: 4 * 3600)],
            capability: ["KB5YZB-7": true],
            tellers: [.init(teller: "KB5YZB-7", claimedAt: now.addingTimeInterval(-600))],
            advertiseSelf: false)
        let ladder = ConnectStrategyPlanner.plan(evidence: full)

        XCTAssertEqual(ladder.steps.count, 3)
        let totalBudget = ladder.steps.map(\.budget).reduce(0, +)
            + ConnectStrategyPlanner.interRungBackoffSeconds * TimeInterval(ladder.steps.count - 1)
        XCTAssertLessThanOrEqual(totalBudget, ConnectStrategyPlanner.totalBudgetSeconds)
        XCTAssertFalse(kinds(ladder).contains { if case .netromCircuit = $0 { return true }; return false },
                       "the stale inferred circuit with advertise off scores lowest and is the trimmed rung")
    }

    /// At most two digi paths join, best engine scores first.
    func testAtMostTwoDigiPathsAreLaddered() {
        let paths = [
            ConnectSuggestions.DigiPath(digis: ["A0AAA"], score: 1.0, source: .routeDerived),
            ConnectSuggestions.DigiPath(digis: ["B0BBB"], score: 0.9, source: .historicalSuccess),
            ConnectSuggestions.DigiPath(digis: ["C0CCC"], score: 0.8, source: .observedForDestination)
        ]
        let ladder = ConnectStrategyPlanner.plan(evidence: evidence(digiPaths: paths))
        let digiKinds = kinds(ladder).filter { if case .ax25ViaDigis = $0 { return true }; return false }
        XCTAssertEqual(digiKinds, [.ax25ViaDigis(["A0AAA"]), .ax25ViaDigis(["B0BBB"])])
    }
}
