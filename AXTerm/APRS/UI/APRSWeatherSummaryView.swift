import SwiftUI

/// A station's current weather, laid out the way a weather report is normally
/// read: the temperature first and large, the rest as small labelled readings
/// beside it, and a wind arrow pointing the way the wind is blowing.
///
/// Deliberately restrained. This sits inside a station card that also carries
/// identity, distance and packet counts, so it earns one block and no more —
/// no panel chrome of its own, no colour except the one the map already uses
/// for weather stations, and nothing drawn for a reading the station did not
/// send. The arrow is a glance cue only; the text beside it always spells the
/// direction out, because an arrow alone cannot say whether it means the wind's
/// source or its heading.
struct APRSWeatherSummaryView: View {

    let weather: APRSWeather
    /// When the reading was taken, so an old one can say so. A temperature
    /// from this morning looks exactly like a temperature from a minute ago.
    var heard: Date?
    /// This station's readings over time. What the barometer is *doing* is
    /// the only forecast a single surface station can give, and it is the one
    /// that keeps working with no service, no internet and no model.
    var history: [Station.WeatherSample] = []
    /// Fahrenheit, mph and inches when true; Celsius, km/h and millimetres
    /// when false. The map's existing distance preference decides.
    var inImperial: Bool = true
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                if let temperature = weather.temperatureText(inFahrenheit: inImperial) {
                    Text(temperature)
                        .font(.system(size: 21, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.teal)
                        .fixedSize()
                        .accessibilityLabel("Temperature \(temperature)")
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let humidity = weather.humidityPercent {
                        reading("humidity.fill", "\(humidity)% humidity")
                    }
                    if let pressure = weather.pressureTenthsMillibars {
                        reading("barometer",
                                String(format: "%.1f mb", Double(pressure) / 10))
                    }
                    if let rain = rainText {
                        reading("drop.fill", rain)
                    }
                    if let snow = snowText {
                        reading("snowflake", snow)
                    }
                }
            }

            if let wind = windText {
                HStack(spacing: 4) {
                    // Points the way the wind is blowing. APRS reports the
                    // direction it comes *from*, hence the half turn.
                    Image(systemName: weather.windDirectionDegrees == nil
                          ? "wind" : "location.north.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(Double(weather.windDirectionDegrees ?? 0) + 180))
                        .accessibilityHidden(true)
                    Text(wind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            // What the barometer is doing, and what that conventionally
            // means. Above the staleness note because it is the reason to
            // look at a weather station before the weather arrives.
            if let tendency = APRSWeatherTrend.pressureTendency(history, now: now) {
                let outlook = APRSWeatherTrend.Outlook.of(tendency.perThreeHours)
                HStack(spacing: 4) {
                    Image(systemName: outlook.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(outlook.isNotable ? .orange : .secondary)
                        .accessibilityHidden(true)
                    Text("Barometer \(outlook.summary)")
                        .font(.caption)
                        .foregroundStyle(outlook.isNotable ? .primary : .secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .help(String(format: "%+.1f mb over the last %.1f hours, measured from this "
                             + "station's own beacons. Three hours is the standard window every "
                             + "published reading of a barometric fall is written against.",
                             tendency.changeMillibars, tendency.span / 3600))
            }

            if let age = staleNote {
                Text(age)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Weather goes stale invisibly \u{2014} an old temperature looks exactly "
                          + "like a current one, so its age is named once it is no longer current.")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func reading(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "1 mph from S, gusting 2 mph" — the model already words this, so the
    /// card and the tooltip can never describe the same reading differently.
    private var windText: String? {
        weather.summaryLines(inImperial: inImperial).first { $0.hasPrefix("Wind") }
    }

    private var rainText: String? {
        weather.summaryLines(inImperial: inImperial)
            .first { $0.hasPrefix("Rain") }
            .map { String($0.dropFirst("Rain ".count)) + " rain" }
    }

    private var snowText: String? {
        weather.summaryLines(inImperial: inImperial).first { $0.hasPrefix("Snow") }
    }

    private var staleNote: String? {
        guard let heard,
              now.timeIntervalSince(heard) > HeardStationMap.weatherFreshWindow
        else { return nil }
        return "Reading taken \(heard.formatted(.relative(presentation: .named)))"
    }
}
