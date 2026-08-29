import XCTest
@testable import AXTerm

/// Reading a node's own nodes table out of a session the operator had.
///
/// One `N` to one node names its whole view of the network. Beacons name one
/// station at a time and only when they happen to transmit, so this is the
/// highest-yield alias source there is — which is exactly why it has to be
/// careful about what it accepts.
final class NodeAliasTableTests: XCTestCase {

    private func table(_ text: String) -> [NodeAliasParser.Announcement] {
        NodeAliasParser.parseNodeTable(text)
    }

    func testATableOfPairs() {
        let found = table("DRLNOD:KE0NCQ-2  EVANS:KC0LDY-10  HORSE:KN6VV-1")
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found[0].alias, "DRLNOD")
        XCTAssertEqual(found[0].callsign, "KE0NCQ-2")
        XCTAssertEqual(found[2].alias, "HORSE")
        XCTAssertEqual(found[2].callsign, "KN6VV-1")
    }

    func testPairsSpanLines() {
        XCTAssertEqual(table("DRLNOD:KE0NCQ-2\nEVANS:KC0LDY-10").count, 2)
    }

    /// BPQ's prompt is the pair the other way round. A parser that trusted the
    /// order would record every node's prompt as an alias pointing at the
    /// wrong station.
    func testWhichHalfIsTheCallsignIsDecidedByShapeNotPosition() {
        let found = table("K0EPI-7:DRLNOD}")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].alias, "DRLNOD")
        XCTAssertEqual(found[0].callsign, "K0EPI-7")
    }

    /// Two callsigns means we cannot tell which is which, and guessing would
    /// make a callsign resolve to another callsign.
    func testAmbiguousPairsAreSkipped() {
        XCTAssertTrue(table("K0EPI-7:KB5YZB-1").isEmpty)
    }

    func testNonPairsAreIgnored() {
        XCTAssertTrue(table("Nodes: 14 known").isEmpty)
        XCTAssertTrue(table("see http://example.com for details").isEmpty)
        XCTAssertTrue(table("14:18:29").isEmpty)
    }

    func testTheSameAliasTwiceIsOneAnnouncement() {
        XCTAssertEqual(table("DRLNOD:KE0NCQ-2 DRLNOD:KE0NCQ-2").count, 1)
    }

    /// An alias travels in a six-character field; anything longer is prose
    /// that happened to contain a colon.
    func testOverlongNamesAreNotAliases() {
        XCTAssertTrue(table("SOMETHINGLONG:KE0NCQ-2").isEmpty)
    }

    /// `parse` still prefers the single-station forms it already handled.
    func testTableParsingDoesNotDisturbBeaconForms() {
        let beacon = NodeAliasParser.parse("NODE: DRLNOD:KE0NCQ, Denver", source: "KE0NCQ")
        XCTAssertEqual(beacon.count, 1)
        XCTAssertEqual(beacon[0].alias, "DRLNOD")

        let services = NodeAliasParser.parse("KE0NCQ DRLNOD/N DRLBBS/B", source: "KE0NCQ")
        XCTAssertEqual(Set(services.map(\.alias)), ["DRLNOD", "DRLBBS"])
    }

    // MARK: - The real thing, off the air

    /// KB5YZB-7's `NODES` reply, captured verbatim through the DRLNOD circuit
    /// on 2026-08-27 at 20:14:34–20:14:59. Reading a parser is not the same as
    /// feeding it what a node actually sends, so this is the bytes as they
    /// arrived: a banner line ending `}`, a bare callsign with no alias, and
    /// alias:callsign pairs padded out into columns.
    func testKB5YZB7NodesReplyIsParsed() {
        let capture = """
        YZBBPQ:KB5YZB-7} Nodes
        KE0GB-1             2RZBPQ:VK2RZ-7      5EBBS:AE5E-3        AGCHAT:K1AJD-5
        AGNODE:K1AJD-4      ARAPEY:CX2SA-7      ARECS:N2NOV-7       ARPBBS:W0ARP-1
        RMS:WW4BSA-10       BWTDX:F4BWT-3       DATBBS:K5DAT-1      DAYBBS:NC8Q
        """
        let found = NodeAliasParser.parse(capture, source: "KB5YZB-7")
        let byAlias = Dictionary(found.map { ($0.alias, $0.callsign) }) { a, _ in a }
        let dump = byAlias.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")

        XCTAssertEqual(byAlias["AGNODE"], "K1AJD-4", dump)
        XCTAssertEqual(byAlias["ARAPEY"], "CX2SA-7", dump)
        XCTAssertEqual(byAlias["DATBBS"], "K5DAT-1", dump)
        XCTAssertEqual(byAlias["DAYBBS"], "NC8Q", dump)
        XCTAssertEqual(byAlias["2RZBPQ"], "VK2RZ-7", dump)

        // The banner names the node itself, which is a true alias fact and
        // worth keeping — my first draft of this test assumed otherwise.
        XCTAssertEqual(byAlias["YZBBPQ"], "KB5YZB-7", dump)
        XCTAssertFalse(found.contains { $0.callsign == "KE0GB-1" },
                       "a bare callsign with no alias teaches nothing about aliases")
    }

    // MARK: - Attribution

    /// An alias is hearsay until you know who published it: `AGNODE` came out
    /// of KB5YZB-7's node table, not from K1AJD-4 itself. The directory page
    /// shows that line, so the directory has to carry it.
    func testTheTellingStationIsRecorded() {
        var directory = NodeAliasDirectory()
        let now = Date()
        directory.record(.init(alias: "AGNODE", callsign: "K1AJD-4", service: "N"),
                         at: now, from: "kb5yzb-7")

        let entry = directory.entry(for: "agnode")
        XCTAssertEqual(entry?.callsign, "K1AJD-4")
        XCTAssertEqual(entry?.learnedFrom, "KB5YZB-7", "normalised, like every other callsign")
    }

    /// Re-hearing the same claim without a named source keeps the attribution
    /// already on file rather than blanking it.
    func testAnUnattributedRepeatKeepsTheKnownSource() {
        var directory = NodeAliasDirectory()
        let now = Date()
        directory.record(.init(alias: "AGNODE", callsign: "K1AJD-4", service: "N"),
                         at: now, from: "KB5YZB-7")
        directory.record(.init(alias: "AGNODE", callsign: "K1AJD-4", service: "N"),
                         at: now.addingTimeInterval(60))

        let entry = directory.entry(for: "AGNODE")
        XCTAssertEqual(entry?.learnedFrom, "KB5YZB-7")
        XCTAssertEqual(entry?.announcements, 2, "the repeat still counts as corroboration")
    }

    /// Entries stored before attribution existed must keep decoding — there are
    /// 179 of them on the operator's machine.
    func testEntriesWithoutASourceStillDecode() throws {
        let legacy = """
        {"alias":"DRLNOD","callsign":"KE0NCQ","service":"N",
         "heardAt":768000000,"announcements":3}
        """
        let entry = try JSONDecoder().decode(
            NodeAliasDirectory.Entry.self, from: Data(legacy.utf8))
        XCTAssertEqual(entry.alias, "DRLNOD")
        XCTAssertNil(entry.learnedFrom)
        XCTAssertTrue(entry.tellers.isEmpty, "no teller means no way in")
    }

    // MARK: - Callsign → alias

    private func directoryFromNodeList() -> NodeAliasDirectory {
        var directory = NodeAliasDirectory()
        let now = Date()
        // A single announcement carrying the shapes that actually appear on air.
        for announcement in NodeAliasParser.parseNodeTable(
            "SOLBPQ:N0HI-7       DRLNOD:KE0NCQ-7     DRLBBS:KE0NCQ-1     YZBBPQ:KB5YZB-7") {
            directory.record(announcement, at: now, from: "KB5YZB-7")
        }
        return directory
    }

    func testCallsignResolvesToItsAlias() {
        let directory = directoryFromNodeList()
        XCTAssertEqual(directory.preferredAlias(for: "N0HI-7"), "SOLBPQ")
    }

    /// Lookup is case- and whitespace-insensitive because callers hand it
    /// whatever the wire or a text field gave them.
    func testLookupToleratesCasingAndPadding() {
        let directory = directoryFromNodeList()
        XCTAssertEqual(directory.preferredAlias(for: "  n0hi-7 "), "SOLBPQ")
    }

    /// The SSID is the distinction, not noise. KE0NCQ runs a node on -7 and a
    /// BBS on -1 and names them differently; asking about one must not return
    /// the other.
    func testSSIDsAreDistinctStations() {
        let directory = directoryFromNodeList()
        XCTAssertEqual(directory.preferredAlias(for: "KE0NCQ-7"), "DRLNOD")
        XCTAssertEqual(directory.preferredAlias(for: "KE0NCQ-1"), "DRLBBS")
        XCTAssertNil(directory.preferredAlias(for: "KE0NCQ"),
                     "the bare licence was never announced under a name")
    }

    /// A station that runs several services names each one. KE0NCQ is the only
    /// such case in the operator's 193 stored aliases, and it is real: a BBS, a
    /// digipeater and a node on one licence. All three come back, node first —
    /// that is the name that turns up in via paths and connect targets.
    func testAllServiceNamesComeBackNodeFirst() {
        var directory = NodeAliasDirectory()
        let now = Date()
        for announcement in NodeAliasParser.parse("DRLBBS/B DRL/D DRLNOD/N",
                                                  source: "KE0NCQ-7") {
            directory.record(announcement, at: now, from: "KB5YZB-7")
        }
        let names = directory.aliases(for: "KE0NCQ").map(\.alias)
        XCTAssertEqual(names, ["DRLNOD", "DRL", "DRLBBS"],
                       "node first, then alphabetical for a stable order")
        XCTAssertEqual(directory.preferredAlias(for: "KE0NCQ"), "DRLNOD")
    }

    func testUnknownCallsignHasNoAlias() {
        let directory = directoryFromNodeList()
        XCTAssertTrue(directory.aliases(for: "W0ARP-10").isEmpty)
        XCTAssertNil(directory.preferredAlias(for: ""))
    }

    // MARK: - The other name, whichever one the caller holds

    /// A sidebar row keyed by the alias wants the licence; a row keyed by the
    /// callsign wants the alias. One question, asked from both directions.
    func testOtherNameWorksBothWays() {
        let directory = directoryFromNodeList()
        XCTAssertEqual(directory.otherName(for: "SOLBPQ"), "N0HI-7")
        XCTAssertEqual(directory.otherName(for: "N0HI-7"), "SOLBPQ")
    }

    func testOtherNameIsNilWhenNothingIsKnown() {
        let directory = directoryFromNodeList()
        XCTAssertNil(directory.otherName(for: "W0ARP-10"))
        XCTAssertNil(directory.otherName(for: "   "))
    }

    /// A station that somehow announced its own callsign as its alias has no
    /// second name, and repeating the first one would be noise on every row.
    func testOtherNameNeverEchoesTheNameGiven() {
        var directory = NodeAliasDirectory()
        directory.record(
            NodeAliasParser.Announcement(alias: "K0ZIA", callsign: "K0ZIA", service: "N"),
            at: Date(), from: "KB5YZB-7")
        XCTAssertNil(directory.otherName(for: "K0ZIA"))
    }

    /// The batch form must agree with the single-lookup form, or a list and a
    /// detail view would disagree about the same station.
    func testBatchOtherNamesAgreesWithSingleLookup() {
        let directory = directoryFromNodeList()
        let batch = directory.otherNames()
        for name in ["SOLBPQ", "N0HI-7", "DRLNOD", "KE0NCQ-7", "YZBBPQ", "KB5YZB-7"] {
            XCTAssertEqual(batch[name], directory.otherName(for: name), name)
        }
        XCTAssertNil(batch["W0ARP-10"])
    }

    /// And it keeps the same node-first preference for a multi-service station.
    func testBatchKeepsTheNodeName() {
        var directory = NodeAliasDirectory()
        for announcement in NodeAliasParser.parse("DRLBBS/B DRL/D DRLNOD/N",
                                                  source: "KE0NCQ-7") {
            directory.record(announcement, at: Date(), from: "KB5YZB-7")
        }
        XCTAssertEqual(directory.otherNames()["KE0NCQ"], "DRLNOD")
    }

    // MARK: - Replays are not evidence

    /// The bug behind "heard ×1708": stored beacons are re-swept whenever the
    /// operator opens Packets, Map or Nodes, and every sweep re-counted every
    /// beacon still in retention. The number measured page visits.
    func testResweepingTheSameFrameDoesNotCountTwice() {
        var directory = NodeAliasDirectory()
        let heard = Date()
        let announcement = NodeAliasParser.Announcement(
            alias: "DRLNOD", callsign: "KE0NCQ", service: "N")

        for _ in 0..<50 {
            directory.record(announcement, at: heard, from: "KE0NCQ")
        }
        XCTAssertEqual(directory.entry(for: "DRLNOD")?.announcements, 1,
                       "one frame, however many times it is read")
    }

    /// A genuinely later beacon is genuinely more evidence.
    func testALaterAnnouncementStillCounts() {
        var directory = NodeAliasDirectory()
        let first = Date()
        let announcement = NodeAliasParser.Announcement(
            alias: "DRLNOD", callsign: "KE0NCQ", service: "N")

        directory.record(announcement, at: first, from: "KE0NCQ")
        directory.record(announcement, at: first.addingTimeInterval(600), from: "KE0NCQ")
        let entry = directory.entry(for: "DRLNOD")
        XCTAssertEqual(entry?.announcements, 2)
        XCTAssertEqual(entry?.heardAt, first.addingTimeInterval(600))
    }

    /// An older frame arriving late must not drag the timestamp backwards —
    /// "Recently heard" would sort on when a sweep happened to reach it.
    func testAnOlderFrameDoesNotRewindLastHeard() {
        var directory = NodeAliasDirectory()
        let now = Date()
        let announcement = NodeAliasParser.Announcement(
            alias: "DRLNOD", callsign: "KE0NCQ", service: "N")

        directory.record(announcement, at: now, from: "KE0NCQ")
        directory.record(announcement, at: now.addingTimeInterval(-3600), from: "KE0NCQ")
        XCTAssertEqual(directory.entry(for: "DRLNOD")?.heardAt, now)
        XCTAssertEqual(directory.entry(for: "DRLNOD")?.announcements, 1)
    }

    /// Learning who told us is new information even when the claim is not, so
    /// a replay of an old frame still fills in a source that was never
    /// recorded. This is what heals the entries reading "source not recorded".
    func testAReplayStillBackfillsAMissingSource() {
        var directory = NodeAliasDirectory()
        let heard = Date()
        let announcement = NodeAliasParser.Announcement(
            alias: "AMJBBS", callsign: "VA3AMJ", service: "N")

        directory.record(announcement, at: heard)
        XCTAssertNil(directory.entry(for: "AMJBBS")?.learnedFrom)

        directory.record(announcement, at: heard, from: "KB5YZB-7")
        let entry = directory.entry(for: "AMJBBS")
        XCTAssertEqual(entry?.learnedFrom, "KB5YZB-7")
        XCTAssertEqual(entry?.announcements, 1, "attribution is not corroboration")
    }

    /// A station that changes what it claims is believed, but only forwards.
    func testAChangedClaimAtAnOlderTimeIsIgnored() {
        var directory = NodeAliasDirectory()
        let now = Date()
        directory.record(
            NodeAliasParser.Announcement(alias: "HORSE", callsign: "W1VAN", service: "N"),
            at: now, from: "W1VAN")
        directory.record(
            NodeAliasParser.Announcement(alias: "HORSE", callsign: "KN6VV-1", service: "N"),
            at: now.addingTimeInterval(-60), from: "KB5YZB-7")
        XCTAssertEqual(directory.entry(for: "HORSE")?.callsign, "W1VAN",
                       "a stale frame does not overwrite a fresher claim")
    }

    // MARK: - Who can reach it

    /// Two nodes listing the same station are two routes. Keeping only the
    /// latest threw one away, and the field exists to answer "where do I
    /// connect".
    func testEveryTellerIsKept() {
        var directory = NodeAliasDirectory()
        let now = Date()
        let announcement = NodeAliasParser.Announcement(
            alias: "AGCHAT", callsign: "K1AJD-5", service: "N")

        directory.record(announcement, at: now, from: "KB5YZB-7")
        directory.record(announcement, at: now.addingTimeInterval(60), from: "DRLNOD")

        let entry = directory.entry(for: "AGCHAT")
        XCTAssertEqual(Set(entry?.tellers.keys ?? [:].keys), ["KB5YZB-7", "DRLNOD"])
        XCTAssertEqual(entry?.reachableVia, ["DRLNOD", "KB5YZB-7"],
                       "freshest claim first — that is the one to try")
        XCTAssertEqual(entry?.learnedFrom, "DRLNOD")
    }

    /// A replayed frame is not new evidence for the claim, but a teller we did
    /// not know about is a route we did not know about.
    func testAReplayStillAddsANewTeller() {
        var directory = NodeAliasDirectory()
        let now = Date()
        let announcement = NodeAliasParser.Announcement(
            alias: "AGCHAT", callsign: "K1AJD-5", service: "N")

        directory.record(announcement, at: now, from: "KB5YZB-7")
        directory.record(announcement, at: now.addingTimeInterval(-30), from: "DRLNOD")

        let entry = directory.entry(for: "AGCHAT")
        XCTAssertEqual(entry?.announcements, 1, "still one announcement")
        XCTAssertEqual(entry?.heardAt, now, "and the older frame does not rewind it")
        XCTAssertEqual(Set(entry?.tellers.keys ?? [:].keys), ["KB5YZB-7", "DRLNOD"],
                       "but both nodes can reach it")
    }

    /// A node listing itself is not a route to itself.
    func testAStationIsNotItsOwnTeller() {
        var directory = NodeAliasDirectory()
        directory.record(
            NodeAliasParser.Announcement(alias: "DRLNOD", callsign: "KE0NCQ", service: "N"),
            at: Date(), from: "KE0NCQ")
        XCTAssertTrue(directory.entry(for: "DRLNOD")?.tellers.isEmpty ?? false)
    }

    /// When a station changes which callsign it claims, what the old tellers
    /// said was about the old claim and does not carry over.
    func testAChangedClaimDropsTheOldRoutes() {
        var directory = NodeAliasDirectory()
        let now = Date()
        directory.record(
            NodeAliasParser.Announcement(alias: "HORSE", callsign: "W1VAN", service: "N"),
            at: now, from: "KB5YZB-7")
        directory.record(
            NodeAliasParser.Announcement(alias: "HORSE", callsign: "KN6VV-1", service: "N"),
            at: now.addingTimeInterval(60), from: "DRLNOD")

        let entry = directory.entry(for: "HORSE")
        XCTAssertEqual(entry?.callsign, "KN6VV-1")
        XCTAssertEqual(Set(entry?.tellers.keys ?? [:].keys), ["DRLNOD"])
    }

    /// Storage written before tellers existed migrates its single name in,
    /// dated by the only timestamp available.
    func testLegacySourceMigratesToATeller() throws {
        let legacy = """
        {"alias":"AGNODE","callsign":"K1AJD-4","service":"N",
         "heardAt":768000000,"announcements":3,"learnedFrom":"KB5YZB-7"}
        """
        let entry = try JSONDecoder().decode(
            NodeAliasDirectory.Entry.self, from: Data(legacy.utf8))
        XCTAssertEqual(entry.reachableVia, ["KB5YZB-7"])
        XCTAssertEqual(entry.tellers["KB5YZB-7"], entry.heardAt)
    }

    /// And a round trip through the new encoding keeps every route.
    func testTellersSurviveARoundTrip() throws {
        var directory = NodeAliasDirectory()
        let now = Date()
        let announcement = NodeAliasParser.Announcement(
            alias: "AGCHAT", callsign: "K1AJD-5", service: "N")
        directory.record(announcement, at: now, from: "KB5YZB-7")
        directory.record(announcement, at: now.addingTimeInterval(60), from: "DRLNOD")

        let data = try JSONEncoder().encode(directory.entries)
        let decoded = try JSONDecoder().decode(
            [String: NodeAliasDirectory.Entry].self, from: data)
        XCTAssertEqual(decoded["AGCHAT"]?.reachableVia, ["DRLNOD", "KB5YZB-7"])
    }

    // MARK: - What may be forgotten

    private func mixedDirectory() -> NodeAliasDirectory {
        var directory = NodeAliasDirectory()
        let now = Date()
        // Routable: a node offered a way in.
        directory.record(
            NodeAliasParser.Announcement(alias: "AGCHAT", callsign: "K1AJD-5", service: "N"),
            at: now, from: "KB5YZB-7")
        // No route, but names a station this operator hears.
        directory.record(
            NodeAliasParser.Announcement(alias: "EATON", callsign: "W2CRS", service: "N"),
            at: now)
        // No route, names a station nothing here has ever seen.
        directory.record(
            NodeAliasParser.Announcement(alias: "XTCNOD", callsign: "PU2XTC-4", service: "N"),
            at: now)
        return directory
    }

    /// Only the row that is both unroutable and unreferenced goes.
    func testForgettableNeedsBothConditions() {
        let doomed = mixedDirectory().forgettable(knownCallsigns: ["W2CRS-7", "K1AJD-5"])
        XCTAssertEqual(doomed.map(\.alias), ["XTCNOD"])
    }

    /// A routable entry is never forgettable, however remote — BPQ links over
    /// AXIP, so "never heard here" says nothing about whether it is reachable.
    func testARoutableEntryIsKeptEvenIfNeverHeard() {
        var directory = NodeAliasDirectory()
        directory.record(
            NodeAliasParser.Announcement(alias: "XTCNOD", callsign: "PU2XTC-4", service: "N"),
            at: Date(), from: "KB5YZB-7")
        XCTAssertTrue(directory.forgettable(knownCallsigns: []).isEmpty)
    }

    /// Hearing one SSID is reason enough to keep a name for another: they are
    /// the same licence, and the operator plainly deals with that station.
    func testKnowingOneSSIDKeepsTheOthers() {
        var directory = NodeAliasDirectory()
        directory.record(
            NodeAliasParser.Announcement(alias: "SOLBBS", callsign: "N0HI-1", service: "N"),
            at: Date())
        XCTAssertTrue(directory.forgettable(knownCallsigns: ["N0HI-7"]).isEmpty)
    }

    /// And forgetting removes exactly those, leaving everything else intact.
    @MainActor
    func testForgetRemovesOnlyTheDoomed() async {
        let store = NodeAliasStore(defaults: isolatedDefaults())
        for entry in mixedDirectory().allEntries {
            store.ingest(text: "\(entry.alias):\(entry.callsign)",
                         source: entry.learnedFrom ?? "",
                         at: entry.heardAt)
        }
        let removed = store.forget(knownCallsigns: ["W2CRS", "K1AJD-5"])
        XCTAssertEqual(removed, 1)
        XCTAssertNotNil(store.directory.entry(for: "EATON"))
        XCTAssertNil(store.directory.entry(for: "XTCNOD"))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "NodeAliasTableTests.\(UUID().uuidString)")!
        return suite
    }

    // MARK: - Claims recorded directly (scraped rows, made hops)

    /// SOLBPQ's ROUTES table, scraped three hops out (2026-08-28 18:52),
    /// could not become router routes — but "SOLBPQ lists W9GM-7" is a
    /// reachability edge the relay planner walks, recorded as a claim.
    @MainActor
    func testARecordedClaimIsWalkableHearsay() async {
        let store = NodeAliasStore(defaults: isolatedDefaults())
        store.recordClaim(station: "W9GM-7", teller: "SOLBPQ")
        XCTAssertEqual(store.directory.tellerClaims(for: "W9GM-7").first?.teller, "SOLBPQ")
    }

    /// Recording a claim about a station whose alias→callsign mapping is
    /// already known must not clobber it: a made hop says "COSCO connected
    /// us to SOLBPQ", not "SOLBPQ's callsign is SOLBPQ".
    @MainActor
    func testARecordedClaimPreservesTheKnownCallsign() async {
        let store = NodeAliasStore(defaults: isolatedDefaults())
        store.ingest(text: "SOLBPQ:N0HI-7", source: "COSCO",
                     at: Date(timeIntervalSinceNow: -3600))
        store.recordClaim(station: "SOLBPQ", teller: "COSCO")
        XCTAssertEqual(store.directory.callsign(for: "SOLBPQ"), "N0HI-7")
        XCTAssertEqual(store.directory.tellerClaims(for: "SOLBPQ").first?.teller, "COSCO")
    }

    // MARK: - A node's table is not a claim about what each station is

    /// The table lists what the network can reach — BBSes, chat servers, RMS
    /// gateways — and never says which is which. Stamping every row `N` made a
    /// BBS report itself a NET/ROM node.
    func testNodeTableEntriesClaimNoService() {
        let found = NodeAliasParser.parseNodeTable(
            "BVJBBS:KA3BVJ-3     BVJCHT:KA3BVJ-11    BVJNOD:KA3BVJ-2")
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { $0.service.isEmpty },
                      "nothing in a node table states a service")
    }

    /// A station's own identification does state one, and that survives.
    func testAStationsOwnIDStillDeclaresItsServices() {
        let found = NodeAliasParser.parse("DRLBBS/B DRL/D DRLNOD/N", source: "KE0NCQ-7")
        XCTAssertEqual(Set(found.map(\.service)), ["B", "D", "N"])
    }

    /// Legacy storage recorded the announcing station as the source even when
    /// it was announcing its own alias, which migrated in as "reach via
    /// KE0NCQ" on KE0NCQ's own entries — connect to the station to reach it.
    func testLegacySelfSourceIsNotARoute() throws {
        let legacy = """
        {"alias":"DRLNOD","callsign":"KE0NCQ","service":"N",
         "heardAt":768000000,"announcements":3,"learnedFrom":"KE0NCQ"}
        """
        let entry = try JSONDecoder().decode(
            NodeAliasDirectory.Entry.self, from: Data(legacy.utf8))
        XCTAssertTrue(entry.tellers.isEmpty)
        XCTAssertEqual(entry.service, "N", "its own declaration is untouched")
    }

    // MARK: - Routes to a station, across all its names

    /// A station listed under several aliases is reachable by every node that
    /// named any of them: `DRLBBS` and `DRLNOD` are one licence.
    func testTellersAreUnionedAcrossAliases() {
        var directory = NodeAliasDirectory()
        let now = Date()
        directory.record(
            NodeAliasParser.Announcement(alias: "BVJBBS", callsign: "KA3BVJ-3", service: ""),
            at: now, from: "KB5YZB-7")
        directory.record(
            NodeAliasParser.Announcement(alias: "BVJALT", callsign: "KA3BVJ-3", service: ""),
            at: now.addingTimeInterval(60), from: "DRLNOD")

        XCTAssertEqual(directory.tellers(forCallsign: "KA3BVJ-3"), ["DRLNOD", "KB5YZB-7"],
                       "freshest first — the order to try them in")
    }

    func testTellersForAnUnknownStationIsEmpty() {
        XCTAssertTrue(directoryFromNodeList().tellers(forCallsign: "W0ARP-10").isEmpty)
        XCTAssertTrue(directoryFromNodeList().tellers(forCallsign: "").isEmpty)
    }

    // MARK: - Feeding the connect bar

    /// Typing either name must find the route: the operator types whichever
    /// one they last read.
    func testConnectRoutesAreKeyedByBothNames() {
        var directory = NodeAliasDirectory()
        directory.record(
            NodeAliasParser.Announcement(alias: "AGCHAT", callsign: "K1AJD-5", service: ""),
            at: Date(), from: "KB5YZB-7")

        let routes = directory.connectRoutes()
        XCTAssertEqual(routes["AGCHAT"], ["KB5YZB-7"])
        XCTAssertEqual(routes["K1AJD-5"], ["KB5YZB-7"])
    }

    /// Nothing unroutable reaches the connect bar — offering a destination
    /// with no way in would produce an attempt that cannot be made.
    func testUnroutableEntriesAreNotOfferedAsRoutes() {
        var directory = NodeAliasDirectory()
        directory.record(
            NodeAliasParser.Announcement(alias: "ARAPEY", callsign: "CX2SA-7", service: ""),
            at: Date())
        XCTAssertTrue(directory.connectRoutes().isEmpty)
    }

    /// A station listed under two names offers both nodes when reached by
    /// callsign, while each alias keeps the route it was published under.
    func testCallsignKeyUnionsRoutesFromEveryAlias() {
        var directory = NodeAliasDirectory()
        let now = Date()
        directory.record(
            NodeAliasParser.Announcement(alias: "BVJBBS", callsign: "KA3BVJ-3", service: ""),
            at: now, from: "KB5YZB-7")
        directory.record(
            NodeAliasParser.Announcement(alias: "BVJALT", callsign: "KA3BVJ-3", service: ""),
            at: now.addingTimeInterval(60), from: "DRLNOD")

        let routes = directory.connectRoutes()
        XCTAssertEqual(routes["KA3BVJ-3"], ["DRLNOD", "KB5YZB-7"])
        XCTAssertEqual(routes["BVJBBS"], ["KB5YZB-7"])
        XCTAssertEqual(routes["BVJALT"], ["DRLNOD"])
    }

    /// Storage written between the two teller changes recorded a station as
    /// its own route. The repair strips those without touching real routes.
    @MainActor
    func testRepairDropsSelfTellers() async {
        let defaults = isolatedDefaults()
        let entry = NodeAliasDirectory.Entry(
            alias: "DRLNOD", callsign: "KE0NCQ", service: "N",
            heardAt: Date(), announcements: 9,
            tellers: ["KE0NCQ": Date(), "KB5YZB-7": Date()])
        defaults.set(try! JSONEncoder().encode(["DRLNOD": entry]),
                     forKey: "station.nodeAliases")

        let store = NodeAliasStore(defaults: defaults)
        let repaired = store.directory.entry(for: "DRLNOD")
        XCTAssertEqual(repaired?.reachableVia, ["KB5YZB-7"],
                       "its own callsign is not a way to reach it")
        XCTAssertEqual(repaired?.announcements, 1, "counts restart")
        XCTAssertEqual(repaired?.service, "", "a table said nothing about services")
    }

    // MARK: - What one node reaches

    /// The sidebar's per-node count and the Nodes page's route filter read
    /// from this one function, so they cannot disagree — and they did:
    /// KB5YZB-7's row said it reached one station while its table listed
    /// eighty-eight, because every station COSCO had listed more recently was
    /// credited to COSCO alone.
    func testANodeIsCreditedWithEverythingItListed() {
        var directory = NodeAliasDirectory()
        let now = Date()
        let shared = NodeAliasParser.Announcement(
            alias: "AGCHAT", callsign: "K1AJD-5", service: "N")

        directory.record(shared, at: now.addingTimeInterval(-3600), from: "KB5YZB-7")
        directory.record(shared, at: now, from: "COSCO")
        directory.record(
            NodeAliasParser.Announcement(alias: "BVJBBS", callsign: "KA3BVJ-3", service: ""),
            at: now.addingTimeInterval(-3600), from: "KB5YZB-7")

        let byTeller = directory.entriesByTeller()
        XCTAssertEqual(byTeller["KB5YZB-7"]?.map(\.alias), ["AGCHAT", "BVJBBS"],
                       "being outbid on recency does not empty a node's table")
        XCTAssertEqual(byTeller["COSCO"]?.map(\.alias), ["AGCHAT"])
    }

    /// The count on the sidebar row is the length of the list the page shows.
    func testTheFilteredPageMatchesTheCount() {
        var directory = NodeAliasDirectory()
        let now = Date()
        for (index, alias) in ["AGCHAT", "BVJBBS", "COSBBS"].enumerated() {
            directory.record(
                NodeAliasParser.Announcement(
                    alias: alias, callsign: "K1AJD-\(index + 1)", service: ""),
                at: now.addingTimeInterval(Double(index)), from: "KB5YZB-7")
        }
        directory.record(
            NodeAliasParser.Announcement(alias: "AGCHAT", callsign: "K1AJD-1", service: ""),
            at: now.addingTimeInterval(600), from: "COSCO")

        let counted = directory.entriesByTeller()["KB5YZB-7"]?.count
        XCTAssertEqual(counted, 3)
        XCTAssertEqual(directory.entries(reachableVia: "KB5YZB-7").count, counted)
        XCTAssertEqual(directory.entries(reachableVia: "kb5yzb-7").map(\.alias),
                       ["AGCHAT", "BVJBBS", "COSBBS"],
                       "the operator's typing decides nothing here")
    }

    func testANodeThatListedNothingReachesNothing() {
        var directory = NodeAliasDirectory()
        directory.record(
            NodeAliasParser.Announcement(alias: "DRLNOD", callsign: "KE0NCQ", service: "N"),
            at: Date(), from: "KB5YZB-7")
        XCTAssertTrue(directory.entries(reachableVia: "COSCO").isEmpty)
        XCTAssertTrue(directory.entries(reachableVia: "  ").isEmpty)
        XCTAssertNil(directory.entriesByTeller()["COSCO"])
    }
}
