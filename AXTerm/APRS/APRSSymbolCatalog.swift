import Foundation

/// One selectable APRS symbol: a table (`/` primary or `\` alternate) and a
/// code character, with the conventional human label. Overlays reuse an
/// alternate-table code with a 0–9/A–Z table character in place of `\`.
struct APRSSymbol: Identifiable, Hashable, Sendable {
    let table: Character
    let code: Character
    let label: String
    var id: String { "\(table)\(code)" }
    /// True for alternate-table symbols that accept an overlay character.
    var overlayable: Bool { table == "\\" }
}

/// The complete approved APRS symbol set — both the primary and alternate
/// tables — so the operator picks from the full list, not a curated subset.
/// Descriptions follow the canonical APRS symbol spec
/// (`http://www.aprs.org/symbols.html`). Codes span the printable range
/// `!`(0x21)…`~`(0x7E).
nonisolated enum APRSSymbolCatalog {

    /// Primary table `/`.
    static let primary: [APRSSymbol] = zip(primaryLabels.indices, primaryLabels).map {
        APRSSymbol(table: "/", code: codeAt($0.0), label: $0.1)
    }

    /// Alternate table `\` (overlayable).
    static let alternate: [APRSSymbol] = zip(alternateLabels.indices, alternateLabels).map {
        APRSSymbol(table: "\\", code: codeAt($0.0), label: $0.1)
    }

    static var all: [APRSSymbol] { primary + alternate }

    /// A default when nothing is chosen: the primary "House QTH" (`/-`),
    /// the most common fixed-station symbol.
    static let defaultSymbol = APRSSymbol(table: "/", code: "-", label: "House QTH (VHF)")

    static func symbol(table: Character, code: Character) -> APRSSymbol? {
        if table == "/" { return primary.first { $0.code == code } }
        if table == "\\" { return alternate.first { $0.code == code } }
        // An overlay: the glyph is the alternate-table code, shown under an
        // overlay character. Report the alternate meaning.
        return alternate.first { $0.code == code }
    }

    /// The code character at index `i` (0 → `!`(0x21)).
    private static func codeAt(_ i: Int) -> Character {
        Character(UnicodeScalar(0x21 + i)!)
    }

    // 94 entries each, `!`…`~` in order. "(reserved)" marks spec-reserved or
    // client-private slots; they remain selectable so nothing is missing.
    private static let primaryLabels: [String] = [
        "Police station",                    // !
        "(reserved)",                        // "
        "Digipeater",                        // #
        "Phone",                             // $
        "DX cluster",                        // %
        "HF gateway",                        // &
        "Small aircraft",                    // '
        "Mobile satellite station",          // (
        "Wheelchair (handicapped)",          // )
        "Snowmobile",                        // *
        "Red Cross",                         // +
        "Boy Scouts",                        // ,
        "House QTH (VHF)",                    // -
        "X (unknown)",                       // .
        "Red dot",                           // /
        "Circle 0",                          // 0
        "Circle 1",                          // 1
        "Circle 2",                          // 2
        "Circle 3",                          // 3
        "Circle 4",                          // 4
        "Circle 5",                          // 5
        "Circle 6",                          // 6
        "Circle 7",                          // 7
        "Circle 8",                          // 8
        "Circle 9",                          // 9
        "Fire",                              // :
        "Campground / portable",             // ;
        "Motorcycle",                        // <
        "Railroad engine",                   // =
        "Car",                               // >
        "File server",                       // ?
        "Hurricane / tropical storm",        // @
        "Aid station",                       // A
        "BBS / PBBS",                        // B
        "Canoe",                             // C
        "(reserved)",                        // D
        "Eyeball",                           // E
        "Farm vehicle / tractor",            // F
        "Grid square (3-digit)",             // G
        "Hotel",                             // H
        "TCP/IP network station",            // I
        "(reserved)",                        // J
        "School",                            // K
        "PC user (away)",                    // L
        "Mac apple",                         // M
        "NTS station",                       // N
        "Balloon",                           // O
        "Police",                            // P
        "TBD",                               // Q
        "Recreational vehicle",              // R
        "Space shuttle",                     // S
        "SSTV",                              // T
        "Bus",                               // U
        "ATV",                               // V
        "National Weather Service site",     // W
        "Helicopter",                        // X
        "Yacht / sailboat",                  // Y
        "WinAPRS",                           // Z
        "Human / person / pedestrian",       // [
        "DF triangle",                       // \
        "Mailbox / post office",             // ]
        "Large aircraft",                    // ^
        "Weather station",                   // _
        "Dish antenna",                      // `
        "Ambulance",                         // a
        "Bicycle",                           // b
        "Incident command post",             // c
        "Fire department",                   // d
        "Horse / equestrian",                // e
        "Fire truck",                        // f
        "Glider",                            // g
        "Hospital",                          // h
        "IOTA (islands on the air)",         // i
        "Jeep",                              // j
        "Truck",                             // k
        "Laptop",                            // l
        "Mic-E repeater",                    // m
        "Node (black bulls-eye)",            // n
        "EOC",                               // o
        "Rover (dog)",                       // p
        "Grid square (above 128 m)",         // q
        "Antenna",                           // r
        "Ship / power boat",                 // s
        "Truck stop",                        // t
        "Truck (18-wheeler)",                // u
        "Van",                               // v
        "Water station",                     // w
        "xAPRS (Unix)",                      // x
        "Yagi at QTH",                       // y
        "TBD",                               // z
        "TBD",                               // {
        "(Kenwood reserved)",                // |
        "TBD",                               // }
        "(Kenwood reserved)"                 // ~
    ]

    private static let alternateLabels: [String] = [
        "Emergency",                         // !
        "(reserved)",                        // "
        "Number (overlay)",                  // #
        "Bank / ATM",                        // $
        "(reserved)",                        // %
        "HF gateway (diamond, overlay)",     // &
        "Crash / incident site",             // '
        "Cloudy",                            // (
        "Firenet MEO / MODIS",               // )
        "Snow",                              // *
        "Church",                            // +
        "Girl Scouts",                       // ,
        "House (HF)",                        // -
        "Ambiguous (big X)",                 // .
        "Waypoint destination",              // /
        "Circle (overlay)",                  // 0
        "(reserved)",                        // 1
        "(reserved)",                        // 2
        "(reserved)",                        // 3
        "(reserved)",                        // 4
        "(reserved)",                        // 5
        "(reserved)",                        // 6
        "(reserved)",                        // 7
        "802.11 Wi-Fi",                      // 8
        "Gas station",                       // 9
        "Hail",                              // :
        "Park / picnic area",                // ;
        "Advisory (gale flag)",              // <
        "APRS (overlay)",                    // =
        "Car (overlay)",                     // >
        "Info kiosk",                        // ?
        "Hurricane / storm",                 // @
        "Box (overlay)",                     // A
        "Blowing snow",                      // B
        "Coast Guard",                       // C
        "Drizzle",                           // D
        "Smoke",                             // E
        "Freezing rain",                     // F
        "Snow shower",                       // G
        "Haze",                              // H
        "Rain shower",                       // I
        "Lightning",                         // J
        "Kenwood",                           // K
        "Lighthouse",                        // L
        "MARS",                              // M
        "Navigation buoy",                   // N
        "Balloon (overlay)",                 // O
        "Parking",                           // P
        "Earthquake",                        // Q
        "Restaurant",                        // R
        "Satellite / PACSAT",                // S
        "Thunderstorm",                      // T
        "Sunny",                             // U
        "VORTAC nav aid",                    // V
        "NWS site (overlay)",                // W
        "Pharmacy",                          // X
        "(reserved)",                        // Y
        "(reserved)",                        // Z
        "Wall cloud",                        // [
        "(reserved)",                        // \
        "(reserved)",                        // ]
        "Aircraft (overlay)",                // ^
        "WX site (green digi)",              // _
        "Rain",                              // `
        "ARRL / ARES / WinLink",             // a
        "Blowing dust / sand",               // b
        "CD triangle (overlay)",             // c
        "DX spot",                           // d
        "Sleet",                             // e
        "Funnel cloud",                      // f
        "Gale flags",                        // g
        "Store / HAM store",                 // h
        "Point of interest (overlay)",       // i
        "Work zone (steam shovel)",          // j
        "Special vehicle SUV / ATV",         // k
        "Areas (box / circle)",              // l
        "Value sign (3-digit)",              // m
        "Triangle (overlay)",                // n
        "Small circle",                      // o
        "Partly cloudy",                     // p
        "(reserved)",                        // q
        "Restrooms",                         // r
        "Ship / boat (overlay)",             // s
        "Tornado",                           // t
        "Truck (overlay)",                   // u
        "Van (overlay)",                     // v
        "Flooding",                          // w
        "Wreck",                             // x
        "Skywarn",                           // y
        "Shelter (overlay)",                 // z
        "Fog",                               // {
        "(Kenwood reserved)",                // |
        "(unused)",                          // }
        "(Kenwood reserved)"                 // ~
    ]
}
