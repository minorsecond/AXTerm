//
//  APRSCommentExtensions.swift
//  AXTerm
//
//  Two more structured fields that hide inside what looks like a comment.
//
//  Both were read off 144.390 and both were confirmed against Direwolf's
//  `decode_aprs` rather than from the specification alone, because a position
//  refinement applied with the wrong scale or sign is a station drawn in the
//  wrong place, and a telemetry value decoded with the wrong base is a number
//  somebody might act on.
//

import Foundation

/// `!DAO!` — the datum/precision extension (APRS 1.2, chapter 6).
///
/// A standard position carries hundredths of a minute. DAO adds the next
/// digits, taking a fix from about 18 m of quantisation to under a metre, and
/// trackers that send it send it on every beacon. Left in the comment it reads
/// as `!w6c!`; read properly it moves the dot to where the station said it is.
///
/// Both forms verified against `decode_aprs` on a real frame:
///
///     !3933.48N/10447.63W … !w+K!  →  N 39 33.4811, W 104 47.6346
///     !3933.48N/10447.63W … !W12!  →  N 39 33.4810, W 104 47.6320
///
nonisolated enum APRSDAO {

    /// Additional precision, in minutes, to be added to the magnitude of each
    /// coordinate — never to the signed value. A west longitude gets *more*
    /// negative, which is what the oracle above shows.
    struct Refinement: Equatable, Hashable, Sendable {
        var latitudeMinutes: Double
        var longitudeMinutes: Double
    }

    /// Take a DAO out of a comment, leaving the comment without it.
    ///
    /// Requires exactly three characters between the marks, which is what
    /// keeps `!SN!` — two characters, sent 28 times in an evening by one
    /// station — from being read as a position refinement.
    static func take(from comment: inout String) -> Refinement? {
        let range = NSRange(comment.startIndex..., in: comment)
        for match in pattern.matches(in: comment, range: range).reversed() {
            guard let whole = Range(match.range, in: comment),
                  let datumRange = Range(match.range(at: 1), in: comment),
                  let latRange = Range(match.range(at: 2), in: comment),
                  let lonRange = Range(match.range(at: 3), in: comment),
                  let datum = comment[datumRange].unicodeScalars.first,
                  let refinement = refinement(datum: Character(datum),
                                              latitude: comment[latRange].first ?? " ",
                                              longitude: comment[lonRange].first ?? " ")
            else { continue }
            comment.removeSubrange(whole)
            comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            return refinement
        }
        return nil
    }

    private static func refinement(datum: Character,
                                   latitude: Character,
                                   longitude: Character) -> Refinement? {
        if datum.isLowercase {
            // Base-91: each character is a 91st of one hundredth of a minute.
            guard let lat = base91Hundredths(latitude), let lon = base91Hundredths(longitude)
            else { return nil }
            return Refinement(latitudeMinutes: lat, longitudeMinutes: lon)
        }
        if datum.isUppercase {
            // Human-readable: each character is the next decimal digit of the
            // minutes, so a thousandth of a minute each.
            guard let lat = digitThousandths(latitude), let lon = digitThousandths(longitude)
            else { return nil }
            return Refinement(latitudeMinutes: lat, longitudeMinutes: lon)
        }
        return nil
    }

    /// A space means "no extra precision for this coordinate", which is a
    /// value of zero rather than a reason to reject the whole extension.
    private static func base91Hundredths(_ c: Character) -> Double? {
        if c == " " { return 0 }
        guard let v = c.asciiValue, (33...123).contains(v) else { return nil }
        return Double(Int(v) - 33) / 91 * 0.01
    }

    private static func digitThousandths(_ c: Character) -> Double? {
        if c == " " { return 0 }
        guard let digit = c.wholeNumberValue, (0...9).contains(digit) else { return nil }
        return Double(digit) / 1000
    }

    /// Exactly three characters between the marks: a datum letter and two
    /// coordinate characters.
    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"!([A-Za-z])(.)(.)!"#)
    }()
}

/// Base-91 comment telemetry (APRS 1.2, chapter 13): a whole telemetry report
/// folded into a position comment, so a tracker can send its readings without
/// spending a second packet on them.
///
/// `|!%%v(3|` is a sequence number and two channels. Verified against
/// `decode_aprs`, which reports the same frame as `Seq=4, A1=449, A2=655`.
nonisolated struct APRSCommentTelemetry: Equatable, Hashable, Sendable {
    /// As sent. Wraps at 8280 rather than at 999 like the `T#` form.
    var sequence: Int
    /// Up to five analogue channels, raw. The station's own `EQNS` turns these
    /// into units, exactly as for a `T#` frame — these are not percentages and
    /// not volts until it says so.
    var values: [Int]

    /// Take a telemetry run out of a comment, leaving the comment without it.
    ///
    /// Only a well-formed run: base-91 characters, an even count, a sequence
    /// plus one to five values. A station on this channel sends a stray `|3`
    /// after its DAO, and Direwolf leaves that as text too — a lone pipe is
    /// not a report, and guessing at one would invent readings.
    static func take(from comment: inout String) -> APRSCommentTelemetry? {
        let range = NSRange(comment.startIndex..., in: comment)
        guard let match = pattern.firstMatch(in: comment, range: range),
              let whole = Range(match.range, in: comment),
              let bodyRange = Range(match.range(at: 1), in: comment)
        else { return nil }

        let body = Array(comment[bodyRange])
        var numbers: [Int] = []
        for pair in stride(from: 0, to: body.count, by: 2) {
            guard let high = body[pair].asciiValue, let low = body[pair + 1].asciiValue
            else { return nil }
            numbers.append((Int(high) - 33) * 91 + (Int(low) - 33))
        }
        guard let sequence = numbers.first else { return nil }

        comment.removeSubrange(whole)
        comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return APRSCommentTelemetry(sequence: sequence, values: Array(numbers.dropFirst()))
    }

    /// `|` then an even number of base-91 characters — four to twelve, being a
    /// sequence and one to five values — then `|`.
    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\|((?:[\x21-\x7B]{2}){2,6})\|"#)
    }()
}
