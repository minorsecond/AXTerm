import GRDB
import XCTest
@testable import AXTerm

/// The NWS layer's fetching and its last good copy (Docs/HazardLayers.md
/// §1, §4): with no connection the map keeps the last alerts, says they are
/// stale, and never passes them off as current.
@MainActor
final class NWSAlertLayerTests: XCTestCase {

    /// Answers by URL and records what was asked.
    private final class FakeFetcher: HazardFetching, @unchecked Sendable {
        var answers: [String: Result<Data, Error>] = [:]
        private(set) var asked: [String] = []
        func data(for request: URLRequest) async throws -> Data {
            let url = request.url?.absoluteString ?? ""
            asked.append(url)
            guard let answer = answers[url] else { throw URLError(.notConnectedToInternet) }
            return try answer.get()
        }
    }

    private let home = GreatCircle.Point(latitude: 39.6123, longitude: -104.7332)
    private let alertsURL = "https://api.weather.gov/alerts/active?point=39.6123,-104.7332"
    private var now = Date(timeIntervalSince1970: 1_791_590_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hazard-cache-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: NWSAlertLayerTests.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func layer(_ fetcher: FakeFetcher) -> NWSAlertLayer {
        NWSAlertLayer(fetcher: fetcher, cache: HazardDiskCache(directory: directory), now: { [unowned self] in self.now })
    }

    /// The zone fixture's 18 zones, all answered with Archuleta's outline.
    private func answerEveryZone(_ fetcher: FakeFetcher) throws {
        let outlook = try XCTUnwrap(try NWSAlertFeed.parse(try fixture("nws-alerts-zones"), fetchedAt: now).first)
        for url in NWSAlertFeed.zoneURLs(of: outlook) {
            fetcher.answers[url.absoluteString] = .success(try fixture("nws-zone-COC007"))
        }
    }

    func testARefreshDrawsTheAlertsAndRecordsWhen() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .success(try fixture("nws-alerts-polygon"))
        let layer = layer(fetcher)
        await layer.refresh(near: home)
        XCTAssertEqual(layer.features.map(\.event), ["Tropical Storm Warning"])
        XCTAssertEqual(layer.lastFetched, now)
        XCTAssertNil(layer.problem)
        XCTAssertFalse(layer.isStale)
    }

    func testZoneOutlinesAreFetchedOnceAndKept() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        let first = layer(fetcher)
        await first.refresh(near: home)
        XCTAssertNotNil(first.features.first?.geometry, "every zone known: drawn")
        XCTAssertEqual(fetcher.asked.count, 1 + 18)

        await first.refresh(near: home)
        XCTAssertEqual(fetcher.asked.count, 1 + 18 + 1, "the second refresh asks for the alerts only")

        let relaunched = layer(fetcher)
        await relaunched.refresh(near: home)
        XCTAssertEqual(fetcher.asked.count, 1 + 18 + 1 + 1, "and so does a relaunch: the outlines are on disk")
    }

    /// No connection: the last alerts stay, the problem is said, and after
    /// ten minutes without a good fetch they are marked stale.
    func testAFailedRefreshKeepsTheLastAlertsAndSaysSo() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .success(try fixture("nws-alerts-polygon"))
        let layer = layer(fetcher)
        await layer.refresh(near: home)
        let fetched = now

        fetcher.answers[alertsURL] = .failure(URLError(.notConnectedToInternet))
        now = now.addingTimeInterval(11 * 60)
        await layer.refresh(near: home)
        XCTAssertEqual(layer.features.map(\.event), ["Tropical Storm Warning"])
        XCTAssertEqual(layer.lastFetched, fetched)
        XCTAssertNotNil(layer.problem)
        XCTAssertTrue(layer.isStale)
    }

    /// A relaunch with no connection shows the saved alerts at their real age.
    func testARelaunchShowsTheSavedAlertsAtTheirRealAge() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .success(try fixture("nws-alerts-polygon"))
        await layer(fetcher).refresh(near: home)
        let fetched = now

        now = now.addingTimeInterval(3600)
        let relaunched = layer(FakeFetcher())
        relaunched.loadCached()
        XCTAssertEqual(relaunched.features.map(\.event), ["Tropical Storm Warning"])
        XCTAssertEqual(relaunched.lastFetched, fetched)
        XCTAssertEqual(relaunched.features.first?.fetchedAt, fetched)
        XCTAssertTrue(relaunched.isStale)
    }

    /// One zone that will not load leaves its own product undrawn and the
    /// rest of the layer alone.
    func testAZoneThatFailsLeavesOnlyItsProductUndrawn() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        fetcher.answers["https://api.weather.gov/zones/county/COC007"] = .failure(URLError(.timedOut))
        let layer = layer(fetcher)
        await layer.refresh(near: home)
        XCTAssertEqual(layer.features.count, 1, "the product is still listed")
        XCTAssertNil(layer.features.first?.geometry, "but not drawn with a zone missing")
        XCTAssertEqual(layer.lastFetched, now, "the alerts themselves were fetched")
    }

    // MARK: - History (§8)

    /// Every good fetch goes into history, recorded from the start so
    /// nothing fetched before the time slider exists is lost.
    func testAGoodRefreshIsRecordedInHistoryAndAFailedOneIsNot() async throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue)
        let history = SQLiteHazardHistoryStore(dbQueue: queue)
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .success(try fixture("nws-alerts-polygon"))
        let layer = NWSAlertLayer(fetcher: fetcher, cache: HazardDiskCache(directory: directory),
                                  history: history, now: { [unowned self] in self.now })
        await layer.refresh(near: home)
        let id = try XCTUnwrap(layer.features.first?.id)
        XCTAssertEqual(try history.versions(of: id).count, 1)

        fetcher.answers[alertsURL] = .failure(URLError(.notConnectedToInternet))
        now = now.addingTimeInterval(300)
        await layer.refresh(near: home)
        XCTAssertEqual(try history.versions(of: id).first?.lastSeen, layer.lastFetched,
                       "a failed fetch is not a sighting")
    }

    // MARK: - Scopes

    /// Chosen states: fetched by state, with no position needed.
    func testAStateScopeFetchesByStateWithoutAPosition() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers["https://api.weather.gov/alerts/active?area=CO"] = .success(try fixture("nws-alerts-polygon"))
        let layer = layer(fetcher)
        await layer.refresh(.states(["CO"]), at: nil)
        XCTAssertEqual(fetcher.asked, ["https://api.weather.gov/alerts/active?area=CO"])
        XCTAssertEqual(layer.features.count, 1)
    }

    /// Within a radius: only what comes within it is kept. The fixture's
    /// warning is in Alabama, far outside 50 miles of home.
    func testARadiusKeepsOnlyWhatIsWithinIt() async throws {
        let fetcher = FakeFetcher()
        let url = try XCTUnwrap(NWSAlertFeed.alertsRequest(.within(miles: 50), at: home)?.url?.absoluteString)
        fetcher.answers[url] = .success(try fixture("nws-alerts-polygon"))
        let layer = layer(fetcher)
        await layer.refresh(.within(miles: 50), at: home)
        XCTAssertEqual(fetcher.asked, [url])
        XCTAssertTrue(layer.features.isEmpty)
        XCTAssertEqual(layer.lastFetched, now, "fetched, and nothing was near")
    }
}
