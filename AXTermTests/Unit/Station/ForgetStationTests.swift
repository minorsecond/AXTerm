import XCTest
@testable import AXTerm

/// Forgetting what one station told us.
///
/// Needed for two reasons that turned out to be the same reason. An operator
/// wants to clear a station's history; and a misattribution — a BBS credited
/// with a node's words — leaves claims in the directory that no rule can
/// safely undo automatically, because nothing distinguishes them afterwards
/// from claims that were correct. So it is the operator's call, and this is
/// the control.
final class ForgetStationTests: XCTestCase {

    private func entry(_ alias: String, _ callsign: String,
                       tellers: [String] = []) -> NodeAliasDirectory.Entry {
        var e = NodeAliasDirectory.Entry(
            alias: alias, callsign: callsign, service: "",
            heardAt: Date(timeIntervalSince1970: 1_788_000_000), announcements: 1)
        for teller in tellers {
            e.tellers[teller] = Date(timeIntervalSince1970: 1_788_000_000)
        }
        return e
    }

    private func directory() -> NodeAliasDirectory {
        NodeAliasDirectory(entries: [
            // BBSCBH wrongly credited with COSCO — the reported case.
            "COSCO": entry("COSCO", "KE0GB-7", tellers: ["BBSCBH", "KB5YZB-7"]),
            "BBSCBH": entry("BBSCBH", "WG3K-4"),
            // An unrelated station that must be untouched.
            "EVANS": entry("EVANS", "W0EVA", tellers: ["DRLNOD"]),
        ])
    }

    func testItDropsTheClaimsThatStationMade() {
        var d = directory()
        _ = d.forgetStation("BBSCBH")
        XCTAssertNil(d.entries["COSCO"]?.tellers["BBSCBH"])
    }

    /// The entry itself survives with its other tellers. COSCO is a real
    /// node reached through KB5YZB-7, and one bad claim about it is not a
    /// reason to forget it exists.
    func testOtherStationsClaimsAboutTheSameNodeSurvive() {
        var d = directory()
        _ = d.forgetStation("BBSCBH")
        XCTAssertNotNil(d.entries["COSCO"])
        XCTAssertNotNil(d.entries["COSCO"]?.tellers["KB5YZB-7"])
    }

    /// Its own entry goes too — that is what "forget this station" means.
    func testItRemovesTheStationsOwnEntry() {
        var d = directory()
        _ = d.forgetStation("BBSCBH")
        XCTAssertNil(d.entries["BBSCBH"])
    }

    /// Stations that were not named are not touched.
    func testEverythingElseIsLeftAlone() {
        var d = directory()
        _ = d.forgetStation("BBSCBH")
        XCTAssertNotNil(d.entries["EVANS"])
        XCTAssertNotNil(d.entries["EVANS"]?.tellers["DRLNOD"])
    }

    /// The operator is told what happened rather than left guessing whether
    /// the button did anything.
    func testItReportsWhatItRemoved() {
        var d = directory()
        let tally = d.forgetStation("BBSCBH")
        XCTAssertEqual(tally.ownEntries, 1)
        XCTAssertEqual(tally.claims, 1)
        XCTAssertTrue(tally.removedAnything)
    }

    /// Forgetting a station we know nothing about is not an error, and must
    /// not claim to have done something.
    func testForgettingAnUnknownStationRemovesNothing() {
        var d = directory()
        let tally = d.forgetStation("N0SUCH")
        XCTAssertFalse(tally.removedAnything)
        XCTAssertEqual(d.entries.count, 3)
    }

    /// Doing it twice is harmless.
    func testItIsIdempotent() {
        var d = directory()
        _ = d.forgetStation("BBSCBH")
        let second = d.forgetStation("BBSCBH")
        XCTAssertFalse(second.removedAnything)
    }

    /// Case and stray whitespace must not let a station escape being
    /// forgotten — the operator typed a callsign, not a key.
    func testTheCallsignIsMatchedLoosely() {
        var d = directory()
        let tally = d.forgetStation("  bbscbh ")
        XCTAssertTrue(tally.removedAnything)
        XCTAssertNil(d.entries["BBSCBH"])
    }
}
