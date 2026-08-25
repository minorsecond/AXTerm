import XCTest
@testable import AXTerm

/// Category codes and InquiryIds here are verbatim from the 2026-08-24
/// catalog capture.
final class WinlinkOutageKitTests: XCTestCase {

    private func item(_ id: String,
                      category: String,
                      size: Int = 1000,
                      enabled: Bool = true) -> WinlinkCatalogItemRecord {
        WinlinkCatalogItemRecord(
            inquiryId: id, category: category, subject: "Subject \(id)", url: "",
            lifetimeDays: 0, sizeEstimate: size, enabled: enabled,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// The real ARES/RACES and HF-net products from the capture.
    private var plans: [WinlinkCatalogItemRecord] {
        [
            item("FL_AUX", category: "ARES_RACES", size: 614),
            item("FL_P2P_NET", category: "ARES_RACES", size: 6072),
            item("TX_D16_RACES", category: "ARES_RACES", size: 1698),
            item("TX_MOCO_ARES", category: "ARES_RACES", size: 1441),
            item("TX_RACES", category: "ARES_RACES", size: 767),
            item("HF_NETS", category: "HF_NETS", size: 4928),
        ]
    }

    // MARK: - What gets staged

    /// Frequency plans and net schedules are the whole point: they tell
    /// you where to find other stations with no infrastructure, and they
    /// are useless to request once it is gone.
    func testEveryOperatingPlanIsStaged() {
        let kit = WinlinkOutageKit.build(items: plans, state: "CO")
        XCTAssertEqual(kit.count, 6)
        XCTAssertTrue(kit.allSatisfy { $0.reason == .operatingPlan })
    }

    func testNamedReferenceAndPropagationProductsAreStaged() {
        let kit = WinlinkOutageKit.build(items: [
            item("WL2K.DISC", category: "WL2K_HELP", size: 2973),
            item("CUSTOM.GRIB", category: "WL2K_HELP", size: 4943),
            item("PROP_WWV", category: "PROPAGATION", size: 482),
        ], state: "CO")
        XCTAssertEqual(Set(kit.map(\.item.inquiryId)),
                       ["WL2K.DISC", "CUSTOM.GRIB", "PROP_WWV"])
    }

    /// `WL2K_HELP` holds 20 documents. Staging all of them would cost
    /// more airtime than the plans that matter, so only named ones ride.
    func testUnnamedHelpDocumentsAreNotStaged() {
        let kit = WinlinkOutageKit.build(items: [
            item("WL2K.DISC", category: "WL2K_HELP"),
            item("MAXSAEA_GRIB", category: "WL2K_HELP"),
            item("SOME.OTHER.HELP", category: "WL2K_HELP"),
        ], state: "CO")
        XCTAssertEqual(kit.map(\.item.inquiryId), ["WL2K.DISC"])
    }

    // MARK: - Local weather

    func testLocalWeatherFollowsTheOperatorsState() {
        let items = [
            item("CO_ZON_DENVER", category: "WX_US_CO"),
            item("TX_ZON_AUSTIN", category: "WX_US_TX"),
        ]
        let kit = WinlinkOutageKit.build(items: items, state: "CO")
        XCTAssertEqual(kit.map(\.item.inquiryId), ["CO_ZON_DENVER"])
    }

    /// Better to stage nothing than another state's forecasts.
    func testNoStateMeansNoLocalWeather() {
        let kit = WinlinkOutageKit.build(items: [
            item("CO_ZON_DENVER", category: "WX_US_CO"),
        ], state: "  ")
        XCTAssertTrue(kit.isEmpty)
    }

    /// Forecasts go stale in hours; an operator staging for a long
    /// outage can leave them out and keep the durable documents.
    func testLocalWeatherCanBeDeclinedWithoutLosingThePlans() {
        let items = plans + [item("CO_ZON_DENVER", category: "WX_US_CO")]
        let kit = WinlinkOutageKit.build(items: items, state: "CO", includeLocalWeather: false)
        XCTAssertFalse(kit.contains { $0.reason == .localWeather })
        XCTAssertEqual(kit.filter { $0.reason == .operatingPlan }.count, 6)
    }

    func testStateMatchingIsCaseInsensitive() {
        let kit = WinlinkOutageKit.build(items: [
            item("CO_ZON_DENVER", category: "wx_us_co"),
        ], state: "co")
        XCTAssertEqual(kit.count, 1)
    }

    // MARK: - What stays out

    /// The 161-product radar category is exactly what must not be
    /// staged: enormous, and perishable within the hour.
    func testBulkWeatherCategoriesAreNotStaged() {
        let items = (0..<20).map { item("RAD\($0)", category: "WX_US_RAD", size: 50_000) }
        XCTAssertTrue(WinlinkOutageKit.build(items: items, state: "CO").isEmpty)
    }

    func testDisabledProductsAreNotStaged() {
        let kit = WinlinkOutageKit.build(items: [
            item("FL_AUX", category: "ARES_RACES", enabled: false),
        ], state: "CO")
        XCTAssertTrue(kit.isEmpty)
    }

    // MARK: - Ordering and totals

    /// Two operators staging from the same index must queue the same
    /// request, and the most load-bearing documents come first.
    func testKitIsDeterministicAndOrderedByReason() {
        let items = [
            item("CO_ZON_DENVER", category: "WX_US_CO"),
            item("PROP_WWV", category: "PROPAGATION"),
            item("WL2K.DISC", category: "WL2K_HELP"),
            item("FL_AUX", category: "ARES_RACES"),
        ]
        let forward = WinlinkOutageKit.build(items: items, state: "CO")
        let reversed = WinlinkOutageKit.build(items: items.reversed(), state: "CO")
        XCTAssertEqual(forward.map(\.item.inquiryId), reversed.map(\.item.inquiryId))
        XCTAssertEqual(forward.map(\.reason),
                       [.operatingPlan, .reference, .propagation, .localWeather])
    }

    /// The whole kit has to be affordable, or an operator will not run
    /// it. The real ARES/RACES + HF-net set is about 15 kB.
    func testTotalBytesIsTheSumOfTheKit() {
        let kit = WinlinkOutageKit.build(items: plans, state: "")
        XCTAssertEqual(WinlinkOutageKit.totalBytes(kit), 15_520)
    }

    func testGroupingReturnsReasonsInPriorityOrder() {
        let items = [
            item("CO_ZON_DENVER", category: "WX_US_CO"),
            item("FL_AUX", category: "ARES_RACES"),
        ]
        let groups = WinlinkOutageKit.grouped(WinlinkOutageKit.build(items: items, state: "CO"))
        XCTAssertEqual(groups.map(\.reason), [.operatingPlan, .localWeather])
        XCTAssertEqual(groups.first?.items.count, 1)
    }
}
