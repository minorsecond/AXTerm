import Foundation

/// How a station's readings are *changing*, read from its stored history.
///
/// This is the part of a surface observation that forecasts anything. A
/// barometer reading of 1008 mb says almost nothing on its own; 1008 and
/// falling four millibars in three hours says a system is arriving, and that
/// is a judgement an operator can act on with no forecast service, no
/// internet, and no model. It is the oldest working piece of weather science
/// there is and it survives the grid going down, which is exactly when it
/// matters.
nonisolated enum APRSWeatherTrend {

    /// The window the pressure tendency is measured over. Three hours is the
    /// meteorological standard and the one every published interpretation of
    /// a barometric fall is written against, so using anything else would
    /// make the thresholds below mean something different.
    static let tendencyWindow: TimeInterval = 3 * 3600
    /// A tendency needs a baseline this old before it means anything. Below
    /// it, ordinary sensor jitter divides into a small elapsed time and comes
    /// out as a dramatic rate.
    static let minimumSpan: TimeInterval = 45 * 60

    /// A measured change over a known span.
    struct Tendency: Equatable, Sendable {
        /// Millibars, signed. Negative is falling.
        var changeMillibars: Double
        /// How long the change was actually measured over, which is usually
        /// not the full window — stations go quiet, and the honest figure is
        /// the one from the readings that exist.
        var span: TimeInterval

        /// Normalised to the standard three hours so the wording below can be
        /// compared against published thresholds.
        var perThreeHours: Double {
            guard span > 0 else { return 0 }
            return changeMillibars * (APRSWeatherTrend.tendencyWindow / span)
        }
    }

    /// What a barometric tendency is conventionally taken to mean.
    ///
    /// Thresholds are the standard ones for a three-hour change. They are
    /// coarse on purpose: a surface barometer supports "something is coming",
    /// not a forecast, and wording it more precisely than that would invite
    /// more trust than one instrument can carry.
    enum Outlook: String, Sendable {
        case rapidFall, falling, steady, rising, rapidRise

        static func of(_ perThreeHours: Double) -> Outlook {
            switch perThreeHours {
            case ..<(-3.5):  return .rapidFall
            case ..<(-1.0):  return .falling
            case 1.0...3.5:  return .rising
            case 3.5...:     return .rapidRise
            default:         return .steady
            }
        }

        /// Plain words, and deliberately about *weather*, not about the
        /// instrument. "−4.2 mb/3h" is precise and tells an operator nothing.
        var summary: String {
            switch self {
            case .rapidFall: return "falling fast \u{2014} deteriorating, wind likely"
            case .falling:   return "falling \u{2014} unsettled weather approaching"
            case .steady:    return "steady"
            case .rising:    return "rising \u{2014} clearing"
            case .rapidRise: return "rising fast \u{2014} clearing, wind likely"
            }
        }

        var symbol: String {
            switch self {
            case .rapidFall: return "arrow.down.right.circle.fill"
            case .falling:   return "arrow.down.right"
            case .steady:    return "arrow.right"
            case .rising:    return "arrow.up.right"
            case .rapidRise: return "arrow.up.right.circle.fill"
            }
        }

        /// Only the two extremes earn a colour. A map where every station
        /// wears a coloured arrow is a map nobody reads.
        var isNotable: Bool { self == .rapidFall || self == .rapidRise }
    }

    /// Pressure change across the history, or nil when the station has not
    /// reported pressure over a long enough span to measure one.
    /// A tendency is only meaningful while its newest reading is current.
    ///
    /// Without this a station last heard seven hours ago still reported
    /// "rising fast — clearing", because the change across its own last three
    /// hours of readings is perfectly computable and says nothing whatever
    /// about now. A forecast from a dead station is the most dangerous thing
    /// this app could print.
    static let readingFreshWindow: TimeInterval = 3600

    static func pressureTendency(_ history: [Station.WeatherSample],
                                 now: Date) -> Tendency? {
        let readings = history.compactMap { sample -> (Date, Double)? in
            sample.weather.pressureTenthsMillibars.map {
                (sample.timestamp, Double($0) / 10)
            }
        }
        guard let latest = readings.last else { return nil }
        guard now.timeIntervalSince(latest.0) <= readingFreshWindow else { return nil }
        // The oldest reading still inside the window; the tendency is a
        // three-hour figure, not "since this station was first heard".
        let cutoff = latest.0.addingTimeInterval(-tendencyWindow)
        guard let baseline = readings.first(where: { $0.0 >= cutoff }) else { return nil }
        let span = latest.0.timeIntervalSince(baseline.0)
        guard span >= minimumSpan else { return nil }
        return Tendency(changeMillibars: latest.1 - baseline.1, span: span)
    }

    /// Temperature change over the same window, in °F. Useful for the same
    /// reason and read the same way — a front arriving moves both.
    static func temperatureChangeF(_ history: [Station.WeatherSample],
                                   now: Date = Date()) -> Tendency? {
        let readings = history.compactMap { sample -> (Date, Double)? in
            sample.weather.temperatureF.map { (sample.timestamp, Double($0)) }
        }
        guard let latest = readings.last else { return nil }
        guard now.timeIntervalSince(latest.0) <= readingFreshWindow else { return nil }
        let cutoff = latest.0.addingTimeInterval(-tendencyWindow)
        guard let baseline = readings.first(where: { $0.0 >= cutoff }) else { return nil }
        let span = latest.0.timeIntervalSince(baseline.0)
        guard span >= minimumSpan else { return nil }
        return Tendency(changeMillibars: latest.1 - baseline.1, span: span)
    }

    /// One line for the card: what the barometer is doing and what that
    /// conventionally means. Nil when the span is too short to say.
    static func pressureLine(_ history: [Station.WeatherSample], now: Date) -> String? {
        guard let tendency = pressureTendency(history, now: now) else { return nil }
        let outlook = Outlook.of(tendency.perThreeHours)
        let hours = tendency.span / 3600
        return String(format: "Barometer %@ (%+.1f mb in %.1f h)",
                      outlook.summary, tendency.changeMillibars, hours)
    }
}
