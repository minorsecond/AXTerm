import XCTest
@testable import AXTerm

/// Every payload here is verbatim from this receiver's own stored
/// packets on 2026-08-24.
final class NodeAliasParserTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Service-list form

    /// The one that matters: DRLNOD appears throughout this operator's
    /// via paths and resolves to KE0NCQ, which the directory can place.
    func testResolvesDRLNODToItsOperator() {
        let found = NodeAliasParser.parse(
            "KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N", source: "KE0NCQ")
        XCTAssertEqual(found.first { $0.alias == "DRLNOD" }?.callsign, "KE0NCQ")
        XCTAssertEqual(found.first { $0.alias == "DRLNOD" }?.service, "N")
        // Its BBS and digipeater aliases resolve to the same station.
        XCTAssertEqual(Set(found.map(\.alias)), ["DRL", "DRLBBS", "DRLNOD"])
    }

    func testResolvesTheOtherAliasesInUse() {
        XCTAssertEqual(
            NodeAliasParser.parse("W1VAN/R W1VAN-7/D HORSE/N", source: "W1VAN")
                .first { $0.alias == "HORSE" }?.callsign, "W1VAN")
        XCTAssertEqual(
            NodeAliasParser.parse("W2CRS/R W2CRS-7/D W2CRS-1/B EATON/N", source: "W2CRS")
                .first { $0.alias == "EATON" }?.callsign, "W2CRS")
    }

    /// `KB5YZB-1/B` is an SSID of the same licence, not a tactical
    /// alias. Recording it would make a callsign resolve to itself.
    func testSSIDsAreNotTreatedAsAliases() {
        let found = NodeAliasParser.parse(
            "KB5YZB/R YZBBPQ/D KB5YZB-1/B KB5YZB-7/N", source: "KB5YZB")
        XCTAssertEqual(found.map(\.alias), ["YZBBPQ"])
    }

    /// A station announcing only its own SSIDs contributes no aliases.
    func testAllSSIDBeaconYieldsNothing() {
        let found = NodeAliasParser.parse(
            "AB0VZ/R AB0VZ-3/G AB0VZ-1/B AB0VZ-7/N", source: "AB0VZ")
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - NODE: form

    /// BPQ names the callsign directly, so this form does not depend on
    /// who transmitted the frame.
    func testNodeFormNamesTheCallsignDirectly() {
        let found = NodeAliasParser.parse(
            "NODE: YZBBPQ:KB5YZB-7, Aurora, CO Area BPQ Packet Node ",
            source: "SOMEONE-ELSE")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].alias, "YZBBPQ")
        XCTAssertEqual(found[0].callsign, "KB5YZB-7")
    }

    // MARK: - Rejection

    /// Ordinary beacon prose must not become a directory of nonsense.
    func testProseYieldsNoAliases() {
        for text in [
            "Colorado Traffic Net BBS & RMS.  Connect to K0NTS-1 & K0NTS-10",
            "Denver Water Amateur Radio Club (DWARC) - Digipeater",
            "==== ==== ==== PATH TO WH6ANH-1 ==== ==== ====C N0HI-7    C 3 WH6ANH-1 V DRL   ENJOY HOBBY",
            "",
        ] {
            XCTAssertTrue(NodeAliasParser.parse(text, source: "N0CALL").isEmpty, text)
        }
    }

    /// A six-character field is the only reliable filter — anything
    /// longer is prose that happened to contain a slash.
    func testAliasLengthIsBounded() {
        XCTAssertTrue(NodeAliasParser.isPlausibleAlias("DRLNOD"))
        XCTAssertTrue(NodeAliasParser.isPlausibleAlias("HORSE"))
        XCTAssertFalse(NodeAliasParser.isPlausibleAlias("A"))
        XCTAssertFalse(NodeAliasParser.isPlausibleAlias("TOOLONGNAME"))
        XCTAssertFalse(NodeAliasParser.isPlausibleAlias("HAS SPACE"))
    }

    func testUnknownSourceYieldsNothing() {
        XCTAssertTrue(NodeAliasParser.parse("DRLNOD/N", source: "").isEmpty)
    }

    // MARK: - Directory

    func testDirectoryResolvesAndCountsRepeatedEvidence() {
        var directory = NodeAliasDirectory()
        let announcement = NodeAliasParser.Announcement(
            alias: "DRLNOD", callsign: "KE0NCQ", service: "N")
        directory.record(announcement, at: now)
        directory.record(announcement, at: now.addingTimeInterval(600))

        XCTAssertEqual(directory.callsign(for: "drlnod"), "KE0NCQ")
        XCTAssertEqual(directory.entry(for: "DRLNOD")?.announcements, 2)
    }

    /// A node can be renamed or a callsign reassigned, so the most
    /// recent claim is current — and the evidence count resets, because
    /// it is now a different claim.
    func testANewClaimReplacesTheOldOne() {
        var directory = NodeAliasDirectory()
        directory.record(.init(alias: "DRLNOD", callsign: "KE0NCQ", service: "N"), at: now)
        directory.record(.init(alias: "DRLNOD", callsign: "W0NEW", service: "N"),
                         at: now.addingTimeInterval(86_400))
        XCTAssertEqual(directory.callsign(for: "DRLNOD"), "W0NEW")
        XCTAssertEqual(directory.entry(for: "DRLNOD")?.announcements, 1)
    }

    func testUnknownAliasResolvesToNothing() {
        XCTAssertNil(NodeAliasDirectory().callsign(for: "NOSUCH"))
    }
}
