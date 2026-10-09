import Foundation

/// The NWS's own colors and priorities for its hazards, from the legend of
/// its hazard map (weather.gov/help-map, read 2026-10-09). Priority 1 is the
/// most urgent; it orders the "Inside" line and which polygon draws on top.
nonisolated enum NWSHazardStyle {
    struct Style: Equatable, Sendable {
        let priority: Int
        /// RGB as six hex digits, e.g. "FF0000".
        let hex: String
    }

    /// An event the table does not list: drawn in plain gray and ranked
    /// below every listed one, rather than guessed at.
    static let unlisted = Style(priority: 1000, hex: "A9A9A9")

    static func style(for event: String) -> Style {
        table[event] ?? unlisted
    }

    static let table: [String: Style] = [
        "Tsunami Warning": Style(priority: 1, hex: "FD6347"),
        "Tornado Warning": Style(priority: 2, hex: "FF0000"),
        "Extreme Wind Warning": Style(priority: 3, hex: "FF8C00"),
        "Severe Thunderstorm Warning": Style(priority: 4, hex: "FFA500"),
        "Flash Flood Warning": Style(priority: 5, hex: "8B0000"),
        "Flash Flood Statement": Style(priority: 6, hex: "8B0000"),
        "Severe Weather Statement": Style(priority: 7, hex: "00FFFF"),
        "Shelter In Place Warning": Style(priority: 8, hex: "FA8072"),
        "Evacuation Immediate": Style(priority: 9, hex: "7FFF00"),
        "Civil Danger Warning": Style(priority: 10, hex: "FFB6C1"),
        "Nuclear Power Plant Warning": Style(priority: 11, hex: "4B0082"),
        "Radiological Hazard Warning": Style(priority: 12, hex: "4B0082"),
        "Hazardous Materials Warning": Style(priority: 13, hex: "4B0082"),
        "Fire Warning": Style(priority: 14, hex: "A0522D"),
        "Civil Emergency Message": Style(priority: 15, hex: "FFB6C1"),
        "Law Enforcement Warning": Style(priority: 16, hex: "C0C0C0"),
        "Storm Surge Warning": Style(priority: 17, hex: "B524F7"),
        "Hurricane Force Wind Warning": Style(priority: 18, hex: "CD5C5C"),
        "Hurricane Warning": Style(priority: 19, hex: "DC143C"),
        "Typhoon Warning": Style(priority: 20, hex: "DC143C"),
        "Special Marine Warning": Style(priority: 21, hex: "FFA500"),
        "Blizzard Warning": Style(priority: 22, hex: "FF4500"),
        "Snow Squall Warning": Style(priority: 23, hex: "C71585"),
        "Ice Storm Warning": Style(priority: 24, hex: "8B008B"),
        "Heavy Freezing Spray Warning": Style(priority: 25, hex: "00BFFF"),
        "Winter Storm Warning": Style(priority: 26, hex: "FF69B4"),
        "Lake Effect Snow Warning": Style(priority: 27, hex: "008B8B"),
        "Dust Storm Warning": Style(priority: 28, hex: "FFE4C4"),
        "Blowing Dust Warning": Style(priority: 29, hex: "FFE4C4"),
        "High Wind Warning": Style(priority: 30, hex: "DAA520"),
        "Tropical Storm Warning": Style(priority: 31, hex: "B22222"),
        "Storm Warning": Style(priority: 32, hex: "9400D3"),
        "Tsunami Advisory": Style(priority: 33, hex: "D2691E"),
        "Tsunami Watch": Style(priority: 34, hex: "FF00FF"),
        "Avalanche Warning": Style(priority: 35, hex: "1E90FF"),
        "Earthquake Warning": Style(priority: 36, hex: "8B4513"),
        "Volcano Warning": Style(priority: 37, hex: "2F4F4F"),
        "Ashfall Warning": Style(priority: 38, hex: "A9A9A9"),
        "Flood Warning": Style(priority: 39, hex: "00FF00"),
        "Coastal Flood Warning": Style(priority: 40, hex: "228B22"),
        "Lakeshore Flood Warning": Style(priority: 41, hex: "228B22"),
        "Ashfall Advisory": Style(priority: 42, hex: "696969"),
        "High Surf Warning": Style(priority: 43, hex: "228B22"),
        "Extreme Heat Warning": Style(priority: 44, hex: "C71585"),
        "Tornado Watch": Style(priority: 45, hex: "FFFF00"),
        "Severe Thunderstorm Watch": Style(priority: 46, hex: "DB7093"),
        "Flash Flood Watch": Style(priority: 47, hex: "2E8B57"),
        "Gale Warning": Style(priority: 48, hex: "DDA0DD"),
        "Flood Statement": Style(priority: 49, hex: "00FF00"),
        "Extreme Cold Warning": Style(priority: 50, hex: "0000FF"),
        "Freeze Warning": Style(priority: 51, hex: "483D8B"),
        "Red Flag Warning": Style(priority: 52, hex: "FF1493"),
        "Storm Surge Watch": Style(priority: 53, hex: "DB7FF7"),
        "Hurricane Watch": Style(priority: 54, hex: "FF00FF"),
        "Hurricane Force Wind Watch": Style(priority: 55, hex: "9932CC"),
        "Typhoon Watch": Style(priority: 56, hex: "FF00FF"),
        "Tropical Storm Watch": Style(priority: 57, hex: "F08080"),
        "Storm Watch": Style(priority: 58, hex: "FFE4B5"),
        "Tropical Cyclone Local Statement": Style(priority: 59, hex: "FFE4B5"),
        "Winter Weather Advisory": Style(priority: 60, hex: "7B68EE"),
        "Avalanche Advisory": Style(priority: 61, hex: "CD853F"),
        "Cold Weather Advisory": Style(priority: 62, hex: "AFEEEE"),
        "Heat Advisory": Style(priority: 63, hex: "FF7F50"),
        "Flood Advisory": Style(priority: 64, hex: "00FF7F"),
        "Coastal Flood Advisory": Style(priority: 65, hex: "7CFC00"),
        "Lakeshore Flood Advisory": Style(priority: 66, hex: "7CFC00"),
        "High Surf Advisory": Style(priority: 67, hex: "BA55D3"),
        "Dense Fog Advisory": Style(priority: 68, hex: "708090"),
        "Dense Smoke Advisory": Style(priority: 69, hex: "F0E68C"),
        "Small Craft Advisory": Style(priority: 70, hex: "D8BFD8"),
        "Brisk Wind Advisory": Style(priority: 71, hex: "D8BFD8"),
        "Hazardous Seas Warning": Style(priority: 72, hex: "D8BFD8"),
        "Dust Advisory": Style(priority: 73, hex: "BDB76B"),
        "Blowing Dust Advisory": Style(priority: 74, hex: "BDB76B"),
        "Lake Wind Advisory": Style(priority: 75, hex: "D2B48C"),
        "Wind Advisory": Style(priority: 76, hex: "D2B48C"),
        "Frost Advisory": Style(priority: 77, hex: "6495ED"),
        "Freezing Fog Advisory": Style(priority: 78, hex: "008080"),
        "Freezing Spray Advisory": Style(priority: 79, hex: "00BFFF"),
        "Low Water Advisory": Style(priority: 80, hex: "A52A2A"),
        "Local Area Emergency": Style(priority: 81, hex: "C0C0C0"),
        "Winter Storm Watch": Style(priority: 82, hex: "4682B4"),
        "Rip Current Statement": Style(priority: 83, hex: "40E0D0"),
        "Beach Hazards Statement": Style(priority: 84, hex: "40E0D0"),
        "Gale Watch": Style(priority: 85, hex: "FFC0CB"),
        "Avalanche Watch": Style(priority: 86, hex: "F4A460"),
        "Hazardous Seas Watch": Style(priority: 87, hex: "483D8B"),
        "Heavy Freezing Spray Watch": Style(priority: 88, hex: "BC8F8F"),
        "Flood Watch": Style(priority: 89, hex: "2E8B57"),
        "Coastal Flood Watch": Style(priority: 90, hex: "66CDAA"),
        "Lakeshore Flood Watch": Style(priority: 91, hex: "66CDAA"),
        "High Wind Watch": Style(priority: 92, hex: "B8860B"),
        "Extreme Heat Watch": Style(priority: 93, hex: "800000"),
        "Extreme Cold Watch": Style(priority: 94, hex: "5F9EA0"),
        "Freeze Watch": Style(priority: 95, hex: "00FFFF"),
        "Fire Weather Watch": Style(priority: 96, hex: "FFDEAD"),
        "Extreme Fire Danger": Style(priority: 97, hex: "E9967A"),
        "911 Telephone Outage": Style(priority: 98, hex: "C0C0C0"),
        "Coastal Flood Statement": Style(priority: 99, hex: "6B8E23"),
        "Lakeshore Flood Statement": Style(priority: 100, hex: "6B8E23"),
        "Special Weather Statement": Style(priority: 101, hex: "FFE4B5"),
        "Marine Weather Statement": Style(priority: 102, hex: "FFDAB9"),
        "Air Quality Alert": Style(priority: 103, hex: "808080"),
        "Air Stagnation Advisory": Style(priority: 104, hex: "808080"),
        "Hazardous Weather Outlook": Style(priority: 105, hex: "EEE8AA"),
        "Hydrologic Outlook": Style(priority: 106, hex: "90EE90"),
        "Short Term Forecast": Style(priority: 107, hex: "98FB98"),
        "Administrative Message": Style(priority: 108, hex: "C0C0C0"),
        "Test": Style(priority: 109, hex: "F0FFFF"),
        "Child Abduction Emergency": Style(priority: 110, hex: "FFFFFF"),
        "Blue Alert": Style(priority: 111, hex: "FFFFFF"),
    ]
}

/// The words beside a hazard. Every line says where it came from and how
/// old it is (Docs/HazardLayers.md §1).
nonisolated enum HazardText {

    /// "Red Flag Warning · NWS Boulder CO · issued 10:28 AM · until 8:00 PM ·
    /// fetched 3 min ago". A stale copy adds ", no newer copy"; an expired
    /// one says "expired" in place of "until".
    static func summary(_ feature: HazardFeature, now: Date, stale: Bool,
                        timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let time = formatter(timeZone, locale)
        var parts = [feature.event, feature.source]
        if let issued = feature.issued { parts.append("issued " + time.string(from: issued)) }
        if let expires = feature.expires {
            parts.append((feature.isExpired(at: now) ? "expired " : "until ") + time.string(from: expires))
        }
        parts.append("fetched " + age(from: feature.fetchedAt, to: now) + (stale ? ", no newer copy" : ""))
        return parts.joined(separator: " · ")
    }

    /// "Inside: Red Flag Warning until 8:00 PM", or nil when the position is
    /// inside nothing current. Inside several, the NWS's highest priority
    /// leads and the rest are counted.
    static func insideLine(_ features: [HazardFeature], at point: GreatCircle.Point, now: Date,
                           timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        let containing = features
            .filter { !$0.isExpired(at: now) }
            .filter { $0.geometry.map { HazardContainment.contains($0, point) } ?? false }
            .sorted { NWSHazardStyle.style(for: $0.event).priority < NWSHazardStyle.style(for: $1.event).priority }
        guard let first = containing.first else { return nil }
        var line = "Inside: " + first.event
        if let expires = first.expires { line += " until " + formatter(timeZone, locale).string(from: expires) }
        if containing.count > 1 { line += ", and \(containing.count - 1) more" }
        return line
    }

    /// The line under the layer's switch: how many alerts and how old, or
    /// that the ones shown are old because no newer copy came.
    static func layerCaption(count: Int, lastFetched: Date?, problem: String?, stale: Bool, now: Date,
                             scope: NWSAlertScope = .here, pausedUntil: Date? = nil, rejected: Bool = false,
                             unplaced: Int = 0,
                             zonesLoading: Int = 0,
                             activity: NWSAlertLayer.Activity? = nil,
                             timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let loading: String
        switch (unplaced, zonesLoading) {
        case (0, 0): loading = ""
        case (0, _): loading = " · \(zonesLoading) zones still loading"
        default: loading = " · \(unplaced) more being placed (\(zonesLoading) zones loading)"
        }
        let paused = pausedUntil.map {
            "NWS asked to slow down; next try " + formatter(timeZone, locale).string(from: $0)
        }
        let refused = rejected ? "NWS did not accept that area" : nil
        if let activity {
            let doing: String
            switch activity {
            case .fetchingAlerts: doing = "Fetching alerts…"
            case .loadingOutlines(let done, let total): doing = "Loading outlines \(min(done + 1, total)) of \(total)…"
            }
            guard let lastFetched, count > 0 else { return doing }
            return "\(doing) · showing \(count == 1 ? "1 alert" : "\(count) alerts") fetched \(age(from: lastFetched, to: now))"
        }
        guard let lastFetched else {
            return paused ?? refused ?? (problem == nil ? "Not fetched yet" : "Could not reach the NWS")
        }
        var alerts = count == 1 ? "1 alert" : "\(count) alerts"
        if case .within = scope, count > 0 { alerts += " " + scope.summary.lowercased() }
        let age = age(from: lastFetched, to: now)
        if let paused { return "\(paused) · showing \(alerts) fetched \(age)" + loading }
        if let refused { return "\(refused) · showing \(alerts) fetched \(age)" }
        if problem != nil { return "Offline · showing \(alerts) fetched \(age)" + loading }
        let lead = count == 0 ? noAlerts(in: scope) : alerts
        return "\(lead) · fetched \(age)" + (stale ? ", no newer copy" : "") + loading
    }

    /// "No alerts here" for the station's point; a wider area is named.
    private static func noAlerts(in scope: NWSAlertScope) -> String {
        switch scope {
        case .here: return "No alerts here"
        case .within: return "No alerts " + scope.summary.lowercased()
        case .states(let codes): return "No alerts in " + codes.joined(separator: ", ")
        case .zones(let codes): return "No alerts in zones " + codes.joined(separator: ", ")
        case .counties: return "No alerts in " + scope.summary(counties: CountyCenters.bundled)
        }
    }

    private static func formatter(_ timeZone: TimeZone, _ locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private static func age(from then: Date, to now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(then) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours) h ago" : "\(hours / 24) days ago"
    }
}

/// What the alert card shows for one alert (`HazardText.detail`).
struct HazardDetail: Equatable, Identifiable {
    let id: String
    let title: String
    let headline: String?
    let timing: String
    let expired: Bool
    let area: String?
    let severity: String?
    let description: [String]
    let instruction: [String]
    let source: String
    let hex: String
}

extension HazardText {
    /// The alerts whose shape holds a tapped point, the most urgent first
    /// (NWS priority), then the one that lasts longest.
    static func alerts(at point: GreatCircle.Point, in features: [HazardFeature]) -> [HazardFeature] {
        features.filter { feature in
            guard let geometry = feature.geometry, case .polygons = geometry else { return false }
            return HazardContainment.contains(geometry, point)
        }
        .sorted { a, b in
            let (pa, pb) = (NWSHazardStyle.style(for: a.event).priority, NWSHazardStyle.style(for: b.event).priority)
            if pa != pb { return pa < pb }
            return (a.expires ?? .distantFuture) > (b.expires ?? .distantFuture)
        }
    }

    /// The card for one alert: the agency's own words and times, its area,
    /// and where the copy came from and how old it is.
    static func detail(_ feature: HazardFeature, now: Date, timeZone: TimeZone = .current,
                       locale: Locale = .current) -> HazardDetail {
        let time = formatter(timeZone, locale)
        let expired = feature.expires.map { $0 <= now } ?? false
        var timing: [String] = []
        if let expires = feature.expires, expired {
            timing.append("Expired at " + time.string(from: expires))
        } else {
            if let issued = feature.issued { timing.append("Issued " + time.string(from: issued)) }
            if let expires = feature.expires { timing.append("until " + time.string(from: expires)) }
        }
        var timingText = timing.joined(separator: " · ")
        if let first = timingText.first { timingText = first.uppercased() + timingText.dropFirst() }
        let qualifiers = [feature.severity, feature.properties["urgency"], feature.properties["certainty"]]
            .compactMap { $0 }.filter { !$0.isEmpty && $0 != "Unknown" }
        return HazardDetail(
            id: feature.id, title: feature.event, headline: feature.headline,
            timing: timingText, expired: expired,
            area: feature.properties["areaDesc"].flatMap { $0.isEmpty ? nil : $0 },
            severity: qualifiers.isEmpty ? nil : qualifiers.joined(separator: " · "),
            description: paragraphs(feature.properties["description"] ?? ""),
            instruction: paragraphs(feature.properties["instruction"] ?? ""),
            source: feature.source + " · fetched " + age(from: feature.fetchedAt, to: now),
            hex: NWSHazardStyle.style(for: feature.event).hex)
    }

    /// Agency text, which arrives wrapped at about 69 columns, joined back
    /// into paragraphs. A blank line or a bullet ("* ", "- ") starts a new
    /// one.
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("* ") || line.hasPrefix("- ") { flush() }
            current += current.isEmpty ? line : " " + line
        }
        flush()
        return result
    }
}
