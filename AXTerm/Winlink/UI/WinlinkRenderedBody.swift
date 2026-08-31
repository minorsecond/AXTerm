import Foundation

/// The reading pane's body, worked out once per message instead of once
/// per view update.
///
/// Everything here used to happen inline in `WinlinkMessageDetail.body`:
/// decode the bytes, run the NWS tabular parser over them, then run
/// `NSDataDetector` across the whole text to find links. Measured on the
/// 181 KB `INQUIRY: LIST` catalog reply that prompted this, the parse and
/// link scan together cost tens of milliseconds — which is affordable once
/// and ruinous on every SwiftUI update, and the reading pane is inside a
/// view that also carries live exchange progress.
///
/// Deriving it here makes the cost proportional to *selecting a message*,
/// which is the only thing that actually changes the answer.
nonisolated struct WinlinkRenderedBody: Equatable, Sendable {

    /// How the body should be presented.
    enum Content: Equatable, Sendable {
        /// A fixed-width NWS product that parsed cleanly into a table.
        case forecast(NWSTabularForecast)
        /// Plain text, with links marked. Possibly only a prefix — see
        /// `shownCharacters` against `totalCharacters`.
        case text(AttributedString)
    }

    var content: Content
    /// The undecorated text, as received. The forecast view keeps it one
    /// disclosure away, and "show everything" re-renders from it.
    var raw: String
    var totalCharacters: Int
    var shownCharacters: Int

    var isTruncated: Bool { shownCharacters < totalCharacters }

    /// How much plain text is rendered before the pane offers the rest.
    ///
    /// This is not about the parse — that is cached now — but about
    /// SwiftUI text layout, which is superlinear enough that a 179,000
    /// character monospaced run with selection enabled visibly stalls the
    /// window. Catalog listings and bulletins are the messages that reach
    /// this size, and the top of one answers the question nearly always.
    static let previewCharacterLimit = 32_768

    /// Builds the rendered form. Pure and free of UI types, so it can run
    /// off the main actor.
    ///
    /// - Parameter fullText: skip the preview cap, because the operator
    ///   asked for the whole thing.
    static func make(body: Data, fullText: Bool = false) -> WinlinkRenderedBody {
        let raw = String(data: body, encoding: .isoLatin1) ?? "(body could not be decoded)"
        let total = raw.count

        // A product that parses as a forecast is rendered as a table, and
        // a table is not big text — no cap applies.
        if let forecast = NWSTabularForecast.parse(raw) {
            return WinlinkRenderedBody(
                content: .forecast(forecast), raw: raw,
                totalCharacters: total, shownCharacters: total)
        }

        let shown: String
        if fullText || total <= previewCharacterLimit {
            shown = raw
        } else {
            // Cut on a line boundary when one is near, so the last visible
            // row is not half a table.
            let hardEnd = raw.index(raw.startIndex, offsetBy: previewCharacterLimit)
            let searchFrom = raw.index(hardEnd, offsetBy: -2_000, limitedBy: raw.startIndex)
                ?? raw.startIndex
            let lastBreak = raw[searchFrom..<hardEnd].lastIndex(where: \.isNewline)
            let cut = lastBreak.map(raw.index(after:)) ?? hardEnd
            shown = String(raw[raw.startIndex..<cut])
        }

        return WinlinkRenderedBody(
            content: .text(WinlinkBodyText.attributed(shown)), raw: raw,
            totalCharacters: total, shownCharacters: shown.count)
    }
}
