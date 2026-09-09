import XCTest
@testable import AXTerm

/// How a weather station's reading reaches the map: kept on the station across
/// beacons that carry none, spelled out on the card, and reduced to one
/// temperature beside the callsign — but only while it is current.
final class HeardStationWeatherTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private let observer = GreatCircle.Point(latitude: 39.7, longitude: -104.9)

    private func packet(_ info: String, from: String, at: Date) -> Packet {
        Packet(timestamp: at,
               from: AX25Address(call: from),
               to: AX25Address(call: "APRS"),
               control: 0x03,
               pid: 0xF0,
               info: Data(info.utf8))
    }

    private func entry(weather: APRSWeather?, heard: Date?) -> HeardStationMap.Entry {
        HeardStationMap.Entry(
            callsign: "N2XGL-1", heardCount: 5, lastHeard: now, lastVia: [],
            position: GreatCircle.Point(latitude: 40.16, longitude: -105.1),
            positionSource: "APRS position (heard over the air)",
            confidence: .exact,
            origin: .transmittedAPRS,
            aprsSymbol: APRSMapSymbol(table: "/", code: "_"),
            weather: weather, weatherHeard: heard)
    }

    private var reading: APRSWeather {
        var w = APRSWeather()
        w.temperatureF = 47
        w.humidityPercent = 63
        w.windSpeedMPH = 4
        w.windDirectionDegrees = 220
        return w
    }

    // MARK: - Keeping the reading on the station

    /// The reason weather is stored apart from the position report: a station
    /// that beacons its fix and its sensors on separate intervals must not
    /// lose the reading when the next bare position arrives.
    func testPositionWithoutWeatherKeepsTheLastReading() {
        var station = Station(call: "N2XGL-1")
        StationTracker.applyAPRS(&station, packet: packet(
            "!4009.60N/10506.00W_220/004g009t047h63", from: "N2XGL-1",
            at: now.addingTimeInterval(-600)))
        XCTAssertEqual(station.weather?.temperatureF, 47)

        StationTracker.applyAPRS(&station, packet: packet(
            "!4009.60N/10506.00W_Just a position now", from: "N2XGL-1", at: now))
        XCTAssertEqual(station.weather?.temperatureF, 47,
                       "a beacon with no readings must not erase the sensors")
        XCTAssertEqual(station.weatherHeard, now.addingTimeInterval(-600),
                       "and the timestamp must stay with the reading it belongs to")
    }

    func testPositionlessWeatherUpdatesTheReadingAndItsTime() {
        var station = Station(call: "N2XGL-1")
        StationTracker.applyAPRS(&station, packet: packet(
            "!4009.60N/10506.00W_220/004g009t047h63", from: "N2XGL-1",
            at: now.addingTimeInterval(-600)))
        StationTracker.applyAPRS(&station, packet: packet(
            "_10090556c220s004g005t051h60", from: "N2XGL-1", at: now))

        XCTAssertEqual(station.weather?.temperatureF, 51)
        XCTAssertEqual(station.weatherHeard, now)
        // The positionless report carries no fix, so the position stands.
        XCTAssertEqual(station.aprs?.latitude ?? 0, 40.16, accuracy: 0.01)
    }

    // MARK: - The card

    /// The identity lines stay in `detail`; the reading is carried separately
    /// so the card can lay it out instead of printing it. Both end up in the
    /// tooltip, which has no layout to give it.
    func testDetailCarriesIdentityAndTheReadingIsSeparate() {
        let e = entry(weather: reading, heard: now.addingTimeInterval(-120))
        let text = HeardStationMap.detail(
            for: e, observer: observer, now: now, distanceInMiles: true)

        XCTAssertTrue(text.contains("Weather station"))
        XCTAssertFalse(text.contains("humidity"),
                       "the card lays the reading out; detail must not print it too")

        let lines = HeardStationMap.weatherLines(for: e, now: now, inImperial: true)
        XCTAssertEqual(lines.first, "47°F · humidity 63%")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Wind 4 mph from SW") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("Reading taken") },
                       "a current reading does not need its age spelled out")
    }

    func testStaleReadingIsQuotedWithItsAge() {
        let lines = HeardStationMap.weatherLines(
            for: entry(weather: reading, heard: now.addingTimeInterval(-4 * 3600)),
            now: now, inImperial: true)

        XCTAssertTrue(lines.contains { $0.contains("47°F") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Reading taken") },
                      "an hours-old temperature must not read as the current one")
    }

    /// Hovering a marker has to show everything the card shows, because a
    /// tooltip is the only thing a keyboard-driven or quick look gets.
    func testTooltipCarriesBothIdentityAndReading() {
        let scope = HeardStationMap.scope(
            observerLabel: "K0EPI-7", observer: observer,
            entries: [entry(weather: reading, heard: now.addingTimeInterval(-120))],
            now: now, distanceInMiles: true)
        let site = scope.sites.first
        XCTAssertEqual(site?.detail.contains("humidity"), false)
        XCTAssertEqual(site?.tooltip.contains("Weather station"), true)
        XCTAssertEqual(site?.tooltip.contains("humidity 63%"), true)
    }

    func testStationWithNoSensorsAddsNothingToTheCard() {
        let e = entry(weather: nil, heard: nil)
        XCTAssertTrue(HeardStationMap.weatherLines(for: e, now: now, inImperial: true).isEmpty)
        let scope = HeardStationMap.scope(
            observerLabel: "K0EPI-7", observer: observer, entries: [e],
            now: now, distanceInMiles: true)
        XCTAssertNil(scope.sites.first?.weather)
        XCTAssertEqual(scope.sites.first?.tooltip, scope.sites.first?.detail)
    }

    // MARK: - The map badge

    func testBadgeIsTheTemperatureInThePreferredUnit() {
        let fresh = entry(weather: reading, heard: now.addingTimeInterval(-120))
        XCTAssertEqual(
            HeardStationMap.weatherBadge(for: fresh, now: now, inImperial: true), "47°F")
        XCTAssertEqual(
            HeardStationMap.weatherBadge(for: fresh, now: now, inImperial: false), "8°C")
    }

    /// A marker has nowhere to say "this was four hours ago", so a stale
    /// reading is simply not drawn — the card still carries it, with its age.
    func testStaleReadingIsNotBadgedOnTheMap() {
        let stale = entry(weather: reading, heard: now.addingTimeInterval(-4 * 3600))
        XCTAssertNil(HeardStationMap.weatherBadge(for: stale, now: now, inImperial: true))
    }

    func testNoTemperatureMeansNoBadge() {
        var windOnly = APRSWeather()
        windOnly.windSpeedMPH = 12
        let e = entry(weather: windOnly, heard: now)
        XCTAssertNil(HeardStationMap.weatherBadge(for: e, now: now, inImperial: true))
    }

    func testScopeCarriesTheBadgeToTheMarker() {
        let scope = HeardStationMap.scope(
            observerLabel: "K0EPI-7", observer: observer,
            entries: [entry(weather: reading, heard: now.addingTimeInterval(-120))],
            now: now, distanceInMiles: true)
        XCTAssertEqual(scope.sites.first?.weatherBadge, "47°F")
        XCTAssertEqual(scope.sites.first?.label, "N2XGL-1",
                       "the badge must not contaminate the station's identity")
    }
}
