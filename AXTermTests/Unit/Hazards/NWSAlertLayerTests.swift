import Combine
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
        NWSAlertLayer(fetcher: fetcher, cache: HazardDiskCache(directory: directory), now: { [unowned self] in self.now },
                      sleep: { _ in })
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

        now = now.addingTimeInterval(HazardRefreshPolicy.interval)
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
        await relaunched.loadCached()
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

    // MARK: - Not getting throttled

    private final class Pauses: @unchecked Sendable {
        var taken: [TimeInterval] = []
    }

    private func pacedLayer(_ fetcher: FakeFetcher, maxZones: Int = 25, pauses: Pauses = Pauses()) -> NWSAlertLayer {
        NWSAlertLayer(fetcher: fetcher, cache: HazardDiskCache(directory: directory),
                      now: { [unowned self] in self.now },
                      maxZonesPerRefresh: maxZones, zonePause: 0.2,
                      sleep: { pauses.taken.append($0) })
    }

    /// Asked to slow down: nothing more for two minutes, then four, then
    /// eight; a success starts over.
    func testASlowDownPausesThenDoubles() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .failure(HazardFetchError.throttled(retryAfter: nil))
        let layer = pacedLayer(fetcher)
        await layer.refresh(near: home)
        XCTAssertEqual(fetcher.asked.count, 1)
        XCTAssertEqual(layer.pausedUntil, now.addingTimeInterval(120))

        now = now.addingTimeInterval(60)
        await layer.refresh(near: home)
        XCTAssertEqual(fetcher.asked.count, 1, "paused: no request")

        now = now.addingTimeInterval(61)
        await layer.refresh(near: home)
        XCTAssertEqual(fetcher.asked.count, 2)
        XCTAssertEqual(layer.pausedUntil, now.addingTimeInterval(240), "doubled")

        now = now.addingTimeInterval(241)
        fetcher.answers[alertsURL] = .success(try fixture("nws-alerts-polygon"))
        await layer.refresh(near: home)
        XCTAssertNil(layer.pausedUntil)
        XCTAssertNil(layer.problem)

        fetcher.answers[alertsURL] = .failure(HazardFetchError.throttled(retryAfter: nil))
        now = now.addingTimeInterval(HazardRefreshPolicy.interval)
        await layer.refresh(near: home)
        XCTAssertEqual(layer.pausedUntil, now.addingTimeInterval(120), "a success starts the doubling over")
    }

    func testTheServersRetryAfterIsHonored() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .failure(HazardFetchError.throttled(retryAfter: 600))
        let layer = pacedLayer(fetcher)
        await layer.refresh(near: home)
        XCTAssertEqual(layer.pausedUntil, now.addingTimeInterval(600))
        XCTAssertTrue(layer.problem?.contains("slow down") == true)
    }

    func testThePauseNeverPassesThirtyMinutes() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .failure(HazardFetchError.throttled(retryAfter: nil))
        let layer = pacedLayer(fetcher)
        for _ in 0..<10 {
            await layer.refresh(near: home)
            now = try XCTUnwrap(layer.pausedUntil).addingTimeInterval(1)
        }
        XCTAssertEqual(fetcher.asked.count, 10)
        await layer.refresh(near: home)
        let pause = try XCTUnwrap(layer.pausedUntil).timeIntervalSince(now)
        XCTAssertEqual(pause, 30 * 60, accuracy: 1)
    }

    /// A statewide storm can name a hundred zones. At most N new outlines per
    /// refresh, paced, and the rest on the next refresh.
    func testZoneOutlinesAreCappedPerRefreshAndPaced() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        let pauses = Pauses()
        let layer = pacedLayer(fetcher, maxZones: 10, pauses: pauses)
        await layer.refresh(near: home)
        XCTAssertEqual(fetcher.asked.count, 1 + 10)
        XCTAssertEqual(pauses.taken, Array(repeating: 0.2, count: 10), "a pause before each outline")
        XCTAssertNil(layer.features.first?.geometry, "not all its zones yet: listed, not drawn")
        XCTAssertEqual(layer.zonesStillLoading, 8)

        now = now.addingTimeInterval(HazardRefreshPolicy.interval)
        await layer.refresh(near: home)
        XCTAssertEqual(fetcher.asked.count, 1 + 10 + 1 + 8)
        XCTAssertNotNil(layer.features.first?.geometry)
        XCTAssertEqual(layer.zonesStillLoading, 0)
    }

    /// Told to slow down while fetching outlines: stop asking for them, and
    /// pause everything.
    func testASlowDownOnAZoneStopsTheZonesAndPauses() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers[alertsURL] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        fetcher.answers["https://api.weather.gov/zones/county/COC029"] = .failure(HazardFetchError.throttled(retryAfter: nil))
        let layer = pacedLayer(fetcher)
        await layer.refresh(near: home)
        XCTAssertEqual(fetcher.asked.count, 1 + 2, "the alerts, COC007, then COC029 refused")
        XCTAssertEqual(layer.pausedUntil, now.addingTimeInterval(120))
        XCTAssertEqual(layer.features.count, 1, "the alerts themselves are kept")
    }

    // MARK: - Zones and radius together

    /// Zones chosen: fetched by zone, everything kept.
    func testAZoneScopeFetchesByZone() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers["https://api.weather.gov/alerts/active?zone=COC007"] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        let layer = layer(fetcher)
        await layer.refresh(.zones(["COC007"]), at: nil)
        XCTAssertEqual(fetcher.asked.first, "https://api.weather.gov/alerts/active?zone=COC007")
        XCTAssertEqual(layer.features.count, 1)
    }

    /// A zone-based alert takes its zones' shape before the radius is
    /// judged: Archuleta County is about 200 miles from home, so it is
    /// dropped at 50 miles and kept at 300.
    func testARadiusJudgesAZoneBasedAlertByItsZones() async throws {
        for (miles, kept) in [(50.0, 0), (300.0, 1)] {
            let fetcher = FakeFetcher()
            let url = try XCTUnwrap(NWSAlertFeed.alertsRequest(.within(miles: miles), at: home)?.url?.absoluteString)
            fetcher.answers[url] = .success(try fixture("nws-alerts-zones"))
            try answerEveryZone(fetcher)
            try? FileManager.default.removeItem(at: directory)
            let layer = layer(fetcher)
            await layer.refresh(.within(miles: miles), at: home)
            XCTAssertEqual(layer.features.count, kept, "within \(miles) mi")
        }
    }

    /// The NWS refusing a request (HTTP 400 range) is not being offline:
    /// the caption said "Offline" when the area was the problem.
    func testARejectedRequestIsNotOffline() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers["https://api.weather.gov/alerts/active?area=CO"] = .failure(HazardFetchError.status(400))
        let layer = layer(fetcher)
        await layer.refresh(.states(["CO"]), at: nil)
        XCTAssertTrue(layer.requestRejected)
        XCTAssertTrue(layer.problem?.contains("did not accept") == true, layer.problem ?? "")
    }

    // MARK: - Counties before outlines

    /// Within 50 miles, the Western Slope outlook is ruled out by its
    /// counties, and none of its 18 zone outlines is downloaded. Live, 200
    /// miles cost 116 outline downloads, mostly for the Texas coast.
    func testAFarAlertIsRuledOutByItsCountiesWithoutFetchingOutlines() async throws {
        let fetcher = FakeFetcher()
        let url = try XCTUnwrap(NWSAlertFeed.alertsRequest(.within(miles: 50), at: home)?.url?.absoluteString)
        fetcher.answers[url] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        let layer = NWSAlertLayer(fetcher: fetcher, cache: HazardDiskCache(directory: directory),
                                  now: { [unowned self] in self.now }, counties: CountyCenters.bundled,
                                  sleep: { _ in })
        await layer.refresh(.within(miles: 50), at: home)
        XCTAssertEqual(fetcher.asked, [url], "no outlines for an alert its counties rule out")
        XCTAssertTrue(layer.features.isEmpty)
        XCTAssertEqual(layer.unplacedCount, 0)
        XCTAssertEqual(layer.zonesStillLoading, 0)
    }

    /// Counties chosen: the state is fetched, and an alert naming none of
    /// the chosen counties is dropped before its outlines are downloaded.
    /// The Western Slope outlook covers Archuleta, not Arapahoe.
    func testACountyScopeSkipsOutlinesForOtherCounties() async throws {
        let fetcher = FakeFetcher()
        let url = "https://api.weather.gov/alerts/active?area=CO"
        fetcher.answers[url] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        let layer = layer(fetcher)
        await layer.refresh(.counties(["08005"]), at: nil)
        XCTAssertEqual(fetcher.asked, [url], "no outlines for another county's alert")
        XCTAssertTrue(layer.features.isEmpty)

        let archuleta = FakeFetcher()
        archuleta.answers[url] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(archuleta)
        try? FileManager.default.removeItem(at: directory)
        let kept = self.layer(archuleta)
        await kept.refresh(.counties(["08007"]), at: nil)
        XCTAssertEqual(kept.features.count, 1)
    }

    // MARK: - Not fetching again for a setting change

    /// Switching from a state to one of its counties asks for the same
    /// thing: answered from the copy fetched a moment ago.
    func testTheSameRequestMomentsLaterIsNotFetchedAgain() async throws {
        let fetcher = FakeFetcher()
        let url = "https://api.weather.gov/alerts/active?area=CO"
        fetcher.answers[url] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        let layer = layer(fetcher)
        await layer.refresh(.states(["CO"]), at: nil)
        now = now.addingTimeInterval(30)
        await layer.refresh(.counties(["08007"]), at: nil)
        XCTAssertEqual(fetcher.asked.filter { $0 == url }.count, 1)
        XCTAssertEqual(layer.features.count, 1)
    }

    /// A wider area fetched moments ago serves a narrower one, trimmed to
    /// the states asked for: Colorado and Wyoming, then Wyoming alone.
    func testAWiderAreaServesANarrowerOne() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers["https://api.weather.gov/alerts/active?area=CO,WY"] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        let layer = layer(fetcher)
        await layer.refresh(.states(["CO", "WY"]), at: nil)
        XCTAssertEqual(layer.features.count, 1)
        let asked = fetcher.asked.count
        now = now.addingTimeInterval(30)
        await layer.refresh(.states(["WY"]), at: nil)
        XCTAssertEqual(fetcher.asked.count, asked, "no new request")
        XCTAssertTrue(layer.features.isEmpty, "the Colorado outlook is not Wyoming's")
    }

    /// Past the reuse window it is fetched again: the copy is for setting
    /// changes, not a way around the refresh.
    func testAnOldCopyIsFetchedAgain() async throws {
        let fetcher = FakeFetcher()
        let url = "https://api.weather.gov/alerts/active?area=CO"
        fetcher.answers[url] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        let layer = layer(fetcher)
        await layer.refresh(.states(["CO"]), at: nil)
        now = now.addingTimeInterval(NWSAlertLayer.reuseWindow + 1)
        await layer.refresh(.states(["CO"]), at: nil)
        XCTAssertEqual(fetcher.asked.filter { $0 == url }.count, 2)
    }

    // MARK: - Saying what it is doing

    /// While it works, the layer says what it is doing: the alerts, then
    /// each outline, then nothing once done.
    func testTheLayerSaysWhatItIsDoing() async throws {
        let fetcher = FakeFetcher()
        fetcher.answers["https://api.weather.gov/alerts/active?zone=COC007"] = .success(try fixture("nws-alerts-zones"))
        try answerEveryZone(fetcher)
        let layer = layer(fetcher)
        var seen: [NWSAlertLayer.Activity?] = []
        let watching = layer.$activity.sink { seen.append($0) }
        await layer.refresh(.zones(["COC007"]), at: nil)
        watching.cancel()
        XCTAssertEqual(seen.first ?? nil, nil)
        XCTAssertTrue(seen.contains(.fetchingAlerts))
        XCTAssertTrue(seen.contains(.loadingOutlines(done: 0, total: 18)))
        XCTAssertTrue(seen.contains(.loadingOutlines(done: 17, total: 18)))
        XCTAssertEqual(seen.last ?? .fetchingAlerts, nil)
        XCTAssertNil(layer.activity)
    }
}
