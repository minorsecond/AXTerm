import XCTest
@testable import AXTerm

/// Category codes and counts here are verbatim from the 2026-08-24 field
/// capture (1466 products, 126 codes).
final class WinlinkCatalogTaxonomyTests: XCTestCase {

    private func item(_ category: String,
                      id: String = "ID1",
                      subject: String = "Subject",
                      size: Int = 1000) -> WinlinkCatalogItemRecord {
        WinlinkCatalogItemRecord(
            inquiryId: id, category: category, subject: subject, url: "",
            lifetimeDays: 0, sizeEstimate: size, enabled: true, fetchedAt: Date())
    }

    // MARK: - Family assignment

    func testFamilyAssignmentIsPrefixDriven() {
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "WX_US_WY"), .unitedStates)
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "WX_US"), .unitedStates)
        // WX_US must win over the general WX rule.
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "WX_US_RAD"), .unitedStates)
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "WX_MED"), .world)
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "WX_CANADA"), .world)
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "METAREA_XIV"), .marineZones)
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "METAREA"), .marineZones)
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "WL2K_HELP"), .winlinkSystem)
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "SAT_PIX"), .skyAndSpace)
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "PROPAGATION"), .skyAndSpace)
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "ARES_RACES"), .other)
    }

    /// Weather products whose codes carry no `WX` prefix still belong in
    /// the weather family — the alternative is an "Other" bucket holding
    /// METARs and hurricane forecasts. Each of these was confirmed by
    /// reading its own items' subjects in the field capture.
    func testUnprefixedWeatherCodesJoinTheWeatherFamily() {
        for code in ["METAR", "HONDURAS", "NICARAGUA", "ARCTIC_ICE",
                     "INDIAN_OCEAN", "S/PACIFIC_WX"] {
            XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: code), .world, code)
        }
    }

    /// `WX_US_DE` is Delaware, not Germany: inside the United States
    /// family the state map must outrank the general token map, which
    /// reads DE as Germany for the Baltic product `WX_BALT_DE`.
    func testStateAbbreviationsWinInsideTheUnitedStatesFamily() {
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_DE", in: .unitedStates),
                       "Delaware")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_BALT_DE", in: .world),
                       "Baltic Germany")
    }

    /// METAREA leaves keep the gateway's own wording rather than being
    /// reduced to a bare numeral in a list.
    func testMarineZonesKeepTheirFullCode() {
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "METAREA_XIV", in: .marineZones),
                       "METAREA XIV")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "METAREA", in: .marineZones),
                       "General")
    }

    /// Roman numerals sort by value, not by spelling — alphabetically
    /// METAREA IX lands between III and V.
    func testMarineZonesSortByNumeralValue() throws {
        let codes = ["METAREA_XIV", "METAREA_II", "METAREA_IX", "METAREA_I", "METAREA_V"]
        let families = WinlinkCatalogTaxonomy.families(from: codes.map { item($0, id: $0) })
        let zones = try XCTUnwrap(families.first { $0.kind == .marineZones })
        XCTAssertEqual(zones.categories.map(\.rawCategory),
                       ["METAREA_I", "METAREA_II", "METAREA_V", "METAREA_IX", "METAREA_XIV"])
    }

    /// A code the catalog grows later still lands somewhere sensible
    /// without a code change — that is the point of a mechanical rule.
    func testUnknownCodeFallsIntoOther() {
        XCTAssertEqual(WinlinkCatalogTaxonomy.family(for: "BRAND_NEW_THING"), .other)
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "BRAND_NEW_THING", in: .other),
                       "Brand New Thing")
    }

    // MARK: - Leaf names

    func testStateCodesExpandToStateNames() {
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_WY", in: .unitedStates), "Wyoming")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_ME", in: .unitedStates), "Maine")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_PR", in: .unitedStates), "Puerto Rico")
    }

    /// Names verified against the items' own subjects, not invented:
    /// WX_US_RAD's subjects read "SNAPSHOT CURRENT RADAR U.S. ALASKA".
    func testNonStateCodesUseNamesReadFromSubjects() {
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_RAD", in: .unitedStates), "Radar")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_SELCTY", in: .unitedStates),
                       "Selected Cities")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_COAST", in: .unitedStates),
                       "Coastal Waters")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_FAX", in: .world), "Weather Fax")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_NFLD", in: .world), "Newfoundland")
    }

    /// Roman zone numerals must survive: "Metarea Xiv" is not a name.
    func testMarineZoneNumeralsKeepTheirCase() {
        // Not "Xiv" — roman numerals must survive title-casing.
        XCTAssertEqual(WinlinkCatalogTaxonomy.categoryTitle("METAREA_XIV"), "METAREA XIV")
    }

    /// Two-letter state codes that are also valid roman numerals (IL, MI)
    /// must resolve as states.
    func testStateCodesBeatRomanNumerals() {
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_IL", in: .unitedStates), "Illinois")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_MI", in: .unitedStates), "Michigan")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US_VA", in: .unitedStates), "Virginia")
    }

    func testBareFamilyCodeIsCalledGeneral() {
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_US", in: .unitedStates), "General")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "METAREA", in: .marineZones), "General")
    }

    func testAwkwardCodesUseOverrides() {
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "WX_CAR_GULF", in: .world),
                       "Caribbean & Gulf")
        XCTAssertEqual(WinlinkCatalogTaxonomy.leafTitle(for: "ARES_RACES", in: .other), "ARES / RACES")
    }

    // MARK: - Grouping

    func testFamiliesAreOrderedAndCountItems() {
        let items = [
            item("WX_US_WY", id: "WY1"), item("WX_US_WY", id: "WY2"),
            item("WX_US_CA", id: "CA1"),
            item("WX_MED", id: "MED1"),
            item("ARES_RACES", id: "ARES1"),
        ]
        let families = WinlinkCatalogTaxonomy.families(from: items)
        XCTAssertEqual(families.map(\.kind), [.unitedStates, .world, .other])

        let us = families[0]
        XCTAssertEqual(us.itemCount, 3)
        // Categories sort by the name the operator reads, not the code.
        XCTAssertEqual(us.categories.map(\.title), ["California", "Wyoming"])
        XCTAssertEqual(us.categories.last?.items.count, 2)
    }

    func testEmptyFamiliesAreOmitted() {
        let families = WinlinkCatalogTaxonomy.families(from: [item("ARES_RACES")])
        XCTAssertEqual(families.map(\.kind), [.other])
    }

    func testCategoryTotalsSumItemSizes() throws {
        let items = [item("WX_US_WY", id: "A", size: 1500), item("WX_US_WY", id: "B", size: 500)]
        let category = try XCTUnwrap(WinlinkCatalogTaxonomy.families(from: items).first?.categories.first)
        XCTAssertEqual(category.totalBytes, 2000)
    }

    // MARK: - Search

    func testSearchMatchesSubjectIdAndCategory() {
        let record = item("WX_US_WY", id: "WY_TAB_STATE", subject: "Tabular State Forecast")
        XCTAssertTrue(WinlinkCatalogTaxonomy.matches(record, query: "tabular"))
        XCTAssertTrue(WinlinkCatalogTaxonomy.matches(record, query: "WY_TAB"))
        XCTAssertTrue(WinlinkCatalogTaxonomy.matches(record, query: "wx_us_wy"))
        XCTAssertFalse(WinlinkCatalogTaxonomy.matches(record, query: "kansas"))
    }

    /// The friendly name is searchable too, so "alaska" finds
    /// WX_AK_COAST even though neither its code nor subject says it.
    func testSearchMatchesFriendlyCategoryName() {
        let record = item("WX_AK_COAST", id: "AK1", subject: "N GULF OF AK COAST 100 NM OUT")
        XCTAssertTrue(WinlinkCatalogTaxonomy.matches(record, query: "Alaska"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(WinlinkCatalogTaxonomy.matches(item("METAR"), query: "   "))
    }

    func testSearchIgnoresCaseAndDiacritics() {
        let record = item("WX_MED", subject: "Wettervorhersagen f\u{FC}r das westliche Mittelmeer")
        XCTAssertTrue(WinlinkCatalogTaxonomy.matches(record, query: "FUR DAS"))
    }

}
