import XCTest
@testable import AXTerm

/// The barometric tendency: the one thing a lone surface station can say about
/// weather that has not arrived yet, and therefore the one that has to be right.
final class APRSWeatherTrendTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func sample(minutesAgo: Double, millibars: Double? = nil,
                        temperatureF: Int? = nil) -> Station.WeatherSample {
        var weather = APRSWeather()
        if let millibars { weather.pressureTenthsMillibars = Int((millibars * 10).rounded()) }
        weather.temperatureF = temperatureF
        return Station.WeatherSample(
            timestamp: now.addingTimeInterval(-minutesAgo * 60), weather: weather)
    }

    // MARK: - Refusing to answer

    func testNoHistoryMeansNoTendency() {
        XCTAssertNil(APRSWeatherTrend.pressureTendency([], now: now))
    }

    /// Two readings ten minutes apart cannot support a three-hour figure.
    /// Ordinary sensor jitter divided by a short span comes out as a dramatic
    /// rate, which is exactly the false alarm this guard exists to prevent.
    func testATooShortSpanIsRefusedRatherThanExtrapolated() {
        let history = [
            sample(minutesAgo: 10, millibars: 1013.0),
            sample(minutesAgo: 0, millibars: 1012.6),
        ]
        XCTAssertNil(APRSWeatherTrend.pressureTendency(history, now: now))
    }

    func testAStationWithNoBarometerHasNoTendency() {
        let history = [
            sample(minutesAgo: 180, temperatureF: 60),
            sample(minutesAgo: 0, temperatureF: 55),
        ]
        XCTAssertNil(APRSWeatherTrend.pressureTendency(history, now: now))
    }

    // MARK: - Measuring

    func testFallIsMeasuredAcrossTheWindow() throws {
        let history = [
            sample(minutesAgo: 180, millibars: 1013.0),
            sample(minutesAgo: 90, millibars: 1011.0),
            sample(minutesAgo: 0, millibars: 1009.0),
        ]
        let tendency = try XCTUnwrap(APRSWeatherTrend.pressureTendency(history, now: now))
        XCTAssertEqual(tendency.changeMillibars, -4.0, accuracy: 0.05)
        XCTAssertEqual(tendency.span, 3 * 3600, accuracy: 1)
        XCTAssertEqual(tendency.perThreeHours, -4.0, accuracy: 0.05)
    }

    /// A station that has only been heard for ninety minutes still gets an
    /// answer, normalised so the wording can be compared against the standard
    /// three-hour thresholds — but the span it was actually measured over is
    /// kept, because that is what the operator is told.
    func testAShorterSpanIsNormalisedButReportedHonestly() throws {
        let history = [
            sample(minutesAgo: 90, millibars: 1013.0),
            sample(minutesAgo: 0, millibars: 1011.0),
        ]
        let tendency = try XCTUnwrap(APRSWeatherTrend.pressureTendency(history, now: now))
        XCTAssertEqual(tendency.changeMillibars, -2.0, accuracy: 0.05)
        XCTAssertEqual(tendency.span, 90 * 60, accuracy: 1)
        XCTAssertEqual(tendency.perThreeHours, -4.0, accuracy: 0.05,
                       "2 mb in 90 minutes is a 4 mb / 3 h rate")
    }

    /// Readings older than the window must not become the baseline, or a
    /// station heard all day would report the change since breakfast.
    func testTheBaselineIsInsideTheWindowNotTheOldestReading() throws {
        let history = [
            sample(minutesAgo: 600, millibars: 1030.0),   // hours ago, ignored
            sample(minutesAgo: 170, millibars: 1013.0),
            sample(minutesAgo: 0, millibars: 1011.0),
        ]
        let tendency = try XCTUnwrap(APRSWeatherTrend.pressureTendency(history, now: now))
        XCTAssertEqual(tendency.changeMillibars, -2.0, accuracy: 0.05)
    }

    // MARK: - What it is taken to mean

    func testOutlookThresholdsAreTheStandardOnes() {
        XCTAssertEqual(APRSWeatherTrend.Outlook.of(-5), .rapidFall)
        XCTAssertEqual(APRSWeatherTrend.Outlook.of(-2), .falling)
        XCTAssertEqual(APRSWeatherTrend.Outlook.of(-0.4), .steady)
        XCTAssertEqual(APRSWeatherTrend.Outlook.of(0.4), .steady)
        XCTAssertEqual(APRSWeatherTrend.Outlook.of(2), .rising)
        XCTAssertEqual(APRSWeatherTrend.Outlook.of(5), .rapidRise)
    }

    /// The wording has to be about weather, not about the instrument. A
    /// number of millibars tells an operator nothing they can act on.
    func testOutlookIsWordedAsWeather() {
        XCTAssertTrue(APRSWeatherTrend.Outlook.rapidFall.summary.contains("deteriorating"))
        XCTAssertTrue(APRSWeatherTrend.Outlook.rising.summary.contains("clearing"))
        XCTAssertTrue(APRSWeatherTrend.Outlook.rapidFall.isNotable)
        XCTAssertFalse(APRSWeatherTrend.Outlook.steady.isNotable)
    }

    func testPressureLineNamesTheChangeAndTheSpanItWasMeasuredOver() throws {
        let history = [
            sample(minutesAgo: 180, millibars: 1013.0),
            sample(minutesAgo: 0, millibars: 1009.0),
        ]
        let line = try XCTUnwrap(APRSWeatherTrend.pressureLine(history, now: now))
        XCTAssertTrue(line.contains("falling fast"))
        XCTAssertTrue(line.contains("-4.0 mb"))
        XCTAssertTrue(line.contains("3.0 h"))
    }

    // MARK: - Storing the history

    func testHistoryIsKeptOldestFirstAndBounded() {
        var station = Station(call: "N0WX-1")
        for minute in stride(from: 200, through: 0, by: -1) {
            var weather = APRSWeather()
            weather.pressureTenthsMillibars = 10130 - minute
            StationTracker.recordWeather(
                &station, weather, at: now.addingTimeInterval(-Double(minute) * 60))
        }
        XCTAssertEqual(station.weatherHistory.count, Station.weatherHistoryLimit)
        let times = station.weatherHistory.map(\.timestamp)
        XCTAssertEqual(times, times.sorted(), "trends read off this assume oldest first")
        XCTAssertEqual(station.weather?.pressureTenthsMillibars, 10130,
                       "the newest reading is still the current one")
    }

    /// A digipeated channel delivers out of order. The history has to be
    /// sorted, not merely appended, because every trend read off it assumes
    /// oldest first.
    func testOutOfOrderArrivalsAreSorted() {
        var station = Station(call: "N0WX-1")
        var older = APRSWeather(); older.pressureTenthsMillibars = 10130
        var newer = APRSWeather(); newer.pressureTenthsMillibars = 10090
        StationTracker.recordWeather(&station, newer, at: now)
        StationTracker.recordWeather(&station, older, at: now.addingTimeInterval(-3 * 3600))

        let times = station.weatherHistory.map(\.timestamp)
        XCTAssertEqual(times, times.sorted())
        let tendency = APRSWeatherTrend.pressureTendency(station.weatherHistory, now: now)
        XCTAssertEqual(tendency?.changeMillibars ?? 0, -4.0, accuracy: 0.05)
    }

    /// A steady barometer beaconing the same value must still build a history:
    /// dropping duplicates would make a settled station look as though it had
    /// stopped reporting, which is the opposite of what steady means.
    func testRepeatedIdenticalReadingsStillBuildAHistory() {
        var station = Station(call: "N0WX-1")
        var weather = APRSWeather(); weather.pressureTenthsMillibars = 10130
        for minute in stride(from: 180, through: 0, by: -30) {
            StationTracker.recordWeather(
                &station, weather, at: now.addingTimeInterval(-Double(minute) * 60))
        }
        XCTAssertEqual(station.weatherHistory.count, 7)
        let tendency = APRSWeatherTrend.pressureTendency(station.weatherHistory, now: now)
        XCTAssertEqual(tendency?.changeMillibars ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(APRSWeatherTrend.Outlook.of(tendency?.perThreeHours ?? 0), .steady)
    }

    // MARK: - Invalidating a stale reading

    /// The bug this guards, seen in the field: a station last heard seven
    /// hours ago still reported "rising fast — clearing". Its own last three
    /// hours of readings compute a tendency perfectly well and say nothing
    /// whatever about now. A forecast from a dead station is the most
    /// dangerous thing this app could print.
    func testATendencyFromStaleReadingsIsNotReported() {
        let history = [
            sample(minutesAgo: 600, millibars: 1009.0),
            sample(minutesAgo: 420, millibars: 1013.0),
        ]
        XCTAssertNil(APRSWeatherTrend.pressureTendency(history, now: now),
                     "the newest reading is seven hours old")
        XCTAssertNil(APRSWeatherTrend.pressureLine(history, now: now))
    }

    func testATendencyIsReportedWhileItsNewestReadingIsCurrent() {
        let history = [
            sample(minutesAgo: 190, millibars: 1013.0),
            sample(minutesAgo: 10, millibars: 1009.0),
        ]
        XCTAssertNotNil(APRSWeatherTrend.pressureTendency(history, now: now))
    }

    func testTemperatureTrendIsInvalidatedTheSameWay() {
        let stale = [
            sample(minutesAgo: 600, temperatureF: 70),
            sample(minutesAgo: 420, temperatureF: 55),
        ]
        XCTAssertNil(APRSWeatherTrend.temperatureChangeF(stale, now: now))
    }
}
