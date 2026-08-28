//
//  BpqRoutesScraperTests.swift
//  AXTermTests
//
//  Pins the ROUTES-table scraper against the field capture of 2026-08-28
//  (KB5YZB-7 answering `routes`), and pins the guardrails: a row-shaped
//  line with no header is prose, tables are per-peer, and garbage never
//  becomes a route.
//

import XCTest
@testable import AXTerm

final class BpqRoutesScraperTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    // MARK: - The field capture

    func testTheCapturedTableYieldsBothRows() {
        var scraper = BpqRoutesScraper()
        XCTAssertNil(scraper.ingest(line: "Routes", peer: "KB5YZB-7", at: now))

        let first = scraper.ingest(line: "> 1 KE0GB-7 192 91", peer: "KB5YZB-7", at: now.addingTimeInterval(1))
        XCTAssertEqual(first?.anchor, "KB5YZB-7")
        XCTAssertEqual(first?.neighbor, "KE0GB-7")
        XCTAssertEqual(first?.port, 1)
        XCTAssertEqual(first?.quality, 192)
        XCTAssertEqual(first?.count, 91)
        XCTAssertEqual(first?.isActive, true)

        let second = scraper.ingest(line: "  1 VE3CGR-7 192 8", peer: "KB5YZB-7", at: now.addingTimeInterval(2))
        XCTAssertEqual(second?.neighbor, "VE3CGR-7")
        XCTAssertEqual(second?.isActive, false)
    }

    /// The field capture of 08:40 2026-08-28, verbatim: BPQ printed the
    /// prompt and the header on ONE line (`YZBBPQ:KB5YZB-7} Routes`), and
    /// a bare-"Routes" check never armed — the whole table scrolled past
    /// as prose and nothing was harvested. Never regress this.
    func testThePromptPrefixedHeaderArmsTheScraper() {
        var scraper = BpqRoutesScraper()
        XCTAssertNil(scraper.ingest(line: "YZBBPQ:KB5YZB-7} Routes", peer: "KB5YZB-7", at: now))

        let first = scraper.ingest(line: "> 1 KE0GB-7   192 97 ", peer: "KB5YZB-7", at: now.addingTimeInterval(1))
        XCTAssertEqual(first?.neighbor, "KE0GB-7")
        XCTAssertEqual(first?.quality, 192)
        XCTAssertEqual(first?.count, 97)

        let second = scraper.ingest(line: "> 1 VE3CGR-7  192 8 ", peer: "KB5YZB-7", at: now.addingTimeInterval(2))
        XCTAssertEqual(second?.neighbor, "VE3CGR-7")
    }

    func testHeaderRecognizerRejectsProseEndingInRoutes() {
        XCTAssertTrue(BpqRoutesScraper.isRoutesHeader("Routes"))
        XCTAssertTrue(BpqRoutesScraper.isRoutesHeader("routes"))
        XCTAssertTrue(BpqRoutesScraper.isRoutesHeader("YZBBPQ:KB5YZB-7} Routes"))
        XCTAssertFalse(BpqRoutesScraper.isRoutesHeader("I know some good Routes"),
                       "prose is not a header without a prompt-shaped prefix")
        XCTAssertFalse(BpqRoutesScraper.isRoutesHeader("see the map} Routes"),
                       "a prompt prefix has a colon and no spaces")
        XCTAssertFalse(BpqRoutesScraper.isRoutesHeader("YZBBPQ:KB5YZB-7} NODES"))
    }

    // MARK: - Guardrails

    /// A bare row without the header is indistinguishable from a line in a
    /// BBS message body — it must teach nothing.
    func testARowWithoutAHeaderIsProse() {
        var scraper = BpqRoutesScraper()
        XCTAssertNil(scraper.ingest(line: "> 1 KE0GB-7 192 91", peer: "KB5YZB-7", at: now))
    }

    func testTheFirstNonRowLineEndsTheTable() {
        var scraper = BpqRoutesScraper()
        _ = scraper.ingest(line: "Routes", peer: "KB5YZB-7", at: now)
        _ = scraper.ingest(line: "> 1 KE0GB-7 192 91", peer: "KB5YZB-7", at: now.addingTimeInterval(1))
        XCTAssertNil(scraper.ingest(line: "KB5YZB-7:YZBBPQ}", peer: "KB5YZB-7", at: now.addingTimeInterval(2)))
        XCTAssertNil(scraper.ingest(line: "  1 VE3CGR-7 192 8", peer: "KB5YZB-7", at: now.addingTimeInterval(3)),
                     "once disarmed, later row-shaped lines are prose again")
    }

    func testASilentMinuteDisarms() {
        var scraper = BpqRoutesScraper()
        _ = scraper.ingest(line: "Routes", peer: "KB5YZB-7", at: now)
        XCTAssertNil(scraper.ingest(line: "> 1 KE0GB-7 192 91", peer: "KB5YZB-7",
                                    at: now.addingTimeInterval(BpqRoutesScraper.armedWindowSeconds + 1)),
                     "a table never takes a minute to print")
    }

    /// The header from one peer must not arm the scraper for another —
    /// two sessions can interleave in the same terminal.
    func testArmingIsPerPeer() {
        var scraper = BpqRoutesScraper()
        _ = scraper.ingest(line: "Routes", peer: "KB5YZB-7", at: now)
        XCTAssertNil(scraper.ingest(line: "> 1 KE0GB-7 192 91", peer: "KE0NCQ", at: now.addingTimeInterval(1)))
        XCTAssertNotNil(scraper.ingest(line: "> 1 KE0GB-7 192 91", peer: "KB5YZB-7", at: now.addingTimeInterval(2)))
    }

    func testAReissuedTableStillYieldsRows() {
        var scraper = BpqRoutesScraper()
        _ = scraper.ingest(line: "Routes", peer: "KB5YZB-7", at: now)
        _ = scraper.ingest(line: "> 1 KE0GB-7 192 91", peer: "KB5YZB-7", at: now.addingTimeInterval(1))
        _ = scraper.ingest(line: "ENTER COMMAND", peer: "KB5YZB-7", at: now.addingTimeInterval(2))

        // The operator asks again ten minutes later: live text is fresh by
        // construction, so the same rows are fresh evidence — deliberately
        // unlike the stored-frame replay rule in the alias directory.
        _ = scraper.ingest(line: "Routes", peer: "KB5YZB-7", at: now.addingTimeInterval(600))
        let again = scraper.ingest(line: "> 1 KE0GB-7 192 91", peer: "KB5YZB-7", at: now.addingTimeInterval(601))
        XCTAssertEqual(again?.observedAt, now.addingTimeInterval(601))
    }

    // MARK: - Row recognizer

    func testRowRecognizerRejectsGarbage() {
        XCTAssertNil(BpqRoutesScraper.parseRow("> 1 KE0GB-7 300 91"), "quality above 255 is not a NET/ROM figure")
        XCTAssertNil(BpqRoutesScraper.parseRow("> 1 ROUTES 192 91"), "the callsign column must look like a callsign")
        XCTAssertNil(BpqRoutesScraper.parseRow("> x KE0GB-7 192 91"), "the port column must be a number")
        XCTAssertNil(BpqRoutesScraper.parseRow("1 KE0GB-7 192"), "too few columns")
        XCTAssertNil(BpqRoutesScraper.parseRow("1 KE0GB-7 192 91 extra"), "too many columns")
        XCTAssertNil(BpqRoutesScraper.parseRow(""))
    }

    func testRowRecognizerAcceptsTabSeparatedColumns() {
        let row = BpqRoutesScraper.parseRow(">\t2\tW0ARP-10\t128\t4")
        XCTAssertEqual(row?.call, "W0ARP-10")
        XCTAssertEqual(row?.port, 2)
        XCTAssertEqual(row?.active, true)
    }
}
