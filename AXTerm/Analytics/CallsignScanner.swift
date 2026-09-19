//
//  CallsignScanner.swift
//  AXTerm
//
//  Finding callsigns inside free text — a beacon comment, an APRS message, a
//  BBS banner — so they can be tapped like the addresses already can.
//
//  `CallsignValidator` answers "is this token a callsign?" given a token. This
//  is the other half: deciding which runs of a sentence are worth asking about,
//  and how sure we are.
//
//  The problem is precision, not recall. A 144.390 channel is full of things
//  shaped exactly like callsigns:
//
//      "`Jb}145.130MHz T088 -060 friesr@yahoo.com_%"
//      "V:7.32 S:16"
//      "PHG5370/WA0DE SIMLA digi W2,COn SE Elbert County, CO 13.8V"
//      Telemetry #074 · 137, 140, 41, 0, 0
//
//  `T088` passes the callsign regex. So does `S9UPPQ`. `W2` sits mid-sentence
//  in a digi comment. Linkifying those would send an operator to a QRZ page for
//  a CTCSS tone, and two of those teach them never to trust a link again — so
//  the bar here is deliberately high, and a token we are unsure of is left as
//  plain text rather than guessed at.
//
//  The strongest evidence is not a pattern. It is whether we have *heard* the
//  station: the app already knows every callsign on the channel, and a token
//  that matches one of them is a callsign in a way no regex can argue with.
//

import Foundation

nonisolated enum CallsignScanner {

    /// How sure we are, which decides whether a run is offered as a link.
    enum Confidence: Int, Comparable, Sendable {
        /// Matched a pattern and nothing else. On a busy channel this is
        /// mostly telemetry and tone codes, so it is not linked by default.
        case possible = 0
        /// Addressed with `@`, the APRS convention for talking to someone.
        case addressed = 1
        /// A station this receiver has actually heard. The best evidence
        /// available, and it costs nothing — the station list is already
        /// there.
        case heard = 2

        static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    }

    struct Hit: Equatable, Sendable {
        /// The callsign as written, SSID included, uppercased.
        let callsign: String
        /// Where it sits in the text that was scanned.
        let range: Range<String.Index>
        let confidence: Confidence
    }

    /// Callsigns in `text`.
    ///
    /// `heard` is the set of base callsigns this station has received, used as
    /// evidence rather than as a filter — an unheard token can still be a hit,
    /// it is simply a weaker one.
    static func scan(_ text: String, heard: Set<String> = []) -> [Hit] {
        guard !text.isEmpty else { return [] }
        let heardBases = Set(heard.map { CallsignValidator.normalize($0).baseCallsign })
        var hits: [Hit] = []

        for range in candidateRanges(in: text) {
            let raw = String(text[range])
            let addressed = raw.hasPrefix("@")
            let token = addressed ? String(raw.dropFirst()) : raw
            let normalized = CallsignValidator.normalize(token)
            guard !normalized.isEmpty else { continue }
            guard CallsignValidator.isValidCallsign(normalized) else { continue }
            guard !CallsignValidator.isServiceEndpoint(normalized) else { continue }

            let confidence: Confidence
            if heardBases.contains(normalized.baseCallsign) {
                confidence = .heard
            } else if addressed {
                confidence = .addressed
            } else {
                confidence = .possible
            }
            hits.append(Hit(callsign: normalized, range: range, confidence: confidence))
        }
        return hits
    }

    /// Hits worth drawing as links.
    ///
    /// Pattern-only matches are excluded: they are the ones that are wrong,
    /// and a link that goes somewhere useless is worse than text that is not a
    /// link at all.
    static func links(in text: String, heard: Set<String> = []) -> [Hit] {
        scan(text, heard: heard).filter { $0.confidence > .possible }
    }

    // MARK: - Tokenising

    /// Runs that could be a callsign, with the things that disqualify a run
    /// taken out first.
    ///
    /// A callsign is letters, digits and one `-SSID`, optionally addressed
    /// with a leading `@`. What matters as much is the *boundary*: a token
    /// glued to `=`, `:`, `/` or `.` belongs to a version string, a telemetry
    /// field or a frequency, and one inside an email address or a URL belongs
    /// to neither.
    private static func candidateRanges(in text: String) -> [Range<String.Index>] {
        let excluded = excludedRanges(in: text)
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard isTokenStart(text, at: index) else {
                index = text.index(after: index)
                continue
            }
            var end = index
            if text[end] == "@" { end = text.index(after: end) }
            while end < text.endIndex, isTokenBody(text[end]) { end = text.index(after: end) }
            let range = index..<end

            defer { index = end < text.endIndex ? text.index(after: end) : text.endIndex }
            guard !range.isEmpty else { continue }
            // Glued to something that makes it part of a larger field.
            if let before = text.index(range.lowerBound, offsetBy: -1, limitedBy: text.startIndex),
               before < range.lowerBound, isGlue(text[before]) { continue }
            if range.upperBound < text.endIndex, isGlue(text[range.upperBound]) { continue }
            if excluded.contains(where: { $0.overlaps(range) }) { continue }
            ranges.append(range)
        }
        return ranges
    }

    /// Punctuation that closes something around an address or ends the
    /// sentence it sits in, rather than being part of it.
    ///
    /// The typographic quotes are the pair that bit. `APRSDigestLine` draws a
    /// station's comment inside “ ”, so a beacon whose comment is nothing but
    /// a URL reaches the scanner as `http://www.k0rap.com”` — and `URL` is
    /// perfectly happy to take that, encoding the quote into the hostname as
    /// the punycode `xn--com-9o0a` and sending the operator's browser to a
    /// domain that has never existed. The link looked right on screen, because
    /// what it drew was the comment and the quote was the console's own.
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}",
        "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "\u{2026}"
    ]

    /// Web addresses and email addresses in the text, as links.
    ///
    /// Stations put them in their comments constantly — `www.ARESDEC.org`,
    /// `http://www.k0rap.com`, `Randy K5RHD.73@GMAIL.COM` — and the console
    /// already knew where they were, because the callsign scanner has to find
    /// them in order to *avoid* them. This returns the same ranges with the
    /// destination attached instead of throwing them away.
    ///
    /// `NSDataDetector` is not used: it reads a bare `146.520` as a link, and
    /// on this channel a frequency mid-comment is the commonest thing there
    /// is. The patterns here require a scheme, a `www.` or an `@`.
    static func webLinks(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        var found: [(Range<String.Index>, URL)] = []
        for range in excludedRanges(in: text) {
            var raw = String(text[range])
            // Trailing punctuation belongs to the sentence, not the address.
            while let last = raw.last, trailingPunctuation.contains(last) { raw.removeLast() }
            guard !raw.isEmpty else { continue }
            let target = raw.contains("@") && !raw.lowercased().hasPrefix("http")
                ? "mailto:\(raw)"
                : (raw.lowercased().hasPrefix("http") ? raw : "https://\(raw)")
            guard let url = URL(string: target) else { continue }
            let trimmed = text.index(range.lowerBound, offsetBy: raw.count)
            found.append((range.lowerBound..<trimmed, url))
        }
        return found
    }

    /// Where an email address or a URL sits, so nothing inside one is offered.
    /// `friesr@yahoo.com` in a beacon comment is the case that matters — the
    /// `@` that makes it an address is also the one that means "addressed to"
    /// in an APRS message, so the two have to be told apart here.
    static func excludedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for pattern in [#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                        #"[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#,
                        #"\bwww\.\S+"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let full = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: full) {
                if let r = Range(match.range, in: text) { ranges.append(r) }
            }
        }
        return ranges
    }

    private static func isTokenStart(_ text: String, at index: String.Index) -> Bool {
        let c = text[index]
        guard c == "@" || c.isLetter || c.isNumber else { return false }
        guard let before = text.index(index, offsetBy: -1, limitedBy: text.startIndex),
              before < index else { return true }
        return !isTokenBody(text[before]) && text[before] != "@"
    }

    private static func isTokenBody(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-"
    }

    /// Characters that make a neighbouring token part of a larger field:
    /// `V:7.32`, `U=12.4V`, `PHG5370/WA0DE`, `145.130MHz`.
    private static func isGlue(_ c: Character) -> Bool {
        c == "=" || c == ":" || c == "/" || c == "." || c == "#"
    }
}

nonisolated extension String {
    /// The callsign without its SSID. `KF0YKI-9` → `KF0YKI`.
    var baseCallsign: String {
        String(split(separator: "-").first ?? Substring(self))
    }
}
