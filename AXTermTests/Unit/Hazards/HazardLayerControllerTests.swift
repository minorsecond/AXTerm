import XCTest
@testable import AXTerm

/// The controller the app ticks: it fetches only when the refresh rule
/// says so (`HazardRefreshPolicy`).
@MainActor
final class HazardLayerControllerTests: XCTestCase {
    private final class CountingFetcher: HazardFetching, @unchecked Sendable {
        var data = Data()
        private(set) var count = 0
        func data(for request: URLRequest) async throws -> Data {
            count += 1
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
}
