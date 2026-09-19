//
//  APRSCoverage.swift
//  AXTerm
//
//  What a station says about its own reach: the seven-byte data extension
//  that can follow the symbol in a position report.
//
//  A digipeater's beacon is mostly this, and printed raw it reads as a serial
//  number —
//
//      "PHG3830 WA6IFI W2,COn /A=12349"
//      "PHG58306/Wilkerson Pass KC0CQZ"
//
//  — where what it actually says is nine watts at 2,560 feet above average
//  terrain into an omni with 3 dB of gain. On a channel where the question is
//  always "can I reach that digi", the station has already answered it and the
//  console was printing the answer as noise.
//
//  APRS 1.01 chapter 7. The slot holds exactly one extension: this one,
//  course/speed, or nothing — so the cases here are mutually exclusive by the
//  wire format rather than by choice.
//
//  This is the station's claim about itself, and it is a different kind of
//  thing from `CoverageEstimate`, which is measured from who answered us. A
//  claim and a measurement are never mixed.
//

import Foundation

/// An antenna, as its owner describes it. `PHGphgd` and `DFSshgd` are the same
/// four digits; they differ only in what the first one counts.
nonisolated struct APRSAntenna: Equatable, Hashable, Sendable {

    /// What the leading digit is a measure of.
    enum Signal: Equatable, Hashable, Sendable {
        /// `PHG`: transmitter power, the digit squared. `3` is nine watts.
        case transmitting(watts: Int)
        /// `DFS`: what a receive-only site hears, in S-points. A direction
        /// finder has no transmitter to describe, so this is the useful half.
        case hearing(strengthSPoints: Int)
    }

    /// Where the beam points, when it points anywhere.
    enum Directivity: Equatable, Hashable, Sendable {
        case omnidirectional
        /// The bearing of maximum radiation, in 45° steps. `8` on the air is
        /// 360°, which is north — the spec numbers it that way rather than
        /// using 0, which already means omni.
        case beam(bearingDegrees: Int)
    }

    var signal: Signal
    /// Height above average terrain. `10 × 2^h` feet, so the digits run 10 ft
    /// to 5,120 ft and a mountaintop digi and a handheld are one digit apart
    /// at the top of the scale.
    var heightFeet: Int
    var gainDecibels: Int
    var directivity: Directivity
    /// Beacons an hour, from the fifth digit the later PHGR convention adds.
    /// Nil when the station sent the original seven-byte field.
    var beaconsPerHour: Int?
}

/// The station's own claim about how far it reaches.
nonisolated enum APRSCoverage: Equatable, Hashable, Sendable {
    /// `PHGphgd` or `DFSshgd`: an antenna, described.
    case antenna(APRSAntenna)
    /// `RNGrrrr`: a radius in statute miles, with nothing said about how it
    /// was arrived at.
    case range(miles: Int)
}

nonisolated extension APRSCoverage {

    /// Read a data extension off the front of the field that follows the
    /// symbol, and take it out of the text.
    ///
    /// Anchored there and nowhere else. `PHG` three words into a comment is
    /// the operator mentioning their antenna, not the structured field, and
    /// QUAIL — which sends `# 12.1V 99F PHG2820 W2,COn` — is exactly that
    /// case: the slot holds a voltage, so the extension is not read and the
    /// whole comment stays as written.
    static func take(from text: inout String) -> APRSCoverage? {
        guard text.count >= 7 else { return nil }
        let field = Array(text.prefix(7))
        let digits = String(field[3...6])
        guard digits.allSatisfy(\.isNumber) else { return nil }
        var consumed = 7

        let coverage: APRSCoverage
        switch String(field[0...2]) {
        case "RNG":
            guard let miles = Int(digits) else { return nil }
            coverage = .range(miles: miles)
        case "PHG", "DFS":
            let values = digits.compactMap(\.wholeNumberValue)
            guard values.count == 4 else { return nil }
            // The fifth digit is the PHGR rate, and only a digit is it: the
            // `/` that follows `PHG5370` is the start of somebody's comment.
            var rate: Int?
            if String(field[0...2]) == "PHG",
               let next = text.dropFirst(7).first, next.isNumber {
                rate = next.wholeNumberValue
                consumed = 8
            }
            coverage = .antenna(APRSAntenna(
                signal: String(field[0...2]) == "PHG"
                    ? .transmitting(watts: values[0] * values[0])
                    : .hearing(strengthSPoints: values[0]),
                heightFeet: 10 << values[1],
                gainDecibels: values[2],
                directivity: values[3] == 0 ? .omnidirectional
                                            : .beam(bearingDegrees: values[3] * 45),
                beaconsPerHour: rate))
        default:
            return nil
        }

        text = String(text.dropFirst(consumed))
        return coverage
    }
}
