import XCTest
@testable import AXTerm

/// The layer catalog behind the sidebar's collapsed summary.
///
/// A collapsed group that miscounts is worse than no summary: it is the only
/// thing standing in for the rows it hides.
final class MapLayerCatalogTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "MapLayerCatalogTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    func testEachFamilySeesOnlyItsOwnLayers() {
        let aprs = MapLayerCatalog.layers(in: .families([.aprs]))
        let ax25 = MapLayerCatalog.layers(in: .families([.ax25]))

        XCTAssertTrue(aprs.allSatisfy { $0.family == .aprs })
        XCTAssertTrue(ax25.allSatisfy { $0.family == .ax25 })
        XCTAssertTrue(aprs.contains { $0.title == "Transmitted Positions" })
        XCTAssertTrue(ax25.contains { $0.title == "Observed Paths" })
        XCTAssertFalse(
            ax25.contains { $0.title == "Transmitted Positions" },
            "a packet channel's stations never beacon a position")
    }

    /// Both families have a layer called "Coverage Rings" and they are
    /// different layers measuring different evidence. Collapsing them onto one
    /// key would tie the two radios' rings together.
    func testTheTwoCoverageRingsAreSeparateLayers() {
        let aprs = MapLayerCatalog.layers(in: .families([.aprs]))
            .first { $0.title == "Coverage Rings" }
        let ax25 = MapLayerCatalog.layers(in: .families([.ax25]))
            .first { $0.title == "Coverage Rings" }

        XCTAssertNotNil(aprs)
        XCTAssertNotNil(ax25)
        XCTAssertNotEqual(aprs?.storageKey, ax25?.storageKey)
    }

    func testAnUntouchedInstallIsSummarisedFromTheDefaults() {
        let summary = MapLayerCatalog.summary(in: .families([.ax25]), defaults: defaults)

        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.on, 1, "only Coverage Rings is on out of the box")
    }

    func testTheSummaryFollowsWhatTheOperatorSet() {
        defaults.set(true, forKey: "stations.showsPaths")
        defaults.set(false, forKey: "stations.showsCoverageRing")

        let summary = MapLayerCatalog.summary(in: .families([.ax25]), defaults: defaults)

        XCTAssertEqual(summary.on, 1)
        XCTAssertEqual(
            MapLayerCatalog.summaryText(in: .families([.ax25]), defaults: defaults),
            "1 of 4 on")
    }

    func testAScopeWithNoLayersSaysSo() {
        XCTAssertEqual(
            MapLayerCatalog.summaryText(in: .families([]), defaults: defaults),
            "No layers")
    }
}
