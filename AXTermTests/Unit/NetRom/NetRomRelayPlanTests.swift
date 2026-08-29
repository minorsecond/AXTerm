import XCTest
@testable import AXTerm

/// Planning the chain of node prompts a terminal relay has to drive.
///
/// The case that forced this: COSCO is listed by KB5YZB-7, but this
/// station cannot get a prompt out of KB5YZB-7 directly — the link comes
/// up and the node stays silent, three separate times on 2026-08-27.
/// The route table held the answer the whole time (`KB5YZB-7 via
/// DRLNOD`), and driving DRLNOD → KB5YZB-7 → COSCO by hand worked.
final class NetRomRelayPlanTests: XCTestCase {

    /// The station's real route table from the field capture.
    private let routes: [String: String] = [
        "KB5YZB-7": "DRLNOD",
        "KB5YZB-1": "DRLNOD",
        "EVANS": "DRLNOD",
        "KC0LDY-10": "DRLNOD",
        "KN6VV-1": "HORSE"
    ]

    private func plan(_ destination: String, teller: String?,
                      using table: [String: String]? = nil) -> NetRomRelayPlan.Plan {
        let source = table ?? routes
        return NetRomRelayPlan.plan(destination: destination, teller: teller) {
            source[$0.uppercased()]
        }
    }

    // MARK: - The COSCO case

    func testTellerThatNeedsARelayIsReachedThroughIt() {
        let result = plan("COSCO", teller: "KB5YZB-7")
        XCTAssertEqual(result.linkTarget, "DRLNOD",
                       "dial the station we can actually reach")
        XCTAssertEqual(result.intermediateHops, ["KB5YZB-7"],
                       "then ask it for the node that lists COSCO")
        XCTAssertEqual(result.destination, "COSCO")
        XCTAssertEqual(result.chain, ["DRLNOD", "KB5YZB-7"])
    }

    func testTheCOSCOChainReadsAsTheOperatorTypedIt() {
        let summary = plan("COSCO", teller: "KB5YZB-7").operatorSummary
        XCTAssertTrue(
            summary.hasPrefix("Reaching COSCO the long way: DRLNOD → KB5YZB-7 → COSCO."),
            summary)
    }

    /// The summary must not let this be mistaken for a NET/ROM circuit.
    /// It is not one — it drives node command prompts, which is exactly
    /// why the operator sees each node's menus (2026-08-27).
    func testSummarySaysTheMenusAreComing() {
        for teller in ["KB5YZB-7", "DRLNOD"] {
            let summary = plan("COSCO", teller: teller).operatorSummary
            XCTAssertTrue(summary.contains("command prompts"), summary)
            XCTAssertTrue(summary.contains("menus"), summary)
        }
    }

    // MARK: - One-hop stays one hop

    func testDirectlyReachableTellerIsASingleHop() {
        // DRLNOD is not in the route table as a destination — this
        // station hears it directly — so nothing is prepended.
        let result = plan("EVANS", teller: "DRLNOD")
        XCTAssertEqual(result.linkTarget, "DRLNOD")
        XCTAssertTrue(result.intermediateHops.isEmpty)
        XCTAssertTrue(result.operatorSummary.hasPrefix(
            "Asking DRLNOD to connect to EVANS."), result.operatorSummary)
    }

    func testNoTellerMeansDialTheDestination() {
        let result = plan("DRLNOD", teller: nil)
        XCTAssertEqual(result.linkTarget, "DRLNOD")
        XCTAssertTrue(result.intermediateHops.isEmpty)
    }

    func testCaseAndWhitespaceAreNormalized() {
        let result = plan("  cosco ", teller: " kb5yzb-7 ")
        XCTAssertEqual(result.linkTarget, "DRLNOD")
        XCTAssertEqual(result.intermediateHops, ["KB5YZB-7"])
        XCTAssertEqual(result.destination, "COSCO")
    }

    // MARK: - Chains of more than two

    func testAThreeNodeChainIsWalkedInOrder() {
        let deep = ["FAR": "MIDDLE", "MIDDLE": "NEAR"]
        let result = plan("TARGET", teller: "FAR", using: deep)
        XCTAssertEqual(result.chain, ["NEAR", "MIDDLE", "FAR"])
        XCTAssertEqual(result.linkTarget, "NEAR")
        XCTAssertEqual(result.intermediateHops, ["MIDDLE", "FAR"])
    }

    func testChainLengthIsBounded() {
        // A table that always has one more hop must not walk forever, and
        // must not spend the operator's airtime on an absurd chain.
        let endless = ["A": "B", "B": "C", "C": "D", "D": "E", "E": "F"]
        let result = plan("TARGET", teller: "A", using: endless)
        XCTAssertEqual(result.chain.count, NetRomRelayPlan.maxChainLength)
    }

    /// The field's deepest real case (2026-08-28): SOLBPQ sits behind
    /// DRLNOD → KB5YZB-7 → COSCO, and its scraped table lists W9GM-7. With
    /// the made-hop claim ("COSCO connected us to SOLBPQ") and the scraped
    /// claim ("SOLBPQ lists W9GM-7") both recorded, a connect to W9GM-7
    /// must plan the full four-node chain.
    func testAStationBehindTheDeepChainPlansFourNodes() {
        // What the production routeLookup closure resolves to: measured
        // routes first (by callsign), then recorded teller claims.
        let knowledge = [
            "SOLBPQ": "COSCO",      // made-hop claim
            "KE0GB-7": "KB5YZB-7",  // harvested route
            "KB5YZB-7": "DRLNOD"    // measured route
        ]
        let aliases = ["COSCO": "KE0GB-7"]
        let result = NetRomRelayPlan.plan(
            destination: "W9GM-7",
            teller: "SOLBPQ",
            routeLookup: { knowledge[$0.uppercased()] },
            aliasResolve: { aliases[$0.uppercased()] })
        XCTAssertEqual(result.chain, ["DRLNOD", "KB5YZB-7", "COSCO", "SOLBPQ"])
        XCTAssertEqual(result.linkTarget, "DRLNOD")
        XCTAssertEqual(result.destination, "W9GM-7")
    }

    // MARK: - Tables that point in circles

    func testASelfReferencingRouteIsNotAHop() {
        let result = plan("TARGET", teller: "LOOPY", using: ["LOOPY": "LOOPY"])
        XCTAssertEqual(result.linkTarget, "LOOPY")
        XCTAssertTrue(result.intermediateHops.isEmpty,
                      "a station that reaches itself is where the walk ends")
    }

    func testACycleTerminatesTheWalk() {
        let cycle = ["A": "B", "B": "A"]
        let result = plan("TARGET", teller: "A", using: cycle)
        XCTAssertEqual(result.chain, ["B", "A"],
                       "B is a real hop; going back to A would loop")
    }

    func testARouteThroughTheDestinationItselfIsNotChained() {
        // If the table claims the teller is reached via the destination
        // we are trying to get to, following it would be circular.
        let odd = ["KB5YZB-7": "COSCO"]
        let result = plan("COSCO", teller: "KB5YZB-7", using: odd)
        XCTAssertEqual(result.linkTarget, "KB5YZB-7")
        XCTAssertTrue(result.intermediateHops.isEmpty)
    }

    func testEmptyRouteEntryIsIgnored() {
        let result = plan("COSCO", teller: "KB5YZB-7", using: ["KB5YZB-7": ""])
        XCTAssertEqual(result.linkTarget, "KB5YZB-7")
        XCTAssertTrue(result.intermediateHops.isEmpty)
    }

    // MARK: - The ASHCHT case (field capture 2026-08-28)

    /// A teller that is a node *name* must be resolved to its callsign
    /// before the route table is consulted. ASHCHT's teller is COSCO; the
    /// route lives under KE0GB-7 (harvested, via KB5YZB-7), and KB5YZB-7
    /// itself is filed via DRLNOD. Without the resolution the walk ended
    /// at COSCO and the relay dialled a node it cannot hear.
    func testAnAliasTellerResolvesThroughItsCallsign() {
        let routes = ["KE0GB-7": "KB5YZB-7", "KB5YZB-7": "DRLNOD"]
        let aliases = ["COSCO": "KE0GB-7"]
        let result = NetRomRelayPlan.plan(
            destination: "ASHCHT",
            teller: "COSCO",
            routeLookup: { routes[$0.uppercased()] },
            aliasResolve: { aliases[$0.uppercased()] })
        XCTAssertEqual(result.chain, ["DRLNOD", "KB5YZB-7", "COSCO"],
                       "the by-hand chain: C KB5YZB-7 at DRLNOD, C COSCO at YZB, "
                       + "C ASHCHT at COSCO")
        XCTAssertEqual(result.linkTarget, "DRLNOD")
        XCTAssertEqual(result.destination, "ASHCHT")
    }

    /// The default resolver resolves nothing, so existing callers keep
    /// exactly the old behaviour.
    func testWithoutAResolverTheAliasEndsTheWalk() {
        let routes = ["KE0GB-7": "KB5YZB-7"]
        let result = NetRomRelayPlan.plan(
            destination: "ASHCHT",
            teller: "COSCO",
            routeLookup: { routes[$0.uppercased()] })
        XCTAssertEqual(result.chain, ["COSCO"])
    }

    // MARK: - Hearsay filtering (field capture 2026-08-28 18:28)

    /// The poisoning: COSCO's banner rode the L2 link from DRLNOD during a
    /// relayed session, the harvester credited DRLNOD with listing COSCO,
    /// and — being freshest — that claim shortened the next chain to
    /// DRLNOD→COSCO. DRLNOD is a KA-Node: it prints no node table, so a
    /// claim with it as teller is a mis-attribution and must be skipped in
    /// favour of the node that genuinely lists the station.
    func testAKaNodeTellerClaimIsMisattributionAndSkipped() {
        let claims: [(teller: String, claimedAt: Date)] = [
            (teller: "DRLNOD", claimedAt: Date()),
            (teller: "KB5YZB-7", claimedAt: Date(timeIntervalSinceNow: -3600))
        ]
        let picked = NetRomRelayPlan.tellerFallback(
            for: "COSCO", claims: claims,
            canRouteNetRom: { $0 == "DRLNOD" ? false : nil })
        XCTAssertEqual(picked, "KB5YZB-7")
    }

    /// The other lie the same mis-attribution produces: once the banner is
    /// credited to the node itself, "COSCO lists COSCO" is the freshest
    /// claim — following it would end the walk at a node we cannot hear.
    func testAStationsOwnClaimAboutItselfIsSkipped() {
        let claims: [(teller: String, claimedAt: Date)] = [
            (teller: "COSCO", claimedAt: Date()),
            (teller: "KB5YZB-7", claimedAt: Date(timeIntervalSinceNow: -3600))
        ]
        let picked = NetRomRelayPlan.tellerFallback(
            for: "COSCO", claims: claims, canRouteNetRom: { _ in nil })
        XCTAssertEqual(picked, "KB5YZB-7")
    }

    /// Unknown capability passes — most tellers are unclassified, and
    /// refusing to guess is the classifier's job, not the planner's.
    func testUnclassifiedTellersAreStillTrusted() {
        let claims: [(teller: String, claimedAt: Date)] = [
            (teller: "KB5YZB-7", claimedAt: Date())
        ]
        XCTAssertEqual(
            NetRomRelayPlan.tellerFallback(for: "COSCO", claims: claims,
                                           canRouteNetRom: { _ in nil }),
            "KB5YZB-7")
    }

    /// Every claim filtered means no hearsay to offer — nil, not a lie.
    func testAllClaimsFilteredYieldsNothing() {
        let claims: [(teller: String, claimedAt: Date)] = [
            (teller: "COSCO", claimedAt: Date()),
            (teller: "DRLNOD", claimedAt: Date())
        ]
        XCTAssertNil(NetRomRelayPlan.tellerFallback(
            for: "COSCO", claims: claims,
            canRouteNetRom: { $0 == "DRLNOD" ? false : nil }))
    }
}
