import Foundation

/// "1 message", "2 messages": a count with its noun in the right number.
///
/// For counters drawn in the interface. Interpolating the count in front of
/// a plural noun gave "1 messages" in the terminal header, and the same
/// pattern had been copied into a dozen other counters.
nonisolated enum CountPhrase {
    /// The count followed by `singular` when it is exactly one, otherwise by
    /// `plural`, which defaults to `singular` with an "s".
    static func of(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(noun(for: count, singular, plural: plural))"
    }

    /// Just the noun, for text that puts the count somewhere else.
    static func noun(for count: Int, _ singular: String, plural: String? = nil) -> String {
        count == 1 ? singular : (plural ?? singular + "s")
    }
}
