import XCTest
@testable import AXTerm

/// KD0SSP's beacon, verbatim off the air on 2026-08-27. It names two SSIDs
/// that have never transmitted and a tactical alias for the station itself,
/// and every one of those facts was being dropped somewhere between the
/// parser and the screen.
final class KD0SSPBeaconTests: XCTestCase {
    private let text = "Denver Water Amateur Radio Club (DWARC) — Digipeat Alias = DWARC; "
        + "Node:KD0SSP-7; PBBS:KD0SSP-1"

    private var declarations: [StationServiceParser.Declaration] {
        StationServiceParser.parse(text, source: "KD0SSP")
    }

    func testTheNodeSSIDIsRead() {
        XCTAssertTrue(declarations.contains { $0.callsign == "KD0SSP-7" && $0.service == .node })
    }

    func testThePBBSSSIDIsRead() {
        XCTAssertTrue(declarations.contains { $0.callsign == "KD0SSP-1" && $0.service == .bbs })
    }

    /// The equals form names the *sending* station, not one it mentions.
    func testTheDigipeatAliasBelongsToTheSender() {
        XCTAssertTrue(declarations.contains {
            $0.alias == "DWARC" && $0.callsign == "KD0SSP" && $0.service == .digipeater
        })
    }

    /// `Node:` and `PBBS:` read like table rows to an alias parser, and an
    /// alias is a global key — every station beaconing `Node:` would take
    /// the name in turn.
    func testNoFieldLabelBecomesAnAlias() {
        XCTAssertTrue(NodeAliasParser.parseNodeTable(text).isEmpty)
    }

    func testAnAliasWithoutTheWordDigipeatStillCounts() {
        let found = StationServiceParser.parse("Denver Radio League. Alias = DRL", source: "KE0NCQ")
        XCTAssertTrue(found.contains { $0.alias == "DRL" && $0.callsign == "KE0NCQ" })
    }

    /// Prose that merely contains the word is not a declaration.
    func testAliasWithoutAnEqualsIsNotRead() {
        let found = StationServiceParser.parse("No alias has been assigned yet", source: "KE0NCQ")
        XCTAssertTrue(found.isEmpty)
    }
}
