import Foundation

/// Maps an APRS symbol (table + code) to an SF Symbol name and a tint, so the
/// UI can draw a recognizable glyph for a heard station. A curated set covers
/// the symbols that actually show up on the air (cars, digis, weather, homes,
/// trackers, aircraft, boats…); anything else falls back to a generic marker
/// with the raw code shown alongside. A pixel-faithful APRS sprite atlas is a
/// later refinement — this gives instant, legible icons with no bundled assets.
nonisolated enum APRSSymbolGlyph {

    /// An SF Symbol name for the symbol, or a generic fallback.
    static func systemImage(table: Character, code: Character) -> String {
        // Overlay symbols (table is a digit/letter) use the alternate meaning.
        map[code] ?? "mappin.circle.fill"
    }

    /// Whether we have a specific glyph (vs the generic fallback).
    static func isKnown(table: Character, code: Character) -> Bool {
        map[code] != nil
    }

    /// A short human label for the symbol, from the full catalog.
    static func label(table: Character, code: Character) -> String {
        APRSSymbolCatalog.symbol(table: table, code: code)?.label ?? "\(table)\(code)"
    }

    /// Keyed by symbol code; the code carries most of the meaning and the
    /// table (primary vs alternate) rarely changes the icon we'd pick.
    private static let map: [Character: String] = [
        ">": "car.fill",                 // car
        "<": "bicycle",                  // motorcycle → closest
        "b": "bicycle",                  // bicycle
        "k": "truck.box.fill",           // truck
        "u": "truck.box.fill",           // 18-wheeler / overlay truck
        "v": "bus.fill",                 // van
        "R": "bus.fill",                 // RV
        "j": "car.fill",                 // jeep
        "=": "tram.fill",                // railroad engine
        "U": "bus.fill",                 // bus
        "'": "airplane",                 // small aircraft
        "^": "airplane",                 // large aircraft
        "X": "airplane",                 // helicopter → closest
        "g": "airplane",                 // glider
        "O": "circle.dotted",            // balloon
        "s": "sailboat.fill",            // ship / boat
        "Y": "sailboat.fill",            // yacht
        "C": "sailboat.fill",            // canoe / coast guard
        "#": "antenna.radiowaves.left.and.right",  // digipeater
        "&": "antenna.radiowaves.left.and.right",  // HF gateway
        "I": "antenna.radiowaves.left.and.right",  // TCP/IP
        "-": "house.fill",               // house QTH
        "h": "cross.fill",               // hospital / HAM store
        "+": "cross.fill",               // Red Cross
        "a": "cross.case.fill",          // ambulance
        "f": "flame.fill",               // fire truck
        ":": "flame.fill",               // fire
        "[": "figure.walk",              // person / pedestrian
        "_": "cloud.sun.fill",           // weather station
        "W": "cloud.sun.fill",           // NWS site
        "r": "antenna.radiowaves.left.and.right",  // repeater / antenna
        ";": "tent.fill",                // campground
        "K": "graduationcap.fill",       // school
        "$": "phone.fill",               // phone
        "P": "shield.lefthalf.filled",   // police
        "!": "exclamationmark.triangle.fill",  // emergency / police station
        "@": "hurricane",                // hurricane
        "y": "exclamationmark.triangle.fill",  // skywarn
    ]
}
