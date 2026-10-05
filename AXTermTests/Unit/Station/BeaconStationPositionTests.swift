//
//  BeaconStationPositionTests.swift
//  AXTermTests
//
//  An APRS position beacon that follows the station goes out from the
//  position the map draws, through the one resolver: the exact coordinate
//  when set, else this device's fix when that is switched on, else the grid
//  center. It used to read the device's last location or the grid center
//  and ignore the exact coordinate, and on iOS nothing was wired at all.
//

import XCTest
@testable import AXTerm

@MainActor
final class BeaconStationPositionTests: XCTestCase {

    private struct FixedGPS: GPSProviding {
        var result: Result<(latitude: Double, longitude: Double), GPSError>
        func requestOneShotFix(timeout: TimeInterval) async throws -> (latitude: Double, longitude: Double) {
            try result.get()
        }
    }

    private func defaults(grid: String = "", lat: String = "", lon: String = "",
                          useDevice: Bool = false) -> UserDefaults {
        let defaults = TestDefaults.make("BeaconStationPosition")
        defaults.set(grid, forKey: WinlinkSettings.gridSquareKey)
        defaults.set(lat, forKey: StationPositionKeys.manualLatitude)
        defaults.set(lon, forKey: StationPositionKeys.manualLongitude)
        defaults.set(useDevice, forKey: StationPositionKeys.useDeviceLocation)
        return defaults
    }

    private func gpsService(_ lat: Double, _ lon: Double) async -> StationLocationService {
        let service = StationLocationService(gps: FixedGPS(result: .success((lat, lon))),
                                             manualGridProvider: { "" },
                                             deviceLocationEnabled: { true })
        _ = await service.currentLocation()
        return service
    }

    func testTheExactCoordinateBeatsTheGridSquare() {
        let provider = StationPositionResolver.beaconProvider(
            defaults: defaults(grid: "DM79lr", lat: "39.61", lon: "-105.01"), locationService: nil)
        let position = provider()
        XCTAssertEqual(position?.latitude ?? 0, 39.61, accuracy: 1e-9)
        XCTAssertEqual(position?.longitude ?? 0, -105.01, accuracy: 1e-9)
    }

    func testTheGridCentreIsTheLastResort() throws {
        let provider = StationPositionResolver.beaconProvider(
            defaults: defaults(grid: "DM79lr"), locationService: nil)
        let centre = try XCTUnwrap(Maidenhead.center(of: "DM79lr"))
        let position = try XCTUnwrap(provider())
        XCTAssertEqual(position.latitude, centre.latitude, accuracy: 1e-9)
        XCTAssertEqual(position.longitude, centre.longitude, accuracy: 1e-9)
    }

    func testNothingSetIsNoPosition() {
        let provider = StationPositionResolver.beaconProvider(defaults: defaults(), locationService: nil)
        XCTAssertNil(provider())
    }

    func testTheDeviceFixIsUsedOnlyWhenSwitchedOn() async throws {
        let service = await gpsService(40.0, -104.0)
        let off = StationPositionResolver.beaconProvider(
            defaults: defaults(grid: "DM79lr"), locationService: service)
        let offPosition = try XCTUnwrap(off())
        XCTAssertNotEqual(offPosition.latitude, 40.0, "the device is not the station unless you say so")

        let on = StationPositionResolver.beaconProvider(
            defaults: defaults(grid: "DM79lr", useDevice: true), locationService: service)
        let onPosition = try XCTUnwrap(on())
        XCTAssertEqual(onPosition.latitude, 40.0, accuracy: 1e-9)
        XCTAssertEqual(onPosition.longitude, -104.0, accuracy: 1e-9)
    }

    /// The same answer the map gets from the same settings.
    func testTheBeaconAndTheMapAgree() async throws {
        let service = await gpsService(40.0, -104.0)
        let stored = defaults(grid: "DM79lr", lat: "39.61", lon: "-105.01", useDevice: true)
        let map = try XCTUnwrap(StationPositionResolver.ownStation(
            gridSquare: "DM79lr", manualLatitude: "39.61", manualLongitude: "-105.01",
            usesDeviceLocation: true, deviceLocation: service.lastLocation))
        let beacon = try XCTUnwrap(StationPositionResolver.beaconProvider(
            defaults: stored, locationService: service)())
        XCTAssertEqual(beacon.latitude, map.point.latitude, accuracy: 1e-9)
        XCTAssertEqual(beacon.longitude, map.point.longitude, accuracy: 1e-9)
    }

    // MARK: - The coordinator uses it

    private func aprsRadio(in settings: AppSettingsStore, _ config: APRSPositionConfig?) -> RadioID {
        let id = settings.radios[0].id
        settings.updateRadio(id) {
            $0.enabled = true
            $0.aprsEnabled = true
            $0.beacon.enabled = true
            $0.beacon.kind = .aprsPosition
            $0.beacon.aprs = config
            $0.aprsPath = ""
        }
        return id
    }

    func testABeaconFollowingTheStationNeedsAStationPosition() {
        let settings = AppSettingsStore(defaults: TestDefaults.make("BeaconFollowsStation"))
        let id = aprsRadio(in: settings, .followingStation)
        let coordinator = SessionCoordinator()

        coordinator.aprsLocationProvider = StationPositionResolver.beaconProvider(
            defaults: defaults(), locationService: nil)
        let why = coordinator.beaconObstacle(for: id, settings: settings)
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("General") == true, why ?? "")

        coordinator.aprsLocationProvider = StationPositionResolver.beaconProvider(
            defaults: defaults(lat: "39.61", lon: "-105.01"), locationService: nil)
        XCTAssertNil(coordinator.beaconObstacle(for: id, settings: settings))
    }

    /// Smoke run 2026-10-03-1, issue 41: Calibrate receive level was offered
    /// with the radio's beacon off, and only said afterwards that no beacon
    /// went. The radio page now asks this first and says it beside Calibrate.
    func testCalibrationIsToldTheBeaconIsOff() {
        let settings = AppSettingsStore(defaults: TestDefaults.make("BeaconOffForCalibration"))
        let id = aprsRadio(in: settings, APRSPositionConfig(useGPS: false, latitude: 38.0, longitude: -104.0))
        settings.updateRadio(id) { $0.beacon.enabled = false }
        let coordinator = SessionCoordinator()
        let why = coordinator.beaconObstacle(for: id, settings: settings)
        XCTAssertEqual(why, "The beacon is switched off for this radio.")
        XCTAssertEqual(ReceiveLevelTuningRows.beaconNote(why),
                       "Calibrating sends this radio's beacon, which can't go out yet: The beacon is switched off for this radio.")
        XCTAssertNil(ReceiveLevelTuningRows.beaconNote(nil))
    }

    /// A position beacon nobody has edited has no position settings stored.
    /// It follows the station like a new one, rather than never going out.
    func testABeaconWithNoPositionSettingsFollowsTheStation() {
        let settings = AppSettingsStore(defaults: TestDefaults.make("BeaconNoConfig"))
        let id = aprsRadio(in: settings, nil)
        let coordinator = SessionCoordinator()
        coordinator.aprsLocationProvider = StationPositionResolver.beaconProvider(
            defaults: defaults(grid: "DM79lr"), locationService: nil)
        XCTAssertNil(coordinator.beaconObstacle(for: id, settings: settings))
    }

    /// A fixed position for one radio still works, and needs no station position.
    func testAFixedPositionIgnoresTheStation() {
        let settings = AppSettingsStore(defaults: TestDefaults.make("BeaconFixed"))
        let id = aprsRadio(in: settings, APRSPositionConfig(useGPS: false, latitude: 38.0, longitude: -104.0))
        let coordinator = SessionCoordinator()
        coordinator.aprsLocationProvider = { nil }
        XCTAssertNil(coordinator.beaconObstacle(for: id, settings: settings))

        settings.updateRadio(id) { $0.beacon.aprs?.latitude = nil }
        XCTAssertNotNil(coordinator.beaconObstacle(for: id, settings: settings))
    }
}
