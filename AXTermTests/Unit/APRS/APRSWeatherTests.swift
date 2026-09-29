import XCTest
@testable import AXTerm

/// APRS weather decoding, pinned against the shapes real stations send on
/// 144.390 — including the ones that report only some of their sensors, which
/// is most of them.
final class APRSWeatherTests: XCTestCase {

    private func report(_ info: String, dest: String = "APRS") -> APRSReport? {
        APRSParser.parse(destination: dest, info: Data(info.utf8))
    }

    // MARK: - Position report carrying weather

    func testCompleteWeatherReport() {
        // A full Davis station: wind, gust, temperature, rain, humidity,
        // pressure, then a software identifier in the comment.
        let r = report("!3959.13N/10515.42W_220/004g009t047r000p000P000h63b10132wRSW")
        XCTAssertEqual(r?.symbolCode, "_")
        let w = r?.weather
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.windDirectionDegrees, 220)
        XCTAssertEqual(w?.windSpeedMPH, 4)
        XCTAssertEqual(w?.gustMPH, 9)
        XCTAssertEqual(w?.temperatureF, 47)
        XCTAssertEqual(w?.rainLastHourHundredths, 0)
        XCTAssertEqual(w?.humidityPercent, 63)
        XCTAssertEqual(w?.pressureTenthsMillibars, 10132)
        // The trailing software identifier is comment, not data.
        XCTAssertEqual(r?.comment, "wRSW")
    }

    /// The bug this guards: the `ddd/sss` slot means wind for a weather
    /// station and course/speed for everyone else. Read as course/speed it
    /// puts a house on the map travelling at four knots.
    func testWindIsNotReportedAsCourseAndSpeed() {
        let r = report("!3959.13N/10515.42W_220/004g009t047")
        XCTAssertNil(r?.courseDegrees)
        XCTAssertNil(r?.speedKnots)
        XCTAssertEqual(r?.weather?.windDirectionDegrees, 220)
        XCTAssertEqual(r?.weather?.windSpeedMPH, 4)
    }

    /// A moving station must keep its course and speed, and gain no weather.
    func testNonWeatherStationKeepsCourseAndSpeed() {
        let r = report("!3851.33N/10452.70Wj180/035/A=006092Anytone")
        XCTAssertEqual(r?.courseDegrees, 180)
        XCTAssertEqual(r?.speedKnots, 35)
        XCTAssertNil(r?.weather)
    }

    func testTimestampedWeatherReport() {
        let r = report("@092345z3959.13N/10515.42W_180/010g015t032h88b09980")
        XCTAssertEqual(r?.hasTimestamp, true)
        XCTAssertEqual(r?.weather?.temperatureF, 32)
        XCTAssertEqual(r?.weather?.humidityPercent, 88)
        XCTAssertEqual(r?.weather?.gustMPH, 15)
    }

    // MARK: - Partial and edge readings

    func testMissingSensorsAreAbsentNotZero() {
        // Dots are the "I have no sensor for this" filler. A station with no
        // anemometer must not be reported as dead calm.
        let r = report("!3959.13N/10515.42W_.../...g...t051r...p...P...h..b.....")
        let w = r?.weather
        XCTAssertNotNil(w)
        XCTAssertNil(w?.windDirectionDegrees)
        XCTAssertNil(w?.windSpeedMPH)
        XCTAssertNil(w?.gustMPH)
        XCTAssertNil(w?.humidityPercent)
        XCTAssertNil(w?.pressureTenthsMillibars)
        XCTAssertEqual(w?.temperatureF, 51)
    }

    func testAllFillerYieldsNoWeatherAtAll() {
        // Nothing was measured, so there is no reading to show.
        let r = report("!3959.13N/10515.42W_.../...g...t...")
        XCTAssertNil(r?.weather)
    }

    func testNegativeTemperature() {
        let r = report("!3959.13N/10515.42W_000/000g000t-12h77")
        XCTAssertEqual(r?.weather?.temperatureF, -12)
        XCTAssertEqual(r?.weather?.humidityPercent, 77)
    }

    /// `h00` is 100% relative humidity — the field has room for two digits, so
    /// saturation wraps to zero on the wire.
    func testHumidityWrapsToOneHundred() {
        XCTAssertEqual(report("!3959.13N/10515.42W_000/000t040h00")?
            .weather?.humidityPercent, 100)
    }

    func testCalmWindIsAReadingNotAnAbsence() {
        let w = report("!3959.13N/10515.42W_000/000t040")?.weather
        XCTAssertEqual(w?.windSpeedMPH, 0)
        XCTAssertEqual(w?.summaryLines(inImperial: true).contains("Wind calm"), true)
    }

    // MARK: - Positionless weather

    func testPositionlessWeatherReport() {
        // `_` DTI, MDHM timestamp, then c/s for wind direction and speed.
        let w = APRSParser.parseWeather(info: Data("_10090556c220s004g005t077r000p000P000h50b09900".utf8))
        XCTAssertEqual(w?.windDirectionDegrees, 220)
        XCTAssertEqual(w?.windSpeedMPH, 4)
        XCTAssertEqual(w?.gustMPH, 5)
        XCTAssertEqual(w?.temperatureF, 77)
        XCTAssertEqual(w?.humidityPercent, 50)
    }

    /// A positionless report has no coordinates, so it must never become an
    /// `APRSReport` — that type promises a position.
    func testPositionlessWeatherIsNotAPositionReport() {
        XCTAssertNil(report("_10090556c220s004g005t077"))
    }

    func testNonWeatherPayloadYieldsNoWeather() {
        XCTAssertNil(APRSParser.parseWeather(info: Data(">Just a status".utf8)))
        XCTAssertNil(APRSParser.parseWeather(info: Data("_not-a-timestamp".utf8)))
    }

    // MARK: - Display

    func testSummaryNamesItsUnits() {
        var w = APRSWeather()
        w.temperatureF = 47
        w.humidityPercent = 63
        w.pressureTenthsMillibars = 10132
        w.windSpeedMPH = 4
        w.windDirectionDegrees = 220
        w.gustMPH = 9
        w.rainSinceMidnightHundredths = 12

        let imperial = w.summaryLines(inImperial: true)
        XCTAssertEqual(imperial.first, "47°F · humidity 63% · 1013.2 mb")
        XCTAssertEqual(imperial.dropFirst().first, "Wind 4 mph from SW, gusting 9 mph")
        XCTAssertEqual(imperial.last, "Rain 0.12 in today")

        let metric = w.summaryLines(inImperial: false)
        XCTAssertEqual(metric.first, "8°C · humidity 63% · 1013.2 mb")
        XCTAssertEqual(metric.dropFirst().first, "Wind 6 km/h from SW, gusting 14 km/h")
    }

    func testSummaryOmitsWhatWasNotReported() {
        var w = APRSWeather()
        w.temperatureF = 33
        let lines = w.summaryLines(inImperial: true)
        XCTAssertEqual(lines, ["33°F"])
    }

    func testTemperatureBadgeConverts() {
        var w = APRSWeather()
        w.temperatureF = 32
        XCTAssertEqual(w.temperatureText(inFahrenheit: true), "32°F")
        XCTAssertEqual(w.temperatureText(inFahrenheit: false), "0°C")
        XCTAssertNil(APRSWeather().temperatureText(inFahrenheit: true))
    }
}
