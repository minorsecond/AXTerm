import Combine
import GRDB
import XCTest
@testable import AXTerm

/// The controller the app ticks: it fetches only when the refresh rule
/// says so (`HazardRefreshPolicy`).
@MainActor
final class HazardLayerControllerTests: XCTestCase {
    private final class CountingFetcher: HazardFetching, @unchecked Sendable {
        var data = Data()
        private(set) var count = 0
        private(set) var lastURL: String?
        func data(for request: URLRequest) async throws -> Data {
            count += 1
            lastURL = request.url?.absoluteString
            return data
        }
    }

    private var now = Date(timeIntervalSince1970: 1_791_576_000)
    private let home = GreatCircle.Point(latitude: 39.6123, longitude: -104.7332)
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hazard-controller-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func controller(_ fetcher: CountingFetcher) throws -> HazardLayerController {
        let url = try XCTUnwrap(Bundle(for: HazardLayerControllerTests.self)
            .url(forResource: "nws-alerts-polygon", withExtension: "json"))
        fetcher.data = try Data(contentsOf: url)
        let layer = NWSAlertLayer(fetcher: fetcher, cache: HazardDiskCache(directory: directory),
                                  now: { [unowned self] in self.now })
        return HazardLayerController(nws: layer, now: { [unowned self] in self.now })
    }

    func testOffFetchesNothing() async throws {
        let fetcher = CountingFetcher()
        let controller = try controller(fetcher)
        await controller.tick(nwsEnabled: false, position: home)
        XCTAssertEqual(fetcher.count, 0)
    }

    func testOnFetchesThenWaitsTwoMinutes() async throws {
        let fetcher = CountingFetcher()
        let controller = try controller(fetcher)
        await controller.tick(nwsEnabled: true, position: home)
        XCTAssertEqual(fetcher.count, 1)
        XCTAssertEqual(controller.nws.features.count, 1)
        now = now.addingTimeInterval(60)
        await controller.tick(nwsEnabled: true, position: home)
        XCTAssertEqual(fetcher.count, 1)
        now = now.addingTimeInterval(61)
        await controller.tick(nwsEnabled: true, position: home)
        XCTAssertEqual(fetcher.count, 2)
    }

    /// Turned off, the alerts leave the map; the last copy stays on disk.
    func testTurningItOffClearsTheMap() async throws {
        let fetcher = CountingFetcher()
        let controller = try controller(fetcher)
        await controller.tick(nwsEnabled: true, position: home)
        await controller.tick(nwsEnabled: false, position: home)
        XCTAssertTrue(controller.drawnFeatures.isEmpty)
        await controller.tick(nwsEnabled: true, position: home)
        XCTAssertEqual(controller.drawnFeatures.count, 1)
    }

    /// The caption under the switch: nothing while off, the count and age
    /// once on.
    func testTheCaptionFollowsTheSwitch() async throws {
        let controller = try controller(CountingFetcher())
        XCTAssertNil(controller.nwsCaption(now: now))
        await controller.tick(nwsEnabled: true, position: home)
        XCTAssertEqual(controller.nwsCaption(now: now), "1 alert · fetched just now")
        await controller.tick(nwsEnabled: false, position: home)
        XCTAssertNil(controller.nwsCaption(now: now))
    }

    /// The area choice reaches the fetch, and a change fetches at once.
    func testTheAreaChoiceReachesTheFetchAndAChangeFetchesAtOnce() async throws {
        let fetcher = CountingFetcher()
        let controller = try controller(fetcher)
        await controller.tick(nwsEnabled: true, scope: .here, position: home)
        XCTAssertEqual(fetcher.count, 1)
        now = now.addingTimeInterval(10)
        await controller.tick(nwsEnabled: true, scope: .states(["CO"]), position: home)
        XCTAssertEqual(fetcher.count, 2, "a new area fetches without waiting")
        XCTAssertEqual(fetcher.lastURL, "https://api.weather.gov/alerts/active?area=CO")
    }

    /// A new distance applies at once, from the copy fetched moments ago
    /// when it covers the same states (operator, 2026-10-09: "we should
    /// cache so we don't have to refetch every time a user changes a
    /// setting"). It used to fetch again.
    func testChangingTheDistanceAppliesAtOnceWithoutFetchingAgain() async throws {
        let fetcher = CountingFetcher()
        let controller = try controller(fetcher)
        await controller.tick(nwsEnabled: true, scope: .within(miles: 25), position: home)
        now = now.addingTimeInterval(10)
        await controller.tick(nwsEnabled: true, scope: .within(miles: 50), position: home)
        XCTAssertEqual(fetcher.count, 1)
    }

    /// The caption follows the layer as it works, not only after each tick.
    func testTheCaptionFollowsAFetchAsItHappens() async throws {
        let controller = try controller(CountingFetcher())
        let status = MapLayerStatus()
        controller.watch(status: status)
        var captions: [String?] = []
        let watching = status.$nwsCaption.sink { captions.append($0) }
        await controller.tick(nwsEnabled: true, position: home)
        let settled = expectation(description: "caption settles")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        watching.cancel()
        XCTAssertTrue(captions.contains("Fetching alerts…"), "\(captions)")
        XCTAssertTrue(status.nwsCaption?.hasPrefix("1 alert") == true, status.nwsCaption ?? "nil")
    }

    /// A change to the layer's settings wakes the loop rather than waiting
    /// out its 15 seconds.
    func testASettingChangeWakesTheLoop() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: TestDefaults.name("hazard-wake")))
        let started = Date()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            defaults.set("states:CO", forKey: NWSAlertScope.storageKey)
        }
        await HazardLayerController.waitForNextTick(seconds: 10, defaults: defaults)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// States need no position, end to end.
    func testStatesFetchWithNoPosition() async throws {
        let fetcher = CountingFetcher()
        let controller = try controller(fetcher)
        await controller.tick(nwsEnabled: true, scope: .states(["CO"]), position: nil)
        XCTAssertEqual(fetcher.lastURL, "https://api.weather.gov/alerts/active?area=CO")
        XCTAssertEqual(controller.drawnFeatures.count, 1)
    }

    /// History is recorded through the app's own controller into a real
    /// database: what was fetched is there afterward.
    func testAFetchLandsInHistory() async throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue)
        let history = SQLiteHazardHistoryStore(dbQueue: queue)
        let fetcher = CountingFetcher()
        let url = try XCTUnwrap(Bundle(for: HazardLayerControllerTests.self)
            .url(forResource: "nws-alerts-polygon", withExtension: "json"))
        fetcher.data = try Data(contentsOf: url)
        let layer = NWSAlertLayer(fetcher: fetcher, cache: HazardDiskCache(directory: directory), history: history,
                                  now: { [unowned self] in self.now }, sleep: { _ in })
        let controller = HazardLayerController(nws: layer, now: { [unowned self] in self.now })
        await controller.tick(nwsEnabled: true, position: home)
        let id = try XCTUnwrap(controller.drawnFeatures.first?.id)
        XCTAssertEqual(try history.versions(of: id).count, 1)
        XCTAssertEqual(try history.inEffect(at: now).map(\.id), [id])
    }

    // MARK: - The position it fetches for

    /// The position is read from its sources each time, never through a
    /// copy of a view. On 2026-10-09 Station C moved its exact coordinate
    /// from Colorado to Alabama and kept fetching Colorado's alerts.
    func testThePositionFollowsAChangeMadeAfterTheLoopStarted() throws {
        let defaults = TestDefaults.make("hazard-position")
        defaults.set("39.6123", forKey: StationPositionKeys.manualLatitude)
        defaults.set("-104.7332", forKey: StationPositionKeys.manualLongitude)
        let position = HazardLayerController.livePosition(defaults: defaults, deviceLocation: { nil })
        XCTAssertEqual(try XCTUnwrap(position()).latitude, 39.6123, accuracy: 1e-6)

        defaults.set("31.4920", forKey: StationPositionKeys.manualLatitude)
        defaults.set("-87.4139", forKey: StationPositionKeys.manualLongitude)
        let moved = try XCTUnwrap(position())
        XCTAssertEqual(moved.latitude, 31.4920, accuracy: 1e-6)
        XCTAssertEqual(moved.longitude, -87.4139, accuracy: 1e-6)
    }

    // MARK: - Where the last copy is kept

    /// A normal install keeps it in Application Support; a test-mode
    /// instance keeps its own, apart from the operator's install and from
    /// other instances, like the rest of test mode.
    func testTheCacheFolderIsKeptApartInTestMode() {
        let support = URL(fileURLWithPath: "/Support")
        let temporary = URL(fileURLWithPath: "/Temp")
        XCTAssertEqual(HazardLayerController.cacheDirectory(testInstance: nil, applicationSupport: support,
                                                           temporary: temporary).path,
                       "/Support/AXTerm/Hazards")
        XCTAssertEqual(HazardLayerController.cacheDirectory(testInstance: "Station A", applicationSupport: support,
                                                           temporary: temporary).path,
                       "/Temp/AXTerm-Test/hazards-Station_A")
    }
}
