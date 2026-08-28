import Foundation

/// Where a callsign is licensed, read from its ITU prefix.
///
/// A node's table can name stations on the other side of the planet —
/// VK2RZ-1 sits in a Colorado node's list because somewhere along the chain
/// there is an internet link. The app cannot *observe* that link (and must
/// not guess: on long-haul HF a distant station can be genuine RF), but the
/// licensing country is a fact printed in the callsign itself, and showing
/// it lets the operator draw the conclusion the evidence supports.
///
/// Deliberately incomplete: the table covers the allocations that actually
/// appear on packet networks. An unknown prefix returns nil and the UI shows
/// nothing, which is honest — a wrong country under a callsign is worse
/// than none.
nonisolated enum CallsignRegion {

    /// Two-character ITU blocks, checked before the single-letter fallback
    /// so `VE` (Canada) wins over any broader `V` reading. Lexicographic
    /// range containment matches how the ITU allocates letter blocks.
    private static let twoCharBlocks: [(ClosedRange<String>, String)] = [
        // Americas
        ("AA", "AL", "United States"), ("KA", "KZ", "United States"),
        ("NA", "NZ", "United States"), ("WA", "WZ", "United States"),
        ("VA", "VG", "Canada"), ("VO", "VO", "Canada"), ("VX", "VY", "Canada"),
        ("CY", "CZ", "Canada"),
        ("XA", "XI", "Mexico"),
        ("PP", "PY", "Brazil"), ("ZV", "ZZ", "Brazil"),
        ("LO", "LW", "Argentina"), ("AY", "AZ", "Argentina"),
        ("CX", "CX", "Uruguay"),
        ("CA", "CE", "Chile"), ("XQ", "XR", "Chile"),
        ("HJ", "HK", "Colombia"),
        ("YV", "YY", "Venezuela"),
        ("OA", "OC", "Peru"),
        ("HC", "HD", "Ecuador"),
        ("CP", "CP", "Bolivia"),
        ("ZP", "ZP", "Paraguay"),
        ("TI", "TI", "Costa Rica"),
        ("HP", "HP", "Panama"),
        ("HH", "HH", "Haiti"), ("HI", "HI", "Dominican Republic"),
        // CM and CO are Cuba but CN between them is Morocco — two singleton
        // ranges rather than one block that would swallow it.
        ("CM", "CM", "Cuba"), ("CO", "CO", "Cuba"),
        ("KP", "KP", "United States"),  // Puerto Rico / USVI
        // Europe
        ("GA", "GZ", "United Kingdom"), ("MA", "MZ", "United Kingdom"),
        ("EI", "EJ", "Ireland"),
        ("DA", "DR", "Germany"),
        ("PA", "PI", "Netherlands"),
        ("ON", "OT", "Belgium"),
        ("FA", "FZ", "France"),
        ("EA", "EH", "Spain"),
        ("CQ", "CU", "Portugal"),
        ("HB", "HB", "Switzerland"),
        ("OE", "OE", "Austria"),
        ("LA", "LN", "Norway"),
        ("SA", "SM", "Sweden"),
        ("OF", "OJ", "Finland"),
        ("OU", "OZ", "Denmark"),
        ("SN", "SR", "Poland"), ("HF", "HF", "Poland"),
        ("OK", "OL", "Czechia"), ("OM", "OM", "Slovakia"),
        ("HA", "HA", "Hungary"), ("HG", "HG", "Hungary"),
        ("UA", "UI", "Russia"), ("RA", "RZ", "Russia"),
        ("UR", "UZ", "Ukraine"), ("EM", "EO", "Ukraine"),
        ("EU", "EW", "Belarus"),
        ("YL", "YL", "Latvia"), ("ES", "ES", "Estonia"), ("LY", "LY", "Lithuania"),
        ("SV", "SZ", "Greece"),
        ("YO", "YR", "Romania"),
        ("LZ", "LZ", "Bulgaria"),
        ("YT", "YU", "Serbia"),
        ("S5", "S5", "Slovenia"),
        ("9A", "9A", "Croatia"),
        ("E7", "E7", "Bosnia and Herzegovina"),
        ("Z3", "Z3", "North Macedonia"),
        ("TF", "TF", "Iceland"),
        ("LX", "LX", "Luxembourg"),
        ("HV", "HV", "Vatican"), ("T7", "T7", "San Marino"),
        ("9H", "9H", "Malta"), ("5B", "5B", "Cyprus"),
        ("TA", "TC", "T\u{00FC}rkiye"),
        ("4X", "4X", "Israel"), ("4Z", "4Z", "Israel"),
        // Asia-Pacific
        ("JA", "JS", "Japan"), ("7J", "7N", "Japan"), ("8J", "8N", "Japan"),
        ("HL", "HL", "South Korea"), ("DS", "DT", "South Korea"),
        ("6K", "6N", "South Korea"),
        ("BM", "BQ", "Taiwan"), ("BU", "BX", "Taiwan"),
        ("BA", "BL", "China"), ("BY", "BZ", "China"),
        ("VU", "VU", "India"),
        ("HS", "HS", "Thailand"), ("E2", "E2", "Thailand"),
        ("YB", "YH", "Indonesia"),
        ("DU", "DZ", "Philippines"),
        ("9M", "9M", "Malaysia"), ("9W", "9W", "Malaysia"),
        ("9V", "9V", "Singapore"),
        ("VH", "VN", "Australia"), ("AX", "AX", "Australia"),
        ("ZL", "ZM", "New Zealand"),
        ("A2", "A2", "Botswana"), ("ZR", "ZU", "South Africa"),
        ("CN", "CN", "Morocco"), ("5C", "5G", "Morocco"),
        ("SU", "SU", "Egypt"),
        ("5Z", "5Z", "Kenya"), ("5N", "5O", "Nigeria"),
        ("A4", "A4", "Oman"), ("A6", "A6", "United Arab Emirates"),
        ("A7", "A7", "Qatar"), ("A9", "A9", "Bahrain"),
        ("HZ", "HZ", "Saudi Arabia"), ("7Z", "7Z", "Saudi Arabia"),
        ("AP", "AS", "Pakistan"),
        ("4S", "4S", "Sri Lanka"),
        ("XV", "XV", "Vietnam"), ("3W", "3W", "Vietnam"),
        ("V8", "V8", "Brunei"),
    ].map { (ClosedRange(uncheckedBounds: (lower: $0.0, upper: $0.1)), $0.2) }

    /// Single-letter allocations, consulted only when no two-character
    /// block matched.
    private static let oneCharBlocks: [Character: String] = [
        "B": "China", "F": "France", "G": "United Kingdom", "I": "Italy",
        "K": "United States", "M": "United Kingdom", "N": "United States",
        "R": "Russia", "W": "United States",
        "2": "United Kingdom",
    ]

    /// The licensing country for a callsign, nil when the prefix is not in
    /// the table (or the string is not a callsign at all).
    static func region(for callsign: String) -> String? {
        let base = CallsignQuery.normalize(callsign)
        // The structural gate matters: a tactical alias like 5EBBS would
        // otherwise read as Morocco through the 5C–5G block. Only strings
        // shaped like real callsigns get a country — and stricter than the
        // shared validator for digit-led prefixes: 9A1ABC and 5B4X always
        // carry a separating numeral, so a digit-led token without one
        // (5EBBS again) is an alias wearing a callsign's first two letters.
        guard CallsignValidator.isValidCallsign(base) else { return nil }
        if let first = base.first, first.isNumber,
           !base.dropFirst().contains(where: { $0.isNumber }) {
            return nil
        }
        let two = String(base.prefix(2))
        if let match = twoCharBlocks.first(where: { $0.0.contains(two) }) {
            return match.1
        }
        guard let first = base.first else { return nil }
        return oneCharBlocks[first]
    }
}
