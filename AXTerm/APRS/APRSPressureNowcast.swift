import Foundation

/// What the barometers on the channel say about the next few hours.
///
/// The one genuinely predictive thing RF carries. Radar, lightning and
/// warnings are all the internet; barometric pressure arrives in every APRS
/// weather report as `bnnnnn`, and a three-hour tendency is the oldest and
/// most durable surface forecast there is.
///
/// Tendency rather than pressure, for a reason that matters here more than
/// most places. Absolute pressure varies about 1 mb per 8 m of altitude, and
/// this channel's stations run from 1500 m to over 3000 m. The APRS spec says
/// the field is reduced to sea level, but plenty of stations get that wrong or
/// do not do it at all, so an absolute-pressure field would mostly be a map of
/// who has configured their WX3in1 correctly. The *change* at a station is
/// independent of both its altitude and its reduction — whatever offset a
/// station carries, it carries it in both readings and it subtracts out.
/// That makes tendency the one pressure product worth trusting from a handful
/// of strangers' weather stations.
///
/// Per-station tendency, its window and its thresholds are
/// `APRSWeatherTrend`'s. This adds only the area view, and the honesty about
/// how thin the evidence is.
nonisolated enum APRSPressureNowcast {

    /// One station's three-hour tendency, already computed and guarded.
    struct Reading: Equatable, Sendable {
        var call: String
        /// Millibars per three hours, signed. Negative is falling.
        var perThreeHours: Double

        init(call: String, perThreeHours: Double) {
            self.call = call
            self.perThreeHours = perThreeHours
        }
    }

    /// Below this many stations there is no area to describe — one barometer
    /// is a station reading, and two that disagree are nothing at all. The
    /// nowcast is still produced, because a single steep fall nearby is worth
    /// seeing; it is produced with `isAreaWide` false and says so.
    static let minimumForAnArea = 3

    /// How much of a change has to be moving the same way before "across the
    /// area" is a fair description. Four stations falling is a system; three
    /// falling and three rising is a map of local noise.
    static let agreementForAnArea = 0.7

    struct Nowcast: Equatable, Sendable {
        var stations: Int
        /// The middle station, not the average: one barometer stuck at a
        /// constant offset drags a mean and cannot move a median.
        var medianPerThreeHours: Double
        var outlook: APRSWeatherTrend.Outlook
        /// The largest absolute change and where — the place to look.
        var steepest: Reading?
        /// The share of stations moving the same way as the median, 0...1.
        var agreement: Double

        /// Whether this describes an area or a station or two.
        var isAreaWide: Bool {
            stations >= APRSPressureNowcast.minimumForAnArea
                && agreement >= APRSPressureNowcast.agreementForAnArea
        }

        /// The sentence. Deliberately says what it rests on: a forecast from
        /// four amateur barometers should look like one.
        var headline: String {
            let scope = isAreaWide
                ? "across \(stations) stations"
                : (stations == 1 ? "at one station" : "at \(stations) stations")
            switch outlook {
            case .steady:
                return "Pressure steady \(scope)."
            case .falling, .rapidFall:
                return "Pressure \(outlook.summary) \(scope)."
            case .rising, .rapidRise:
                return "Pressure \(outlook.summary) \(scope)."
            }
        }

        /// What stops this being read as more than it is, or nil when the
        /// ordinary reading needs no qualification.
        var caveat: String? {
            if stations < APRSPressureNowcast.minimumForAnArea {
                return "Too few barometers to call this an area trend \u{2014} "
                    + "it describes \(stations == 1 ? "one station" : "\(stations) stations")."
            }
            if agreement < APRSPressureNowcast.agreementForAnArea {
                return "The stations disagree, so this is local variation rather than "
                    + "a system moving through."
            }
            return nil
        }
    }

    /// Build the area view from whatever tendencies exist.
    ///
    /// Returns nil only when nothing reported: an empty map says "no data",
    /// which is different from "steady" and must not be printed as it.
    static func build(_ readings: [Reading]) -> Nowcast? {
        guard !readings.isEmpty else { return nil }
        let values = readings.map(\.perThreeHours).sorted()
        let median: Double = values.count % 2 == 1
            ? values[values.count / 2]
            : (values[values.count / 2 - 1] + values[values.count / 2]) / 2

        // Agreement is measured against the direction the median points, and
        // a station inside the steady band counts for neither side — calling
        // a flat barometer "agreeing with the fall" would inflate every
        // verdict on a quiet day.
        let outlook = APRSWeatherTrend.Outlook.of(median)
        let sameWay = readings.filter { reading in
            switch outlook {
            case .falling, .rapidFall: return reading.perThreeHours < 0
            case .rising, .rapidRise:  return reading.perThreeHours > 0
            case .steady:              return APRSWeatherTrend.Outlook.of(reading.perThreeHours) == .steady
            }
        }.count

        return Nowcast(
            stations: readings.count,
            medianPerThreeHours: median,
            outlook: outlook,
            steepest: readings.max { abs($0.perThreeHours) < abs($1.perThreeHours) },
            agreement: Double(sameWay) / Double(readings.count))
    }
}
