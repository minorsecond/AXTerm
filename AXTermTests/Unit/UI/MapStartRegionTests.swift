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
    /// old behaviour apply — it is a last resort, not the default.
    func testFitEverythingIsTheLastResort() {
        let fit = MapStartRegion(latitude: 39, longitude: -103,
                                 latitudeDelta: 8, longitudeDelta: 9)
        XCTAssertEqual(MapStartRegion.opening(saved: nil, observerLatitude: nil,
                                              observerLongitude: nil, fitEverything: fit), fit)
        XCTAssertNil(MapStartRegion.opening(saved: nil, observerLatitude: nil,
                                            observerLongitude: nil, fitEverything: nil))
    }

    /// A stored region that would open the map off the globe, inside-out, or
    /// zoomed past anything renderable must not be honoured — it would look
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
        let suite = try XCTUnwrap(UserDefaults(suiteName: "MapStartRegionTests"))
        suite.removePersistentDomain(forName: "MapStartRegionTests")
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
        suite.removePersistentDomain(forName: "MapStartRegionTests")
    }
}
