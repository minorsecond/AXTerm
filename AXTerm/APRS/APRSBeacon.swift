import Foundation

/// Formats APRS position reports — the info field a beacon carries. Pure and
/// deterministic so the exact bytes are golden-tested before they touch the
/// air. Aims for spec parity: uncompressed and compressed position, position
/// ambiguity, symbol table/code (incl. overlays), and the standard data
/// extensions (course/speed, altitude). See `http://www.aprs.org/APRS-docs`.
nonisolated enum APRSBeacon {

    /// Optional course (degrees true, 0–359) and speed (knots) extension.
    struct CourseSpeed: Equatable {
        var courseDegrees: Int
        var speedKnots: Int
    }

    struct PositionReport: Equatable {
        var latitude: Double
        var longitude: Double
        /// `/` primary, `\` alternate, or an overlay char (0–9, A–Z).
        var symbolTable: Character
        var symbolCode: Character
        /// 0–4 low-order minute digits blanked for position ambiguity.
        var ambiguity: Int = 0
        var courseSpeed: CourseSpeed?
        /// Altitude in feet, emitted as `/A=DDDDDD` in the comment.
        var altitudeFeet: Int?
        var comment: String = ""
        var compressed: Bool = false
    }

    /// The APRS info field for a no-timestamp position report (`!`). The
    /// caller wraps this in an AX.25 UI frame to the APRS tocall.
    static func infoField(_ r: PositionReport) -> String {
        r.compressed ? compressedInfo(r) : uncompressedInfo(r)
    }

    // MARK: - Uncompressed  `!DDMM.mmN/DDDMM.mmW$...`

    static func uncompressedInfo(_ r: PositionReport) -> String {
        let lat = latitudeField(r.latitude, ambiguity: r.ambiguity)
        let lon = longitudeField(r.longitude, ambiguity: r.ambiguity)
        var s = "!" + lat + String(r.symbolTable) + lon + String(r.symbolCode)
        if let cs = r.courseSpeed {
            // CSE/SPD: three digits each, course 001–360 (000 = unknown).
            let course = ((cs.courseDegrees % 360) + 360) % 360
            let shown = course == 0 ? 360 : course
            s += String(format: "%03d/%03d", shown, max(0, min(999, cs.speedKnots)))
        }
        if let alt = r.altitudeFeet {
            s += String(format: "/A=%06d", max(-99999, min(999999, alt)))
        }
        s += r.comment
        return s
    }

    /// `DDMM.mmN` with the low `ambiguity` minute digits blanked to spaces.
    static func latitudeField(_ lat: Double, ambiguity: Int) -> String {
        let hemi = lat < 0 ? "S" : "N"
        let (d, mm) = degreesMinutes(abs(lat))
        return String(format: "%02d", min(90, d)) + blankable(mm, ambiguity) + hemi
    }

    /// `DDDMM.mmW` — three degree digits for longitude.
    static func longitudeField(_ lon: Double, ambiguity: Int) -> String {
        let hemi = lon < 0 ? "W" : "E"
        let (d, mm) = degreesMinutes(abs(lon))
        return String(format: "%03d", min(180, d)) + blankable(mm, ambiguity) + hemi
    }

    /// Split a positive coordinate into whole degrees and `MM.mm` minutes,
    /// rounding to hundredths of a minute and carrying into degrees.
    private static func degreesMinutes(_ value: Double) -> (Int, Double) {
        var deg = Int(value)
        var minutes = (value - Double(deg)) * 60
        // Round to 1/100 minute; a carry (…59.999 → 60.00) rolls into degrees.
        minutes = (minutes * 100).rounded() / 100
        if minutes >= 60 { minutes -= 60; deg += 1 }
        return (deg, minutes)
    }

    /// `MM.mm` with the `ambiguity` rightmost significant digits blanked to
    /// spaces (the decimal point is kept). 0 = full precision, 4 = both
    /// minute and both fractional digits blanked.
    static func blankable(_ minutes: Double, _ ambiguity: Int) -> String {
        // Four significant digits MM mm around a fixed '.'.
        let whole = Int(minutes)
        let frac = Int((minutes - Double(whole)) * 100 + 0.5)
        var digits = Array(String(format: "%02d%02d", whole, frac)) // [M,M,m,m]
        let n = max(0, min(4, ambiguity))
        for i in 0..<n { digits[3 - i] = " " }
        let mm = String(digits[0...1])
        let ff = String(digits[2...3])
        return mm + "." + ff
    }

    // MARK: - Compressed  `!/YYYYXXXX$cs`

    /// Base-91 compressed position: `!` + symbol table + 4-byte compressed
    /// latitude + 4-byte compressed longitude + symbol code + 2 compression
    /// bytes + a type byte. Course/speed are encoded into the two compression
    /// bytes when present; otherwise they are spaces (`no data`) and the type
    /// byte is a plain current position. Altitude/comment follow verbatim.
    static func compressedInfo(_ r: PositionReport) -> String {
        let latVal = Int(((90.0 - r.latitude) * 380926.0).rounded())
        let lonVal = Int(((180.0 + r.longitude) * 190463.0).rounded())
        let lat = base91(latVal, width: 4)
        let lon = base91(lonVal, width: 4)

        var cs = "  "                         // two spaces = no course/speed
        var typeByte = Character(UnicodeScalar(33 + 0b100000)!)  // GGA, current
        if let cse = r.courseSpeed {
            let course = (((cse.courseDegrees % 360) + 360) % 360)
            let c = Character(UnicodeScalar(33 + course / 4)!)   // 0..89
            // Compressed speed: s where speed = 1.08^s − 1 (knots).
            let s = Int((log(Double(max(0, cse.speedKnots)) + 1) / log(1.08)).rounded())
            let sc = Character(UnicodeScalar(33 + min(89, max(0, s)))!)
            cs = String(c) + String(sc)
            typeByte = Character(UnicodeScalar(33 + 0b111010)!)  // course/speed, current, other
        }

        var s = "!" + String(r.symbolTable) + lat + lon + String(r.symbolCode) + cs + String(typeByte)
        if let alt = r.altitudeFeet { s += String(format: "/A=%06d", max(-99999, min(999999, alt))) }
        s += r.comment
        return s
    }

    /// APRS base-91 printable encoding, most-significant first, space-padded
    /// width. Each digit is `value % 91 + 33` (`!`…`{`).
    static func base91(_ value: Int, width: Int) -> String {
        var v = max(0, value)
        var out = [Character](repeating: "!", count: width)
        var i = width - 1
        while i >= 0 {
            out[i] = Character(UnicodeScalar(33 + v % 91)!)
            v /= 91
            i -= 1
        }
        return String(out)
    }

    /// The APRS tocall (destination) for the beacon. `APZ…` is the reserved
    /// prefix for experimental / homebrew software, which AXTerm's sound
    /// modem is until it registers an assigned `APxxxx` tocall.
    static let tocall = "APZAXT"
}
