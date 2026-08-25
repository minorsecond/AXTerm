import Foundation

/// Turns the catalog's flat `CATEGORY` codes into a browsable hierarchy.
///
/// The Winlink catalog is ~1450 products across ~126 category codes, and
/// three quarters of those codes are `WX_US_<state>`. Listed flat that is
/// an unusable wall; grouped by the structure already present in the code
/// it is a two-level browser.
///
/// Grouping is **mechanical** — a prefix decomposition of the code, never
/// a judgement about the product — so a catalog refresh that adds new
/// codes slots them in without a code change. Token expansions come from
/// two sources only: the standard USPS state abbreviations, and codes
/// whose meaning was read off their own items' subjects in the 2026-08-24
/// field capture (`WX_US_RAD` → "SNAPSHOT CURRENT RADAR U.S. ALASKA" →
/// Radar). Anything unrecognized keeps its raw token capitalized rather
/// than being guessed at, and every row shows the raw code alongside the
/// friendly name, so nothing the gateway said is hidden or invented.
nonisolated enum WinlinkCatalogTaxonomy {

    // MARK: - Model

    struct Category: Identifiable, Hashable, Sendable {
        /// The gateway's own code — also the stable selection identity.
        var rawCategory: String
        /// Friendly leaf name within its family ("Wyoming", "Radar").
        var title: String
        var items: [WinlinkCatalogItemRecord]

        var id: String { rawCategory }
        var totalBytes: Int { items.reduce(0) { $0 + $1.sizeEstimate } }
    }

    struct Family: Identifiable, Hashable, Sendable {
        var kind: Kind
        var categories: [Category]

        var id: Kind { kind }
        var title: String { kind.title }
        var systemImage: String { kind.systemImage }
        var itemCount: Int { categories.reduce(0) { $0 + $1.items.count } }
    }

    /// Sidebar sections, in display order. Each is defined by a prefix
    /// rule over the raw code — see `family(for:)`.
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case unitedStates, world, marineZones, skyAndSpace, winlinkSystem, other

        var title: String {
            switch self {
            case .unitedStates: "United States Weather"
            case .world: "World & Marine Weather"
            case .marineZones: "METAREA Marine Zones"
            case .skyAndSpace: "Satellite & Propagation"
            case .winlinkSystem: "Winlink System"
            case .other: "Other"
            }
        }

        var systemImage: String {
            switch self {
            case .unitedStates: "flag"
            case .world: "globe"
            case .marineZones: "water.waves"
            case .skyAndSpace: "antenna.radiowaves.left.and.right"
            case .winlinkSystem: "envelope"
            case .other: "square.grid.2x2"
            }
        }
    }

    // MARK: - Grouping

    /// Groups catalog items into families of categories. Empty families
    /// are omitted; categories and items sort alphabetically by the name
    /// the operator actually reads.
    static func families(from items: [WinlinkCatalogItemRecord]) -> [Family] {
        let byCategory = Dictionary(grouping: items, by: \.category)
        var byFamily = [Kind: [Category]]()

        for (raw, categoryItems) in byCategory {
            let kind = family(for: raw)
            let category = Category(
                rawCategory: raw,
                title: leafTitle(for: raw, in: kind),
                items: categoryItems.sorted { displayTitle($0) < displayTitle($1) })
            byFamily[kind, default: []].append(category)
        }

        return Kind.allCases.compactMap { kind in
            guard let categories = byFamily[kind], !categories.isEmpty else { return nil }
            return Family(kind: kind, categories: sortCategories(categories, in: kind))
        }
    }

    /// Alphabetical by the name the operator reads — except METAREA
    /// zones, whose numerals must order I, II, V, IX, XIV rather than by
    /// spelling (alphabetically IX falls between III and V).
    private static func sortCategories(_ categories: [Category], in kind: Kind) -> [Category] {
        guard kind == .marineZones else {
            return categories.sorted { ($0.title, $0.rawCategory) < ($1.title, $1.rawCategory) }
        }
        return categories.sorted {
            (romanValue(of: $0.rawCategory), $0.rawCategory)
                < (romanValue(of: $1.rawCategory), $1.rawCategory)
        }
    }

    /// Value of the trailing roman numeral in a code, or 0 when there is
    /// none — the bare `METAREA` code sorts first.
    private static func romanValue(of rawCategory: String) -> Int {
        guard let token = rawCategory.uppercased().split(separator: "_").last,
              isRomanNumeral(String(token)) else { return 0 }
        let digits: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
        var total = 0
        var previous = 0
        for character in token.reversed() {
            let value = digits[character] ?? 0
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        return total
    }

    /// Which sidebar section a raw code belongs to. Order matters: the
    /// `WX_US` test must precede the general `WX` one.
    static func family(for rawCategory: String) -> Kind {
        let raw = rawCategory.uppercased()
        if raw == "WX_US" || raw.hasPrefix("WX_US_") { return .unitedStates }
        if raw == "WX" || raw.hasPrefix("WX_") { return .world }
        if raw.hasPrefix("METAREA") { return .marineZones }
        if raw.hasPrefix("WL2K") { return .winlinkSystem }
        if raw.hasPrefix("SAT_") || raw == "PROPAGATION" || raw == "AURORA" { return .skyAndSpace }
        if unprefixedWeatherCodes.contains(raw) { return .world }
        return .other
    }

    /// Weather codes the gateway did not prefix with `WX`. Without these
    /// the weather family silently omits every METAR and the Central
    /// American forecasts, and "Other" fills with weather. Each entry was
    /// confirmed by reading its own items' subjects in the 2026-08-24
    /// capture ("Airport metar weather - Icao Tirana - Albania",
    /// "15 day WX forecast for CATACAMAS", "Iceberg Canada East Coast
    /// Waters") — not inferred from the code alone.
    private static let unprefixedWeatherCodes: Set<String> = [
        "METAR", "HONDURAS", "NICARAGUA", "ARCTIC_ICE", "INDIAN_OCEAN", "S/PACIFIC_WX",
    ]

    /// The name shown inside a family, with the family's own prefix
    /// removed: `WX_US_WY` in United States reads simply "Wyoming".
    static func leafTitle(for rawCategory: String, in kind: Kind) -> String {
        let raw = rawCategory.uppercased()
        let prefix: String
        switch kind {
        case .unitedStates: prefix = "WX_US"
        case .world: prefix = "WX"
        case .winlinkSystem: prefix = "WL2K"
        // METAREA zones are named only by a numeral; stripping the
        // prefix would leave a column of bare "I", "II", "XIV".
        case .marineZones: prefix = "METAREA"
        case .skyAndSpace, .other: prefix = ""
        }

        if let override = categoryOverrides[raw] { return override }

        if !prefix.isEmpty, raw == prefix {
            // A bare family code (`WX_US`) holds that family's
            // region-wide products; it has no leaf of its own.
            return "General"
        }
        if kind == .marineZones { return expand(raw) }

        var remainder = raw
        if !prefix.isEmpty, raw.hasPrefix(prefix + "_") {
            remainder = String(raw.dropFirst(prefix.count + 1))
        }
        // Inside the United States family a two-letter token is a state:
        // `WX_US_DE` is Delaware, though DE reads as Germany in
        // `WX_BALT_DE`.
        return expand(remainder, preferStates: kind == .unitedStates)
    }

    /// The full standalone name of a category, family prefix included —
    /// used where a row appears outside its section (search results).
    static func categoryTitle(_ rawCategory: String) -> String {
        let raw = rawCategory.uppercased()
        return categoryOverrides[raw] ?? expand(raw)
    }

    /// Expands an underscore-separated code into words.
    private static func expand(_ code: String, preferStates: Bool = false) -> String {
        let words = code
            .split(separator: "_", omittingEmptySubsequences: true)
            .map { token -> String in
                let key = String(token)
                if preferStates, let state = usStates[key] { return state }
                if let known = tokenNames[key] { return known }
                if let state = usStates[key] { return state }
                // Roman numerals (METAREA I…XVI) must not be title-cased
                // into "Xiv". Checked after the state map so IL, MI, VA
                // resolve as states first.
                if isRomanNumeral(key) { return key }
                return key.capitalized
            }
        return words.isEmpty ? code : words.joined(separator: " ")
    }

    private static func isRomanNumeral(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { "IVXLC".contains($0) }
    }

    /// Codes whose token-by-token expansion reads badly. Keyed by the
    /// full raw code; the value is the name shown inside its family.
    private static let categoryOverrides: [String: String] = [
        "WX_CAR_GULF": "Caribbean & Gulf",
        "ARES_RACES": "ARES / RACES",
        "WX_GT_LAKES": "Great Lakes",
        "WX_US_HRLY_T": "Hourly Temperatures",
        // The catalog never says what CADET stands for, so this is a
        // formatting of the code, not a reading of it.
        "UK_CADET": "UK Cadet",
    ]

    /// Codes whose meaning was read off their own items' subjects rather
    /// than guessed — see the type comment.
    private static let tokenNames: [String: String] = [
        "WX": "Weather",
        "METAREA": "METAREA",
        "RAD": "Radar",
        "COAST": "Coastal Waters",
        "HRLY": "Hourly",
        "T": "Temperature",
        "OUTDR": "Outdoor Activities",
        "SELCTY": "Selected Cities",
        "FAX": "Weather Fax",
        "BUOY": "Buoy Reports",
        "CAR": "Caribbean",
        "GULF": "Gulf",
        "GT": "Great",
        "LAKES": "Lakes",
        "MED": "Mediterranean",
        "NFLD": "Newfoundland",
        "PANAMAR": "Panama Canal",
        "EASTPAC": "East Pacific",
        "NORTHSEA": "North Sea",
        "NED": "Netherlands",
        "BALT": "Baltic",
        "DE": "Germany",  // WX_BALT_DE — "German Coastal Baltic"
        "BC": "British Columbia",
        "S/PACIFIC": "South Pacific",
        "S": "South",
        "AFRICA": "Africa",
        "UK": "United Kingdom",
        "AUS": "Australia",
        "SAT": "Satellite",
        "PIX": "Images",
        "KEPS": "Keplerian Elements",
        "WL2K": "Winlink",
        "RMS": "RMS Gateways",
        "HF": "HF",
        "NETS": "Nets",
        "ARES": "ARES",
        "RACES": "RACES",
        "METAR": "METAR Airport Reports",
        "NAVTEX": "NAVTEX",
        "NOAA": "NOAA",
        "US": "United States",
        "PR": "Puerto Rico",
        "GUAM": "Guam",
        "SAMOA": "American Samoa",
        "HIGH": "High",
        "SEAS": "Seas",
        "MARITIMES": "Maritimes",
    ]

    /// Standard USPS abbreviations — an unambiguous public mapping, not
    /// a reading of the catalog.
    private static let usStates: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas",
        "CA": "California", "CO": "Colorado", "CT": "Connecticut", "DC": "District of Columbia", "DE": "Delaware",
        "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho",
        "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi",
        "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
        "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah",
        "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
        "WI": "Wisconsin", "WY": "Wyoming",
    ]

    // MARK: - Search

    /// Case- and diacritic-insensitive match across everything the
    /// operator can see: subject, product ID, raw code, and friendly
    /// name — so "alaska" finds `WX_AK_COAST` even though the word
    /// appears in neither the subject nor the code.
    static func matches(_ item: WinlinkCatalogItemRecord, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystacks = [
            item.subject, item.inquiryId, item.category, categoryTitle(item.category),
        ]
        return haystacks.contains {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Row label: a product with no subject still needs a name.
    static func displayTitle(_ item: WinlinkCatalogItemRecord) -> String {
        item.subject.isEmpty ? item.inquiryId : item.subject
    }
}
