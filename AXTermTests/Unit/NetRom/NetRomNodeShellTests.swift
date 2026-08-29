import XCTest
@testable import AXTerm

/// The node level a NET/ROM circuit caller lands in: honest AXTerm
/// identity, the conventional prompt grammar, and answers other
/// stations' tools can read — pinned by feeding our own ROUTES output
/// to our own scraper.
final class NetRomNodeShellTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func makeShell() -> NetRomNodeShell {
        NetRomNodeShell(nodeAlias: "EPINOD", nodeCall: "K0EPI-7",
                        version: "AXTerm 1.0", caller: "W0ARP-1")
    }

    private var snapshot: NetRomNodeShell.Snapshot {
        NetRomNodeShell.Snapshot(
            routes: [.init(destination: "KE0GB-7", alias: "COSCO",
                           nextHop: "KB5YZB-7", quality: 192)],
            neighbors: [.init(callsign: "KB5YZB-7", quality: 192, count: 42),
                        .init(callsign: "KE0NCQ", quality: 84, count: 7)],
            heard: [.init(callsign: "KD0SSP", lastHeard: now.addingTimeInterval(-60))],
            stationInfo: "IC-7100 into a discone at 25 ft.",
            bbsAvailable: true)
    }

    func testTheGreetingIsHonestAXTermInConventionalGrammar() {
        let out = makeShell().greeting()
        XCTAssertTrue(out.lines.first?.contains("AXTerm") == true,
                      "identity honesty: the banner names what we are — a "
                      + "BPQ costume would poison other stations' fingerprints")
        XCTAssertTrue(out.lines.first?.contains("EPINOD:K0EPI-7") == true)
        XCTAssertEqual(out.prompt, "EPINOD:K0EPI-7} ",
                       "the prompt grammar every operator and scraper knows — "
                       + "and the node capability it signals is now real")
    }

    func testOurRoutesOutputFeedsOurOwnScraper() {
        var shell = makeShell()
        let out = shell.handle(line: "ROUTES", snapshot: snapshot, now: now)
        var scraper = BpqRoutesScraper()
        var rows: [BpqRoutesScraper.HarvestedLink] = []
        for line in out.lines {
            if let row = scraper.ingest(line: line, peer: "EPINOD", at: now) {
                rows.append(row)
            }
        }
        XCTAssertEqual(rows.map(\.neighbor), ["KB5YZB-7", "KE0NCQ"],
                       "another AXTerm connecting here can harvest our table "
                       + "with the same scraper we point at BPQ")
        XCTAssertEqual(rows.first?.quality, 192)
    }

    func testNodesListsAliasColonCallPairs() {
        var shell = makeShell()
        let out = shell.handle(line: "NODES", snapshot: snapshot, now: now)
        XCTAssertTrue(out.lines.contains { $0.contains("COSCO:KE0GB-7") })
    }

    func testHeardAnswersInEveryDialect() {
        for verb in ["MH", "J", "MHEARD", "JHEARD"] {
            var shell = makeShell()
            let out = shell.handle(line: verb, snapshot: snapshot, now: now)
            XCTAssertTrue(out.lines.contains { $0.contains("KD0SSP") },
                          "\(verb) should answer the heard list")
        }
    }

    func testConnectEmitsTheOnwardEffect() {
        var shell = makeShell()
        let out = shell.handle(line: "C cosco", snapshot: snapshot, now: now)
        XCTAssertEqual(out.effects, [.connectOnward("COSCO")])
        XCTAssertTrue(out.lines.contains { $0.contains("Trying COSCO") })
        XCTAssertNil(out.prompt, "no prompt while the node is dialing")
    }

    func testConnectRefusesItselfAndTeachesUsage() {
        var shell = makeShell()
        let selfTry = shell.handle(line: "C EPINOD", snapshot: snapshot, now: now)
        XCTAssertTrue(selfTry.effects.isEmpty)
        XCTAssertTrue(selfTry.lines.contains { $0.contains("this node") })

        var shell2 = makeShell()
        let bare = shell2.handle(line: "C", snapshot: snapshot, now: now)
        XCTAssertTrue(bare.effects.isEmpty)
        XCTAssertTrue(bare.lines.contains { $0.contains("C <call") })
    }

    func testBBSHandsOffAndByeDisconnects() {
        var shell = makeShell()
        let bbs = shell.handle(line: "BBS", snapshot: snapshot, now: now)
        XCTAssertEqual(bbs.effects, [.enterBBS])

        var shell2 = makeShell()
        let bye = shell2.handle(line: "B", snapshot: snapshot, now: now)
        XCTAssertEqual(bye.effects, [.disconnect])
        XCTAssertNil(bye.prompt, "no prompt after goodbye")
    }

    func testBBSWhenMailboxIsOffSaysSo() {
        var shell = makeShell()
        var quiet = snapshot
        quiet.bbsAvailable = false
        let out = shell.handle(line: "BBS", snapshot: quiet, now: now)
        XCTAssertTrue(out.effects.isEmpty)
        XCTAssertTrue(out.lines.joined().lowercased().contains("not on the air"))
    }

    func testUnknownCommandTeachesTheMenu() {
        var shell = makeShell()
        let out = shell.handle(line: "XYZZY", snapshot: snapshot, now: now)
        XCTAssertTrue(out.lines.first?.hasPrefix("?") == true)
        XCTAssertTrue(out.lines.joined().contains("NODES"))
    }
}

/// Who gets in: a pure gate between the endpoint's acceptor hook and
/// the operator's setting.
final class NetRomInboundPolicyTests: XCTestCase {

    func testDisabledRefusesEveryone() {
        XCTAssertFalse(NetRomInboundPolicy.shouldAccept(
            enabled: false, activeCallers: 0))
    }

    func testEnabledAcceptsUpToTheCap() {
        XCTAssertTrue(NetRomInboundPolicy.shouldAccept(
            enabled: true, activeCallers: 0))
        XCTAssertTrue(NetRomInboundPolicy.shouldAccept(
            enabled: true, activeCallers: NetRomInboundPolicy.maxCallers - 1))
        XCTAssertFalse(NetRomInboundPolicy.shouldAccept(
            enabled: true, activeCallers: NetRomInboundPolicy.maxCallers),
            "circuits multiplex, but a shared channel is not infinite")
    }
}
