import XCTest
@testable import AXTerm

/// The directory can be pruned, not only grown: one claim, one entry, or
/// a whole node's presence — and everything removed is re-learned from
/// the next over-the-air announcement, because removal clears data, not
/// the willingness to listen.
@MainActor
final class NodeAliasRemovalTests: XCTestCase {

    private var store: NodeAliasStore!
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "alias-removal-tests")!
        defaults.removePersistentDomain(forName: "alias-removal-tests")
        store = NodeAliasStore(defaults: defaults)
        // DRLNOD:KE0NCQ is itself in the directory, and both of its
        // names have vouched for COSCO; SOLBPQ vouches independently.
        store.ingest(text: "KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N",
                     source: "KE0NCQ", at: now)
        store.recordClaim(station: "COSCO", teller: "DRLNOD", at: now)
        store.recordClaim(station: "COSCO", teller: "KE0NCQ", at: now)
        store.recordClaim(station: "COSCO", teller: "SOLBPQ", at: now)
        store.recordClaim(station: "INRMS", teller: "DRLNOD", at: now)
    }

    func testRemovingOneClaimLeavesTheEntryAndItsOtherTellers() async {
        store.removeClaim(teller: "DRLNOD", fromAlias: "COSCO")

        let cosco = store.directory.entry(for: "COSCO")
        XCTAssertNotNil(cosco, "the entry survives; only the claim goes")
        XCTAssertFalse(cosco!.reachableVia.contains("DRLNOD"))
        XCTAssertTrue(cosco!.reachableVia.contains("SOLBPQ"),
                      "other nodes' claims are untouched")
    }

    func testForgettingAnEntryRemovesItEntirely() async {
        store.removeEntry(alias: "COSCO")
        XCTAssertNil(store.directory.entry(for: "COSCO"))
    }

    func testRemovingANodeStripsBothOfItsNamesAndItsOwnRow() async {
        let removed = store.removeNode("DRLNOD")

        XCTAssertNil(store.directory.entry(for: "DRLNOD"),
                     "the node's own directory row goes with it")
        let cosco = store.directory.entry(for: "COSCO")
        XCTAssertFalse(cosco!.reachableVia.contains("DRLNOD"))
        XCTAssertFalse(cosco!.reachableVia.contains("KE0NCQ"),
                       "a node's claims under its callsign are the same "
                       + "node's claims")
        XCTAssertTrue(cosco!.reachableVia.contains("SOLBPQ"))
        XCTAssertTrue(store.directory.entries(reachableVia: "DRLNOD").isEmpty)
        XCTAssertEqual(removed.entries, 1)
        XCTAssertGreaterThanOrEqual(removed.claims, 3,
                                    "COSCO×2 names + INRMS at least")
    }

    func testARemovedNodeIsRelearnedFromTheNextAnnouncement() async {
        _ = store.removeNode("DRLNOD")
        store.ingest(text: "KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N", source: "KE0NCQ",
                     at: now.addingTimeInterval(60))
        store.recordClaim(station: "COSCO", teller: "DRLNOD",
                          at: now.addingTimeInterval(60))

        XCTAssertNotNil(store.directory.entry(for: "DRLNOD"))
        XCTAssertTrue(store.directory.entry(for: "COSCO")!
            .reachableVia.contains("DRLNOD"),
            "removal clears data, not the willingness to listen")
    }

    func testRemovalPersists() async {
        store.removeEntry(alias: "INRMS")
        let reloaded = NodeAliasStore(defaults: UserDefaults(suiteName: "alias-removal-tests")!)
        XCTAssertNil(reloaded.directory.entry(for: "INRMS"))
    }
}
