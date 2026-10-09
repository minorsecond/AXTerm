import XCTest
@testable import AXTerm

/// How NWS hazards look and read on the map (Docs/HazardLayers.md §1, §4):
/// the NWS's own colors and priorities, a line that always says where an
/// alert came from and how old it is, and the "Inside" line.
final class HazardPresentationTests: XCTestCase {
    private let denver = TimeZone(identifier: "America/Denver")!
    private let locale = Locale(identifier: "en_US")
    /// 2026-10-09 14:00 MDT.
    private let now = Date(timeIntervalSince1970: 1_791_576_000)

    /// The system puts a narrow no-break space before AM/PM, and which space
    /// depends on the OS's locale data; the words are what is under test.
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: - The NWS table (weather.gov/help-map, read 2026-10-09)

    func testColorsAndPrioritiesAreTheNWSOwn() {
        XCTAssertEqual(NWSHazardStyle.style(for: "Tornado Warning"), .init(priority: 2, hex: "FF0000"))
        XCTAssertEqual(NWSHazardStyle.style(for: "Red Flag Warning"), .init(priority: 52, hex: "FF1493"))
        XCTAssertEqual(NWSHazardStyle.style(for: "Winter Storm Warning"), .init(priority: 26, hex: "FF69B4"))
        XCTAssertEqual(NWSHazardStyle.style(for: "Hydrologic Outlook"), .init(priority: 106, hex: "90EE90"))
        XCTAssertEqual(NWSHazardStyle.table.count, 111)
    }

    /// An event the table does not list is drawn plainly, ranked below every
    /// listed one, rather than guessed at.
    func testAnUnlistedEventIsDrawnPlainlyAndRankedLast() {
        let style = NWSHazardStyle.style(for: "Made Up Warning")
        XCTAssertEqual(style.hex, NWSHazardStyle.unlisted.hex)
        XCTAssertGreaterThan(style.priority, 111)
    }

    // MARK: - Source and age, always

    private func redFlag(expiresIn: TimeInterval = 6 * 3600, fetchedAgo: TimeInterval = 180) -> HazardFeature {
        var feature = HazardFeature(id: "rf", kind: .warning, event: "Red Flag Warning", source: "NWS Boulder CO",
                                    fetchedAt: now.addingTimeInterval(-fetchedAgo))
        feature.issued = now.addingTimeInterval(-(3 * 3600 + 32 * 60))  // 10:28 AM
        feature.expires = now.addingTimeInterval(expiresIn)
        let square = [GreatCircle.Point(latitude: 39, longitude: -105), GreatCircle.Point(latitude: 39, longitude: -104),
                      GreatCircle.Point(latitude: 40, longitude: -104), GreatCircle.Point(latitude: 40, longitude: -105)]
        feature.geometry = .polygons([[square]])
        return feature
    }

    func testTheLineSaysWhoWhenAndHowOld() {
        XCTAssertEqual(plain(HazardText.summary(redFlag(), now: now, stale: false, timeZone: denver, locale: locale)),
                       "Red Flag Warning · NWS Boulder CO · issued 10:28 AM · until 8:00 PM · fetched 3 min ago")
    }

    /// No newer copy for a while: said, so a stale warning cannot pass for a
    /// current one.
    func testAStaleCopySaysSo() {
        let text = HazardText.summary(redFlag(fetchedAgo: 47 * 60), now: now, stale: true,
                                      timeZone: denver, locale: locale)
        XCTAssertTrue(text.hasSuffix("fetched 47 min ago, no newer copy"), text)
    }

    func testAnExpiredAlertSaysExpired() {
        let text = plain(HazardText.summary(redFlag(expiresIn: -3600), now: now, stale: false,
                                            timeZone: denver, locale: locale))!
        XCTAssertTrue(text.contains("expired 1:00 PM"), text)
    }

    // MARK: - Inside

    private let inside = GreatCircle.Point(latitude: 39.5, longitude: -104.5)

    func testInsideNamesTheHazardAndWhenItEnds() {
        XCTAssertEqual(plain(HazardText.insideLine([redFlag()], at: inside, now: now, timeZone: denver, locale: locale)),
                       "Inside: Red Flag Warning until 8:00 PM")
        XCTAssertNil(HazardText.insideLine([redFlag()], at: GreatCircle.Point(latitude: 41, longitude: -104.5),
                                           now: now, timeZone: denver, locale: locale))
    }

    func testAnExpiredHazardIsNotInside() {
        XCTAssertNil(HazardText.insideLine([redFlag(expiresIn: -60)], at: inside, now: now,
                                           timeZone: denver, locale: locale))
    }

    /// Inside several: the NWS's highest priority first, and a count.
    func testInsideSeveralLeadsWithTheHighestPriority() {
        var tornado = redFlag(expiresIn: 1800)
        tornado.event = "Tornado Warning"
        XCTAssertEqual(plain(HazardText.insideLine([redFlag(), tornado], at: inside, now: now,
                                                   timeZone: denver, locale: locale)),
                       "Inside: Tornado Warning until 2:30 PM, and 1 more")
    }

    // MARK: - The sidebar caption

    func testTheCaptionSaysHowManyAndHowOld() {
        let fetched = now.addingTimeInterval(-180)
        XCTAssertEqual(HazardText.layerCaption(count: 2, lastFetched: fetched, problem: nil, stale: false, now: now),
                       "2 alerts · fetched 3 min ago")
        XCTAssertEqual(HazardText.layerCaption(count: 1, lastFetched: fetched, problem: nil, stale: false, now: now),
                       "1 alert · fetched 3 min ago")
        XCTAssertEqual(HazardText.layerCaption(count: 0, lastFetched: fetched, problem: nil, stale: false, now: now),
                       "No alerts here · fetched 3 min ago")
    }

    func testTheCaptionBeforeAnyFetch() {
        XCTAssertEqual(HazardText.layerCaption(count: 0, lastFetched: nil, problem: nil, stale: false, now: now),
                       "Not fetched yet")
        XCTAssertEqual(HazardText.layerCaption(count: 0, lastFetched: nil, problem: "no connection",
                                               stale: false, now: now),
                       "Could not reach the NWS")
    }

    /// Offline or stale: the caption says the alerts shown are old.
    func testTheCaptionSaysWhenTheAlertsAreOld() {
        let fetched = now.addingTimeInterval(-47 * 60)
        XCTAssertEqual(HazardText.layerCaption(count: 2, lastFetched: fetched, problem: "no connection",
                                               stale: true, now: now),
                       "Offline · showing 2 alerts fetched 47 min ago")
        XCTAssertEqual(HazardText.layerCaption(count: 2, lastFetched: fetched, problem: nil, stale: true, now: now),
                       "2 alerts · fetched 47 min ago, no newer copy")
    }

    /// "No alerts here" is right for the station's point; for a wider area
    /// the caption names it (Station C, 2026-10-09: within 50 miles said
    /// "here").
    func testNoAlertsNamesTheAreaThatWasSearched() {
        let fetched = now.addingTimeInterval(-60)
        func caption(_ scope: NWSAlertScope) -> String {
            HazardText.layerCaption(count: 0, lastFetched: fetched, problem: nil, stale: false, now: now, scope: scope)
        }
        XCTAssertEqual(caption(.here), "No alerts here · fetched 1 min ago")
        XCTAssertEqual(caption(.within(miles: 50)), "No alerts within 50 mi · fetched 1 min ago")
        XCTAssertEqual(caption(.states(["CO", "WY"])), "No alerts in CO, WY · fetched 1 min ago")
        XCTAssertEqual(caption(.zones(["COZ039"])), "No alerts in zones COZ039 · fetched 1 min ago")
    }

    /// Paused at the NWS's request: said, with when the next try is, rather
    /// than "Offline".
    func testAPauseAtTheNWSRequestIsSaid() {
        let text = plain(HazardText.layerCaption(count: 2, lastFetched: now.addingTimeInterval(-180),
                                                 problem: "slow down", stale: false, now: now,
                                                 pausedUntil: now.addingTimeInterval(120),
                                                 timeZone: denver, locale: locale))
        XCTAssertEqual(text, "NWS asked to slow down; next try 2:02 PM · showing 2 alerts fetched 3 min ago")
    }

    /// Zone outlines still loading a few at a time: counted, so an alert
    /// listed without a shape is explained.
    func testZonesStillLoadingAreCounted() {
        XCTAssertEqual(HazardText.layerCaption(count: 1, lastFetched: now.addingTimeInterval(-60), problem: nil,
                                               stale: false, now: now, zonesLoading: 8),
                       "1 alert · fetched 1 min ago · 8 zones still loading")
    }

    func testAlertsStillBeingPlacedAreCountedApart() {
        XCTAssertEqual(HazardText.layerCaption(count: 3, lastFetched: now.addingTimeInterval(-60), problem: nil,
                                               stale: false, now: now, scope: .within(miles: 200),
                                               unplaced: 21, zonesLoading: 116),
                       "3 alerts within 200 mi · fetched 1 min ago · 21 more being placed (116 zones loading)")
    }

    func testARejectedAreaIsSaidAsSuch() {
        XCTAssertEqual(HazardText.layerCaption(count: 8, lastFetched: now.addingTimeInterval(-60), problem: "rejected",
                                               stale: false, now: now, rejected: true),
                       "NWS did not accept that area · showing 8 alerts fetched 1 min ago")
    }

    /// A fetch in progress shows in the caption, first time or not.
    func testTheCaptionSaysWhatIsBeingFetched() {
        let now = Date(timeIntervalSince1970: 1_791_590_000)
        XCTAssertEqual(HazardText.layerCaption(count: 0, lastFetched: nil, problem: nil, stale: false, now: now,
                                               activity: .fetchingAlerts),
                       "Fetching alerts…")
        XCTAssertEqual(HazardText.layerCaption(count: 3, lastFetched: now.addingTimeInterval(-120), problem: nil,
                                               stale: false, now: now, activity: .fetchingAlerts),
                       "Fetching alerts… · showing 3 alerts fetched 2 min ago")
        XCTAssertEqual(HazardText.layerCaption(count: 0, lastFetched: nil, problem: nil, stale: false, now: now,
                                               activity: .loadingOutlines(done: 2, total: 18)),
                       "Loading outlines 3 of 18…")
    }
}
