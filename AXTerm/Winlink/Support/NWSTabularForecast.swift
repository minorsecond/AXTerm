import Foundation

/// A National Weather Service **tabular state forecast** (AWIPS product
/// `SFTxx`), parsed out of a Winlink catalog product's body.
///
/// These arrive as fixed-width text: a row of forecast days across the
/// top, then, per city, three lines in a fixed cadence — predominant
/// daytime weather, `low/high` temperatures, and `night/day` probability
/// of precipitation. Monospaced text preserves the alignment but leaves
/// the operator counting columns to answer "will it storm in Pueblo on
/// Thursday". A parsed table answers it directly.
///
/// Parsing is **structural, not semantic**. Columns come from the
/// product's own whitespace runs rather than assumed character offsets,
/// the day count comes from the `FCST` header row rather than a constant,
/// and any weather abbreviation not in `weatherNames` is displayed
/// verbatim rather than guessed at. If the product does not match the
/// expected shape, `parse` returns nil and the reading pane shows the raw
/// text unchanged — a half-understood forecast is worse than a plain one.
nonisolated struct NWSTabularForecast: Equatable, Sendable {

    struct Day: Equatable, Sendable, Identifiable {
        /// "Tue"
        var weekday: String
        /// "Aug 25"
        var date: String
        var id: String { "\(weekday) \(date)" }
    }

    struct Cell: Equatable, Sendable {
        /// The product's own abbreviation, always kept: "Ptcldy".
        var weatherCode: String
        /// Early-morning low, in °F. Nil for `MM` (missing).
        var low: Int?
        /// Daytime high, in °F. Nil for `MM`.
        var high: Int?
        /// Probability of precipitation, nighttime 6PM–6AM, percent.
        var popNight: Int?
        /// Probability of precipitation, daytime 6AM–6PM, percent.
        var popDay: Int?

        /// Expanded name where the abbreviation is known, otherwise the
        /// product's own token — never a guess.
        var weatherName: String {
            NWSTabularForecast.weatherNames[weatherCode.uppercased()] ?? weatherCode
        }

        var symbolName: String {
            NWSTabularForecast.weatherSymbols[weatherCode.uppercased()] ?? "questionmark.circle"
        }

        /// The higher of the two periods — what a "will it rain?" glance
        /// actually wants.
        var peakPop: Int? {
            [popNight, popDay].compactMap { $0 }.max()
        }
    }

    struct Place: Equatable, Sendable, Identifiable {
        /// "COLORADO SPRINGS"
        var name: String
        /// One cell per day, in `days` order. Places whose cadence broke
        /// mid-product are dropped rather than padded with invented data.
        var cells: [Cell]
        var id: String { name }
    }

    struct Section: Equatable, Sendable, Identifiable {
        /// "Northeast Colorado"
        var title: String
        var places: [Place]
        var id: String { title }
    }

    /// AWIPS product identifier, e.g. `SFTCO`.
    var productId: String
    /// "Tabular State Forecast for Colorado"
    var title: String
    /// Issuing office line, e.g. "National Weather Service Denver/Boulder CO".
    var office: String
    /// Issuance timestamp exactly as printed: "1247 AM MDT Mon Aug 24 2026".
    var issued: String
    var days: [Day]
    var sections: [Section]

    var placeCount: Int { sections.reduce(0) { $0 + $1.places.count } }

    // MARK: - Parsing

    /// Returns nil for anything that is not a tabular state forecast, or
    /// whose day header cannot be read.
    /// Every place in the product, flattened, in the product's own order.
    var allPlaces: [Place] { sections.flatMap(\.places) }

    /// The section a place belongs to, for the picker's grouping.
    func sectionTitle(for place: Place) -> String? {
        sections.first { $0.places.contains(where: { $0.name == place.name }) }?.title
    }

    /// Which place to show first.
    ///
    /// A state forecast lists two dozen cities and the operator cares about
    /// one of them. Matching the station's own locality gets that right most
    /// of the time; otherwise the product's first city is as good a guess as
    /// any, and the picker is one tap away.
    ///
    /// Matching is loose on purpose: the product writes "COLORADO SPRINGS"
    /// and a licence record writes "Colorado Springs".
    func defaultPlace(preferring locality: String?) -> Place? {
        let places = allPlaces
        guard !places.isEmpty else { return nil }
        guard let wanted = locality?
            .trimmingCharacters(in: .whitespaces)
            .uppercased(), !wanted.isEmpty else { return places.first }

        if let exact = places.first(where: { $0.name.uppercased() == wanted }) {
            return exact
        }
        // "Denver Intl" should still find "DENVER", and a licence saying
        // "Aurora" should find it inside a longer product name.
        if let partial = places.first(where: {
            let name = $0.name.uppercased()
            return name.contains(wanted) || wanted.contains(name)
        }) {
            return partial
        }
        return places.first
    }

    static func parse(_ text: String) -> NWSTabularForecast? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let productId = awipsProductId(in: lines) else { return nil }

        // The `FCST` row states how many day columns follow; everything
        // downstream is validated against that count rather than a
        // hard-coded seven.
        guard let headerIndex = lines.firstIndex(where: { line in
            let tokens = columns(of: line)
            return tokens.count > 1 && tokens.allSatisfy { $0.uppercased() == "FCST" }
        }) else { return nil }

        let dayCount = columns(of: lines[headerIndex]).count
        // The two rows under the header carry weekday and date. Blank
        // lines between them are normal, so step by content rather than
        // by offset — and remember where the dates ended, because the
        // city blocks start after that, not after the header.
        let afterHeader = lines.indices
            .filter { $0 > headerIndex && !lines[$0].trimmed.isEmpty }
        guard afterHeader.count >= 2 else { return nil }
        let weekdays = columns(of: lines[afterHeader[0]])
        let dates = columns(of: lines[afterHeader[1]])
        guard weekdays.count == dayCount, dates.count == dayCount else { return nil }

        let days = zip(weekdays, dates).map { Day(weekday: $0, date: $1) }

        return NWSTabularForecast(
            productId: productId,
            title: titleLine(in: lines) ?? "Tabular State Forecast",
            office: officeLine(in: lines) ?? "",
            issued: issuedLine(in: lines) ?? "",
            days: days,
            sections: sections(in: Array(lines[(afterHeader[1] + 1)...]), dayCount: dayCount))
    }

    /// Walks the city blocks. A section header is `...LIKE THIS...`; a
    /// place is a line that is not a data row, followed by exactly three
    /// data rows. `$$` ends the product — everything after it is the
    /// Winlink footer, not forecast.
    private static func sections(in lines: [String], dayCount: Int) -> [Section] {
        var sections: [Section] = []
        var currentTitle = ""
        var currentPlaces: [Place] = []
        var pendingName: String?
        var pendingRows: [[String]] = []

        func flushPlace() {
            defer { pendingName = nil; pendingRows = [] }
            guard let name = pendingName, pendingRows.count == 3 else { return }
            let cells = (0..<dayCount).map { index in
                let (low, high) = pair(pendingRows[1][index])
                let (night, day) = pair(pendingRows[2][index])
                return Cell(weatherCode: pendingRows[0][index],
                            low: low, high: high, popNight: night, popDay: day)
            }
            currentPlaces.append(Place(name: name, cells: cells))
        }

        func flushSection() {
            flushPlace()
            guard !currentPlaces.isEmpty else { currentPlaces = []; return }
            sections.append(Section(
                title: currentTitle.isEmpty ? "Forecast" : currentTitle,
                places: currentPlaces))
            currentPlaces = []
        }

        for line in lines {
            let trimmed = line.trimmed
            if trimmed == "$$" { break }
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("...") && trimmed.hasSuffix("...") && trimmed.count > 6 {
                flushSection()
                currentTitle = trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .capitalized
                continue
            }

            let tokens = columns(of: line)
            if tokens.count == dayCount, pendingName != nil, pendingRows.count < 3 {
                pendingRows.append(tokens)
                if pendingRows.count == 3 { flushPlace() }
                continue
            }
            // Anything else starts a new place. The legend block above
            // the table lands here too, but never collects three data
            // rows, so `flushPlace` discards it.
            flushPlace()
            pendingName = trimmed
        }
        flushSection()
        return sections
    }

    /// Splits a fixed-width row on runs of **two or more** blanks.
    ///
    /// Not on single spaces: a date column reads "Aug 25" and a city
    /// "COLORADO SPRINGS", both of which carry an internal space that a
    /// naive whitespace split would tear in half — taking the column
    /// count with it. Character offsets are not used either, since
    /// column widths vary between products and offices; a run of blanks
    /// between values is the one thing the format guarantees.
    private static func columns(of line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var blankRun = 0
        for character in line {
            if character == " " || character == "\t" {
                blankRun += 1
                if blankRun >= 2, !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                // A single blank is inside a value, not between two.
                if blankRun == 1, !current.isEmpty { current.append(" ") }
                blankRun = 0
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// `62/88` → (62, 88). `MM` and unparseable halves become nil, which
    /// the UI renders as "—" rather than as a temperature.
    private static func pair(_ token: String) -> (Int?, Int?) {
        let parts = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (nil, nil) }
        return (Int(parts[0]), Int(parts[1]))
    }

    /// The AWIPS identifier sits on its own line near the top: three
    /// letters of product category plus a two-letter state. Only `SFT`
    /// (tabular state forecast) is claimed here.
    private static func awipsProductId(in lines: [String]) -> String? {
        for line in lines.prefix(6) {
            let candidate = line.trimmed.uppercased()
            guard candidate.count == 5, candidate.hasPrefix("SFT") else { continue }
            guard candidate.allSatisfy({ $0.isLetter }) else { continue }
            return candidate
        }
        return nil
    }

    private static func titleLine(in lines: [String]) -> String? {
        lines.first { $0.localizedCaseInsensitiveContains("Tabular State Forecast") }?.trimmed
    }

    private static func officeLine(in lines: [String]) -> String? {
        lines.first { $0.localizedCaseInsensitiveContains("National Weather Service") }?.trimmed
    }

    /// The issuance line follows the office line and carries a time zone
    /// and a year — matched on shape so a reformat does not break it.
    private static func issuedLine(in lines: [String]) -> String? {
        lines.first { line in
            let trimmed = line.trimmed
            guard trimmed.contains(" AM ") || trimmed.contains(" PM ") else { return false }
            return trimmed.split(separator: " ").count >= 6
        }?.trimmed
    }

    // MARK: - Weather abbreviations

    /// NWS tabular-forecast weather abbreviations.
    ///
    /// `SUNNY`, `PTCLDY`, `TSTRMS` and `VRYHOT` are confirmed against the
    /// 2026-08-24 SFTCO capture; the rest follow the same six-character
    /// convention the product uses. Anything absent here is shown as the
    /// product wrote it — see `Cell.weatherName`.
    static let weatherNames: [String: String] = [
        "SUNNY": "Sunny",
        "MOSUNY": "Mostly Sunny",
        "PTSUNY": "Partly Sunny",
        "PTCLDY": "Partly Cloudy",
        "MOCLDY": "Mostly Cloudy",
        "CLOUDY": "Cloudy",
        "TSTRMS": "Thunderstorms",
        "RAIN": "Rain",
        "RNSHWR": "Rain Showers",
        "SHOWRS": "Showers",
        "DRIZZL": "Drizzle",
        "SNOW": "Snow",
        "SNSHWR": "Snow Showers",
        "FLURRY": "Flurries",
        "SLEET": "Sleet",
        "FRZRN": "Freezing Rain",
        "BLZZRD": "Blizzard",
        "WINDY": "Windy",
        "FOGGY": "Fog",
        "HAZY": "Haze",
        "SMOKE": "Smoke",
        "VRYHOT": "Very Hot",
        "HOT": "Hot",
        "VRYCLD": "Very Cold",
        "COLD": "Cold",
    ]

    /// SF Symbols for the same set. Unknown codes get a neutral marker
    /// rather than a plausible-looking wrong icon.
    static let weatherSymbols: [String: String] = [
        "SUNNY": "sun.max",
        "MOSUNY": "sun.max",
        "PTSUNY": "cloud.sun",
        "PTCLDY": "cloud.sun",
        "MOCLDY": "cloud",
        "CLOUDY": "cloud.fill",
        "TSTRMS": "cloud.bolt.rain",
        "RAIN": "cloud.rain",
        "RNSHWR": "cloud.sun.rain",
        "SHOWRS": "cloud.rain",
        "DRIZZL": "cloud.drizzle",
        "SNOW": "cloud.snow",
        "SNSHWR": "cloud.snow",
        "FLURRY": "snowflake",
        "SLEET": "cloud.sleet",
        "FRZRN": "cloud.sleet",
        "BLZZRD": "wind.snow",
        "WINDY": "wind",
        "FOGGY": "cloud.fog",
        "HAZY": "sun.haze",
        "SMOKE": "smoke",
        "VRYHOT": "thermometer.sun.fill",
        "HOT": "thermometer.sun",
        "VRYCLD": "thermometer.snowflake",
        "COLD": "thermometer.snowflake",
    ]
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
