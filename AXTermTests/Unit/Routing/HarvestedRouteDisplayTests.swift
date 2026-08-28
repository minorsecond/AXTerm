//
//  HarvestedRouteDisplayTests.swift
//  AXTermTests
//
//  End-to-end through the display pipeline: a ROUTES table scraped in a
//  live session must come out the other side as visible rows on the
//  Routes page. Written while chasing a field report of 2026-08-28
//  ("didn't seem to work") — the router and the database both held the
//  harvested routes, so this pins the remaining stretch: integration →
//  hybrid mode filter → view model refresh → display array.
//

import XCTest
@testable import AXTerm

@MainActor
final class HarvestedRouteDisplayTests: XCTestCase {

    private let localCallsign = "K0EPI-7"

    private func makeIntegration() -> NetRomIntegration {
        NetRomIntegration(
            localCallsign: localCallsign,
            mode: .hybrid,
            routerConfig: NetRomConfig.default,
            inferenceConfig: .default,
            linkConfig: LinkQualityConfig.default
        )
    }

    /// The exact field sequence of 09:03 2026-08-28: KB5YZB-7 is a classic
    /// neighbor, its scraped ROUTES rows pass the capability gate, and the
    /// Routes page in "All Routes" mode shows both rows as Harvested.
    func testScrapedRoutesReachTheRoutesPage() async {
        let integration = makeIntegration()
        let now = Date()

        // KB5YZB-7 heard direct → classic neighbor, so the funnel has a
        // link quality to scale the claims by.
        let info = "HELLO".data(using: .ascii) ?? Data()
        let direct = Packet(
            timestamp: now.addingTimeInterval(-60),
            from: AX25Address(call: "KB5YZB", ssid: 7),
            to: AX25Address(call: "K0EPI", ssid: 7),
            via: [],
            frameType: .ui,
            info: info,
            rawAx25: info,
            infoText: "HELLO"
        )
        integration.observePacket(direct, timestamp: now.addingTimeInterval(-60))

        // The scraped table, through the same policy the app runs.
        var scraper = BpqRoutesScraper()
        _ = scraper.ingest(line: "YZBBPQ:KB5YZB-7} Routes", peer: "KB5YZB-7", at: now)
        let rows = [
            scraper.ingest(line: "> 1 KE0GB-7   192 97 ", peer: "KB5YZB-7", at: now),
            scraper.ingest(line: "> 1 VE3CGR-7  192 8 ", peer: "KB5YZB-7", at: now)
        ].compactMap { $0 }
        XCTAssertEqual(rows.count, 2)

        let decision = HarvestedRoutePolicy.decide(
            rows: rows,
            anchorCanRouteNetRom: true,
            localCallsign: localCallsign)
        XCTAssertEqual(decision.accepted.count, 2)
        integration.harvestedRoutes(from: "KB5YZB-7", destinations: decision.accepted, timestamp: now)

        // The integration's hybrid view carries them...
        let hybrid = integration.currentRoutes(forMode: .hybrid)
        XCTAssertTrue(hybrid.contains { $0.destination == "KE0GB-7" && $0.sourceType == "harvested" },
                      "hybrid mode must include harvested routes; got \(hybrid.map { "\($0.destination)/\($0.sourceType)" })")

        // ...and the Routes page's view model displays them.
        let viewModel = NetRomRoutesViewModel(integration: integration, settings: nil)
        viewModel.setMode(.hybrid)
        viewModel.refresh()

        let displayed = viewModel.routes
        let cosco = displayed.first { $0.destination == "KE0GB-7" }
        XCTAssertNotNil(cosco, "KE0GB-7 (COSCO) must appear on the Routes page; page shows \(displayed.map(\.destination))")
        XCTAssertEqual(cosco?.sourceType, "harvested")
        XCTAssertEqual(cosco?.nextHop, "KB5YZB-7")
        XCTAssertTrue(cosco?.heardPathSummary.contains("ROUTES table") ?? false)
        XCTAssertGreaterThan(cosco?.freshness ?? 0, 0.9,
                             "a minute-old harvested route must not read as expired")
        XCTAssertTrue(displayed.contains { $0.destination == "VE3CGR-7" && $0.sourceType == "harvested" })
    }
}
