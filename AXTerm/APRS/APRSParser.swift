import Foundation

/// A decoded APRS position from a heard packet — where a station says it is,
/// with its symbol and optional motion. Pure output of `APRSParser`.
struct APRSReport: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable { case uncompressed, compressed, micE }

    var latitude: Double
    var longitude: Double
    var symbolTable: Character
    var symbolCode: Character
    var courseDegrees: Int?
    var speedKnots: Int?
    var altitudeFeet: Int?
    var comment: String
    var hasTimestamp: Bool
    var kind: Kind
    /// The weather this beacon carried, for a station whose symbol code is
    /// `_`. Nil for every other station — and for a weather station whose
    /// report was all "no sensor" filler.
    var weather: APRSWeather? = nil
    /// The repeater listing at the front of the comment, when there was one.
    /// Read out of `comment` rather than left in it, the same way the altitude
    /// is — see `APRSFrequencySpec`.
    var frequency: APRSFrequencySpec? = nil
    /// What the station says about its own reach — power, height, gain and
    /// directivity, or a plain radius — from the data extension that follows
    /// the symbol. See `APRSCoverage`.
    var coverage: APRSCoverage? = nil
    /// Telemetry the station folded into its comment instead of spending a
    /// second packet on it. See `APRSCommentTelemetry`.
    var commentTelemetry: APRSCommentTelemetry? = nil
    /// Whether `latitude` and `longitude` carry the extra digits a `!DAO!`
    /// supplied. Worth knowing: it is the difference between a fix good to
    /// about eighteen metres and one good to under one.
    var hasRefinedPosition: Bool = false
}

/// Parses the position out of a received APRS packet. Pure and deterministic
/// so the byte handling is golden-tested. Handles the three position encodings
/// that carry a station's location — uncompressed, compressed, and Mic-E —
/// and returns nil for anything else (messages, status, telemetry).
nonisolated enum APRSParser {

    /// Exactly 0°N 0°E: the Gulf of Guinea, and the sentinel every GPS-fed
    /// beacon in the world sends when it has no fix.
    ///
    /// NI0W-9 transmitted one on 144.390 on 2026-09-09 — a Yaesu with no lock,
    /// Mic-E destination `PPP0PP`, every latitude digit zero. Read literally
    /// it places a Colorado mobile 13 000 km away off Africa. A parser that
    /// returns it hands the map a dot at coordinates nobody transmitted, and a
    /// map that fits its stations then drags the whole view out to sea.
    ///
    /// The test is for the exact point, not a neighbourhood of it: there is no
    /// distance at which a real position quietly becomes a fiction, and a buoy
    /// really sitting near the origin is still a station.
    static func isNullIsland(latitude: Double, longitude: Double) -> Bool {
        latitude == 0 && longitude == 0
    }

    /// A bearing, or nil for anything that is not one.
    ///
    /// APRS writes due north as 360 and "unknown" as 0 in the uncompressed
    /// extension, so both ends of that range are real. Anything outside it
    /// came from a corrupted frame — NI0W-9's gated copy decoded to 579° the
    /// same morning — and an arrow drawn at 579° points somewhere the station
    /// is not going. An absent heading is honest; a wrong one is not.
    static func validCourse(_ degrees: Int?) -> Int? {
        guard let degrees, degrees > 0, degrees <= 360 else { return nil }
        return degrees
    }

    /// `destination` is the AX.25 destination callsign (Mic-E hides latitude
    /// there); `info` is the AX.25 information field.
    static func parse(destination: String, info: Data) -> APRSReport? {
        guard var report = decode(destination: destination, info: info) else { return nil }
        // Applied here rather than in each of the three decoders: every
        // encoding can carry them, and doing it once is how they cannot be
        // added to two of the three and forgotten in the last.
        applyCommentExtensions(to: &report)
        guard !isNullIsland(latitude: report.latitude, longitude: report.longitude) else { return nil }
        return report
    }

    private static func decode(destination: String, info: Data) -> APRSReport? {
        let b = [UInt8](info)
        guard let dti = b.first else { return nil }
        switch dti {
        case UInt8(ascii: "!"), UInt8(ascii: "="):
            return parsePosition(b, offset: 1, hasTimestamp: false)
        case UInt8(ascii: "/"), UInt8(ascii: "@"):
            // 7-char timestamp follows the DTI.
            guard b.count > 8 else { return nil }
            return parsePosition(b, offset: 8, hasTimestamp: true)
        case UInt8(ascii: "`"), UInt8(ascii: "'"), 0x1c, 0x1d:
            return parseMicE(destination: destination, info: b)
        default:
            return nil
        }
    }

    /// The weather in a **positionless** report (DTI `_`): a station that
    /// beacons its fix and its weather in separate packets, which many home
    /// stations do. There is no position to return, so this is a second entry
    /// point rather than a case of `parse` — a report with no coordinates
    /// must never become an `APRSReport`, which promises one.
    ///
    /// Wire shape: `_` then an 8-character MDHM timestamp, then the fields.
    static func parseWeather(info: Data) -> APRSWeather? {
        let b = [UInt8](info)
        guard b.first == UInt8(ascii: "_"), b.count > 9 else { return nil }
        // The timestamp is month/day/hour/minute; it says when the station
        // took the reading, which the receiver's own clock already answers
        // well enough for a live map, so it is skipped rather than trusted.
        let stamp = ascii(b, 1, 8)
        guard stamp.allSatisfy(\.isNumber) else { return nil }
        return APRSWeather.parse(ascii(b, 9, b.count - 9), form: .positionless)
    }

    // MARK: - Uncompressed / compressed dispatch

    /// Internal so object and item reports can reuse it: their payload after
    /// the name and state byte is a position report in exactly this form.
    static func parsePosition(_ b: [UInt8], offset: Int, hasTimestamp: Bool) -> APRSReport? {
        guard offset < b.count else { return nil }
        let first = b[offset]
        // Uncompressed latitude starts with a digit or an ambiguity space;
        // compressed starts with the symbol table id (`/`, `\`, or overlay).
        if (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")) || first == UInt8(ascii: " ") {
            return parseUncompressed(b, offset: offset, hasTimestamp: hasTimestamp)
        }
        return parseCompressed(b, offset: offset, hasTimestamp: hasTimestamp)
    }

    // MARK: - Uncompressed  DDMM.mmN/DDDMM.mmW$

    static func parseUncompressed(_ b: [UInt8], offset: Int, hasTimestamp: Bool) -> APRSReport? {
        guard offset + 19 <= b.count else { return nil }
        let latField = ascii(b, offset, 8)          // DDMM.mmN
        let table = Character(UnicodeScalar(b[offset + 8]))
        let lonField = ascii(b, offset + 9, 9)      // DDDMM.mmW
        let code = Character(UnicodeScalar(b[offset + 18]))
        guard let lat = latitude(latField), let lon = longitude(lonField) else { return nil }

        var course: Int?
        var speed: Int?
        var coverage: APRSCoverage?
        var weather: APRSWeather?
        var rest = ascii(b, offset + 19, b.count - (offset + 19))
        if code == "_" {
            // A weather station reuses the course/speed slot for wind
            // direction and wind speed. Decoding it as course and speed would
            // report a house as travelling at 4 knots, and would put a fixed
            // station in the map's "moving" class — so the whole tail goes to
            // the weather parser instead, and motion stays nil.
            let scanned = APRSWeather.scan(rest, form: .withPosition)
            weather = scanned.weather
            rest = scanned.comment
        } else if rest.count >= 7 {
            // Leading CSE/SPD: three digits, a slash, three digits.
            let cs = Array(rest.prefix(7))
            if cs[3] == "/", cs[0...2].allSatisfy(\.isNumber), cs[4...6].allSatisfy(\.isNumber) {
                course = Int(String(cs[0...2]))
                speed = Int(String(cs[4...6]))
                rest = String(rest.dropFirst(7))
            } else {
                // The same seven bytes, when what the station has to say about
                // itself is its aerial rather than its travel.
                coverage = APRSCoverage.take(from: &rest)
            }
        }
        let altitude = extractAltitude(&rest)
        let listing = takeFrequency(&rest)
        return APRSReport(latitude: lat, longitude: lon, symbolTable: table, symbolCode: code,
                          courseDegrees: validCourse(course), speedKnots: speed, altitudeFeet: altitude,
                          comment: rest, hasTimestamp: hasTimestamp, kind: .uncompressed,
                          weather: weather, frequency: listing, coverage: coverage)
    }

    /// `DDMM.mmN` → signed degrees, ambiguity spaces treated as zero.
    static func latitude(_ f: String) -> Double? {
        let c = Array(f)
        guard c.count == 8, "NS".contains(c[7]) else { return nil }
        let digits = c[0..<7].map { $0 == " " ? "0" : String($0) }.joined()   // DDMM.mm
        guard let deg = Double(digits.prefix(2)),
              let min = Double(digits.dropFirst(2)) else { return nil }
        let value = deg + min / 60
        return c[7] == "S" ? -value : value
    }

    /// `DDDMM.mmW` → signed degrees.
    static func longitude(_ f: String) -> Double? {
        let c = Array(f)
        guard c.count == 9, "EW".contains(c[8]) else { return nil }
        let digits = c[0..<8].map { $0 == " " ? "0" : String($0) }.joined()   // DDDMM.mm
        guard let deg = Double(digits.prefix(3)),
              let min = Double(digits.dropFirst(3)) else { return nil }
        let value = deg + min / 60
        return c[8] == "W" ? -value : value
    }

    /// `/A=DDDDDD` altitude in feet, removed from the comment when found.
    static func extractAltitude(_ text: inout String) -> Int? {
        guard let r = text.range(of: "/A=") else { return nil }
        // Six digits is what the spec asks for and what almost everything
        // sends. WA6IFI-6 sends five — `/A=12349` — and insisting on six
        // printed the field where the altitude should have been. Taken as they
        // come, up to six; `/A=` with no digits after it is still not one.
        let digits = text[r.upperBound...].prefix(while: \.isNumber).prefix(6)
        guard !digits.isEmpty, let feet = Int(digits) else { return nil }
        text.removeSubrange(r.lowerBound..<text.index(r.upperBound, offsetBy: digits.count))
        return feet
    }

    // MARK: - Compressed  /YYYYXXXX$cs T

    static func parseCompressed(_ b: [UInt8], offset: Int, hasTimestamp: Bool) -> APRSReport? {
        guard offset + 13 <= b.count else { return nil }
        let table = Character(UnicodeScalar(b[offset]))
        let y = base91(b, offset + 1, 4)
        let x = base91(b, offset + 5, 4)
        let code = Character(UnicodeScalar(b[offset + 9]))
        let c = b[offset + 10]
        let s = b[offset + 11]
        let lat = 90.0 - Double(y) / 380926.0
        let lon = -180.0 + Double(x) / 190463.0

        var course: Int?
        var speed: Int?
        var windDirection: Int?
        var windSpeedMPH: Int?
        if c != UInt8(ascii: " "), c >= 33, c <= 33 + 89 {
            let degrees = Int(c - 33) * 4
            let knots = Int((pow(1.08, Double(s) - 33) - 1).rounded())
            if code == "_" {
                // In a compressed weather report the same two bytes carry wind
                // rather than travel. The encoding is identical, so the speed
                // arrives in knots and is converted to the mph the rest of the
                // weather layer speaks.
                windDirection = degrees
                windSpeedMPH = Int((Double(knots) * 1.150779).rounded())
            } else {
                course = degrees
                speed = knots
            }
        }
        var rest = ascii(b, offset + 13, b.count - (offset + 13))
        var weather: APRSWeather?
        if code == "_" {
            let scanned = APRSWeather.scan(rest, form: .withPosition)
            rest = scanned.comment
            // The keyed fields carry everything except wind, which the
            // compressed header already gave.
            var reading = scanned.weather ?? APRSWeather()
            reading.windDirectionDegrees = windDirection
            reading.windSpeedMPH = windSpeedMPH
            weather = reading.isEmpty ? nil : reading
        }
        let altitude = extractAltitude(&rest)
        return APRSReport(latitude: lat, longitude: lon, symbolTable: table, symbolCode: code,
                          courseDegrees: course, speedKnots: speed, altitudeFeet: altitude,
                          comment: rest, hasTimestamp: hasTimestamp, kind: .compressed,
                          weather: weather)
    }

    /// APRS base-91: sum of (byte − 33) · 91^(width−1−i).
    static func base91(_ b: [UInt8], _ offset: Int, _ width: Int) -> Int {
        var value = 0
        for i in 0..<width {
            value = value * 91 + Int(b[offset + i]) - 33
        }
        return value
    }

    // MARK: - Mic-E (latitude in the destination, the rest in the info)

    static func parseMicE(destination: String, info b: [UInt8]) -> APRSReport? {
        let dest = Array(destination.uppercased().prefix(6))
        guard dest.count == 6, b.count >= 9 else { return nil }

        // Destination: six chars give latitude digits + the sign/offset bits.
        var latDigits = ""
        var north = false, west = false, lonOffset = false
        for (i, ch) in dest.enumerated() {
            guard let v = ch.asciiValue else { return nil }
            let digit: Character
            let high: Bool           // the char is in the "1" class (A–K or P–Z)
            switch v {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = ch; high = false
            case UInt8(ascii: "A")...UInt8(ascii: "J"): digit = Character(String(v - UInt8(ascii: "A"))); high = true
            case UInt8(ascii: "P")...UInt8(ascii: "Y"): digit = Character(String(v - UInt8(ascii: "P"))); high = true
            case UInt8(ascii: "K"), UInt8(ascii: "L"), UInt8(ascii: "Z"): digit = " "; high = (v != UInt8(ascii: "L"))
            default: return nil
            }
            latDigits.append(digit)
            if i == 3 { north = high }
            if i == 4 { lonOffset = high }
            if i == 5 { west = high }
        }
        let d = latDigits.map { $0 == " " ? "0" : String($0) }.joined()   // DDMMmm
        guard d.count == 6, let dd = Double(d.prefix(2)),
              let mm = Double(d.dropFirst(2).prefix(2)),
              let hh = Double(d.suffix(2)) else { return nil }
        var lat = dd + (mm + hh / 100) / 60
        if !north { lat = -lat }

        // Info: longitude (3 bytes), speed/course (3 bytes), symbol code+table.
        var lonDeg = Int(b[1]) - 28
        if lonOffset { lonDeg += 100 }
        if lonDeg >= 180 && lonDeg <= 189 { lonDeg -= 80 }
        else if lonDeg >= 190 && lonDeg <= 199 { lonDeg -= 190 }
        var lonMin = Int(b[2]) - 28
        if lonMin >= 60 { lonMin -= 60 }
        let lonHund = Int(b[3]) - 28
        var lon = Double(lonDeg) + (Double(lonMin) + Double(lonHund) / 100) / 60
        if west { lon = -lon }

        let sp = Int(b[4]) - 28
        let dc = Int(b[5]) - 28
        let se = Int(b[6]) - 28
        var speed = sp * 10 + dc / 10
        if speed >= 800 { speed -= 800 }
        var course = (dc % 10) * 100 + se
        if course >= 400 { course -= 400 }

        let code = Character(UnicodeScalar(b[7]))
        let table = Character(UnicodeScalar(b[8]))
        let tail = b.count > 9 ? ascii(b, 9, b.count - 9) : ""
        var status = micEStatusText(tail)
        let listing = takeFrequency(&status)
        return APRSReport(latitude: lat, longitude: lon, symbolTable: table, symbolCode: code,
                          courseDegrees: validCourse(course == 0 ? nil : course),
                          speedKnots: speed == 0 ? nil : speed,
                          altitudeFeet: micEAltitude(tail),
                          comment: status, hasTimestamp: false, kind: .micE,
                          frequency: listing)
    }

    /// Lift a leading repeater listing out of a comment, as `extractAltitude`
    /// lifts out `/A=`. Leaves the comment untouched when there is none.
    static func takeFrequency(_ text: inout String) -> APRSFrequencySpec? {
        guard let (spec, rest) = APRSFrequencySpec.parse(text) else { return nil }
        text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return spec
    }

    /// Everything else that hides in a comment: the DAO precision extension
    /// and base-91 telemetry. Both are removed from `comment`, the DAO is
    /// applied to the coordinates, and what is left is the operator's words.
    ///
    /// The refinement is added to the *magnitude* of each coordinate, never to
    /// the signed value — a west longitude gets more negative. Confirmed
    /// against `decode_aprs`; see `APRSDAO`.
    static func applyCommentExtensions(to report: inout APRSReport) {
        var text = report.comment
        if let dao = APRSDAO.take(from: &text) {
            report.latitude += (report.latitude < 0 ? -1 : 1) * dao.latitudeMinutes / 60
            report.longitude += (report.longitude < 0 ? -1 : 1) * dao.longitudeMinutes / 60
            report.hasRefinedPosition = true
        }
        report.commentTelemetry = APRSCommentTelemetry.take(from: &text)
        // Trimmed once, here, so all three encodings agree. Lifting a field
        // out of the middle of a comment leaves the space that separated it:
        // `PHG3830 WA6IFI W2,COn /A=12349` is ` WA6IFI W2,COn ` once the
        // extension and the altitude are gone, and a comment is a sentence
        // rather than a fixed-width field.
        report.comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Mic-E type code: the first character of the status text, when it is
    /// the radio naming its family rather than the operator saying something.
    ///
    /// Only the four documented ones. A station whose comment genuinely begins
    /// with some other punctuation keeps it — dropping a character because it
    /// might be a type code would quietly eat the first letter of somebody's
    /// sentence.
    ///
    /// Which family it names decides how long a signature to look for at the
    /// far end, which is why the two ends cannot be read apart from each other.
    private enum MicEFamily {
        /// `>` — TH-D7A, TH-D74, TH-D75 — and `]` — TM-D700, TM-D710. One
        /// character of signature, or none.
        case kenwood
        /// `` ` `` and `'`: the Yaesu, AnyTone and Byonics trackers, and
        /// anything else carrying a two-character signature.
        case twoCharacter
    }

    private static let micETypeCodes: [Character: MicEFamily] = [
        ">": .kenwood, "]": .kenwood, "`": .twoCharacter, "'": .twoCharacter
    ]

    /// The single character a Kenwood signs with: `=` a TM-D710 or TH-D75, `^`
    /// a TH-D74.
    ///
    /// The older TM-D700 and TH-D7A sign with nothing at all, and that is the
    /// cost of the scheme rather than of this implementation: a D700 operator
    /// whose comment really does end in `=` loses that character, and no
    /// parser can tell which of the two it was looking at.
    private static let micEKenwoodSuffixes: Set<Character> = ["=", "^"]

    /// Two-character device identifiers a Mic-E status text ends with.
    ///
    /// A tracker signs its transmissions: `_1` is a Yaesu, `|3` a Byonics
    /// TinyTrak3. It is the radio naming itself, not the operator writing, and
    /// it is why a comment ends in what looks like line noise.
    ///
    /// `|3` is the one worth calling out. It reads exactly like the tail of a
    /// base-91 telemetry run, and a first pass here treated it as one — a
    /// mistake made with Direwolf's own agreement, because `decode_aprs`
    /// without its `tocalls.yaml` cannot identify devices either and leaves
    /// the suffix in the comment while saying so. With the table loaded it
    /// names the radio and consumes it, which is what settled it.
    ///
    /// The set is from the APRS device identification list maintained by
    /// Hessu, OH7LZB, for aprs.fi (CC BY-SA 2.0). Only which two characters
    /// end a status text is used here; the vendor and model mapping is not.
    private static let micEDeviceSuffixes: Set<String> = [
        "_ ", "_\\", "_#", "_$", "_(", "_0", "_1", "_2", "_3", "_4", "_5",
        "_)", "_%", "(5", "(8", "|3", "|4", "^v", "*v", ":2", " X", "[1"
    ]

    /// The Mic-E status text with the fields that are not text taken out.
    ///
    /// What follows the position is not all comment. The first character may
    /// be a type code naming the radio's family — `]` a Kenwood TM-D700/710,
    /// `>` a TH-D7 — the last one or two may be that family's signature naming
    /// the model, and an altitude rides in between as three base-91 characters
    /// and a `}`. All of it is read into its own field, so leaving any of it
    /// in the comment prints the altitude twice — once as `5,587 ft` and again
    /// as `"FX}` in the middle of the operator's own words — and finishes what
    /// the operator did write with `_4` or `=`.
    ///
    /// `parseUncompressed` has always removed `/A=` from the comment it read;
    /// Mic-E was the path where it did not, which is why
    /// `testCommentsAgreeWhereDirewolfLeavesThemWhole` covers the other two
    /// encodings and not this one. Direwolf strips both of these too.
    ///
    /// The altitude is removed only when one was actually read, so a `}` that
    /// is just a brace in a comment survives.
    static func micEStatusText(_ tail: String) -> String {
        var text = tail
        var family: MicEFamily?
        if let first = text.first, let named = micETypeCodes[first] {
            family = named
            text.removeFirst()
        }
        if micEAltitude(tail) != nil,
           let brace = text.firstIndex(of: "}"),
           text.distance(from: text.startIndex, to: brace) >= 3 {
            text.removeSubrange(text.index(brace, offsetBy: -3)..<text.index(after: brace))
        }
        // Trimmed *before* the signature is looked for, not after. These
        // frames end with a carriage return, so the last two characters of the
        // raw text are `4\r` rather than `_4`: the match failed, the trim then
        // removed only the return, and the suffix survived — glued to the URL
        // in front of it, which turned `www.k0rap.com` into a link to
        // `www.k0rap.com_4` and a punycode hostname that goes nowhere.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // The signature, at the very end, and only as long as the type code at
        // the front said it would be. A comment finishing in two characters
        // that happen to spell a Yaesu keeps them when the radio was a
        // Kenwood, and a station that sent no type code keeps everything.
        switch family {
        case .kenwood:
            if let last = text.last, micEKenwoodSuffixes.contains(last) {
                text.removeLast()
            }
        case .twoCharacter:
            if text.count >= 2, micEDeviceSuffixes.contains(String(text.suffix(2))) {
                text.removeLast(2)
            }
        case nil:
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mic-E altitude: `cccc}` where the three chars before `}` are base-91
    /// metres offset by −10000; returned as feet.
    static func micEAltitude(_ comment: String) -> Int? {
        guard let r = comment.range(of: "}") else { return nil }
        let before = comment[..<r.lowerBound]
        guard before.count >= 3 else { return nil }
        let chars = Array(before.suffix(3)).compactMap { $0.asciiValue }
        guard chars.count == 3 else { return nil }
        let metres = (Int(chars[0]) - 33) * 91 * 91 + (Int(chars[1]) - 33) * 91 + (Int(chars[2]) - 33) - 10000
        return Int((Double(metres) * 3.28084).rounded())
    }

    // MARK: - Bytes

    private static func ascii(_ b: [UInt8], _ offset: Int, _ count: Int) -> String {
        guard count > 0, offset + count <= b.count else { return "" }
        return String(bytes: b[offset..<(offset + count)], encoding: .ascii)
            ?? String(decoding: b[offset..<(offset + count)], as: UTF8.self)
    }
}
