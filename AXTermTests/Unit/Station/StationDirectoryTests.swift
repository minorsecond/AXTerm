import XCTest
@testable import AXTerm

/// Grouping and filtering the network's own directory.
final class StationDirectoryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ callsign: String,
                       _ service: StationServiceParser.Service,
                       alias: String? = nil,
                       confidence: StationServiceConfidence = .declared,
                       times: Int = 1,
                       last: Date? = nil) -> StationServiceEntry {
        StationServiceEntry(callsign: callsign, service: service, alias: alias,
                            confidence: confidence, firstHeard: t0,
                            lastHeard: last ?? t0, timesHeard: times,
                            sourceText: "")
    }

    // MARK: - Grouping

    func testEntriesGroupIntoOneListingPerStation() {
        let listings = StationDirectory.listings(from: [
            entry("KD0SSP-7", .node), entry("KD0SSP-7", .bbs),
            entry("W0ARP-10", .gateway),
        ])
        XCTAssertEqual(listings.count, 2)
        XCTAssertEqual(listings.first?.callsign, "KD0SSP-7")
        XCTAssertEqual(listings.first?.entries.count, 2)
    }

    func testListingsSortByCallsignSoTheListCanBeScanned() {
        let listings = StationDirectory.listings(from: [
            entry("W0ARP-10", .gateway, last: t0.addingTimeInterval(9999)),
            entry("KB5YZB-7", .digipeater),
        ])
        // Not by recency — a list that reorders as traffic arrives cannot be
        // scanned for a name you half-remember.
        XCTAssertEqual(listings.map(\.callsign), ["KB5YZB-7", "W0ARP-10"])
    }

    /// Observed is the stronger claim and leads the station's entries.
    func testObservedServicesSortAboveDeclaredOnes() {
        let listing = StationDirectory.listings(from: [
            entry("KB5YZB-7", .bbs, confidence: .declared),
            entry("KB5YZB-7", .digipeater, confidence: .demonstrated),
        ]).first
        XCTAssertEqual(listing?.entries.first?.confidence, .demonstrated)
    }

    func testCallsignsMatchRegardlessOfCase() {
        let listings = StationDirectory.listings(from: [
            entry("kd0ssp-7", .node), entry("KD0SSP-7", .bbs),
        ])
        XCTAssertEqual(listings.count, 1)
    }

    func testTheAliasIsSurfacedOnTheListing() {
        let listing = StationDirectory.listings(
            from: [entry("KB5YZB-7", .node, alias: "DRLNOD")]).first
        XCTAssertEqual(listing?.alias, "DRLNOD")
    }

    func testLastHeardIsTheMostRecentOfAnyService() {
        let later = t0.addingTimeInterval(3600)
        let listing = StationDirectory.listings(from: [
            entry("A", .node, last: t0), entry("A", .bbs, last: later),
        ]).first
        XCTAssertEqual(listing?.lastHeard, later)
    }

    /// A station whose every claim is its own word reads differently from one
    /// we watched repeat a frame.
    func testAStationWithOnlyDeclarationsIsMarkedAsSuch() {
        let declared = StationDirectory.listings(
            from: [entry("A", .node), entry("A", .bbs)]).first
        XCTAssertTrue(declared?.isEntirelyDeclared == true)

        let observed = StationDirectory.listings(from: [
            entry("A", .node), entry("A", .digipeater, confidence: .demonstrated),
        ]).first
        XCTAssertFalse(observed?.isEntirelyDeclared == true)
    }

    // MARK: - Filtering

    private var sample: [StationDirectory.Listing] {
        StationDirectory.listings(from: [
            entry("KB5YZB-7", .node, alias: "DRLNOD"),
            entry("KB5YZB-7", .digipeater, confidence: .demonstrated),
            entry("KD0SSP-1", .bbs),
            entry("W0ARP-10", .gateway),
        ])
    }

    func testAnEmptyQueryKeepsEverything() {
        XCTAssertEqual(StationDirectory.filter(sample, query: "", service: nil).count, 3)
    }

    func testQueryMatchesCallsign() {
        let found = StationDirectory.filter(sample, query: "kd0ssp", service: nil)
        XCTAssertEqual(found.map(\.callsign), ["KD0SSP-1"])
    }

    func testQueryMatchesAnAnnouncedAlias() {
        // Operators name nodes by alias, not by callsign.
        let found = StationDirectory.filter(sample, query: "DRLNOD", service: nil)
        XCTAssertEqual(found.map(\.callsign), ["KB5YZB-7"])
    }

    func testQueryMatchesTheServiceName() {
        let found = StationDirectory.filter(sample, query: "bulletin", service: nil)
        XCTAssertEqual(found.map(\.callsign), ["KD0SSP-1"])
    }

    func testQueryIgnoresSurroundingSpace() {
        XCTAssertEqual(
            StationDirectory.filter(sample, query: "  w0arp  ", service: nil).count, 1)
    }

    /// Filtering by service narrows the rows under a station too. Showing a
    /// station's BBS entry under a digipeater filter would misreport what the
    /// filter did.
    func testAServiceFilterAlsoNarrowsTheRowsShown() {
        let found = StationDirectory.filter(sample, query: "", service: .digipeater)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.callsign, "KB5YZB-7")
        XCTAssertEqual(found.first?.entries.count, 1)
        XCTAssertEqual(found.first?.entries.first?.service, .digipeater)
    }

    func testAServiceFilterDropsStationsWithoutIt() {
        XCTAssertTrue(StationDirectory.filter(sample, query: "", service: .relay).isEmpty)
    }

    func testTextAndServiceFiltersApplyTogether() {
        XCTAssertTrue(
            StationDirectory.filter(sample, query: "KD0SSP", service: .gateway).isEmpty)
        XCTAssertEqual(
            StationDirectory.filter(sample, query: "KD0SSP", service: .bbs).count, 1)
    }

    /// The picker must not offer a filter that can only ever return nothing.
    func testOnlyServicesActuallyPresentAreOffered() {
        let available = StationDirectory.availableServices(in: sample)
        XCTAssertEqual(Set(available), [.node, .digipeater, .bbs, .gateway])
        XCTAssertFalse(available.contains(.relay))
    }

    func testAnEmptyDirectoryOffersNoFilters() {
        XCTAssertTrue(StationDirectory.availableServices(in: []).isEmpty)
    }
}
