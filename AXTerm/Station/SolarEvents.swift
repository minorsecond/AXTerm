import Foundation

/// Sunrise, sunset, twilight, and moon phase for a position.
///
/// Computed locally from the date and coordinates: no network, no
/// gateway, no radio. That is the point — it is the one piece of
/// situational awareness that keeps working when everything else is
/// down, and on a summit "how long until dark" outranks most of what a
/// radio can tell you.
///
/// It is also useful on the air: HF paths open along the terminator, so
/// the sunrise and sunset windows are when a marginal band is most
/// likely to be workable.
///
/// **Accuracy.** These are the standard low-precision solar equations —
/// good to roughly a minute at mid latitudes, degrading near the poles
/// and around the solstices. That is ample for planning a descent or a
/// band change. It is not a navigational almanac, and nothing here
/// should be used as one.
nonisolated struct SolarEvents: Equatable, Sendable {

    /// Nil at latitudes where the sun does not cross the horizon on this
    /// date — polar day and polar night are real answers, not errors.
    var sunrise: Date?
    var sunset: Date?
    /// Sun 6° below the horizon: the practical bounds of usable light.
    var civilDawn: Date?
    var civilDusk: Date?
    /// Local solar noon — the sun's highest point, which is not clock
    /// noon anywhere except on a handful of meridians.
    var solarNoon: Date

    /// The sun never rises today.
    var isPolarNight: Bool
    /// The sun never sets today.
    var isPolarDay: Bool

    /// Length of the day, nil during polar day or night.
    var daylight: TimeInterval? {
        guard let sunrise, let sunset else { return nil }
        return sunset.timeIntervalSince(sunrise)
    }

    /// Time until the sun goes down, or nil if it already has (or will
    /// not). The number that matters on a summit.
    func daylightRemaining(from now: Date) -> TimeInterval? {
        guard let sunset, sunset > now else { return nil }
        return sunset.timeIntervalSince(now)
    }

    /// Whether the sun is up at `now`, by this date's own events.
    func isDaylight(at now: Date) -> Bool {
        if isPolarDay { return true }
        if isPolarNight { return false }
        guard let sunrise, let sunset else { return false }
        return now >= sunrise && now <= sunset
    }

    /// Windows where the terminator is overhead and HF gray-line
    /// propagation is most likely. Empty during polar day or night,
    /// where there is no terminator crossing to speak of.
    func grayLineWindows(halfWidth: TimeInterval = 45 * 60) -> [(label: String, start: Date, end: Date)] {
        var windows: [(String, Date, Date)] = []
        if let sunrise {
            windows.append(("Sunrise", sunrise.addingTimeInterval(-halfWidth),
                            sunrise.addingTimeInterval(halfWidth)))
        }
        if let sunset {
            windows.append(("Sunset", sunset.addingTimeInterval(-halfWidth),
                            sunset.addingTimeInterval(halfWidth)))
        }
        return windows
    }

    // MARK: - Computation

    /// Standard refraction-corrected sun altitude at rise/set.
    private static let sunriseAltitude = -0.833
    private static let civilAltitude = -6.0

    static func compute(latitude: Double, longitude: Double, date: Date) -> SolarEvents {
        let julianDay = julianDayNumber(date)
        // Two steps, and both matter. `dayNumber` is a whole number of
        // days since J2000: left fractional, the transit is computed for
        // the *instant supplied* rather than for that location's noon,
        // so asking about midnight returns a "solar noon" just after
        // midnight. `meanSolarNoon` then reapplies the longitude term —
        // dropping it there collapses every meridian onto the same
        // transit and the answer stops depending on where you are.
        // Two uses of the longitude term, with *opposite* signs, and
        // getting that wrong is invisible in the output.
        //
        // Picking the day: transit for day n happens at n − λ/360, so the
        // nearest day to `julianDay` is round(julianDay − J2000 + λ/360).
        // With the sign flipped, an afternoon in the western hemisphere
        // rounds to the *next* day — and since the result is displayed as
        // a time of day, tomorrow's sunset looks exactly like today's.
        // "32h 36m of daylight left" is what that looks like (field
        // report 2026-08-24, Denver, 11:07 local).
        //
        // Placing the transit within that day: solar noon at longitude λ
        // is 12:00 UTC − λ/15 hours, hence −λ/360 in days.
        let dayNumber = (julianDay - 2_451_545.0 + 0.0009 + longitude / 360.0).rounded()
        let meanSolarNoon = dayNumber + 0.0009 - longitude / 360.0

        let meanAnomaly = (357.5291 + 0.98560028 * meanSolarNoon)
            .truncatingRemainder(dividingBy: 360)
        let center = 1.9148 * sinDeg(meanAnomaly)
            + 0.0200 * sinDeg(2 * meanAnomaly)
            + 0.0003 * sinDeg(3 * meanAnomaly)
        let eclipticLongitude = (meanAnomaly + center + 180 + 102.9372)
            .truncatingRemainder(dividingBy: 360)

        let transit = 2_451_545.0 + meanSolarNoon
            + 0.0053 * sinDeg(meanAnomaly)
            - 0.0069 * sinDeg(2 * eclipticLongitude)

        // Earth's axial tilt sets the declination from ecliptic longitude.
        let declination = asinDeg(sinDeg(eclipticLongitude) * sinDeg(23.44))

        let noon = dateFrom(julianDay: transit)
        let riseSet = hourAngle(latitude: latitude, declination: declination,
                                altitude: sunriseAltitude)
        let civil = hourAngle(latitude: latitude, declination: declination,
                              altitude: civilAltitude)

        // No hour angle means the sun stays above or below the horizon
        // all day; which one depends on the sign of the declination
        // relative to the observer's hemisphere.
        let sunUpAllDay = riseSet == nil && (latitude * declination) > 0

        return SolarEvents(
            sunrise: riseSet.map { dateFrom(julianDay: transit - $0 / 360.0) },
            sunset: riseSet.map { dateFrom(julianDay: transit + $0 / 360.0) },
            civilDawn: civil.map { dateFrom(julianDay: transit - $0 / 360.0) },
            civilDusk: civil.map { dateFrom(julianDay: transit + $0 / 360.0) },
            solarNoon: noon,
            isPolarNight: riseSet == nil && !sunUpAllDay,
            isPolarDay: sunUpAllDay)
    }

    /// Degrees of rotation between the sun's transit and it reaching
    /// `altitude`. Nil when the sun never reaches that altitude.
    private static func hourAngle(latitude: Double,
                                  declination: Double,
                                  altitude: Double) -> Double? {
        let numerator = sinDeg(altitude) - sinDeg(latitude) * sinDeg(declination)
        let denominator = cosDeg(latitude) * cosDeg(declination)
        guard denominator != 0 else { return nil }
        let cosOmega = numerator / denominator
        guard cosOmega >= -1, cosOmega <= 1 else { return nil }
        return acosDeg(cosOmega)
    }

    // MARK: - Julian day helpers

    static func julianDayNumber(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400.0 + 2_440_587.5
    }

    private static func dateFrom(julianDay julian: Double) -> Date {
        Date(timeIntervalSince1970: (julian - 2_440_587.5) * 86400.0)
    }

    private static func sinDeg(_ degrees: Double) -> Double { sin(degrees * .pi / 180) }
    private static func cosDeg(_ degrees: Double) -> Double { cos(degrees * .pi / 180) }
    private static func asinDeg(_ value: Double) -> Double { asin(value) * 180 / .pi }
    private static func acosDeg(_ value: Double) -> Double { acos(value) * 180 / .pi }
}

/// Moon phase and illumination.
///
/// A mean-synodic approximation: it ignores the moon's orbital
/// eccentricity, so the age can be off by several hours near the
/// quarters. Ample for "will there be light to pack up by", which is the
/// question being asked.
nonisolated struct MoonPhase: Equatable, Sendable {

    /// Days since the last new moon, 0 up to the synodic month.
    var age: Double
    /// Fraction of the disc lit, 0 (new) to 1 (full).
    var illuminatedFraction: Double

    /// Mean synodic month.
    static let synodicMonth = 29.530588853
    /// A known new moon: 2000-01-06 18:14 UTC.
    static let referenceNewMoon = Date(timeIntervalSince1970: 947_182_440)

    static func at(_ date: Date) -> MoonPhase {
        let elapsed = date.timeIntervalSince(referenceNewMoon) / 86400.0
        var age = elapsed.truncatingRemainder(dividingBy: synodicMonth)
        if age < 0 { age += synodicMonth }
        // Illumination follows the phase angle, not the age directly.
        let phaseAngle = 2 * Double.pi * age / synodicMonth
        return MoonPhase(age: age, illuminatedFraction: (1 - cos(phaseAngle)) / 2)
    }

    var isWaxing: Bool { age < Self.synodicMonth / 2 }

    var name: String {
        switch age {
        case ..<1.85: "New Moon"
        case ..<5.54: "Waxing Crescent"
        case ..<9.23: "First Quarter"
        case ..<12.91: "Waxing Gibbous"
        case ..<16.61: "Full Moon"
        case ..<20.30: "Waning Gibbous"
        case ..<23.99: "Last Quarter"
        case ..<27.68: "Waning Crescent"
        default: "New Moon"
        }
    }

    var symbolName: String {
        switch age {
        case ..<1.85: "moonphase.new.moon"
        case ..<5.54: "moonphase.waxing.crescent"
        case ..<9.23: "moonphase.first.quarter"
        case ..<12.91: "moonphase.waxing.gibbous"
        case ..<16.61: "moonphase.full.moon"
        case ..<20.30: "moonphase.waning.gibbous"
        case ..<23.99: "moonphase.last.quarter"
        case ..<27.68: "moonphase.waning.crescent"
        default: "moonphase.new.moon"
        }
    }
}
