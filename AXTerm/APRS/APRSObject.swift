import Foundation

/// An APRS **object** or **item**: a point on the map that a station places
/// about somewhere *other than itself*.
///
/// This is the payload emergency traffic actually runs on. A station reports
/// its own position by beaconing; it reports a fire, a washed-out bridge, a
/// shelter, an aid station, a road closure or a landing zone by placing an
/// object. Nothing upstream is involved — an operator types it and a
/// digipeater relays it — so it is the one incident-reporting channel that
/// keeps working when everything else has stopped.
///
/// Two things about an object matter as much as its position, and both are
/// carried here rather than left to the UI to guess:
///
/// * **Who placed it.** An object is a claim by a person, not a measurement.
///   "Bridge out" from a station two miles away and the same words from one
///   two hundred miles away are different claims, and only the sender can
///   tell them apart.
/// * **When.** An object about a moving fire is a different statement at ten
///   minutes old and at six hours old, and the packet itself never says which.
///
/// Objects can also be **killed** by their owner, which is how "the road is
/// open again" is said. A killed object must disappear, or the map becomes a
/// list of every hazard that has ever existed.
nonisolated struct APRSObjectReport: Equatable, Sendable {

    enum Kind: String, Sendable {
        /// `;` — a 9-character padded name and a timestamp.
        case object
        /// `)` — a 3-to-9 character name, no timestamp.
        case item
    }

    var kind: Kind
    /// Trimmed of the padding the wire format requires. Case is preserved:
    /// operators use it, and two objects differing only in case are the same
    /// object as far as APRS is concerned.
    var name: String
    /// False when the sender has killed it — "this is over, stop showing it".
    var isLive: Bool
    var latitude: Double
    var longitude: Double
    var symbolTable: Character
    var symbolCode: Character
    var courseDegrees: Int?
    var speedKnots: Int?
    var comment: String
    /// Objects may carry a full weather report, which is how an unattended
    /// sensor with no callsign of its own gets onto the map.
    var weather: APRSWeather?

    /// The name every consumer keys on. APRS object names are compared
    /// case-insensitively after trimming, so "Fire  " and "FIRE" are one
    /// object and a station can kill what it created.
    var key: String { name.trimmingCharacters(in: .whitespaces).uppercased() }
}

// MARK: - Parsing

extension APRSObjectReport {

    /// Parses an object (`;`) or item (`)`) report, or nil for anything else.
    static func parse(info: Data) -> APRSObjectReport? {
        let bytes = [UInt8](info)
        guard let dti = bytes.first else { return nil }
        switch dti {
        case UInt8(ascii: ";"): return parseObject(bytes)
        case UInt8(ascii: ")"): return parseItem(bytes)
        default: return nil
        }
    }

    /// `;NAMEXXXXX*DDHHMMz<position><comment>` — the name is exactly nine
    /// characters, space padded, and the byte after it says live or killed.
    private static func parseObject(_ bytes: [UInt8]) -> APRSObjectReport? {
        // 1 DTI + 9 name + 1 state + 7 timestamp = 18 before the position.
        guard bytes.count > 18 else { return nil }
        let name = ascii(bytes, 1, 9)
        let state = Character(UnicodeScalar(bytes[10]))
        guard state == "*" || state == "_" else { return nil }
        // The timestamp is present but not trusted: it is the sender's clock,
        // and what matters for staleness is when *we* heard it, which the
        // receiver knows exactly. Only its shape is checked, to confirm this
        // really is an object report and not a coincidence.
        let stamp = Array(ascii(bytes, 11, 7))
        guard stamp.count == 7, stamp.prefix(6).allSatisfy(\.isNumber),
              "zh/".contains(stamp[6]) else { return nil }

        guard let position = APRSParser.parsePosition(bytes, offset: 18, hasTimestamp: true)
        else { return nil }
        return report(kind: .object, name: name, isLive: state == "*", position: position)
    }

    /// `)NAME!<position><comment>` — the name runs 3 to 9 characters and ends
    /// at the first `!` (live) or `_` (killed), which is why neither character
    /// may appear inside a name.
    private static func parseItem(_ bytes: [UInt8]) -> APRSObjectReport? {
        guard bytes.count > 4 else { return nil }
        var terminator: Int?
        // Start at 1; a name is at least three characters, so the earliest a
        // terminator can legally appear is index 4.
        for index in 4..<min(bytes.count, 11) {
            let byte = bytes[index]
            if byte == UInt8(ascii: "!") || byte == UInt8(ascii: "_") {
                terminator = index
                break
            }
        }
        guard let terminator else { return nil }
        let name = ascii(bytes, 1, terminator - 1)
        guard !name.isEmpty else { return nil }
        guard let position = APRSParser.parsePosition(
            bytes, offset: terminator + 1, hasTimestamp: false) else { return nil }
        return report(kind: .item, name: name,
                      isLive: bytes[terminator] == UInt8(ascii: "!"), position: position)
    }

    /// Shared tail: an object's payload after the position is identical to a
    /// station's, weather included.
    private static func report(kind: Kind, name: String, isLive: Bool,
                               position: APRSReport) -> APRSObjectReport? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return APRSObjectReport(
            kind: kind, name: trimmed, isLive: isLive,
            latitude: position.latitude, longitude: position.longitude,
            symbolTable: position.symbolTable, symbolCode: position.symbolCode,
            courseDegrees: position.courseDegrees, speedKnots: position.speedKnots,
            comment: position.comment, weather: position.weather)
    }

    private static func ascii(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String {
        guard count > 0, offset + count <= bytes.count else { return "" }
        return String(bytes: bytes[offset..<(offset + count)], encoding: .ascii)
            ?? String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
    }
}

// MARK: - What the operator sees

extension APRSObjectReport {

    /// A coarse read of what an object is *for*, from the symbol it wears.
    ///
    /// Deliberately shallow. The symbol is the only machine-readable thing an
    /// object carries about its own meaning, and a symbol is chosen by a
    /// person in a hurry. So this sorts objects into "look at this now" and
    /// "this is a marker", and leaves the actual meaning to the name and
    /// comment the operator wrote — which are shown in full and never
    /// summarised.
    enum Urgency: Int, Comparable, Sendable {
        case marker
        case notable
        case hazard

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Symbols that mean something is wrong somewhere.
    ///
    /// **The table matters here**, unlike in the marker glyph. `/!` is a
    /// police station — somewhere to go — while `\!` is Emergency, and
    /// treating the two alike would raise a hazard banner for every sheriff's
    /// office on the map and teach the operator to ignore it. Kept small for
    /// the same reason: a list that flags everything flags nothing.
    private static let hazardSymbols: Set<String> = [
        "\\!",   // EMERGENCY
        "/:",    // fire
        "\\:",   // fire (alternate)
        "/f",    // fire truck
        "\\'",   // crash / incident site
        "\\@",   // hurricane / tropical storm
        "\\e",   // smoke / haze
        "\\w",   // flooding
    ]

    /// Symbols that mean somewhere to go, or something worth knowing about.
    private static let notableSymbols: Set<String> = [
        "/+",    // Red Cross
        "/a",    // ambulance
        "/h",    // hospital
        "/c",    // incident command post
        "/o",    // EOC
        "/A",    // aid station
        "/W",    // water station
        "/;",    // campground / shelter
        "/K",    // school
        "/H",    // hotel
        "/!",    // police / sheriff station
        "/P",    // police
    ]

    /// The symbol as the tables key it. An overlay (a digit or letter in the
    /// table position) is an alternate-table symbol wearing a character, so it
    /// reads as `\` for classification.
    private var symbolKey: String {
        let table: Character = (symbolTable == "/") ? "/" : "\\"
        return "\(table)\(symbolCode)"
    }

    var urgency: Urgency {
        if Self.hazardSymbols.contains(symbolKey) { return .hazard }
        if Self.notableSymbols.contains(symbolKey) { return .notable }
        return .marker
    }

    /// The symbol's canonical name, so an unfamiliar glyph can always be read.
    var symbolLabel: String {
        APRSSymbolCatalog.symbol(table: symbolTable, code: symbolCode)?.label
            ?? "\(symbolTable)\(symbolCode)"
    }
}
