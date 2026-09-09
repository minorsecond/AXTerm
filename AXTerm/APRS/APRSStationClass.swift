import Foundation

/// Coarse APRS station class, used to scope a "who can hear me" probe the way
/// Xastir lets you aim at all stations, just the fixed infrastructure, or just
/// the movers. Pure and symbol-driven so it is testable and cheap.
nonisolated enum APRSStationClass: String, Sendable, CaseIterable {
    /// Fixed relay infrastructure: digipeaters, i-gates, gateways, repeaters.
    case infrastructure
    /// Something on the move: has course/speed, or wears a vehicle symbol.
    case moving
    /// Anything else placed on the map — homes, weather stations, etc.
    case fixed

    /// Symbol codes that mean fixed relay infrastructure (either table; an
    /// overlaid digi still reads as one).
    private static let infrastructureCodes: Set<Character> = [
        "#",   // digipeater
        "&",   // HF gateway
        "I",   // TCP/IP i-gate
        "r",   // repeater / antenna
    ]

    /// Symbol codes that mean a vehicle or aircraft — a mover even at rest.
    private static let vehicleCodes: Set<Character> = [
        ">", "<", "k", "u", "v", "j", "=", "U", "s", "Y", "'", "^", "X", "g",
    ]

    /// Classify a station from its beaconed symbol and whether it reported
    /// motion (course/speed present). `hasMotion` wins for the moving class.
    static func classify(code: Character, hasMotion: Bool) -> APRSStationClass {
        if infrastructureCodes.contains(code) { return .infrastructure }
        if hasMotion || vehicleCodes.contains(code) { return .moving }
        return .fixed
    }
}

/// A short, human name for a station's type, read from its beaconed APRS
/// symbol — the thing the map draws as a glyph and never spells out. Precise
/// where the symbol is unambiguous (a digipeater is a digipeater), and honest
/// where it is not (one generic word per class, never a guessed specific).
///
/// Only a transmitted fix carries a symbol, so this only answers for stations
/// placed where they beaconed from; a looked-up address has no type to give.
/// The four buckets the map colours, filters and keys by — one place so the
/// marker colour, the layer show/hide toggles and the legend can never
/// disagree about which class a symbol falls in. Weather is split out from
/// the coarse `APRSStationClass.fixed` because it is common and worth its own
/// colour and toggle.
nonisolated enum APRSTypeBucket: String, CaseIterable, Sendable {
    case digipeater   // fixed relay infrastructure
    case weather
    case vehicle
    case fixed        // fixed, not infrastructure, not weather

    static func of(code: Character) -> APRSTypeBucket {
        if code == "_" { return .weather }
        switch APRSStationClass.classify(code: code, hasMotion: false) {
        case .infrastructure: return .digipeater
        case .moving:         return .vehicle
        case .fixed:          return .fixed
        }
    }
}

nonisolated enum APRSSymbolType {

    static func label(code: Character) -> String {
        // Weather is its own thing on the map and worth naming: its symbol is
        // a fixed station otherwise.
        if code == "_" { return "Weather station" }
        switch APRSStationClass.classify(code: code, hasMotion: false) {
        case .infrastructure:
            switch code {
            case "#": return "Digipeater"
            case "&": return "Gateway (i-gate)"
            case "I": return "I-gate"
            case "r": return "Repeater"
            default:  return "Relay"
            }
        case .moving:
            // The vehicle set spans cars, boats, aircraft and gliders; naming
            // the class rather than the glyph avoids calling a yacht a car.
            return "Vehicle"
        case .fixed:
            return code == "-" ? "Home station" : "Fixed station"
        }
    }
}

/// The scope of a reachability probe.
nonisolated enum APRSProbeScope: String, Sendable, CaseIterable, Identifiable {
    case all
    case infrastructure
    case moving

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All stations"
        case .infrastructure: return "Infrastructure"
        case .moving: return "Moving"
        }
    }

    /// Whether a station of `stationClass` is in this scope.
    func includes(_ stationClass: APRSStationClass) -> Bool {
        switch self {
        case .all: return true
        case .infrastructure: return stationClass == .infrastructure
        case .moving: return stationClass == .moving
        }
    }
}
