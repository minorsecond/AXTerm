import XCTest
@testable import AXTerm

@MainActor
final class StationLocationTests: XCTestCase {

    // MARK: - Maidenhead encoding

    func testGridEncodingKnownLocations() {
        // W1AW, Newington CT.
        XCTAssertEqual(Maidenhead.gridSquare(latitude: 41.7147, longitude: -72.7272), "FN31pr")
        // Denver area.
        XCTAssertEqual(Maidenhead.gridSquare(latitude: 39.7392, longitude: -104.9903), "DM79mr")
        XCTAssertEqual(Maidenhead.gridSquare(latitude: 39.7392, longitude: -104.9903, length: 4), "DM79")
    }

    func testGridEncodingRoundTripsThroughCenter() {
        for grid in ["DM79lr", "FN31pr", "JO59jw", "RE78ir"] {
            let center = Maidenhead.center(of: grid)!
            XCTAssertEqual(
                Maidenhead.gridSquare(latitude: center.latitude, longitude: center.longitude)?.lowercased(),
                grid.lowercased(), grid)
        }
    }

    func testGridEncodingEdges() {
        XCTAssertNotNil(Maidenhead.gridSquare(latitude: 90, longitude: 180))
        XCTAssertNotNil(Maidenhead.gridSquare(latitude: -90, longitude: -180))
        XCTAssertNil(Maidenhead.gridSquare(latitude: 91, longitude: 0))
        XCTAssertNil(Maidenhead.gridSquare(latitude: 0, longitude: 0, length: 5))
        XCTAssertEqual(Maidenhead.gridSquare(latitude: 39.7392, longitude: -104.9903, length: 8)?.count, 8)
    }

    // MARK: - Formats (Winlink insertion-tag conventions)

    private let denver = StationLocation(
        latitude: 39.7392, longitude: -104.9903, gridSquare: "DM79lr",
        source: .gps, timestamp: Date(timeIntervalSince1970: 1_787_500_000))

    func testSignedDecimalFormat() {
        XCTAssertEqual(StationLocationFormat.signedDecimal(denver), "39.7392 -104.9903")
    }

    func testDecimalFormat() {
        XCTAssertEqual(StationLocationFormat.decimal(denver), "39.7392N 104.9903W")
    }

    func testDegreeMinuteFormat() {
        XCTAssertEqual(StationLocationFormat.degreeMinute(denver), "39-44.35N 104-59.42W")
    }

    func testStampFormat() {
        let stamp = StationLocationFormat.stamp(denver)
        XCTAssertTrue(stamp.hasPrefix("Position: 39.7392 -104.9903 (DM79lr) via GPS "), stamp)
        XCTAssertTrue(stamp.hasSuffix(" UTC"), stamp)
    }

    // MARK: - Service

    private struct MockGPS: GPSProviding {
        var result: Result<(latitude: Double, longitude: Double), GPSError>
        func requestOneShotFix(timeout: TimeInterval) async throws -> (latitude: Double, longitude: Double) {
            try result.get()
        }
    }

    func testServicePrefersGPS() async {
        let service = StationLocationService(
            gps: MockGPS(result: .success((39.7392, -104.9903))),
            manualGridProvider: { "FN31pr" },
            deviceLocationEnabled: { true },
            now: { Date(timeIntervalSince1970: 42) })
        let location = await service.currentLocation()

        XCTAssertEqual(location?.source, .gps)
        XCTAssertEqual(location?.gridSquare, "DM79mr", "grid derived from the fix, not the manual setting")
        XCTAssertEqual(service.lastLocation, location)
        XCTAssertNil(service.lastGPSError)
    }

    // MARK: - The device location switch (smoke run 2026-10-03-1, issue 31)

    /// Counts CoreLocation requests, so a test can say none were made.
    private final class RequestCountingGPS: GPSProviding, @unchecked Sendable {
        var requests = 0
        func requestOneShotFix(timeout: TimeInterval) async throws -> (latitude: Double, longitude: Double) {
            requests += 1
            return (39.7392, -104.9903)
        }
    }

    /// A Winlink session log stored a GPS fix, and a form sent one over the
    /// air, while "This device's location" was off. Every caller goes
    /// through this service, so the switch is honored here.
    func testWithDeviceLocationOffTheGridIsUsedAndGPSIsNotAsked() async {
        let gps = RequestCountingGPS()
        let service = StationLocationService(
            gps: gps, manualGridProvider: { "DM79po" },
            deviceLocationEnabled: { false },
            now: { Date(timeIntervalSince1970: 42) })

        let location = await service.currentLocation()
        XCTAssertEqual(location?.source, .manualGrid)
        XCTAssertEqual(gps.requests, 0)
        let recent = await service.recentLocation(within: 600)
        XCTAssertEqual(recent?.source, .manualGrid)
        XCTAssertEqual(gps.requests, 0)
    }

    /// A fix taken while the switch was on is not handed out once it is off.
    func testAFixHeldFromBeforeTheSwitchWentOffIsNotUsed() async {
        var enabled = true
        let service = StationLocationService(
            gps: RequestCountingGPS(), manualGridProvider: { "DM79po" },
            deviceLocationEnabled: { enabled },
            now: { Date(timeIntervalSince1970: 42) })
        let first = await service.currentLocation()
        XCTAssertEqual(first?.source, .gps)

        enabled = false
        XCTAssertEqual(service.lastLocation?.source, .manualGrid)
        let held = await service.currentLocation()
        XCTAssertEqual(held?.source, .manualGrid)
        let recent = await service.recentLocation(within: 600)
        XCTAssertEqual(recent?.source, .manualGrid)
    }

    func testServiceFallsBackToManualGrid() async {
        let service = StationLocationService(
            gps: MockGPS(result: .failure(.denied)),
            manualGridProvider: { "DM79po" },
            deviceLocationEnabled: { true },
            now: { Date(timeIntervalSince1970: 42) })
        let location = await service.currentLocation()

        XCTAssertEqual(location?.source, .manualGrid)
        XCTAssertEqual(location?.gridSquare, "DM79po")
        XCTAssertEqual(location!.latitude, Maidenhead.center(of: "DM79po")!.latitude, accuracy: 0.001)
        XCTAssertEqual(service.lastGPSError, .denied)
    }

    func testServiceNilWhenNothingAvailable() async {
        let service = StationLocationService(
            gps: MockGPS(result: .failure(.timeout)),
            manualGridProvider: { "" }, deviceLocationEnabled: { true })
        let location = await service.currentLocation()
        XCTAssertNil(location)
    }

    func testManualLocationSkipsGPS() async {
        let service = StationLocationService(
            gps: nil,
            manualGridProvider: { "DM79po" })
        XCTAssertEqual(service.manualLocation()?.source, .manualGrid)
    }

    // MARK: - Fix lifetime

    /// Counts CoreLocation round trips so the cache can be proven to absorb
    /// callers.
    private final class CountingGPS: GPSProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        var result: Result<(latitude: Double, longitude: Double), GPSError> =
            .success((39.7392, -104.9903))
        func requestOneShotFix(timeout: TimeInterval) async throws -> (latitude: Double, longitude: Double) {
            lock.withLock { _calls += 1 }
            return try result.get()
        }
    }

    /// Reference clock the tests can advance.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    /// The whole app reads through one fix: the map, the chip, Winlink
    /// field status and compose all call this freely, and each call used to
    /// be a live CoreLocation request.
    func testAFreshFixServesEveryCallerWithoutRereadingGPS() async {
        let gps = CountingGPS()
        let clock = Clock()
        let service = StationLocationService(
            gps: gps, manualGridProvider: { "" }, deviceLocationEnabled: { true }, now: { clock.now })

        _ = await service.currentLocation()
        clock.now += 60
        let second = await service.currentLocation()
        clock.now += 120
        let third = await service.currentLocation()

        XCTAssertEqual(gps.calls, 1, "one fix serves everyone inside the lifetime")
        XCTAssertEqual(second?.source, .gps)
        XCTAssertEqual(third?.timestamp, Date(timeIntervalSince1970: 1_000_000))
    }

    func testAnExpiredFixIsReRead() async {
        let gps = CountingGPS()
        let clock = Clock()
        let service = StationLocationService(
            gps: gps, manualGridProvider: { "" }, deviceLocationEnabled: { true }, now: { clock.now })

        _ = await service.currentLocation()
        clock.now += StationLocationService.gpsFixLifetime + 1
        let refreshed = await service.currentLocation()

        XCTAssertEqual(gps.calls, 2)
        XCTAssertEqual(refreshed?.timestamp, clock.now)
    }

    /// The settings pane's refresh is the one deliberate re-read.
    func testMaxFixAgeZeroForcesAReRead() async {
        let gps = CountingGPS()
        let clock = Clock()
        let service = StationLocationService(
            gps: gps, manualGridProvider: { "" }, deviceLocationEnabled: { true }, now: { clock.now })

        _ = await service.currentLocation()
        clock.now += 5
        _ = await service.currentLocation(maxFixAge: 0)
        XCTAssertEqual(gps.calls, 2)
    }

    /// A station with no GPS must not be re-interrogated once per caller —
    /// failure backs off on the same clock success does.
    func testAFailedAttemptIsNotRetriedFasterThanTheLifetime() async {
        let gps = CountingGPS()
        gps.result = .failure(.timeout)
        let clock = Clock()
        let service = StationLocationService(
            gps: gps, manualGridProvider: { "DM79po" }, deviceLocationEnabled: { true }, now: { clock.now })

        let first = await service.currentLocation()
        clock.now += 60
        let second = await service.currentLocation()

        XCTAssertEqual(gps.calls, 1, "the failure backs off; the fallback answers")
        XCTAssertEqual(first?.source, .manualGrid)
        XCTAssertEqual(second?.source, .manualGrid)

        clock.now += StationLocationService.gpsFixLifetime
        _ = await service.currentLocation()
        XCTAssertEqual(gps.calls, 2, "the backoff expires with the lifetime")
    }

    // MARK: - Profile

    func testProfileNameWithTitleAndContactBlock() async {
        let defaults = TestDefaults.make("StationProfileTests")
        let profile = StationProfile(defaults: defaults)
        XCTAssertEqual(profile.nameWithTitle, "")

        profile.realName = "Ross Wardrup"
        profile.positionTitle = "EC"
        profile.organization = "ARES District 3"
        profile.phone = "555-0100"
        profile.city = "Denver"
        profile.state = "CO"

        XCTAssertEqual(profile.nameWithTitle, "Ross Wardrup, EC")
        let block = profile.contactBlock
        XCTAssertTrue(block.contains("Ross Wardrup\r\n"), block)
        XCTAssertTrue(block.contains("Denver, CO"), block)

        // Values persist through a fresh instance on the same suite.
        let reloaded = StationProfile(defaults: defaults)
        XCTAssertEqual(reloaded.organization, "ARES District 3")
    }
}
