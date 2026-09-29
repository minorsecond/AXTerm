import XCTest
@testable import AXTerm

/// The toolbar search field, made actually universal: one query, every
/// category the app knows, grouped with honest totals. Pure model —
/// the panel just renders what this returns.
final class UniversalSearchTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func entry(_ alias: String, _ call: String,
                       tellers: [String] = []) -> NodeAliasDirectory.Entry {
        var entry = NodeAliasDirectory.Entry(
            alias: alias, callsign: call, service: "",
            heardAt: now, announcements: 1)
        for teller in tellers { entry.noteTeller(teller, at: now) }
        return entry
    }

    private func line(_ text: String, from: String? = nil) -> ConsoleLine {
        ConsoleLine(timestamp: now, from: from, to: "CQ", text: text)
    }

    func testOneQueryGroupsMatchesByCategory() {
        let results = UniversalSearchIndex.search(
            "EPI",
            directory: [entry("EPINOD", "K0EPI-7", tellers: ["KB5YZB-7"]),
                        entry("COSCO", "KE0GB-7")],
            routes: [RouteInfo(destination: "K0EPI-7", origin: "DRLNOD",
                               quality: 90, path: [], lastUpdated: now)],
            consoleLines: [line("connected to EPINOD"), line("nothing here")],
            mail: [],
            now: now)

        let categories = results.sections.map(\.category)
        XCTAssertEqual(categories, [.directory, .routes, .terminal],
                       "only categories with matches appear, identity first")
        XCTAssertEqual(results.sections[0].rows.first?.title, "EPINOD:K0EPI-7")
        XCTAssertEqual(results.sections[1].totalCount, 1)
        XCTAssertEqual(results.sections[2].rows.first?.title, "connected to EPINOD")
    }

    func testRowsAreCappedButTotalsAreHonest() {
        let many = (0..<20).map { entry("EPI\($0)BBS", "K\($0)EPI-1") }
        let results = UniversalSearchIndex.search(
            "EPI", directory: many, routes: [], consoleLines: [], mail: [], now: now)

        let section = results.sections[0]
        XCTAssertEqual(section.rows.count, UniversalSearchIndex.rowCap,
                       "the panel shows a taste, not the haystack")
        XCTAssertEqual(section.totalCount, 20,
                       "but never lies about how much matched")
    }

    func testShortAndEmptyQueriesReturnNothing() {
        let sources = [entry("EPINOD", "K0EPI-7")]
        XCTAssertTrue(UniversalSearchIndex.search(
            "", directory: sources, routes: [], consoleLines: [], mail: [], now: now).sections.isEmpty)
        XCTAssertTrue(UniversalSearchIndex.search(
            "E", directory: sources, routes: [], consoleLines: [], mail: [], now: now).sections.isEmpty,
            "one character matches half the world — wait for two")
    }

    func testPrefixMatchesOutrankContainsMatches() {
        let results = UniversalSearchIndex.search(
            "EPI",
            directory: [entry("WEPIX", "W1AAA"), entry("EPINOD", "K0EPI-7")],
            routes: [], consoleLines: [], mail: [], now: now)
        XCTAssertEqual(results.sections[0].rows.first?.title, "EPINOD:K0EPI-7",
                       "what the operator started typing comes first")
    }

    func testMailMatchesOnSubjectAndCorrespondents() {
        let message = WinlinkMessageSummary(
            mid: "M1", direction: .inbound, date: now,
            fromAddr: "K0NTS", toAddrs: ["K0EPI"],
            subject: "EPI antenna party", bodySize: 10, attachmentCount: 0,
            isRead: false, deliveryState: .received, folderId: 1)
        let results = UniversalSearchIndex.search(
            "EPI", directory: [], routes: [], consoleLines: [], mail: [message], now: now)
        XCTAssertEqual(results.sections.first?.category, .mail)
        XCTAssertEqual(results.sections.first?.rows.first?.title, "EPI antenna party")
    }
}
