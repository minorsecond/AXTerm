import Foundation

/// Maps an APRS symbol (table + code) to an SF Symbol name, so the UI can draw
/// a recognisable glyph for every station on the air.
///
/// Both tables are covered end to end - 94 codes each, `!`(0x21)...`~`(0x7E) -
/// because a partial map is indistinguishable, on screen, from a wrong one: an
/// unmapped symbol fell back to a generic pin, so `/M` (Mac apple) drew the
/// same marker as a station carrying no symbol at all.
///
/// **The table is part of the symbol.** Keying on the code alone collapses
/// pairs that mean different things: `/M` is a Mac and `\M` is MARS; `/;` a
/// campground and `\;` a park; `/_` a weather station and `\_` a green digi.
/// Overlay symbols (the table character is a digit or letter) carry the
/// alternate table's meaning, which is what the overlay decorates.
///
/// SF Symbols approximate the APRS sprite set rather than reproducing it - the
/// point is a legible icon with no bundled assets. Every name here is resolved
/// against the running system by `APRSSymbolGlyphTests`, so a typo or a symbol
/// this OS lacks fails a test instead of silently drawing nothing.
nonisolated enum APRSSymbolGlyph {

    /// A generic marker, for a code outside the printable symbol range.
    static let fallback = "mappin.circle.fill"

    /// An SF Symbol name for the symbol. Never empty.
    static func systemImage(table: Character, code: Character) -> String {
        // Primary is the only table that is its own; `\` and every overlay
        // character share the alternate table's meanings.
        if table == "/" { return primaryGlyphs[code] ?? fallback }
        return alternateGlyphs[code] ?? fallback
    }

    /// Whether we have a specific glyph rather than the generic marker.
    static func isKnown(table: Character, code: Character) -> Bool {
        (table == "/" ? primaryGlyphs[code] : alternateGlyphs[code]) != nil
    }

    /// A short human label for the symbol, from the full catalog.
    static func label(table: Character, code: Character) -> String {
        APRSSymbolCatalog.symbol(table: table, code: code)?.label ?? "\(table)\(code)"
    }

    private static let primaryGlyphs: [Character: String] = [
        "!": "shield.lefthalf.filled",
        "\"": "questionmark.circle",
        "#": "antenna.radiowaves.left.and.right",
        "$": "phone.fill",
        "%": "globe.americas.fill",
        "&": "antenna.radiowaves.left.and.right",
        "'": "airplane",
        "(": "dot.radiowaves.left.and.right",
        ")": "figure.roll",
        "*": "snowflake",
        "+": "cross.fill",
        ",": "figure.hiking",
        "-": "house.fill",
        ".": "xmark.circle",
        "/": "circle.fill",
        "0": "0.circle.fill",
        "1": "1.circle.fill",
        "2": "2.circle.fill",
        "3": "3.circle.fill",
        "4": "4.circle.fill",
        "5": "5.circle.fill",
        "6": "6.circle.fill",
        "7": "7.circle.fill",
        "8": "8.circle.fill",
        "9": "9.circle.fill",
        ":": "flame.fill",
        ";": "tent.fill",
        "<": "bicycle",
        "=": "tram.fill",
        ">": "car.fill",
        "?": "externaldrive.fill",
        "@": "hurricane",
        "A": "cross.case.fill",
        "B": "tray.full.fill",
        "C": "sailboat.fill",
        "D": "questionmark.circle",
        "E": "eye.fill",
        "F": "leaf.fill",
        "G": "square.grid.3x3.fill",
        "H": "bed.double.fill",
        "I": "network",
        "J": "questionmark.circle",
        "K": "graduationcap.fill",
        "L": "desktopcomputer",
        "M": "applelogo",
        "N": "envelope.fill",
        "O": "circle.dotted",
        "P": "shield.lefthalf.filled",
        "Q": "questionmark.circle",
        "R": "bus.fill",
        "S": "airplane.departure",
        "T": "tv.fill",
        "U": "bus.fill",
        "V": "car.fill",
        "W": "cloud.sun.fill",
        "X": "airplane",
        "Y": "sailboat.fill",
        "Z": "desktopcomputer",
        "[": "figure.walk",
        "\\": "triangle.fill",
        "]": "envelope.fill",
        "^": "airplane",
        "_": "cloud.sun.fill",
        "`": "antenna.radiowaves.left.and.right",
        "a": "cross.case.fill",
        "b": "bicycle",
        "c": "flag.fill",
        "d": "flame.fill",
        "e": "pawprint.fill",
        "f": "flame.fill",
        "g": "airplane",
        "h": "cross.fill",
        "i": "water.waves",
        "j": "car.fill",
        "k": "truck.box.fill",
        "l": "laptopcomputer",
        "m": "antenna.radiowaves.left.and.right",
        "n": "circle.circle.fill",
        "o": "building.2.fill",
        "p": "pawprint.fill",
        "q": "square.grid.3x3.fill",
        "r": "antenna.radiowaves.left.and.right",
        "s": "ferry.fill",
        "t": "fuelpump.fill",
        "u": "truck.box.fill",
        "v": "bus.fill",
        "w": "drop.fill",
        "x": "terminal.fill",
        "y": "antenna.radiowaves.left.and.right",
        "z": "questionmark.circle",
        "{": "questionmark.circle",
        "|": "questionmark.circle",
        "}": "questionmark.circle",
        "~": "questionmark.circle",
    ]

    private static let alternateGlyphs: [Character: String] = [
        "!": "exclamationmark.triangle.fill",
        "\"": "questionmark.circle",
        "#": "number.circle.fill",
        "$": "banknote.fill",
        "%": "questionmark.circle",
        "&": "antenna.radiowaves.left.and.right",
        "'": "exclamationmark.triangle.fill",
        "(": "cloud.fill",
        ")": "flame.fill",
        "*": "snowflake",
        "+": "building.columns.fill",
        ",": "figure.hiking",
        "-": "house.fill",
        ".": "xmark.circle",
        "/": "mappin.and.ellipse",
        "0": "circle.fill",
        "1": "questionmark.circle",
        "2": "questionmark.circle",
        "3": "questionmark.circle",
        "4": "questionmark.circle",
        "5": "questionmark.circle",
        "6": "questionmark.circle",
        "7": "questionmark.circle",
        "8": "wifi",
        "9": "fuelpump.fill",
        ":": "cloud.hail.fill",
        ";": "tree.fill",
        "<": "flag.fill",
        "=": "antenna.radiowaves.left.and.right",
        ">": "car.fill",
        "?": "info.circle.fill",
        "@": "hurricane",
        "A": "square.fill",
        "B": "wind.snow",
        "C": "sailboat.fill",
        "D": "cloud.drizzle.fill",
        "E": "smoke.fill",
        "F": "cloud.sleet.fill",
        "G": "cloud.snow.fill",
        "H": "sun.haze.fill",
        "I": "cloud.rain.fill",
        "J": "bolt.fill",
        "K": "radio.fill",
        "L": "lightbulb.fill",
        "M": "star.fill",
        "N": "water.waves",
        "O": "circle.dotted",
        "P": "parkingsign.circle.fill",
        "Q": "waveform.path.ecg",
        "R": "fork.knife",
        "S": "dot.radiowaves.left.and.right",
        "T": "cloud.bolt.rain.fill",
        "U": "sun.max.fill",
        "V": "dot.radiowaves.left.and.right",
        "W": "cloud.sun.fill",
        "X": "pills.fill",
        "Y": "questionmark.circle",
        "Z": "questionmark.circle",
        "[": "cloud.fill",
        "\\": "questionmark.circle",
        "]": "questionmark.circle",
        "^": "airplane",
        "_": "cloud.sun.fill",
        "`": "cloud.rain.fill",
        "a": "antenna.radiowaves.left.and.right",
        "b": "wind",
        "c": "triangle.fill",
        "d": "globe.americas.fill",
        "e": "cloud.sleet.fill",
        "f": "tornado",
        "g": "flag.fill",
        "h": "cart.fill",
        "i": "mappin.and.ellipse",
        "j": "wrench.and.screwdriver.fill",
        "k": "car.fill",
        "l": "square.dashed",
        "m": "textformat.123",
        "n": "triangle.fill",
        "o": "circle.fill",
        "p": "cloud.sun.fill",
        "q": "questionmark.circle",
        "r": "toilet.fill",
        "s": "ferry.fill",
        "t": "tornado",
        "u": "truck.box.fill",
        "v": "bus.fill",
        "w": "water.waves",
        "x": "exclamationmark.triangle.fill",
        "y": "eye.fill",
        "z": "house.fill",
        "{": "cloud.fog.fill",
        "|": "radio.fill",
        "}": "questionmark.circle",
        "~": "questionmark.circle",
    ]
}
