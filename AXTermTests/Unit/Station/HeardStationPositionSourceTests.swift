import XCTest
@testable import AXTerm

/// The map's transmitted-vs-licence position toggle: a station carries both a
/// beaconed APRS fix and a licence address, and the operator chooses which the
/// map shows — with the origin tagged so only a transmitted fix wears the
/// station's APRS symbol.
final class HeardStationPositionSourceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func aprsReport(lat: Double, lon: Double) -> APRSReport {
        APRSReport(latitude: lat, longitude: lon, symbolTable: "/", symbolCode: ">",
                   courseDegrees: nil, speedKnots: nil, altitudeFeet: nil,
                   comment: "", hasTimestamp: false, kind: .uncompressed)
    }

    private func station(_ call: String, aprs: APRSReport?) -> Station {
        var s = Station(call: call, lastHeard: now.addingTimeInterval(-60), heardCount: 5, lastVia: [])
        s.aprs = aprs
        return s
    }

    private func record(_ call: String, lat: Double, lon: Double) -> CallsignRecord {
        CallsignRecord(callsign: call, name: "Lee Starr", gridSquare: "DM79no",
                       latitude: lat, longitude: lon, locality: "Greenwood Vlg",
                       source: "HamDB", fetchedAt: now)
    }

    /// Beaconed fix ≠ licence address; the two placements are genuinely apart.
    private let beacon = (lat: 39.65, lon: -104.95)
    private let licence = (lat: 39.62, lon: -104.90)

    func testTransmittedPreferenceUsesTheBeaconedFixAndTagsItAPRS() throws {
        let entries = HeardStationMap.entries(
            stations: [station("W3OO-1", aprs: aprsReport(lat: beacon.lat, lon: beacon.lon))],
            directory: ["W3OO": record("W3OO", lat: licence.lat, lon: licence.lon)],
            gatewayGrids: [:],
            preference: .transmitted)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.origin, .transmittedAPRS)
        XCTAssertEqual(e.position?.latitude ?? 0, beacon.lat, accuracy: 1e-6)
        XCTAssertEqual(e.positionSource, "APRS position (heard over the air)")
    }

    func testLicencePreferenceUsesTheLicenceAddressAndTagsItDerived() throws {
        let entries = HeardStationMap.entries(
            stations: [station("W3OO-1", aprs: aprsReport(lat: beacon.lat, lon: beacon.lon))],
            directory: ["W3OO": record("W3OO", lat: licence.lat, lon: licence.lon)],
            gatewayGrids: [:],
            preference: .licence)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.origin, .licenceOrGrid)
        XCTAssertEqual(e.position?.latitude ?? 0, licence.lat, accuracy: 1e-6)
        XCTAssertTrue(e.positionSource?.contains("licence address") == true, e.positionSource ?? "")
    }

    func testLicencePreferenceFallsBackToTheBeaconWhenNoLookupExists() throws {
        // No directory record: the licence point does not exist, so even with
        // the licence preference the station is placed at its transmitted fix.
        let entries = HeardStationMap.entries(
            stations: [station("W3OO-1", aprs: aprsReport(lat: beacon.lat, lon: beacon.lon))],
            directory: [:], gatewayGrids: [:],
            preference: .licence)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.origin, .transmittedAPRS)
        XCTAssertEqual(e.position?.latitude ?? 0, beacon.lat, accuracy: 1e-6)
    }

    func testTransmittedPreferenceFallsBackToLicenceWhenNoBeaconExists() throws {
        // No APRS fix: even preferring transmitted, the licence point is used.
        let entries = HeardStationMap.entries(
            stations: [station("W3OO-1", aprs: nil)],
            directory: ["W3OO": record("W3OO", lat: licence.lat, lon: licence.lon)],
            gatewayGrids: [:],
            preference: .transmitted)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.origin, .licenceOrGrid)
        XCTAssertEqual(e.position?.latitude ?? 0, licence.lat, accuracy: 1e-6)
    }

    func testAStationWithNeitherIsUnplaced() throws {
        let entries = HeardStationMap.entries(
            stations: [station("W3OO-1", aprs: nil)],
            directory: [:], gatewayGrids: [:])
        let e = try XCTUnwrap(entries.first)
        XCTAssertFalse(e.isPlaced)
        XCTAssertEqual(e.origin, .unplaced)
    }

    func testTheScopeSiteCarriesTheAPRSSymbolForABeaconedStation() throws {
        // The symbol must ride on the Site itself — that is what makes a
        // SwiftUI Map annotation rebuild and actually draw the glyph.
        let entries = HeardStationMap.entries(
            stations: [station("W3OO-1", aprs: aprsReport(lat: beacon.lat, lon: beacon.lon))],
            directory: [:], gatewayGrids: [:])
        let scope = HeardStationMap.scope(
            observerLabel: "DM79", observer: GreatCircle.Point(latitude: 39.6, longitude: -104.9),
            entries: entries, now: now)
        let site = try XCTUnwrap(scope.sites.first { $0.id == "W3OO-1" })
        XCTAssertEqual(site.aprsSymbol, APRSMapSymbol(table: "/", code: ">"))
    }

    func testTheScopeSiteHasNoSymbolForAnAddressPlacedStation() throws {
        let entries = HeardStationMap.entries(
            stations: [station("W3OO-1", aprs: nil)],
            directory: ["W3OO": record("W3OO", lat: licence.lat, lon: licence.lon)],
            gatewayGrids: [:])
        let scope = HeardStationMap.scope(
            observerLabel: "DM79", observer: GreatCircle.Point(latitude: 39.6, longitude: -104.9),
            entries: entries, now: now)
        let site = try XCTUnwrap(scope.sites.first { $0.id == "W3OO-1" })
        XCTAssertNil(site.aprsSymbol, "an address-placed station wears no APRS symbol")
    }

    func testTheDefaultPreferenceIsTransmitted() throws {
        // No explicit preference argument — the beaconed fix must still win.
        let entries = HeardStationMap.entries(
            stations: [station("W3OO-1", aprs: aprsReport(lat: beacon.lat, lon: beacon.lon))],
            directory: ["W3OO": record("W3OO", lat: licence.lat, lon: licence.lon)],
            gatewayGrids: [:])
        XCTAssertEqual(entries.first?.origin, .transmittedAPRS)
    }
}
