import XCTest
@testable import AXTerm

/// Reading a KA-Node's two list commands.
///
/// Every fixture here is verbatim from DRLNOD (KE0NCQ) on 2026-08-31, so
/// the parser is measured against the thing it has to read rather than
/// against an idea of it.
final class KaNodeOutputTests: XCTestCase {

    // MARK: - N (Nodes)

    /// `N` lists what the node calls other nodes: alias, callsign in
    /// parentheses, and when it last heard from them.
    func testParsesTheNodeList() throws {
        let lines = [
            "IVAN            (W1VAN-2)   06/04/2026 07:36:16",
            "WIND            (W0WAL)     08/08/2026 10:49:09",
            "KE0GB-7         (KE0GB-7)   05/21/2026 19:25:16",
            "EATON           (W2CRS)     08/31/2026 05:04:41",
        ]
        let entries = lines.compactMap(KaNodeOutput.NodeEntry.parse)
        XCTAssertEqual(entries.count, 4)

        XCTAssertEqual(entries[0].alias, "IVAN")
        XCTAssertEqual(entries[0].callsign, "W1VAN-2")
        XCTAssertEqual(entries[1].alias, "WIND")
        XCTAssertEqual(entries[1].callsign, "W0WAL")
        // An entry may have no distinct alias — the alias column repeats
        // the callsign — and that is not an alias, it is a callsign.
        XCTAssertNil(entries[2].alias)
        XCTAssertEqual(entries[2].callsign, "KE0GB-7")
    }

    /// A trailing `*` marks the node's own channel entries. It is not part
    /// of the alias and must not become one.
    func testStripsTheChannelMarker() throws {
        let entry = try XCTUnwrap(KaNodeOutput.NodeEntry.parse(
            "AA0QC-7*        (AA0QC)     04/30/2026 12:22:31"))
        XCTAssertEqual(entry.callsign, "AA0QC")
        XCTAssertNil(entry.alias, "AA0QC-7 is the same station as AA0QC")
    }

    /// The first row of the captured list had an empty alias column.
    /// Garbage in the alias field is worse than no alias.
    func testAnEmptyAliasColumnIsNotAnAlias() throws {
        let entry = try XCTUnwrap(KaNodeOutput.NodeEntry.parse(
            "-7*             (KA9QJT-1)  04/11/2026 12:04:08"))
        XCTAssertEqual(entry.callsign, "KA9QJT-1")
        XCTAssertNil(entry.alias)
    }

    // MARK: - J (JHEARD)

    /// `J` lists stations the node heard *directly* — callsign and time,
    /// no alias column. One RF hop from that node.
    func testParsesTheHeardList() throws {
        let lines = [
            "AF0AJ-7   08/31/2026 04:54:18",
            "W1VAN     08/31/2026 04:54:36",
            "KD0SSP    08/31/2026 04:58:10",
            "KF0HEG    08/31/2026 04:59:32",
        ]
        let entries = lines.compactMap(KaNodeOutput.HeardEntry.parse)
        XCTAssertEqual(entries.map(\.callsign),
                       ["AF0AJ-7", "W1VAN", "KD0SSP", "KF0HEG"])
    }

    /// A heard line has no parenthesised callsign; a node line does. Confusing
    /// the two would file a node's peers as stations it heard directly.
    func testHeardAndNodeLinesAreNotConfusedForEachOther() {
        let nodeLine = "IVAN            (W1VAN-2)   06/04/2026 07:36:16"
        let heardLine = "W1VAN     08/31/2026 04:54:36"

        XCTAssertNil(KaNodeOutput.HeardEntry.parse(nodeLine))
        XCTAssertNil(KaNodeOutput.NodeEntry.parse(heardLine))
    }

    // MARK: - Refusing everything else

    /// Prompts, banners and chatter must produce nothing. A parser that
    /// invents a station from a menu line poisons the directory.
    func testNoiseIsRejected() {
        let noise = [
            "ENTER COMMAND: B,C,J,N, or Help ?",
            "###CONNECTED TO NODE DRLNOD(KE0NCQ) CHANNEL A",
            "",
            "   ",
            "*** connected to KB5YZB-7",
            "Bye",
            "NOT A CALLSIGN AT ALL 99/99/9999",
        ]
        for line in noise {
            XCTAssertNil(KaNodeOutput.NodeEntry.parse(line), line)
            XCTAssertNil(KaNodeOutput.HeardEntry.parse(line), line)
        }
    }

    /// Timestamps are the node's own clock in its own zone, which is not
    /// knowable from here. Parsing one as if it were ours would put
    /// stations in the future or the past by hours.
    func testTimestampsAreKeptVerbatimRatherThanInterpreted() throws {
        let entry = try XCTUnwrap(KaNodeOutput.HeardEntry.parse(
            "W1VAN     08/31/2026 04:54:36"))
        XCTAssertEqual(entry.reportedAt, "08/31/2026 04:54:36")
    }

    // MARK: - What may be believed

    /// A KA-Node has no L3. Its lists are evidence about *reachability
    /// through it*, never NET/ROM routes — synthesising a route through a
    /// station that cannot route is how the app would fabricate paths.
    func testNothingHereIsANetRomRoute() {
        XCTAssertFalse(KaNodeOutput.yieldsNetRomRoutes)
    }
}
