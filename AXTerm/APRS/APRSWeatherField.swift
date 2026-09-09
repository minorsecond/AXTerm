import Foundation

/// A temperature field inferred from the weather stations this receiver has
/// actually heard.
///
/// **Why not kriging.** Kriging is the right tool when you can estimate a
/// variogram, and estimating one needs on the order of a hundred observations;
/// thirty is usually called the bare minimum. A VHF receiver hears somewhere
/// between one and a dozen weather stations. Fitting a variogram to five
/// points is fitting noise, and the kriging variance that comes back — the
/// thing that would make kriging worth the trouble — would be derived from
/// that same noise. It would produce a more confident-looking map, not a more
/// accurate one.
///
/// **What actually dominates the error.** Over ground like Colorado's, surface
/// temperature is governed far more by *elevation* than by horizontal
/// distance. Denver sits near 1600 m and the foothills twenty kilometres west
/// are past 2500 m; that is roughly 9 °F of difference from lapse rate alone.
/// Any purely horizontal interpolator — kriging included — smears that into
/// nonsense. So the useful idea is not a better distance kernel, it is
/// removing the trend before interpolating at all.
///
/// This is that: fit a lapse rate against elevation, interpolate the
/// *residuals* with inverse-distance weighting, then add the trend back using
/// the terrain height at each output point. In geostatistical terms it is the
/// cheap sibling of regression kriging, and it keeps the part that matters
/// (the physical trend) while dropping the part that cannot be estimated here
/// (the fitted covariance structure). If station density ever gets high
/// enough, the residual interpolator is the only piece that has to change.
///
/// Everything is honest about its own limits: a cell further than
/// `coverageRadiusKm` from every contributing station is not estimated at all,
/// because past that distance the answer is the global mean wearing a colour.
nonisolated struct APRSWeatherField: Equatable, Sendable {

    /// Which reading the field is drawn from.
    ///
    /// Not every reading can honestly be interpolated, and the difference is
    /// physical rather than a matter of taste:
    ///
    /// * **Pressure** is the best behaved thing a surface network measures. It
    ///   varies smoothly over hundreds of kilometres, which is why hand-drawn
    ///   isobars from sparse stations worked for a century. Weather-station
    ///   software reports it already reduced to sea level, so it needs no
    ///   height correction — only a sanity check that a station really is
    ///   sending sea-level pressure.
    /// * **Temperature** needs the elevation trend removed first; see the type
    ///   comment.
    /// * **Humidity** is noisier and more local, so it gets plain distance
    ///   weighting and no trend.
    /// * **Rainfall is deliberately absent.** Rain cells are kilometres across
    ///   and gauges are tens of kilometres apart, so a smooth surface drawn
    ///   through a handful of them invents storms between the gauges and
    ///   erases the ones that fell between them. Rain belongs at the stations
    ///   that measured it, as numbers, and that is where AXTerm keeps it.
    enum Parameter: String, CaseIterable, Sendable {
        case temperature
        case pressure
        case humidity

        var label: String {
            switch self {
            case .temperature: return "Temperature"
            case .pressure: return "Pressure"
            case .humidity: return "Humidity"
            }
        }

        /// Whether the elevation trend is removed before interpolating.
        var isElevationCorrected: Bool { self == .temperature }

        /// Reading out of a station's weather, in the field's own unit.
        func value(from weather: APRSWeather) -> Double? {
            switch self {
            case .temperature:
                return weather.temperatureF.map(Double.init)
            case .pressure:
                guard let tenths = weather.pressureTenthsMillibars else { return nil }
                let millibars = Double(tenths) / 10
                // APRS carries barometric pressure already reduced to sea
                // level, which is what every weather-station package sends.
                // A station transmitting raw station pressure from altitude
                // reads a hundred millibars low and would drag a whole field
                // with it, so anything outside the range surface pressure
                // actually occupies at sea level is treated as a broken
                // sensor rather than as data.
                guard (870...1085).contains(millibars) else { return nil }
                return millibars
            case .humidity:
                return weather.humidityPercent.map(Double.init)
            }
        }

        var unitSuffix: String {
            switch self {
            case .temperature: return "\u{00b0}"
            case .pressure: return " mb"
            case .humidity: return "%"
            }
        }
    }

    /// Which reading this field was built from.
    var parameter: Parameter = .temperature

    /// One station's contribution: where it is, what it read, and how high it
    /// sits when terrain is available. `value` is in the field's own unit —
    /// °F, millibars or percent — because a field only ever holds one
    /// parameter at a time.
    struct Observation: Equatable, Sendable {
        var callsign: String
        var position: GreatCircle.Point
        var value: Double
        /// Metres above sea level, when terrain data covers the station.
        var elevationMetres: Double?
    }

    /// Beyond this from every station, nothing is drawn.
    static let coverageRadiusKm: Double = 40
    /// Inverse-distance exponent. Two is the usual choice and keeps a single
    /// nearby station from flattening the whole neighbourhood.
    static let power: Double = 2
    /// The standard environmental lapse rate, °F per metre, used when the
    /// stations themselves cannot support fitting one.
    static let standardLapseFPerMetre: Double = -0.00650 * 9 / 5

    var observations: [Observation]
    /// °F per metre. Negative: colder with height.
    var lapseFPerMetre: Double
    /// True when `lapseFPerMetre` was fitted from these stations rather than
    /// assumed. The UI says which, because "we measured this" and "we assumed
    /// the textbook value" are different claims.
    var lapseWasFitted: Bool

    /// Builds a field. Returns nil when nothing was heard that can support
    /// one — a single station is a reading, not a field.
    ///
    /// - Parameter elevation: terrain height at a point, or nil where no
    ///   elevation data is stored. With no elevation anywhere the field
    ///   degrades to plain inverse-distance weighting, which the caller must
    ///   disclose rather than quietly present as terrain-aware.
    static func build(observations: [Observation],
                      parameter: Parameter = .temperature) -> APRSWeatherField? {
        guard observations.count >= 2 else { return nil }
        // Only temperature carries a height trend. Fitting one against
        // pressure would be fitting the sea-level reduction that has already
        // been applied, and against humidity it would be fitting noise.
        let (lapse, fitted) = parameter.isElevationCorrected
            ? lapseRate(for: observations)
            : (0, false)
        return APRSWeatherField(parameter: parameter, observations: observations,
                                lapseFPerMetre: lapse, lapseWasFitted: fitted)
    }

    /// Least-squares slope of temperature against elevation.
    ///
    /// Only trusted with at least three stations spanning real relief: fitting
    /// a slope to two points, or to stations all at the same height, produces
    /// a number with no information in it and occasionally an absurd one (a
    /// *positive* 20 °F per hundred metres from two stations that happen to
    /// disagree). Those cases fall back to the standard lapse rate, which is
    /// at least physically sane.
    static func lapseRate(for observations: [Observation]) -> (Double, Bool) {
        let withElevation = observations.compactMap { observation -> (Double, Double)? in
            observation.elevationMetres.map { ($0, observation.value) }
        }
        guard withElevation.count >= 3 else { return (standardLapseFPerMetre, false) }

        let heights = withElevation.map(\.0)
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        // Under 200 m of relief the slope is dominated by sensor scatter.
        guard spread >= 200 else { return (standardLapseFPerMetre, false) }

        let n = Double(withElevation.count)
        let meanHeight = heights.reduce(0, +) / n
        let meanTemperature = withElevation.map(\.1).reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for (height, temperature) in withElevation {
            covariance += (height - meanHeight) * (temperature - meanTemperature)
            variance += (height - meanHeight) * (height - meanHeight)
        }
        guard variance > 0 else { return (standardLapseFPerMetre, false) }
        let slope = covariance / variance
        // A lapse rate outside this range is not a lapse rate; it is a station
        // reporting nonsense, or an inversion so strong that assuming it holds
        // across the whole map would be worse than assuming the standard.
        guard (-0.030...0.005).contains(slope) else { return (standardLapseFPerMetre, false) }
        return (slope, true)
    }

    /// Temperature at a point, or nil when no station is close enough to say.
    ///
    /// - Parameter elevationMetres: terrain height there. Nil skips the trend
    ///   correction for this cell, which is the honest thing to do where no
    ///   elevation is stored — better a smooth field than one that pretends
    ///   sea level in the mountains.
    func temperature(at point: GreatCircle.Point, elevationMetres: Double?) -> Double? {
        var weightedSum = 0.0
        var weights = 0.0
        var nearest = Double.greatestFiniteMagnitude

        for observation in observations {
            let km = GreatCircle.kilometres(from: point, to: observation.position)
            nearest = min(nearest, km)
            guard km <= Self.coverageRadiusKm else { continue }
            // The residual: what this station reads once its own height is
            // accounted for.
            let residual = observation.value
                - Self.lapseFPerMetre(lapseFPerMetre, at: observation.elevationMetres)
            // A station essentially at the cell wins outright, and avoids a
            // divide by zero.
            if km < 0.05 { return residual + Self.lapseFPerMetre(lapseFPerMetre, at: elevationMetres) }
            let weight = 1 / pow(km, Self.power)
            weightedSum += residual * weight
            weights += weight
        }

        guard weights > 0, nearest <= Self.coverageRadiusKm else { return nil }
        return weightedSum / weights + Self.lapseFPerMetre(lapseFPerMetre, at: elevationMetres)
    }

    /// The trend's contribution at a height, and zero where none is known.
    private static func lapseFPerMetre(_ lapse: Double, at metres: Double?) -> Double {
        guard let metres else { return 0 }
        return lapse * metres
    }

    /// How far this field can honestly speak: the distance from the nearest
    /// contributing station, as a 0…1 confidence that fades to nothing at the
    /// coverage radius. Used to fade the overlay out rather than ending it at
    /// a hard edge, which would read as a boundary in the weather.
    func confidence(at point: GreatCircle.Point) -> Double {
        let nearest = observations
            .map { GreatCircle.kilometres(from: point, to: $0.position) }
            .min() ?? .greatestFiniteMagnitude
        guard nearest < Self.coverageRadiusKm else { return 0 }
        // Full strength close in, fading over the outer third.
        let fadeFrom = Self.coverageRadiusKm * 0.66
        guard nearest > fadeFrom else { return 1 }
        return 1 - (nearest - fadeFrom) / (Self.coverageRadiusKm - fadeFrom)
    }

    /// The range to colour across, padded so the extremes are not the very
    /// edge of the ramp. Nil when every station reads the same.
    var temperatureRange: ClosedRange<Double>? {
        let values = observations.map(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        if high - low < 1 { return (low - 5)...(high + 5) }
        let pad = (high - low) * 0.15
        return (low - pad)...(high + pad)
    }

    /// One line saying what this field is and is not, for the layer's caption.
    /// It always names the station count, because two stations and twelve are
    /// very different maps and they look identical once coloured.
    func summary(inFahrenheit: Bool) -> String {
        let count = observations.count
        let stations = "\(count) station\(count == 1 ? "" : "s")"
        guard parameter.isElevationCorrected else { return stations }
        let basis = lapseWasFitted
            ? "lapse rate fitted from them"
            : "standard lapse rate assumed"
        return "\(stations) \u{b7} \(basis)"
    }
}
