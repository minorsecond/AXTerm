import Foundation

/// The rules behind the message composer, kept out of the view.
///
/// Worth separating because two of them are easy to get subtly wrong and
/// neither is visible in a screenshot: what counts as a sendable addressee,
/// and what happens at the 67-character limit. The old sheet silently
/// truncated on send, so a message could go out shorter than what the
/// operator read back before pressing the button.
nonisolated struct APRSComposeModel: Equatable, Sendable {

    /// A station worth offering as an addressee, because it has been heard.
    struct Suggestion: Equatable, Sendable, Identifiable {
        let callsign: String
        let lastHeard: Date?
        /// How it reached us the last time, for telling a local station from
        /// one that only arrives through a digipeater.
        let via: String?

        var id: String { callsign }
    }

    var to: String = ""
    var text: String = ""

    /// Addressee as it would go on the air.
    var normalizedTo: String {
        to.trimmingCharacters(in: .whitespaces).uppercased()
    }

    var remainingCharacters: Int {
        APRSMessage.maxTextLength - text.count
    }

    var isOverLength: Bool { remainingCharacters < 0 }

    /// Whether the addressee is a callsign at all.
    ///
    /// Empty is not invalid, only incomplete: an empty field should read as
    /// "nothing typed yet" rather than being marked wrong the moment the
    /// sheet opens.
    var addresseeProblem: String? {
        let call = normalizedTo
        guard !call.isEmpty else { return nil }
        guard call.count <= 9 else { return "Too long for a callsign." }
        guard CallsignValidator.isValidCallsign(call) else {
            return "Not a callsign. APRS messages are addressed to a station, "
                + "optionally with an SSID like W0ARP-9."
        }
        return nil
    }

    var canSend: Bool {
        !normalizedTo.isEmpty
            && addresseeProblem == nil
            && !text.trimmingCharacters(in: .whitespaces).isEmpty
            && !isOverLength
    }

    /// What the addressee field should offer, narrowed by what has been typed.
    ///
    /// Ordered by when each was last heard, because the station you want is
    /// almost always one that just said something. Matching is a prefix on the
    /// callsign rather than a fuzzy search: an operator typing `W0` means the
    /// callsigns starting `W0`, and anything cleverer gets in the way.
    func suggestions(from heard: [Suggestion], limit: Int = 8) -> [Suggestion] {
        let typed = normalizedTo
        let matching = typed.isEmpty
            ? heard
            : heard.filter { $0.callsign.uppercased().hasPrefix(typed) && $0.callsign.uppercased() != typed }
        return matching
            .sorted {
                // Most recently heard first; never-heard last, alphabetically,
                // so the order is stable rather than however the caller built it.
                switch ($0.lastHeard, $1.lastHeard) {
                case let (a?, b?): return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.callsign < $1.callsign
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The heard station the addressee names, if any.
    ///
    /// Used to confirm a prefilled addressee back to the operator. Opening the
    /// composer from a station's own card fills the field in, and a filled
    /// field looks exactly like one that was typed — so the station it is
    /// actually addressed to is worth stating rather than implying.
    func match(in heard: [Suggestion]) -> Suggestion? {
        let call = normalizedTo
        guard !call.isEmpty else { return nil }
        return heard.first { $0.callsign.uppercased() == call }
    }

    /// Whether the addressee has been heard here.
    ///
    /// Not a blocker. A message to a station this receiver has never heard can
    /// still be delivered by an i-gate, and refusing to send one would be
    /// wrong. It is worth saying, though: on RF alone it is going nowhere, and
    /// that is the difference between "no reply yet" and "never left".
    func isHeard(in heard: [Suggestion]) -> Bool {
        let call = normalizedTo
        guard !call.isEmpty else { return true }
        return heard.contains { $0.callsign.uppercased() == call }
    }

    /// The body as it will actually be transmitted.
    ///
    /// Trimmed of surrounding whitespace and never longer than the limit. The
    /// view refuses to send an over-length message rather than relying on
    /// this, so this only ever has to be the last line of defence.
    var outgoingText: String {
        String(text.trimmingCharacters(in: .whitespaces).prefix(APRSMessage.maxTextLength))
    }
}
