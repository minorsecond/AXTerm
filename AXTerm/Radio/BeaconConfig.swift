import Foundation

/// What a radio's beacon carries. `.text` is the classic plain-text UI-frame
/// beacon AXTerm has always sent; `.aprsPosition` (wired in a later phase) is
/// a proper APRS position report. Kept as a raw-string enum so an older build
/// decodes an unknown future kind to `.text` rather than throwing.
enum BeaconKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case text
    case aprsPosition

    var id: String { rawValue }

    /// Tolerant decode: anything unrecognised is a plain text beacon.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BeaconKind(rawValue: raw) ?? .text
    }
}

/// A single radio's beacon, stored on its `RadioProfile`. Service *content*
/// is per radio — one radio's 145.050 packet beacon never rides another
/// radio's 144.390 APRS channel. Every field is defaulted and decoded
/// defensively (`decodeIfPresent`) so the struct can grow across phases
/// without breaking older saved settings, exactly like `RadioProfile`.
struct BeaconConfig: Codable, Equatable, Sendable {
    /// Off by default: a newly added radio does not beacon until the operator
    /// configures it. The first/only radio is turned on by migration from the
    /// legacy station-wide beacon, so single-radio stations are unchanged.
    var enabled: Bool = false
    var kind: BeaconKind = .text

    // Text beacon (kind == .text)
    var text: String = ""
    var path: String = ""

    /// Minutes between beacons; clamped to a sane floor when scheduled.
    var intervalMinutes: Int = 30

    // APRS position beacon (kind == .aprsPosition) — populated in a later
    // phase; kept optional so it is absent (and free) until used.
    var aprs: APRSPositionConfig?

    init(enabled: Bool = false,
         kind: BeaconKind = .text,
         text: String = "",
         path: String = "",
         intervalMinutes: Int = 30,
         aprs: APRSPositionConfig? = nil) {
        self.enabled = enabled
        self.kind = kind
        self.text = text
        self.path = path
        self.intervalMinutes = intervalMinutes
        self.aprs = aprs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        kind = try c.decodeIfPresent(BeaconKind.self, forKey: .kind) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30
        aprs = try c.decodeIfPresent(APRSPositionConfig.self, forKey: .aprs)
    }
}

/// The APRS position half of a beacon. Fleshed out (symbol catalog, GPS vs
/// fixed, ambiguity, data extensions, compressed form) in the APRS phase;
/// declared now so `BeaconConfig` has a stable shape and older/newer settings
/// interoperate. Every field defaulted and `decodeIfPresent`-ed.
struct APRSPositionConfig: Codable, Equatable, Sendable {
    /// Drive the position from the device's GPS instead of the fixed lat/lon.
    var useGPS: Bool = false
    var latitude: Double?
    var longitude: Double?
    /// `/` primary table, `\` alternate table, or an overlay character.
    var symbolTable: String = "/"
    /// The symbol code within the table.
    var symbolCode: String = "-"
    var comment: String = ""
    /// Position ambiguity, 0–4 low-order minute digits blanked.
    var ambiguityDigits: Int = 0
    /// Compressed position form; uncompressed by default for readability.
    var compressed: Bool = false

    init(useGPS: Bool = false,
         latitude: Double? = nil,
         longitude: Double? = nil,
         symbolTable: String = "/",
         symbolCode: String = "-",
         comment: String = "",
         ambiguityDigits: Int = 0,
         compressed: Bool = false) {
        self.useGPS = useGPS
        self.latitude = latitude
        self.longitude = longitude
        self.symbolTable = symbolTable
        self.symbolCode = symbolCode
        self.comment = comment
        self.ambiguityDigits = ambiguityDigits
        self.compressed = compressed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useGPS = try c.decodeIfPresent(Bool.self, forKey: .useGPS) ?? false
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        symbolTable = try c.decodeIfPresent(String.self, forKey: .symbolTable) ?? "/"
        symbolCode = try c.decodeIfPresent(String.self, forKey: .symbolCode) ?? "-"
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        ambiguityDigits = try c.decodeIfPresent(Int.self, forKey: .ambiguityDigits) ?? 0
        compressed = try c.decodeIfPresent(Bool.self, forKey: .compressed) ?? false
    }
}
