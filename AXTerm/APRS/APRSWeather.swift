import Foundation

/// The weather a station reported in an APRS beacon.
///
/// APRS carries weather as fixed-width, single-letter fields appended to a
/// position report whose symbol code is `_`, or as a standalone "positionless"
/// report (DTI `_`). Every field is optional and a station that has no sensor
/// for one sends dots or spaces in its place — so every property here is an
/// optional, and a missing value is an absence rather than a zero. Reporting
/// `0 mph` for a station with no anemometer would be a fabrication.
///
/// Units are the wire's own (Fahrenheit, mph, hundredths of an inch, tenths of
/// a millibar) so the parse is lossless; conversion happens at display time.
nonisolated struct APRSWeather: Equatable, Hashable, Sendable {
    /// Direction the wind blows *from*, degrees true.
    var windDirectionDegrees: Int?
    /// Sustained wind, mph.
    var windSpeedMPH: Int?
    /// Peak gust over the last five minutes, mph.
    var gustMPH: Int?
    /// Air temperature, degrees Fahrenheit. Negative values are on the wire
    /// as `-01`…`-99`.
    var temperatureF: Int?
    /// Rainfall in the last hour, hundredths of an inch.
    var rainLastHourHundredths: Int?
    /// Rainfall in the last 24 hours, hundredths of an inch.
    var rainLast24HoursHundredths: Int?
    /// Rainfall since local midnight, hundredths of an inch.
    var rainSinceMidnightHundredths: Int?
    /// Relative humidity, percent. `h00` on the wire means 100%.
    var humidityPercent: Int?
    /// Barometric pressure, tenths of a millibar (hPa).
    var pressureTenthsMillibars: Int?
    /// Snowfall in the last 24 hours, inches.
    var snowfallInches: Int?
    /// Luminosity, watts per square metre.
    var luminosityWattsPerSquareMetre: Int?

    /// True when the station reported nothing at all — every field absent.
    /// A report like that is not weather and must not be shown as any.
    var isEmpty: Bool {
        windDirectionDegrees == nil && windSpeedMPH == nil && gustMPH == nil
            && temperatureF == nil && rainLastHourHundredths == nil
            && rainLast24HoursHundredths == nil && rainSinceMidnightHundredths == nil
            && humidityPercent == nil && pressureTenthsMillibars == nil
            && snowfallInches == nil && luminosityWattsPerSquareMetre == nil
    }
}

// MARK: - Parsing

extension APRSWeather {

    /// Which shape of report the fields came from. The two differ in one
    /// place that matters: `s` means wind speed in a positionless report and
    /// snowfall in a position report, so the caller must say which it has
    /// rather than let the parser guess.
    nonisolated enum Form: Sendable {
        /// Appended to a position report whose symbol code is `_`. Wind rides
        /// in the leading `ddd/sss` slot (the one a moving station uses for
        /// course and speed).
        case withPosition
        /// A standalone report, DTI `_`, with no position at all. Wind
        /// direction is `c` and wind speed is `s`.
        case positionless
    }

    /// Parses the weather fields at the start of `payload`, stopping at the
    /// first thing that is not a weather field — everything after that is the
    /// station's comment (software and unit identifiers such as `wRSW` live
    /// there, and must not be mistaken for data).
    ///
    /// - Returns: nil when nothing parsed, so "no weather" never arrives as an
    ///   empty reading.
    nonisolated static func parse(_ payload: String, form: Form) -> APRSWeather? {
        scan(payload, form: form).weather
    }

    /// The weather fields at the start of `payload` and whatever follows them.
    /// The split matters: the tail is the station's own comment, and it has to
    /// survive as the comment rather than be eaten as data.
    nonisolated static func scan(_ payload: String, form: Form) -> (weather: APRSWeather?, comment: String) {
        var weather = APRSWeather()
        let chars = Array(payload)
        var index = 0

        if form == .withPosition {
            // `ddd/sss` — wind direction and sustained speed, in the slot a
            // moving station uses for course and speed. Either half may be
            // dots or spaces when the station has no anemometer.
            if chars.count >= 7, chars[3] == "/" {
                weather.windDirectionDegrees = number(chars, 0, 3, range: 0...360)
                weather.windSpeedMPH = number(chars, 4, 3, range: 0...999)
                index = 7
            }
        }

        // Fixed-width keyed fields, in whatever order the station sends them.
        loop: while index < chars.count {
            let key = chars[index]
            let width: Int
            switch key {
            case "g", "t", "r", "p", "P", "L", "l", "#": width = 3
            case "c":                                    width = 3
            case "s":                                    width = 3
            case "h":                                    width = 2
            case "b":                                    width = 5
            default: break loop
            }
            guard index + 1 + width <= chars.count else { break loop }
            let value = number(chars, index + 1, width, range: nil)
            // Temperature is the one field that may carry a sign: below zero
            // it rides as `-01`…`-99` inside the same three characters, which
            // the plain digit reader rejects.
            let signed = key == "t" ? signedNumber(chars, index + 1, width) : nil
            // A key whose field is neither a number nor the "no sensor" filler
            // is not a weather field at all — it is the comment starting with
            // a letter that happens to collide with a key.
            guard value != nil || signed != nil || isFiller(chars, index + 1, width)
            else { break loop }

            switch key {
            case "g": weather.gustMPH = value
            case "t": weather.temperatureF = signed
            case "r": weather.rainLastHourHundredths = value
            case "p": weather.rainLast24HoursHundredths = value
            case "P": weather.rainSinceMidnightHundredths = value
            case "h":
                // `h00` is 100%, not zero — the field only has room for two
                // digits, so full saturation wraps.
                weather.humidityPercent = value.map { $0 == 0 ? 100 : $0 }
            case "b": weather.pressureTenthsMillibars = value
            case "L": weather.luminosityWattsPerSquareMetre = value
            case "l": weather.luminosityWattsPerSquareMetre = value.map { $0 + 1000 }
            case "c" where form == .positionless:
                weather.windDirectionDegrees = value.flatMap { (0...360).contains($0) ? $0 : nil }
            case "s":
                if form == .positionless {
                    weather.windSpeedMPH = value
                } else {
                    weather.snowfallInches = value
                }
            case "#": break   // raw rain counter — a tick count, not a depth
            default: break
            }
            index += 1 + width
        }

        let comment = String(chars[index...])
        return weather.isEmpty ? (nil, payload) : (weather, comment)
    }

    /// Digits at `offset`, or nil when the station sent the "no sensor"
    /// filler (dots or spaces) or anything else non-numeric.
    private static func number(_ chars: [Character], _ offset: Int, _ width: Int,
                               range: ClosedRange<Int>?) -> Int? {
        guard offset + width <= chars.count else { return nil }
        let field = String(chars[offset..<(offset + width)])
        guard field.allSatisfy(\.isNumber), let value = Int(field) else { return nil }
        if let range, !range.contains(value) { return nil }
        return value
    }

    /// Like `number`, but accepts a leading `-`: temperatures below zero ride
    /// as `-01`…`-99` inside the same three characters.
    private static func signedNumber(_ chars: [Character], _ offset: Int, _ width: Int) -> Int? {
        guard offset + width <= chars.count else { return nil }
        let field = String(chars[offset..<(offset + width)])
        if field.hasPrefix("-") {
            let digits = field.dropFirst()
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits) else { return nil }
            return -value
        }
        return number(chars, offset, width, range: nil)
    }

    /// The "I have no sensor for this" filler: dots or spaces.
    private static func isFiller(_ chars: [Character], _ offset: Int, _ width: Int) -> Bool {
        guard offset + width <= chars.count else { return false }
        return chars[offset..<(offset + width)].allSatisfy { $0 == "." || $0 == " " }
    }
}

// MARK: - Display

extension APRSWeather {

    /// The temperature, formatted for the operator's unit preference — the
    /// same preference the map already keys distances by, so one setting
    /// governs the whole page.
    func temperatureText(inFahrenheit: Bool) -> String? {
        guard let temperatureF else { return nil }
        if inFahrenheit { return "\(temperatureF)°F" }
        return "\(Int(((Double(temperatureF) - 32) * 5 / 9).rounded()))°C"
    }

    /// One short line per reading the station actually sent, for the station
    /// card and the tooltip. Empty when nothing was reported.
    ///
    /// Every line names its units. A bare "12" beside a wind arrow is the kind
    /// of number an operator has to go and look up, which is exactly what the
    /// card exists to prevent.
    func summaryLines(inImperial: Bool) -> [String] {
        var lines: [String] = []

        var conditions: [String] = []
        if let temperature = temperatureText(inFahrenheit: inImperial) {
            conditions.append(temperature)
        }
        if let humidityPercent { conditions.append("humidity \(humidityPercent)%") }
        if let pressureTenthsMillibars {
            conditions.append(String(format: "%.1f mb", Double(pressureTenthsMillibars) / 10))
        }
        if !conditions.isEmpty { lines.append(conditions.joined(separator: " · ")) }

        if let wind = windText(inImperial: inImperial) { lines.append(wind) }
        if let rain = rainText(inImperial: inImperial) { lines.append(rain) }
        if let snowfallInches, snowfallInches > 0 {
            lines.append(inImperial
                         ? "Snow \(snowfallInches) in in 24 h"
                         : String(format: "Snow %.0f cm in 24 h", Double(snowfallInches) * 2.54))
        }
        return lines
    }

    /// "Wind 12 mph from NW, gusting 20 mph" — only the parts that were sent.
    /// A gust with no sustained reading still says something, so it is not
    /// suppressed for want of its companion.
    private func windText(inImperial: Bool) -> String? {
        func speed(_ mph: Int) -> String {
            inImperial ? "\(mph) mph" : "\(Int((Double(mph) * 1.609344).rounded())) km/h"
        }
        var parts: [String] = []
        if let windSpeedMPH {
            // Calm is a real reading from a station that has an anemometer,
            // and "Wind calm" says more than "Wind 0 mph".
            parts.append(windSpeedMPH == 0 ? "Wind calm" : "Wind \(speed(windSpeedMPH))")
            if windSpeedMPH > 0, let windDirectionDegrees {
                parts[0] += " from \(GreatCircle.compassPoint(Double(windDirectionDegrees)))"
            }
        } else if let windDirectionDegrees {
            parts.append("Wind from \(GreatCircle.compassPoint(Double(windDirectionDegrees)))")
        }
        if let gustMPH, gustMPH > 0 { parts.append("gusting \(speed(gustMPH))") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Rain, in the two windows worth reading: the last hour and today.
    private func rainText(inImperial: Bool) -> String? {
        func depth(_ hundredths: Int) -> String {
            inImperial
                ? String(format: "%.2f in", Double(hundredths) / 100)
                : String(format: "%.1f mm", Double(hundredths) * 0.254)
        }
        var parts: [String] = []
        if let rainLastHourHundredths, rainLastHourHundredths > 0 {
            parts.append("\(depth(rainLastHourHundredths)) last hour")
        }
        if let rainSinceMidnightHundredths, rainSinceMidnightHundredths > 0 {
            parts.append("\(depth(rainSinceMidnightHundredths)) today")
        } else if let rainLast24HoursHundredths, rainLast24HoursHundredths > 0 {
            parts.append("\(depth(rainLast24HoursHundredths)) in 24 h")
        }
        return parts.isEmpty ? nil : "Rain " + parts.joined(separator: " · ")
    }
}
