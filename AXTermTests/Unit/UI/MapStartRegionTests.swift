//
//  MapStartRegionTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

/// Where the map opens.
///
/// It framed the observer *and* every station heard, so on a channel reaching
/// Dodge City, Raton and Fort Collins it opened showing three states — and
/// asked the tile store for 700 km of tiles to do it.
final class MapStartRegionTests: XCTestCase {

    private let home = (lat: 39.6117, lon: -104.7317)

    // MARK: - Which region wins

    func testTheLastPlaceTheOperatorLookedWins() {
        let saved = MapStartRegion(latitude: 40, longitude: -105,
                                   latitudeDelta: 0.2, longitudeDelta: 0.3)
        let opened = MapStartRegion.opening(
            saved: saved, observerLatitude: home.lat, observerLongitude: home.lon,
            fitEverything: MapStartRegion(latitude: 0, longitude: 0,
                                          latitudeDelta: 90, longitudeDelta: 90))
        XCTAssertEqual(opened, saved)
    }

    func testWithNothingSavedItOpensOnTheOperator() throws {
        let opened = try XCTUnwrap(MapStartRegion.opening(
            saved: nil, observerLatitude: home.lat, observerLongitude: home.lon,
            fitEverything: MapStartRegion(latitude: 0, longitude: 0,
                                          latitudeDelta: 90, longitudeDelta: 90)))
        XCTAssertEqual(opened.latitude, home.lat, accuracy: 0.0001)
        XCTAssertEqual(opened.longitude, home.lon, accuracy: 0.0001)
        XCTAssertEqual(opened.latitudeDelta, MapStartRegion.defaultLatitudeDelta, accuracy: 0.0001)
        XCTAssertLessThan(opened.latitudeDelta, 2.0, "a hundred km, not three states")
    }

    /// Only when there is no saved view and no position of our own does the
    /// old behavior apply — it is a last resort, not the default.
    func testFitEverythingIsTheLastResort() {
        let fit = MapStartRegion(latitude: 39, longitude: -103,
                                 latitudeDelta: 8, longitudeDelta: 9)
        XCTAssertEqual(MapStartRegion.opening(saved: nil, observerLatitude: nil,
                                              observerLongitude: nil, fitEverything: fit), fit)
        XCTAssertNil(MapStartRegion.opening(saved: nil, observerLatitude: nil,
                                            observerLongitude: nil, fitEverything: nil))
    }

    /// A stored region that would open the map off the globe, inside-out, or
    /// zoomed past anything renderable must not be honored — it would look
    /// exactly like the app failing to open.
    func testAnInsaneSavedRegionIsIgnored() {
        for bad in [MapStartRegion(latitude: 999, longitude: 0, latitudeDelta: 1, longitudeDelta: 1),
                    MapStartRegion(latitude: 39, longitude: -104, latitudeDelta: 0, longitudeDelta: 1),
                    MapStartRegion(latitude: 39, longitude: -104, latitudeDelta: -3, longitudeDelta: 1),
                    MapStartRegion(latitude: 39, longitude: -104,
                                   latitudeDelta: 0.00001, longitudeDelta: 0.00001)] {
            XCTAssertFalse(bad.isSane, "\(bad) should be rejected")
            let opened = MapStartRegion.opening(saved: bad, observerLatitude: home.lat,
                                                observerLongitude: home.lon, fitEverything: nil)
            XCTAssertEqual(opened?.latitude, home.lat, "fall back to the operator, not to nothing")
        }
    }

    // MARK: - Shape

    /// Longitude degrees shrink towards the poles. Equal deltas would draw a
    /// letterbox that is wrong by a factor of two at this latitude.
    func testTheDefaultBoxIsSquareOnScreenNotInDegrees() {
        let here = MapStartRegion.around(latitude: 39.6, longitude: -104.7)
        XCTAssertGreaterThan(here.longitudeDelta, here.latitudeDelta)
        XCTAssertEqual(here.longitudeDelta, here.latitudeDelta / cos(39.6 * .pi / 180),
                       accuracy: 0.001)
        // And it does not blow up at the pole.
        XCTAssertLessThan(MapStartRegion.around(latitude: 89.9, longitude: 0).longitudeDelta, 10)
    }

    // MARK: - Round trip

    func testItSurvivesBeingWrittenAndReadBack() throws {
        let region = MapStartRegion(latitude: 39.611712, longitude: -104.731712,
                                    latitudeDelta: 0.412345, longitudeDelta: 0.534567)
        let back = try XCTUnwrap(MapStartRegion.decode(region.encoded))
        XCTAssertEqual(back.latitude, region.latitude, accuracy: 0.000001)
        XCTAssertEqual(back.longitude, region.longitude, accuracy: 0.000001)
        XCTAssertEqual(back.latitudeDelta, region.latitudeDelta, accuracy: 0.000001)
        XCTAssertEqual(back.longitudeDelta, region.longitudeDelta, accuracy: 0.000001)
    }

    func testGarbageDecodesToNothingRatherThanACorruptRegion() {
        for text in [nil, "", "not a region", "1,2,3", "1,2,3,4,5", "a,b,c,d",
                     "39.6,-104.7,0,0"] {
            XCTAssertNil(MapStartRegion.decode(text), "\(text ?? "nil") should not decode")
        }
    }

    func testPersistenceRoundTripsThroughDefaults() throws {
        let suite = TestDefaults.make("MapStartRegionTests")
        XCTAssertNil(MapStartRegion.load(suite))
        let region = MapStartRegion.around(latitude: home.lat, longitude: home.lon)
        MapStartRegion.save(region, to: suite)
        // Stored as text at six decimals, so this is a round-trip within the
        // precision it is written at, not bit equality.
        let back = try XCTUnwrap(MapStartRegion.load(suite))
        XCTAssertEqual(back.latitude, region.latitude, accuracy: 0.000001)
        XCTAssertEqual(back.longitude, region.longitude, accuracy: 0.000001)
        XCTAssertEqual(back.latitudeDelta, region.latitudeDelta, accuracy: 0.000001)
        XCTAssertEqual(back.longitudeDelta, region.longitudeDelta, accuracy: 0.000001)
    }

    // MARK: - Smoke run 2026-10-03-1, issue 23

    /// What Station A had saved: the whole world, longitude span clamped at
    /// 180 and the center shifted half a turn from the station. It passed
    /// `isSane`, won over the station's own position, and the map opened
    /// over Asia with the station off screen.
    func testAWorldWideSavedRegionIsIgnored() {
        XCTAssertNil(MapStartRegion.decode("39.445896,75.239157,74.728462,180.000000"))
        let world = MapStartRegion(latitude: 39.45, longitude: 75.24,
                                   latitudeDelta: 74.7, longitudeDelta: 180)
        let opened = MapStartRegion.opening(saved: world, observerLatitude: home.lat,
                                            observerLongitude: home.lon, fitEverything: nil)
        XCTAssertEqual(opened?.latitude, home.lat)
        XCTAssertEqual(opened?.longitude, home.lon)
    }

    /// A view across a few states is still a place an operator looks.
    func testAStateSizedViewIsStillHonored() {
        XCTAssertTrue(MapStartRegion(latitude: 39, longitude: -104,
                                     latitudeDelta: 12, longitudeDelta: 20).isSane)
    }

    /// Kept in the app's own suite. In `UserDefaults.standard` the test-mode
    /// wipe never cleared it, so every test instance opened where the last
    /// one had looked, and the main app opened there too.
    func testTheDefaultStoreIsTheAppSuite() throws {
        let key = MapStartRegion.storageKey
        let before = UserDefaults.standard.string(forKey: key)
        let previous = AppEnvironment.defaults.string(forKey: key)
        defer { AppEnvironment.defaults.set(previous, forKey: key) }
        let region = MapStartRegion.around(latitude: home.lat, longitude: home.lon)
        MapStartRegion.save(region)
        XCTAssertEqual(AppEnvironment.defaults.string(forKey: key), region.encoded)
        XCTAssertEqual(try XCTUnwrap(MapStartRegion.load()).latitude, region.latitude, accuracy: 0.000001)
        if AppEnvironment.defaults !== UserDefaults.standard {
            XCTAssertEqual(UserDefaults.standard.string(forKey: key), before, "written to the shared domain")
        }
    }

    // MARK: - Smoke run 2026-10-03-1, test 13.3 (issue 107)

    /// The iPhone had saved a region over Antarctica (-80.447, 145.864)
    /// that nobody had panned to, and opened on blank ice every time. The
    /// map now remembers only where the operator moved it by hand.
    func testOnlyARegionTheOperatorMovedToIsRemembered() {
        XCTAssertTrue(MapStartRegion.remembers(mapHasOpened: true, operatorMoved: true))
        XCTAssertFalse(MapStartRegion.remembers(mapHasOpened: true, operatorMoved: false),
                       "a camera the app or MapKit set is not the place the operator last looked")
        XCTAssertFalse(MapStartRegion.remembers(mapHasOpened: false, operatorMoved: true))
    }

    /// Regions saved under the old rule may be ones nobody chose, so they
    /// are left behind once rather than trusted.
    func testARegionSavedUnderTheOldRuleIsNotReopened() {
        let suite = TestDefaults.make("MapStartRegionLegacy")
        suite.set("-80.447431,145.863916,1.113120,4.500000", forKey: "map.lastRegion")
        XCTAssertNotEqual(MapStartRegion.storageKey, "map.lastRegion")
        XCTAssertNil(MapStartRegion.load(suite))
    }
}
