import XCTest
@testable import AXTerm

/// These assert physical invariants rather than published almanac times.
/// An invariant that must hold everywhere catches a wrong formula; a
/// single memorised sunrise time mostly catches typos.
final class SolarEventsTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: iso)!
    }

    // Roughly: equinoxes and solstices for 2026.
    private var marchEquinox: Date { date("2026-03-20T12:00:00Z") }
    private var juneSolstice: Date { date("2026-06-21T12:00:00Z") }
    private var decemberSolstice: Date { date("2026-12-21T12:00:00Z") }

    // MARK: - Day length

    /// On an equinox the day is twelve hours everywhere. The refraction
    /// correction stretches it slightly, so allow a few minutes.
    func testEquinoxDayLengthIsTwelveHoursAtTheEquator() throws {
        let events = SolarEvents.compute(latitude: 0, longitude: 0, date: marchEquinox)
        let daylight = try XCTUnwrap(events.daylight)
        XCTAssertEqual(daylight / 3600, 12.0, accuracy: 0.2)
    }

    func testEquinoxDayLengthIsTwelveHoursAtHighLatitudeToo() throws {
        let events = SolarEvents.compute(latitude: 60, longitude: 0, date: marchEquinox)
        let daylight = try XCTUnwrap(events.daylight)
        XCTAssertEqual(daylight / 3600, 12.0, accuracy: 0.5)
    }

    /// Northern summer days lengthen with latitude.
    func testSummerDaysAreLongerFurtherNorth() throws {
        let denver = try XCTUnwrap(
            SolarEvents.compute(latitude: 39.74, longitude: -104.98, date: juneSolstice).daylight)
        let anchorage = try XCTUnwrap(
            SolarEvents.compute(latitude: 61.2, longitude: -149.9, date: juneSolstice).daylight)
        XCTAssertGreaterThan(anchorage, denver)
    }

    /// And winter days shorten with latitude — the same relationship,
    /// inverted, which a sign error would break.
    func testWinterDaysAreShorterFurtherNorth() throws {
        let denver = try XCTUnwrap(
            SolarEvents.compute(latitude: 39.74, longitude: -104.98, date: decemberSolstice).daylight)
        let anchorage = try XCTUnwrap(
            SolarEvents.compute(latitude: 61.2, longitude: -149.9, date: decemberSolstice).daylight)
        XCTAssertLessThan(anchorage, denver)
    }

    // MARK: - Ordering

    func testEventsAreInTheOnlyOrderTheyCanBe() throws {
        let events = SolarEvents.compute(latitude: 39.74, longitude: -104.98, date: marchEquinox)
        let dawn = try XCTUnwrap(events.civilDawn)
        let sunrise = try XCTUnwrap(events.sunrise)
        let sunset = try XCTUnwrap(events.sunset)
        let dusk = try XCTUnwrap(events.civilDusk)

        XCTAssertLessThan(dawn, sunrise)
        XCTAssertLessThan(sunrise, events.solarNoon)
        XCTAssertLessThan(events.solarNoon, sunset)
        XCTAssertLessThan(sunset, dusk)
    }

    /// Sunrise and sunset are symmetric about solar noon.
    func testSunriseAndSunsetAreSymmetricAboutSolarNoon() throws {
        let events = SolarEvents.compute(latitude: 39.74, longitude: -104.98, date: marchEquinox)
        let sunrise = try XCTUnwrap(events.sunrise)
        let sunset = try XCTUnwrap(events.sunset)
        let before = events.solarNoon.timeIntervalSince(sunrise)
        let after = sunset.timeIntervalSince(events.solarNoon)
        XCTAssertEqual(before, after, accuracy: 60)
    }

    /// The equation of time is bounded at about ±16 minutes, so solar
    /// noon on the prime meridian is always near 12:00 UTC. A longitude
    /// sign error would blow this apart immediately.
    func testSolarNoonOnThePrimeMeridianIsNearUTCNoon() {
        for iso in ["2026-02-11T00:00:00Z", "2026-05-14T00:00:00Z",
                    "2026-08-01T00:00:00Z", "2026-11-03T00:00:00Z"] {
            let events = SolarEvents.compute(latitude: 0, longitude: 0, date: date(iso))
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let hour = Double(utc.component(.hour, from: events.solarNoon))
                + Double(utc.component(.minute, from: events.solarNoon)) / 60
            XCTAssertEqual(hour, 12.0, accuracy: 0.35, iso)
        }
    }

    /// Denver is about 105° west, so its solar noon runs about seven
    /// hours after the prime meridian's.
    func testSolarNoonShiftsWithLongitude() {
        let greenwich = SolarEvents.compute(latitude: 0, longitude: 0, date: marchEquinox)
        let denver = SolarEvents.compute(latitude: 0, longitude: -104.98, date: marchEquinox)
        let offset = denver.solarNoon.timeIntervalSince(greenwich.solarNoon) / 3600
        XCTAssertEqual(offset, 104.98 / 15, accuracy: 0.1)
    }

    // MARK: - The right day

    /// The invariant the earlier tests all missed: the events must belong
    /// to the day the caller asked about. Solar noon is by definition
    /// within twelve hours of any instant in its own day, so anything
    /// further out means a whole day was skipped — which is invisible
    /// when the result is rendered as a time of day.
    func testSolarNoonIsAlwaysWithinTwelveHoursOfTheInstant() {
        let instants = ["2026-08-24T17:07:00Z", "2026-08-24T00:30:00Z",
                        "2026-08-24T23:30:00Z", "2026-01-15T06:00:00Z",
                        "2026-06-21T18:45:00Z"]
        let longitudes = [0.0, -104.98, -74.0, 139.7, 151.2, -157.8, 24.9]
        for iso in instants {
            for longitude in longitudes {
                let moment = date(iso)
                let events = SolarEvents.compute(
                    latitude: 39.7, longitude: longitude, date: moment)
                let offset = abs(events.solarNoon.timeIntervalSince(moment))
                XCTAssertLessThan(offset, 12 * 3600,
                                  "\(iso) at lon \(longitude) picked the wrong day")
            }
        }
    }

    /// The bug as the operator saw it: mid-morning in Denver reported
    /// 32h 36m of daylight left — a day's worth too much.
    func testDaylightRemainingCannotExceedADay() {
        let moment = date("2026-08-24T17:07:00Z")   // 11:07 MDT
        let events = SolarEvents.compute(
            latitude: 39.7392, longitude: -104.9903, date: moment)
        let remaining = events.daylightRemaining(from: moment)
        let hours = (remaining ?? 0) / 3600
        XCTAssertGreaterThan(hours, 7, "sunset should still be hours away")
        XCTAssertLessThan(hours, 10, "but nowhere near a day away")
    }

    /// Sunrise and sunset must straddle the instant when the sun is up.
    func testEventsBracketAMiddayInstant() throws {
        let moment = date("2026-08-24T17:07:00Z")
        let events = SolarEvents.compute(
            latitude: 39.7392, longitude: -104.9903, date: moment)
        let sunrise = try XCTUnwrap(events.sunrise)
        let sunset = try XCTUnwrap(events.sunset)
        XCTAssertLessThan(sunrise, moment)
        XCTAssertGreaterThan(sunset, moment)
        XCTAssertTrue(events.isDaylight(at: moment))
    }

    /// Asking at any hour of a day must give the same events for that
    /// day — the answer cannot depend on when you asked.
    func testTheAnswerIsTheSameWheneverYouAskWithinTheDay() throws {
        let longitude = -104.9903
        var previous: Date?
        for hour in [8, 12, 16, 20, 23] {
            let moment = date(String(format: "2026-08-24T%02d:00:00Z", hour))
            let events = SolarEvents.compute(
                latitude: 39.7392, longitude: longitude, date: moment)
            let noon = events.solarNoon
            if let previous {
                XCTAssertEqual(noon.timeIntervalSince(previous), 0, accuracy: 120,
                               "solar noon moved when asked at \(hour):00Z")
            }
            previous = noon
        }
    }

    // MARK: - Polar cases

    /// Polar day and night are real answers, not failures.
    func testPolarNightHasNoSunrise() {
        let events = SolarEvents.compute(latitude: 80, longitude: 0, date: decemberSolstice)
        XCTAssertTrue(events.isPolarNight)
        XCTAssertFalse(events.isPolarDay)
        XCTAssertNil(events.sunrise)
        XCTAssertNil(events.daylight)
        XCTAssertFalse(events.isDaylight(at: decemberSolstice))
    }

    func testPolarDayHasNoSunset() {
        let events = SolarEvents.compute(latitude: 80, longitude: 0, date: juneSolstice)
        XCTAssertTrue(events.isPolarDay)
        XCTAssertFalse(events.isPolarNight)
        XCTAssertNil(events.sunset)
        XCTAssertTrue(events.isDaylight(at: juneSolstice))
    }

    /// The southern hemisphere is the mirror image on the same date —
    /// this is what catches a hemisphere sign error in the polar test.
    func testSouthernPolarCasesAreTheMirrorImage() {
        XCTAssertTrue(SolarEvents.compute(latitude: -80, longitude: 0,
                                          date: decemberSolstice).isPolarDay)
        XCTAssertTrue(SolarEvents.compute(latitude: -80, longitude: 0,
                                          date: juneSolstice).isPolarNight)
    }

    // MARK: - Operator-facing helpers

    func testDaylightRemainingCountsDownAndThenStops() throws {
        let events = SolarEvents.compute(latitude: 39.74, longitude: -104.98, date: marchEquinox)
        let sunset = try XCTUnwrap(events.sunset)
        let hourBefore = sunset.addingTimeInterval(-3600)
        XCTAssertEqual(try XCTUnwrap(events.daylightRemaining(from: hourBefore)), 3600, accuracy: 1)
        XCTAssertNil(events.daylightRemaining(from: sunset.addingTimeInterval(60)))
    }

    /// Gray-line windows straddle the terminator crossings.
    func testGrayLineWindowsBracketSunriseAndSunset() throws {
        let events = SolarEvents.compute(latitude: 39.74, longitude: -104.98, date: marchEquinox)
        let windows = events.grayLineWindows()
        XCTAssertEqual(windows.map(\.label), ["Sunrise", "Sunset"])
        let sunrise = try XCTUnwrap(events.sunrise)
        XCTAssertLessThan(windows[0].start, sunrise)
        XCTAssertGreaterThan(windows[0].end, sunrise)
    }

    func testPolarDayHasNoGrayLine() {
        let events = SolarEvents.compute(latitude: 80, longitude: 0, date: juneSolstice)
        XCTAssertTrue(events.grayLineWindows().isEmpty)
    }
}

final class MoonPhaseTests: XCTestCase {

    func testIlluminationStaysInRangeAcrossAWholeCycle() {
        for day in 0..<60 {
            let date = MoonPhase.referenceNewMoon.addingTimeInterval(Double(day) * 86400)
            let phase = MoonPhase.at(date)
            XCTAssertGreaterThanOrEqual(phase.illuminatedFraction, 0)
            XCTAssertLessThanOrEqual(phase.illuminatedFraction, 1)
            XCTAssertGreaterThanOrEqual(phase.age, 0)
            XCTAssertLessThan(phase.age, MoonPhase.synodicMonth)
        }
    }

    func testNewMoonIsDarkAndFullMoonIsLit() {
        XCTAssertEqual(MoonPhase.at(MoonPhase.referenceNewMoon).illuminatedFraction,
                       0, accuracy: 0.01)
        let full = MoonPhase.referenceNewMoon
            .addingTimeInterval(MoonPhase.synodicMonth / 2 * 86400)
        XCTAssertEqual(MoonPhase.at(full).illuminatedFraction, 1, accuracy: 0.01)
    }

    /// The cycle repeats: one synodic month later is the same phase.
    func testPhaseRepeatsEachSynodicMonth() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let later = start.addingTimeInterval(MoonPhase.synodicMonth * 86400)
        XCTAssertEqual(MoonPhase.at(start).illuminatedFraction,
                       MoonPhase.at(later).illuminatedFraction, accuracy: 0.001)
    }

    /// Dates before the reference epoch must not produce a negative age.
    func testDatesBeforeTheEpochStillGiveAPositiveAge() {
        let phase = MoonPhase.at(Date(timeIntervalSince1970: 0))
        XCTAssertGreaterThanOrEqual(phase.age, 0)
        XCTAssertLessThan(phase.age, MoonPhase.synodicMonth)
    }

    func testWaxingIsTheFirstHalfOfTheCycle() {
        XCTAssertTrue(MoonPhase.at(
            MoonPhase.referenceNewMoon.addingTimeInterval(5 * 86400)).isWaxing)
        XCTAssertFalse(MoonPhase.at(
            MoonPhase.referenceNewMoon.addingTimeInterval(20 * 86400)).isWaxing)
    }

    func testEveryPointInTheCycleHasANameAndASymbol() {
        for day in stride(from: 0.0, to: MoonPhase.synodicMonth, by: 0.5) {
            let phase = MoonPhase.at(
                MoonPhase.referenceNewMoon.addingTimeInterval(day * 86400))
            XCTAssertFalse(phase.name.isEmpty)
            XCTAssertTrue(phase.symbolName.hasPrefix("moonphase."), phase.symbolName)
        }
    }
}
