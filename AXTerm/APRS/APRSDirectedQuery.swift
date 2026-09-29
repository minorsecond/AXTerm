import Foundation

/// The APRS **directed** queries: one message, addressed to one station.
///
/// The counterpart to `APRSGeneralQuery`. A general query is shouted at the
/// channel and answered by everyone in earshot; a directed query is a message
/// to a single station, so it costs one transmission and gets at most one
/// answer. That makes it the right tool for a question about *this* station —
/// what is it running, what can it hear, how did my frame reach it.
///
/// **What comes back is the thing that matters.** Some of these are answered
/// with a message addressed back to us, which is proof: the station received
/// the query, decided to answer, and named us. Others are answered with an
/// ordinary broadcast — a position, a status, an object — that carries no
/// reference to the query at all and is indistinguishable from the beacon the
/// station was going to send anyway. `APRSAnswerEvidence` exists because of the
/// second kind, and `answer` is how the UI tells the operator which they are
/// getting *before* they send it.
///
/// Sources: APRS Protocol Reference 1.01 chapter 15, and Xastir's
/// `process_directed_query` (`src/db.c`) as the reference implementation.
nonisolated enum APRSDirectedQuery: String, CaseIterable, Identifiable, Sendable {

    /// Send me your position.
    case position = "?APRSP"
    /// Send me the path my query took to reach you.
    case trace = "?APRST"
    /// What software are you running?
    case version = "?VER"
    /// Which stations are you hearing directly?
    case directs = "?APRSD"
    /// Send me your status text.
    case status = "?APRSS"
    /// Re-send the objects and items you are running.
    case objects = "?APRSO"
    /// Send me any messages you are holding for me.
    case messages = "?APRSM"

    var id: String { rawValue }

    /// The literal query text that goes in the message body.
    var token: String { rawValue }

    /// How the station replies, which decides whether an answer can be
    /// *proved* or only inferred from timing.
    enum Answer: Sendable, Equatable {
        /// A message addressed back to us. Unambiguous.
        case message
        /// An ordinary broadcast — position, status or object — with nothing
        /// in it that refers to the query.
        case broadcast
    }

    var answer: Answer {
        switch self {
        case .trace, .version, .directs, .messages: return .message
        case .position, .status, .objects: return .broadcast
        }
    }

    /// Whether an answer to this query is provable rather than inferred.
    var isProvable: Bool { answer == .message }

    var label: String {
        switch self {
        case .position: return "Position"
        case .trace: return "Path my query took"
        case .version: return "Software version"
        case .directs: return "Who they hear directly"
        case .status: return "Status text"
        case .objects: return "Objects & items"
        case .messages: return "Messages held for me"
        }
    }

    /// One line under the label: what actually arrives.
    var reply: String {
        switch self {
        case .position: return "A position report, broadcast to the channel."
        case .trace: return "A message back to you: PATH= your call > the digipeaters it came through."
        case .version: return "A message back to you naming their software and version."
        case .directs: return "A message back to you: Directs= the stations they hear with no digipeater."
        case .status: return "Their status text, broadcast to the channel."
        case .objects: return "Every object and item they are running, re-broadcast."
        case .messages: return "Any messages they are holding for you, re-sent as messages."
        }
    }

    var systemImage: String {
        switch self {
        case .position: return "mappin.and.ellipse"
        case .trace: return "arrow.triangle.swap"
        case .version: return "cpu"
        case .directs: return "point.3.connected.trianglepath.dotted"
        case .status: return "text.bubble"
        case .objects: return "exclamationmark.triangle"
        case .messages: return "tray.and.arrow.down"
        }
    }

    /// Whether AXTerm answers this query when another station asks *it*.
    /// Shown in the picker so the operator can see what this station offers
    /// the channel, and so the two halves cannot drift apart unnoticed.
    var axtermAnswersIt: Bool {
        switch self {
        case .position, .trace, .version, .directs: return true
        case .status, .objects, .messages: return false
        }
    }

    var help: String {
        switch self {
        case .position:
            return "Sends \(token). Fills in the map for a station heard but not yet placed. "
                + "The reply is a plain broadcast beacon, so nothing in it says it was an "
                + "answer \u{2014} only its timing can suggest that."
        case .trace:
            return "Sends \(token) (also written ?PING?). The station replies with the path "
                + "your query travelled to reach it, which is the one query that tells you how "
                + "the network got you there rather than only that it did."
        case .version:
            return "Sends \(token). The station names its software. Answered with a message "
                + "addressed to you, so a reply is proof it heard you \u{2014} the cleanest "
                + "reachability test APRS offers."
        case .directs:
            return "Sends \(token). The station lists what it hears with no digipeater in "
                + "between, which maps the network around it rather than around you."
        case .status:
            return "Sends \(token). Asks for the status line, where operators put what they "
                + "are doing and what they can offer. Broadcast, not addressed to you."
        case .objects:
            return "Sends \(token). Asks the station to re-broadcast its objects and items "
                + "\u{2014} hazards, shelters, closures. Worth doing after a restart, when "
                + "this receiver has heard none of them yet."
        case .messages:
            return "Sends \(token). Asks the station to re-send any messages it is holding for "
                + "you. Rarely implemented \u{2014} Xastir does not."
        }
    }
}

/// One directed query, aimed at one station, ready to transmit.
///
/// A struct rather than a pile of closure arguments because every part of it
/// is a decision the operator made: who, what, and how far to reach. The token
/// is carried literally so a query typed by hand travels the same road as one
/// picked from the list.
nonisolated struct APRSStationQuery: Equatable, Sendable {

    var callsign: String
    /// The literal text of the query, e.g. `?APRSP`. Authoritative: `kind` is
    /// for display only, and is nil for a query the operator typed.
    var token: String
    var reach: APRSProbeReach
    var kind: APRSDirectedQuery?

    init(callsign: String, kind: APRSDirectedQuery, reach: APRSProbeReach = .direct) {
        self.callsign = callsign.uppercased()
        self.token = kind.token
        self.reach = reach
        self.kind = kind
    }

    /// A query the operator typed. Normalised the way the spec writes them —
    /// uppercase, leading `?` — because a station that follows the spec (as
    /// Xastir does) rejects any other case as an illegal query rather than
    /// guessing what was meant.
    init(callsign: String, custom: String, reach: APRSProbeReach = .direct) {
        self.callsign = callsign.uppercased()
        self.token = Self.normalize(custom)
        self.reach = reach
        self.kind = APRSDirectedQuery(rawValue: Self.normalize(custom))
    }

    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("?") ? trimmed : "?" + trimmed
    }

    /// A typed query has to be something, and short enough to ride in a
    /// message body alongside nothing else.
    var isValid: Bool {
        !callsign.isEmpty && token.count > 1 && token.count <= APRSMessage.maxTextLength
    }
}
