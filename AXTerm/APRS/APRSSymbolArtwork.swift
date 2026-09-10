import Foundation

/// AXTerm's own APRS symbol artwork, and the overlay character that rides on
/// top of it.
///
/// `APRSSymbolGlyph` maps every one of the 188 codes to an SF Symbol, which is
/// coverage rather than fidelity — the glyphs approximate the APRS set. This
/// maps the subset we have drawn to bundled vector artwork, and anything
/// without a drawing falls through to SF Symbols unchanged. Both layers are
/// table-aware; keying on the code alone collapses symbols that mean
/// different things.
///
/// The artwork is original, drawn for AXTerm — see `Design/aprs-symbols`. Two
/// codes stop deliberately short of the trademark they name: `\K` (Kenwood)
/// is a plain letter K, and `/M` (Mac apple) is an apple with no bite.
nonisolated enum APRSSymbolArtwork {

    /// A symbol resolved into the parts that get drawn: which table's meaning
    /// applies, and the character the sender put in the table slot.
    struct Resolved: Equatable, Sendable {
        /// `/` or `\` — the table whose meaning the code carries.
        let table: Character
        let code: Character
        /// The overlay character, when the sender put one in the table slot.
        ///
        /// This is the half of the symbol AXTerm used to discard. A quarter of
        /// the position reports on a live channel carry one, and `S#`, `1#`,
        /// `I#` and `D#` are four kinds of digipeater that drew as one picture
        /// until it was drawn.
        let overlay: Character?
    }

    /// Splits a symbol into its table, code and overlay.
    ///
    /// The primary table is the only one that is its own. `\` is the alternate
    /// table; any other character in that slot is an overlay *on* the
    /// alternate table's meaning, and per the spec is a digit or a capital
    /// letter — anything else is not an overlay and is treated as the
    /// alternate table with nothing on top.
    static func resolve(table: Character, code: Character) -> Resolved {
        if table == "/" { return Resolved(table: "/", code: code, overlay: nil) }
        if table == "\\" { return Resolved(table: "\\", code: code, overlay: nil) }
        let isLegalOverlay = table.isNumber || (table.isUppercase && table.isLetter)
        return Resolved(table: "\\", code: code, overlay: isLegalOverlay ? table : nil)
    }

    /// The character to draw on top of the artwork.
    ///
    /// Usually the overlay. But `/0`..`/9` are "Circle 0".."Circle 9" — ten
    /// symbols that are one plate and a numeral — so there the numeral is the
    /// code itself, and without this they all render as the same empty ring.
    static func inscription(table: Character, code: Character) -> Character? {
        let r = resolve(table: table, code: code)
        if let overlay = r.overlay { return overlay }
        if r.table == "/", code.isNumber { return code }
        return nil
    }

    /// The asset name for a symbol, or `nil` where nothing has been drawn yet
    /// and SF Symbols should answer instead.
    static func assetName(table: Character, code: Character) -> String? {
        let r = resolve(table: table, code: code)
        return (r.table == "/" ? primary[r.code] : alternate[r.code]).map { "APRSSymbols/" + $0 }
    }

    /// Whether our own artwork exists for this symbol.
    static func isDrawn(table: Character, code: Character) -> Bool {
        assetName(table: table, code: code) != nil
    }

    // Ten "Circle 0".."Circle 9" symbols differ only by a digit, so one plate
    // carries all of them and the digit is drawn by the same renderer that
    // draws overlays. Ten near-identical drawings would be ten chances to
    // drift apart.
    private static let primary: [Character: String] = {
        var m: [Character: String] = [
            "-": "house", "#": "digipeater", "&": "hf-gateway", "r": "antenna",
            "`": "dish-antenna", ">": "car", "v": "van", "j": "jeep", "k": "truck",
            "u": "truck-18-wheeler", "R": "rv", "f": "fire-truck", "s": "boat",
            "b": "bicycle", "[": "person", ";": "campground", "_": "weather-station",
            "M": "mac-apple", "J": "unassigned",
        ]
        for d in "0123456789" { m[d] = "circle-plate" }
        return m
    }()

    // `\#` is spec-named "Number (overlay)" but is, in practice, the
    // digipeater symbol: the New n-N Paradigm tells digis to beacon `#` with
    // a letter on it. `S` says the digi honours the state alias, `1` a
    // WIDE1-1 fill-in, `I` an igate. Drawing it as a plain plate was
    // spec-literal and practice-wrong — the most common infrastructure on the
    // map got the one shape that says nothing about being infrastructure.
    private static let alternate: [Character: String] = [
        "-": "house-hf", "#": "digipeater", "A": "box-plate", "&": "hf-gateway",
        ">": "car", "k": "suv-atv", "9": "gas-station", "_": "weather-station",
        "I": "rain-shower", "w": "flooding", "b": "blowing-dust", "@": "hurricane",
        "K": "kenwood-k",
    ]
}
