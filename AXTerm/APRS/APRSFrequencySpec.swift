//
//  APRSFrequencySpec.swift
//  AXTerm
//
//  The repeater listing that rides at the front of a station's comment.
//
//  A great deal of what looks like free text on 144.390 is structured: a
//  frequency, a tone and an offset, in a fixed order, at the start of the
//  comment field. Printed raw it reads as noise —
//
//      "145.190MHz      -060="
//      "147.210MHz C100 +060_1"
//
//  — and read properly it is the single most useful thing the station is
//  saying: which repeater it is on, what tone opens it, and which way the
//  input is offset.
//
//  Direwolf lifts this out too, which is how the cross-validation fixture can
//  check us: for its Mic-E frame it is left with `_1`, having consumed the
//  type code, the altitude and this.
//

import Foundation

nonisolated struct APRSFrequencySpec: Equatable, Hashable, Sendable {

    /// What opens the repeater.
    enum Tone: Equatable, Hashable, Sendable {
        /// A continuous sub-audible tone, in hertz — 88.5, 100.0, 162.2.
        case ctcss(hertz: Double)
        /// A digital squelch code, kept as the three characters sent: the
        /// leading zero is part of how DCS codes are written and named.
        case dcs(code: String)
        /// The station said explicitly that there is no tone (`T000`), which
        /// is different from saying nothing about one.
        case none
    }

    var megahertz: Double
    var tone: Tone?
    /// Repeater input offset. Sent in units of 10 kHz, kept here in kHz:
    /// `-060` on the air is −600 kHz, the standard 2 m offset.
    var offsetKilohertz: Int?

    /// Read a frequency spec off the front of a comment.
    ///
    /// Returns nil when the comment does not begin with one — which is most of
    /// them — so a comment that merely mentions a frequency in passing is left
    /// alone. The format is anchored deliberately: only a leading
    /// `FFF.FFFMHz` is the structured field, and `"net at 147.210MHz Thursday"`
    /// is somebody talking.
    static func parse(_ comment: String) -> (spec: APRSFrequencySpec, remainder: String)? {
        guard let match = pattern.firstMatch(
            in: comment, range: NSRange(comment.startIndex..., in: comment)),
            let whole = Range(match.range, in: comment),
            let mhzRange = Range(match.range(at: 1), in: comment),
            let megahertz = Double(comment[mhzRange])
        else { return nil }

        var spec = APRSFrequencySpec(megahertz: megahertz)

        if let kindRange = Range(match.range(at: 2), in: comment),
           let digitsRange = Range(match.range(at: 3), in: comment) {
            let digits = String(comment[digitsRange])
            switch comment[kindRange].lowercased() {
            case "d":
                spec.tone = .dcs(code: digits)
            default:
                // `T`/`C` both carry CTCSS in the wild.
                spec.tone = digits == "000" ? Tone.none : ctcss(digits).map(Tone.ctcss(hertz:))
            }
        }

        if let offsetRange = Range(match.range(at: 4), in: comment),
           let tens = Int(comment[offsetRange]) {
            spec.offsetKilohertz = tens * 10
        }

        return (spec, String(comment[whole.upperBound...]))
    }

    /// The tone a three-digit field names.
    ///
    /// The field is the standard tone with its decimal point dropped and the
    /// fraction truncated — 88.5 is sent as `088`, 162.2 as `162`. No two
    /// standard tones share a whole-number part, so the lookup is exact.
    /// Anything not on the list returns nil rather than a number invented by
    /// dividing by ten: a wrong tone is worse than no tone, because an
    /// operator will dial it in and wonder why the repeater stays shut.
    static func ctcss(_ field: String) -> Double? {
        guard let whole = Int(field) else { return nil }
        return standardTones.first { Int($0) == whole }
    }

    /// EIA/TIA standard CTCSS tones.
    static let standardTones: [Double] = [
        67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5, 94.8, 97.4,
        100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3, 131.8, 136.5,
        141.3, 146.2, 151.4, 156.7, 159.8, 162.2, 165.5, 167.9, 171.3, 173.8,
        177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5, 203.5, 206.5,
        210.7, 213.8, 218.1, 221.3, 225.7, 229.1, 233.6, 237.1, 241.8, 245.5,
        250.3, 254.1
    ]

    /// `FFF.FFFMHz`, then optionally a tone and an offset, each separated by
    /// any run of spaces — a TM-D710 pads the gap with six of them.
    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^(\d{3}\.\d{3})MHz[ ]*(?:([TtCcDd])(\d{3})[ ]*)?(?:([+-]\d{3})[ ]*)?"#)
    }()
}
