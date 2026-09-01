import Foundation

/// One connected-mode session, as it will be remembered.
///
/// The terminal kept its sessions in `@State`, capped at twenty and gone on
/// relaunch, so "what did BBSCBH say last Tuesday" had no answer and neither
/// did "have I ever actually worked this node". A session is the unit an
/// operator thinks in, one conversation with one station over one path, and
/// it is worth keeping.
nonisolated struct TerminalSession: Identifiable, Equatable, Sendable {

    /// How a session ended, in the terms the operator would use.
    ///
    /// Distinguished because they mean different things about the path. A
    /// refusal is the far end answering; a timeout is nothing answering at
    /// all; only one of those is evidence the station is there.
    enum Outcome: String, Equatable, Sendable, CaseIterable {
        case live, closed, refused, timedOut, lost

        var label: String {
            switch self {
            case .live: return "Live"
            case .closed: return "Closed"
            case .refused: return "Refused"
            case .timedOut: return "No answer"
            case .lost: return "Dropped"
            }
        }

        /// Whether the far end demonstrably heard us. A refusal counts: it
        /// took a decoded frame to produce one.
        var provesTheFarEndHeardUs: Bool { self == .closed || self == .refused }

        /// From the terminal's own status line.
        ///
        /// Reusing those strings rather than inventing a second vocabulary:
        /// the history should describe a session in the words the operator
        /// watched it happen in, and two vocabularies eventually disagree.
        ///
        /// Nil while a session is still in progress, which is most of the
        /// states the strip shows.
        init?(statusText: String) {
            switch statusText.lowercased() {
            case "disconnected": self = .closed
            case "refused", "busy": self = .refused
            case "timed out", "no answer": self = .timedOut
            case "failed", "lost": self = .lost
            default: return nil
            }
        }
    }

    let id: UUID
    var remote: String
    /// Digipeaters actually used, in order. Empty for a direct link.
    var via: [String]
    /// On a node-prompt relay, the station on the far end of the chain.
    var relayDestination: String?
    var transport: String
    var startedAt: Date
    var endedAt: Date?
    var outcome: Outcome
    var framesSent: Int
    var framesReceived: Int
    var bytesSent: Int
    var bytesReceived: Int
    /// What was said, kept verbatim.
    var transcript: String
    /// The operator's own labels, lowercased on the way in so "Winlink" and
    /// "winlink" are one tag rather than two.
    var tags: [String]
    var note: String?

    init(id: UUID = UUID(), remote: String, via: [String] = [],
         relayDestination: String? = nil, transport: String = "AX.25",
         startedAt: Date, endedAt: Date? = nil, outcome: Outcome = .live,
         framesSent: Int = 0, framesReceived: Int = 0,
         bytesSent: Int = 0, bytesReceived: Int = 0,
         transcript: String = "", tags: [String] = [], note: String? = nil) {
        self.id = id
        self.remote = remote.uppercased()
        self.via = via
        self.relayDestination = relayDestination?.uppercased()
        self.transport = transport
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.framesSent = framesSent
        self.framesReceived = framesReceived
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.transcript = transcript
        self.tags = TerminalSession.normalized(tags)
        self.note = note
    }

    /// One canonical form per tag, so the filter list does not carry three
    /// spellings of the same word.
    static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The far end of the conversation, which on a relay is not who we
    /// dialled.
    var correspondent: String { relayDestination ?? remote }

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    /// Everything a search should look at, kept here rather than in the view
    /// so a query means the same thing wherever it is typed.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        if remote.lowercased().contains(needle) { return true }
        if relayDestination?.lowercased().contains(needle) == true { return true }
        if via.contains(where: { $0.lowercased().contains(needle) }) { return true }
        if transport.lowercased().contains(needle) { return true }
        if outcome.label.lowercased().contains(needle) { return true }
        if tags.contains(where: { $0.contains(needle) }) { return true }
        if note?.lowercased().contains(needle) == true { return true }
        // The transcript last: it is the largest haystack and the least
        // likely thing someone typing a callsign is aiming at.
        return transcript.lowercased().contains(needle)
    }
}
