import Foundation

/// Parses and formats the APRS *message* class of packets — text messages,
/// their acknowledgements and rejects, bulletins/announcements, and the
/// message-style directed queries — plus the general (broadcast) query.
///
/// Positions are handled by `APRSParser`; this covers the `:` message data
/// type and the `?` query data type, which `APRSParser` deliberately returns
/// `nil` for. Pure and deterministic so the exact info-field bytes are
/// golden-tested before they touch the air.
///
/// References: APRS 1.01 ch. 14 (Message Format), ch. 15 (Query Formats),
/// ch. 17 (Bulletins), and the reply-ack addendum (`http://www.aprs.org`).
nonisolated enum APRSMessage {

    /// A parsed inbound message-class frame.
    enum Inbound: Equatable, Sendable {
        /// A text message *to* `addressee`, with an optional message number
        /// (the sender wants an ack when a number is present).
        case message(addressee: String, text: String, number: String?)
        /// An acknowledgement of message `number`, addressed to `addressee`.
        case ack(addressee: String, number: String)
        /// A rejection of message `number`, addressed to `addressee`.
        case reject(addressee: String, number: String)
        /// A bulletin or announcement. `id` is the raw addressee (`BLN…`),
        /// which encodes the bulletin line and optional group.
        case bulletin(id: String, text: String)
        /// A directed query addressed to `addressee` — a message whose text
        /// is an APRS query token such as `?APRSP` (send position) or
        /// `?PING?`. `query` keeps the leading `?`.
        case directedQuery(addressee: String, query: String)
        /// A general, broadcast query (info data type `?`), e.g. `?APRS?`.
        case generalQuery(String)
    }

    /// The greatest APRS message-text length (APRS 1.01 §14): 67 characters.
    static let maxTextLength = 67
    /// A message number is at most five characters.
    static let maxNumberLength = 5

    // MARK: - Addressee

    /// The addressee field is exactly nine characters, left-justified and
    /// space-padded on the right. A callsign longer than nine (never valid on
    /// the air) is clamped.
    static func addresseeField(_ call: String) -> String {
        let c = String(call.uppercased().prefix(9))
        return c.padding(toLength: 9, withPad: " ", startingAt: 0)
    }

    /// Whether `addressee` (already trimmed of padding) names us, given our
    /// own callsigns. Compared case-insensitively on the full call+SSID.
    static func isAddressedToUs(_ addressee: String, ours: [String]) -> Bool {
        let a = addressee.uppercased()
        return ours.contains { $0.uppercased() == a }
    }

    // MARK: - Parse

    /// Parse an AX.25 information field into a message-class frame, or `nil`
    /// if it is not one. A third-party frame (`}`) is unwrapped once and its
    /// payload re-parsed, so a message an i-gate relayed still reads.
    static func parse(info: Data) -> Inbound? {
        guard let text = decodeInfo(info), let dti = text.first else { return nil }
        switch dti {
        case ":":
            return parseMessageClass(String(text.dropFirst()))
        case "?":
            return .generalQuery(text)
        case "}":
            // Third-party: `}src>dst,path:<payload>`. Re-parse the payload
            // after the header-terminating colon.
            if let colon = text.dropFirst().firstIndex(of: ":") {
                let payload = String(text[text.index(after: colon)...])
                return parse(info: Data(payload.utf8))
            }
            return nil
        default:
            return nil
        }
    }

    /// The body after the leading `:` DTI: `AAAAAAAAA:text…`.
    private static func parseMessageClass(_ body: String) -> Inbound? {
        // Addressee is nine characters, then a `:` separator.
        guard body.count >= 10 else { return nil }
        let addrEnd = body.index(body.startIndex, offsetBy: 9)
        guard body[addrEnd] == ":" else { return nil }
        let rawAddressee = String(body[body.startIndex..<addrEnd])
        let addressee = rawAddressee.trimmingCharacters(in: .whitespaces).uppercased()
        var rest = String(body[body.index(after: addrEnd)...])
        // A trailing CR is common on the air; it belongs to no field.
        if rest.hasSuffix("\r") { rest.removeLast() }

        // Bulletins and announcements are addressed to BLN…; their text is
        // never an ack/rej and carries no message number.
        if addressee.hasPrefix("BLN") {
            return .bulletin(id: addressee, text: rest)
        }

        // ack / rej: `:ack{num}` / `:rej{num}` (reply-ack `ackAA}BB` allowed;
        // we keep the whole token as the number so a match still succeeds).
        if rest.hasPrefix("ack"), rest.count > 3 {
            return .ack(addressee: addressee, number: String(rest.dropFirst(3)))
        }
        if rest.hasPrefix("rej"), rest.count > 3 {
            return .reject(addressee: addressee, number: String(rest.dropFirst(3)))
        }

        // A plain message. Split a trailing `{number` (1–5 chars) off the end.
        let (messageText, number) = splitNumber(rest)

        // A message whose text begins with `?` is a directed query.
        if messageText.hasPrefix("?") {
            return .directedQuery(addressee: addressee, query: messageText)
        }
        return .message(addressee: addressee, text: messageText, number: number)
    }

    /// Split a trailing `{NNNNN` message number off message text. The number
    /// is the run after the *last* `{` when that run is 1–5 characters of the
    /// permitted set; otherwise the whole string is text and there is no
    /// number (a `{` inside body text does not become a spurious ack line).
    private static func splitNumber(_ text: String) -> (String, String?) {
        guard let brace = text.lastIndex(of: "{") else { return (text, nil) }
        let tail = String(text[text.index(after: brace)...])
        guard (1...maxNumberLength).contains(tail.count),
              tail.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "}" }) else {
            return (text, nil)
        }
        return (String(text[text.startIndex..<brace]), tail)
    }

    /// Decode the info field as Latin-1-tolerant text: APRS is 7-bit ASCII in
    /// practice, but a stray high byte must not drop the whole frame.
    private static func decodeInfo(_ info: Data) -> String? {
        if let s = String(data: info, encoding: .utf8) { return s }
        return String(data: info, encoding: .isoLatin1)
    }

    // MARK: - Encode

    /// A message info field: `:AAAAAAAAA:text{NNN`. The number is appended
    /// only when present (its presence is what requests an ack). Text is
    /// clamped to the 67-character limit; callers should validate first for a
    /// user-facing warning rather than relying on the silent clamp.
    static func messageInfo(to addressee: String, text: String, number: String?) -> String {
        let body = String(text.prefix(maxTextLength))
        var s = ":" + addresseeField(addressee) + ":" + body
        if let number, !number.isEmpty {
            s += "{" + String(number.prefix(maxNumberLength))
        }
        return s
    }

    /// An acknowledgement info field: `:AAAAAAAAA:ack{NNN`.
    static func ackInfo(to addressee: String, number: String) -> String {
        ":" + addresseeField(addressee) + ":ack" + String(number.prefix(maxNumberLength))
    }

    /// A reject info field: `:AAAAAAAAA:rej{NNN`.
    static func rejectInfo(to addressee: String, number: String) -> String {
        ":" + addresseeField(addressee) + ":rej" + String(number.prefix(maxNumberLength))
    }

    /// A directed query info field: a message whose text is the query token,
    /// e.g. `:N0CALL   :?APRSP`. No message number (queries are not acked).
    static func directedQueryInfo(to addressee: String, query: String) -> String {
        messageInfo(to: addressee, text: query.hasPrefix("?") ? query : "?" + query,
                    number: nil)
    }

    /// The general-query info field, transmitted **unaddressed** to the APRS
    /// tocall — the flood used by "who can hear me". Every APRS station in
    /// earshot answers on its own with a position/status; plain AX.25 nodes
    /// aren't listening for it, so it never bothers them. One transmission
    /// replaces a directed query per station.
    static let generalQueryAllInfo = "?APRS?"
}

/// The standard APRS **general queries**: one unaddressed transmission that
/// every station in earshot answers on its own.
///
/// This is the flood-broadcast idea Xastir exposes, and it is the cheapest
/// question this app can ask. Instead of polling forty stations one at a time
/// — forty transmissions on a shared channel, which is antisocial and slow —
/// one frame goes to the APRS tocall and the network answers itself. Plain
/// AX.25 nodes are not listening for these, so they are never bothered.
///
/// Query strings are from the APRS specification, chapter 15. They are not
/// invented and must not be: a station only answers a string it recognises.
nonisolated enum APRSGeneralQuery: String, CaseIterable, Identifiable, Sendable {
    /// Everything a station is willing to say: position, status, capabilities.
    case all = "?APRS?"
    /// Position reports only. The narrowest question, and the one to ask when
    /// you want the map filled in and nothing else.
    case position = "?APRSP"
    /// Weather stations report their current conditions.
    case weather = "?WX?"
    /// Station status text.
    case status = "?APRSS"
    /// Objects and items a station is running — the incident markers.
    case objects = "?APRSO"
    /// Which stations each responder is hearing *directly*. Answers come back
    /// as a list, which is how you learn the shape of the network around you
    /// rather than only who can hear you.
    case directHeard = "?APRSD"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "Anything they will say"
        case .position: return "Positions"
        case .weather: return "Weather conditions"
        case .status: return "Status text"
        case .objects: return "Objects & items"
        case .directHeard: return "Who they hear directly"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "dot.radiowaves.left.and.right"
        case .position: return "mappin.and.ellipse"
        case .weather: return "cloud.sun.fill"
        case .status: return "text.bubble"
        case .objects: return "exclamationmark.triangle"
        case .directHeard: return "point.3.connected.trianglepath.dotted"
        }
    }

    var help: String {
        switch self {
        case .all:
            return "Sends \(rawValue). Every APRS station in earshot answers with whatever it "
                + "is set to give \u{2014} usually a position and a status line."
        case .position:
            return "Sends \(rawValue). Asks every station for a position report, which fills in "
                + "the map for anyone heard but not yet placed."
        case .weather:
            return "Sends \(rawValue). Asks the weather stations for current conditions. The "
                + "fastest way to refresh the temperature, wind and pressure the map is "
                + "drawing from."
        case .status:
            return "Sends \(rawValue). Asks each station for its status text, which is where "
                + "operators put what they are doing and what they can offer."
        case .objects:
            return "Sends \(rawValue). Asks stations to re-send the objects and items they are "
                + "running \u{2014} hazards, shelters, closures. Worth doing after a restart, "
                + "when this receiver has heard none of them yet."
        case .directHeard:
            return "Sends \(rawValue). Asks each station which stations it is hearing directly, "
                + "which maps the network around you rather than only around this radio."
        }
    }
}
