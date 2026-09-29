import XCTest
@testable import AXTerm

/// The inferred temperature field: what it claims, and — more importantly —
/// where it refuses to claim anything.
final class APRSWeatherFieldTests: XCTestCase {

    private func observation(_ call: String, lat: Double, lon: Double,
                             temperature: Double, metres: Double? = nil)
        -> APRSWeatherField.Observation {
        APRSWeatherField.Observation(
            callsign: call,
            position: GreatCircle.Point(latitude: lat, longitude: lon),
            value: temperature, elevationMetres: metres)
    }

    // MARK: - Building

    /// One reading is a reading, not a field. Colouring a map from it would
    /// paint one station's thermometer across a county.
    func testASingleStationIsNotAField() {
        XCTAssertNil(APRSWeatherField.build(observations: [
            observation("N0WX", lat: 39.7, lon: -104.9, temperature: 60),
        ]))
        XCTAssertNil(APRSWeatherField.build(observations: []))
    }

    func testTwoStationsMakeAField() {
        let field = APRSWeatherField.build(observations: [
            observation("N0WX", lat: 39.7, lon: -104.9, temperature: 60),
            observation("W0TMP", lat: 39.8, lon: -105.0, temperature: 50),
        ])
        XCTAssertNotNil(field)
    }

    // MARK: - The lapse rate

    /// Fitting a slope to two points, or to stations all at one height, gives
    /// a number with no information in it — so the standard rate is used and
    /// the field says it was assumed.
    func testLapseRateFallsBackWithoutRelief() {
        let flat = [
            observation("A", lat: 39.7, lon: -104.9, temperature: 60, metres: 1600),
            observation("B", lat: 39.8, lon: -105.0, temperature: 62, metres: 1620),
            observation("C", lat: 39.6, lon: -104.8, temperature: 61, metres: 1610),
        ]
        let (rate, fitted) = APRSWeatherField.lapseRate(for: flat)
        XCTAssertFalse(fitted)
        XCTAssertEqual(rate, APRSWeatherField.standardLapseFPerMetre, accuracy: 1e-9)
    }

    func testLapseRateIsFittedWhenStationsSpanRealRelief() {
        // 10 °F colder over 1000 m — a believable mountain profile.
        let hills = [
            observation("PLAIN", lat: 39.7, lon: -104.9, temperature: 70, metres: 1600),
            observation("MID", lat: 39.8, lon: -105.3, temperature: 65, metres: 2100),
            observation("PEAK", lat: 39.9, lon: -105.6, temperature: 60, metres: 2600),
        ]
        let (rate, fitted) = APRSWeatherField.lapseRate(for: hills)
        XCTAssertTrue(fitted)
        XCTAssertEqual(rate, -0.01, accuracy: 0.002)
    }

    /// A station reporting nonsense must not drag the whole map with it. A
    /// fitted slope outside physical bounds is discarded for the standard one.
    func testAbsurdSlopeIsRejected() {
        let broken = [
            observation("A", lat: 39.7, lon: -104.9, temperature: 20, metres: 1600),
            observation("B", lat: 39.8, lon: -105.3, temperature: 90, metres: 2100),
            observation("C", lat: 39.9, lon: -105.6, temperature: 160, metres: 2600),
        ]
        let (rate, fitted) = APRSWeatherField.lapseRate(for: broken)
        XCTAssertFalse(fitted, "a +0.14 °F/m slope is not a lapse rate")
        XCTAssertEqual(rate, APRSWeatherField.standardLapseFPerMetre, accuracy: 1e-9)
    }

    // MARK: - Interpolating

    func testAtAStationTheFieldReadsThatStation() throws {
        let field = try XCTUnwrap(APRSWeatherField.build(observations: [
            observation("A", lat: 39.70, lon: -104.90, temperature: 70),
            observation("B", lat: 39.90, lon: -105.10, temperature: 50),
        ]))
        let atA = field.temperature(
            at: GreatCircle.Point(latitude: 39.70, longitude: -104.90), elevationMetres: nil)
        XCTAssertEqual(try XCTUnwrap(atA), 70, accuracy: 0.5)
    }

    func testBetweenStationsTheFieldIsBetweenTheirReadings() throws {
        let field = try XCTUnwrap(APRSWeatherField.build(observations: [
            observation("A", lat: 39.70, lon: -104.90, temperature: 70),
            observation("B", lat: 39.90, lon: -104.90, temperature: 50),
        ]))
        let middle = try XCTUnwrap(field.temperature(
            at: GreatCircle.Point(latitude: 39.80, longitude: -104.90), elevationMetres: nil))
        XCTAssertGreaterThan(middle, 50)
        XCTAssertLessThan(middle, 70)
    }

    /// The whole point of detrending: the same horizontal position reads
    /// colder when the ground under it is higher.
    func testHeightMakesACellColder() throws {
        let field = try XCTUnwrap(APRSWeatherField.build(observations: [
            observation("PLAIN", lat: 39.70, lon: -104.90, temperature: 70, metres: 1600),
            observation("MID", lat: 39.80, lon: -105.20, temperature: 65, metres: 2100),
            observation("PEAK", lat: 39.90, lon: -105.50, temperature: 60, metres: 2600),
        ]))
        let point = GreatCircle.Point(latitude: 39.78, longitude: -105.05)
        let low = try XCTUnwrap(field.temperature(at: point, elevationMetres: 1600))
        let high = try XCTUnwrap(field.temperature(at: point, elevationMetres: 2600))
        XCTAssertLessThan(high, low - 5,
                          "1000 m of extra height should cost roughly 10 °F")
    }

    // MARK: - Refusing to answer

    /// Past the coverage radius there is no evidence, so there is no colour.
    /// The alternative — extrapolating — draws the global mean wearing a
    /// gradient, which looks exactly like data.
    func testFarFromEveryStationTheFieldSaysNothing() throws {
        let field = try XCTUnwrap(APRSWeatherField.build(observations: [
            observation("A", lat: 39.70, lon: -104.90, temperature: 70),
            observation("B", lat: 39.80, lon: -104.90, temperature: 60),
        ]))
        // Roughly 500 km away.
        let faraway = GreatCircle.Point(latitude: 35.0, longitude: -104.9)
        XCTAssertNil(field.temperature(at: faraway, elevationMetres: nil))
        XCTAssertEqual(field.confidence(at: faraway), 0)
    }

    func testConfidenceFadesWithDistanceRatherThanEndingAbruptly() throws {
        let field = try XCTUnwrap(APRSWeatherField.build(observations: [
            observation("A", lat: 39.70, lon: -104.90, temperature: 70),
            observation("B", lat: 39.75, lon: -104.90, temperature: 60),
        ]))
        let near = field.confidence(at: GreatCircle.Point(latitude: 39.70, longitude: -104.90))
        // ~30 km north: inside the radius, out in the fade.
        let edge = field.confidence(at: GreatCircle.Point(latitude: 40.00, longitude: -104.90))
        XCTAssertEqual(near, 1, accuracy: 0.001)
        XCTAssertGreaterThan(edge, 0)
        XCTAssertLessThan(edge, 1)
    }

    // MARK: - Presentation

    func testRangeIsPaddedAndNeverCollapses() throws {
        let identical = try XCTUnwrap(APRSWeatherField.build(observations: [
            observation("A", lat: 39.70, lon: -104.90, temperature: 60),
            observation("B", lat: 39.75, lon: -104.90, temperature: 60),
        ]))
        let range = try XCTUnwrap(identical.temperatureRange)
        XCTAssertGreaterThan(range.upperBound - range.lowerBound, 1,
                             "two identical readings must still produce a usable ramp")
    }

    /// The caption has to name the station count: two stations and twelve are
    /// very different maps and they look identical once coloured.
    func testSummaryNamesTheStationCountAndWhereTheLapseCameFrom() throws {
        let assumed = try XCTUnwrap(APRSWeatherField.build(observations: [
            observation("A", lat: 39.70, lon: -104.90, temperature: 70),
            observation("B", lat: 39.75, lon: -104.90, temperature: 60),
        ]))
        XCTAssertEqual(assumed.summary(inFahrenheit: true),
                       "2 stations \u{b7} standard lapse rate assumed")

        let fitted = try XCTUnwrap(APRSWeatherField.build(observations: [
            observation("PLAIN", lat: 39.70, lon: -104.90, temperature: 70, metres: 1600),
            observation("MID", lat: 39.80, lon: -105.20, temperature: 65, metres: 2100),
            observation("PEAK", lat: 39.90, lon: -105.50, temperature: 60, metres: 2600),
        ]))
        XCTAssertEqual(fitted.summary(inFahrenheit: true),
                       "3 stations \u{b7} lapse rate fitted from them")
    }

    func testColourRampRunsColdToWarmAndStaysInGamut() {
        for step in 0...10 {
            let (r, g, b) = WeatherFieldOverlay.colour(Double(step) / 10)
            for channel in [r, g, b] {
                XCTAssertGreaterThanOrEqual(channel, 0)
                XCTAssertLessThanOrEqual(channel, 1)
            }
        }
        let cold = WeatherFieldOverlay.colour(0)
        let hot = WeatherFieldOverlay.colour(1)
        XCTAssertGreaterThan(cold.2, cold.0, "the cold end is blue")
        XCTAssertGreaterThan(hot.0, hot.2, "the warm end is red")
    }

    // MARK: - Which readings can honestly be interpolated

    /// Pressure is the best-behaved thing a surface network measures — smooth
    /// over hundreds of kilometres — and it arrives already reduced to sea
    /// level, so it must NOT be height-corrected a second time.
    func testPressureIsNotElevationCorrected() throws {
        var low = APRSWeather(); low.pressureTenthsMillibars = 10130
        var high = APRSWeather(); high.pressureTenthsMillibars = 10090
        let field = try XCTUnwrap(APRSWeatherField.build(
            observations: [
                observation("A", lat: 39.70, lon: -104.90, temperature: 1013.0, metres: 1600),
                observation("B", lat: 39.80, lon: -105.20, temperature: 1010.0, metres: 2100),
                observation("C", lat: 39.90, lon: -105.50, temperature: 1009.0, metres: 2600),
            ],
            parameter: .pressure))
        XCTAssertFalse(field.lapseWasFitted)
        XCTAssertEqual(field.lapseFPerMetre, 0)

        let point = GreatCircle.Point(latitude: 39.78, longitude: -105.05)
        let atLow = try XCTUnwrap(field.temperature(at: point, elevationMetres: 1600))
        let atHigh = try XCTUnwrap(field.temperature(at: point, elevationMetres: 2600))
        XCTAssertEqual(atLow, atHigh, accuracy: 0.001,
                       "sea-level pressure must not be reduced twice")
        XCTAssertEqual(field.summary(inFahrenheit: true), "3 stations",
                       "no lapse rate was involved, so none is claimed")
    }

    /// A station sending raw station pressure from altitude reads ~100 mb low
    /// and would drag a whole field with it. Anything outside the range
    /// surface pressure occupies at sea level is a broken sensor, not data.
    func testImplausiblePressureIsRejected() {
        var sane = APRSWeather(); sane.pressureTenthsMillibars = 10132
        var raw = APRSWeather(); raw.pressureTenthsMillibars = 8300
        XCTAssertEqual(APRSWeatherField.Parameter.pressure.value(from: sane) ?? 0,
                       1013.2, accuracy: 0.01)
        XCTAssertNil(APRSWeatherField.Parameter.pressure.value(from: raw))
    }

    func testEachParameterReadsItsOwnValue() {
        var weather = APRSWeather()
        weather.temperatureF = 47
        weather.humidityPercent = 63
        weather.pressureTenthsMillibars = 10132
        XCTAssertEqual(APRSWeatherField.Parameter.temperature.value(from: weather), 47)
        XCTAssertEqual(APRSWeatherField.Parameter.humidity.value(from: weather), 63)
        XCTAssertEqual(APRSWeatherField.Parameter.pressure.value(from: weather) ?? 0,
                       1013.2, accuracy: 0.01)
    }

    /// Rainfall is deliberately not a field. Rain cells are kilometres across
    /// and gauges are tens of kilometres apart, so a smooth surface through a
    /// few of them invents storms between the gauges.
    func testRainfallIsNotOfferedAsAField() {
        XCTAssertFalse(APRSWeatherField.Parameter.allCases.contains { $0.label.lowercased().contains("rain") })
        XCTAssertEqual(APRSWeatherField.Parameter.allCases.count, 3)
    }
}
