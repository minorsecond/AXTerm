import Foundation

/// Turns a received message body into displayable text with live links.
///
/// Winlink service replies routinely quote the resource they fetched —
/// "Resource URL: https://radar.weather.gov/ridge/standard/KFTG_0.gif" —
/// and an operator reading that wants to open it, not retype it. The
/// body itself is never altered: the characters that arrived are the
/// characters shown, with link attributes laid over them.
///
/// Links are made *clickable*, never followed automatically. A message
/// body is untrusted input that arrived over the air from a third party,
/// and deciding to open it stays the operator's.
nonisolated enum WinlinkBodyText {

    /// URL schemes worth linking. Anything else — `file:`, `mailto:` with
    /// no address, exotic schemes — is left as plain text rather than
    /// handed to the system opener.
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// The body as an `AttributedString`, with detected web links
    /// carrying `.link`. Returns plain text when nothing is detected.
    static func attributed(_ body: String) -> AttributedString {
        var attributed = AttributedString(body)
        for match in detectLinks(in: body) {
            guard let range = Range(match.range, in: body),
                  let attributedRange = Swift.Range(range, in: attributed) else { continue }
            // The link attribute alone is what makes it clickable;
            // styling stays with the view.
            attributed[attributedRange].link = match.url
        }
        return attributed
    }

    /// Every linkable URL in the body, in order of appearance. Exposed
    /// so callers can offer the links directly — a monospaced wall of
    /// text is not the easiest place to hit a small target.
    static func links(in body: String) -> [URL] {
        var seen = Set<String>()
        return detectLinks(in: body).compactMap { match in
            guard seen.insert(match.url.absoluteString).inserted else { return nil }
            return match.url
        }
    }

    // MARK: - Detection

    private struct Match {
        var range: NSRange
        var url: URL
    }

    private static func detectLinks(in body: String) -> [Match] {
        guard !body.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        let full = NSRange(body.startIndex..<body.endIndex, in: body)
        return detector.matches(in: body, options: [], range: full).compactMap { result in
            guard var url = result.url else { return nil }
            guard let scheme = url.scheme?.lowercased() else { return nil }
            // The detector happily promotes bare "www.example.com" to
            // http; that is fine. Anything outside the allow-list is not.
            guard allowedSchemes.contains(scheme) else { return nil }

            // Trailing punctuation belongs to the sentence, not the URL.
            var range = result.range
            while let last = url.absoluteString.last, ".,;:)]}\u{201D}\"'".contains(last) {
                guard let trimmed = URL(string: String(url.absoluteString.dropLast())) else { break }
                url = trimmed
                range = NSRange(location: range.location, length: range.length - 1)
            }
            guard range.length > 0 else { return nil }
            return Match(range: range, url: url)
        }
    }
}
