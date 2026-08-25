import Foundation

/// Parses the Winlink inquiry server's `LIST` reply — the radio-path
/// catalog index. Sending `LIST` to INQUIRY returns a plain-text table
/// of every catalog product as ordinary mail; ingesting it fills the
/// same cache the CMS web service would, without needing the personal
/// access key that gates the web service.
///
/// Wire format (field capture 2026-08-24, MID 6KFOMF87WJ8T, 1466 items):
///
///     Automated reply from Winlink Inquiry Server.
///     Processed: 2026/08/23 14:09
///     Re: INQUIRY LIST
///     Global_Modified: 2026/08/17 20:36
///
///     CATEGORY     INQUIRY_ID      SUBJECT             SIZE    ORIGINATED       G/L
///
///     ARCTIC_ICE   FICN10CWIS      "Iceberg Canada East Coast Waters"  1657  2025/11/25 21:18  [G]
///
/// Two quirks matter: a subject long enough to fill its column runs
/// flush against SIZE with no separating space, and subjects may embed
/// `"` characters (buoy positions) — the *last* quote before the size
/// terminates the subject, so the subject capture must be greedy.
nonisolated enum WinlinkCatalogListReply {

    /// Distinguishes the inquiry server's reply from ordinary mail that
    /// merely mentions the catalog: the sender is the SERVICE robot and
    /// the body opens with the server's banner line.
    static func isListReply(_ message: WinlinkB2Message) -> Bool {
        guard message.from.uppercased() == "SERVICE" else { return false }
        guard let text = bodyText(message) else { return false }
        return text.contains("Winlink Inquiry Server")
    }

    /// The catalog items carried by `message`, or nil when it is not a
    /// LIST reply or parses to zero items. Zero items returns nil rather
    /// than [] so a garbled reply can never wipe a good cache.
    ///
    /// `fetchedAt` is stamped from the message date — the catalog was
    /// current when the server generated it, not when we opened it.
    static func parse(_ message: WinlinkB2Message) -> [WinlinkCatalogItemRecord]? {
        guard isListReply(message), let text = bodyText(message) else { return nil }

        var items: [WinlinkCatalogItemRecord] = []
        var seen = Set<String>()  // inquiryId is the cache's primary key
        // \r\n is a single Character in Swift, so split on any newline
        // rather than on "\n" (which would never match a CRLF pair).
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = line.wholeMatch(of: Self.itemLine) else { continue }
            let inquiryId = String(match.2)
            guard seen.insert(inquiryId).inserted else { continue }
            items.append(WinlinkCatalogItemRecord(
                inquiryId: inquiryId,
                category: String(match.1),
                subject: String(match.3),
                url: "",
                lifetimeDays: 0,
                sizeEstimate: Int(match.4) ?? 0,
                enabled: true,
                fetchedAt: message.date))
        }
        return items.isEmpty ? nil : items
    }

    /// One table row: CATEGORY  ID  "SUBJECT"  SIZE  yyyy/MM/dd HH:mm  [G]
    /// `.*` is greedy so an embedded quote cannot end the subject early,
    /// and `\s*` after the closing quote accepts the flush-size case.
    private static let itemLine =
        /(\S+)\s+(\S+)\s+"(.*)"\s*(\d+)\s+\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}\s+\[[A-Z]\]\s*/

    /// The reply is 7-bit-plus-Latin-1 in practice ("für", "°"); try
    /// UTF-8 first for correctness, Latin-1 as the lossless fallback.
    private static func bodyText(_ message: WinlinkB2Message) -> String? {
        String(data: message.body, encoding: .utf8)
            ?? String(data: message.body, encoding: .isoLatin1)
    }
}
