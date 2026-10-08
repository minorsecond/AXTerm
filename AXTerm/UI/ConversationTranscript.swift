import Foundation

/// The Session view as a conversation, for the iPhone and iPad (park
/// rehearsal 2026-10-08, the operator's choice). A BBS listing read as one
/// bubble per line, each with its own header, interleaved with I(6,5),
/// RR(1) F and RTO notes. Here protocol frames and link chatter are left out
/// (the Packets tab keeps them), and consecutive text from one station reads
/// as one block.
nonisolated enum ConversationTranscript {
    /// A pause this long, or a line from anyone else, starts a new block.
    static let blockGap: TimeInterval = 10

    /// The lines a conversation shows, with each run of text from one
    /// station to another joined into one line.
    static func lines(_ lines: [ConsoleLine]) -> [ConsoleLine] {
        var blocks: [ConsoleLine] = []
        var run: [ConsoleLine] = []

        func flush() {
            guard let first = run.first else { return }
            if run.count == 1 {
                blocks.append(first)
            } else {
                blocks.append(ConsoleLine(
                    id: first.id, kind: first.kind, timestamp: first.timestamp,
                    from: first.from, to: first.to,
                    text: run.map(\.text).joined(separator: "\n"),
                    via: first.via, messageType: first.messageType, subject: first.subject))
            }
            run = []
        }

        for line in lines where !isLinkControl(line) {
            if let last = run.last, joins(line, after: last) {
                run.append(line)
            } else {
                flush()
                if isJoinable(line) {
                    run = [line]
                } else {
                    blocks.append(line)
                }
            }
        }
        flush()
        return blocks
    }

    /// A protocol frame's summary ("I(6,5)", "RR(1) F", "SABM P") or the
    /// link's own chatter ("Frame sent successfully", "Adaptive: …").
    static func isLinkControl(_ line: ConsoleLine) -> Bool {
        switch line.kind {
        case .system:
            return line.text == "Frame sent successfully" || line.text.hasPrefix("Adaptive: ")
        case .packet:
            return line.messageType == .prompt && line.text.wholeMatch(of: frameSummary) != nil
        case .error:
            return false
        }
    }

    /// What `PacketEngine.describeControlFrame` writes for a frame.
    private static let frameSummary =
        /(?:SABME?|DISC|UA|DM|FRMR|XID|U\?|RR|RNR|REJ|SREJ|I)(?:\(\d+(?:,\d+)?\))?(?: (?:P|F|P\/F))?/

    /// Text one station sent another: what a block is made of. Beacons, IDs
    /// and duplicates heard by another path keep their own rows.
    private static func isJoinable(_ line: ConsoleLine) -> Bool {
        guard line.kind == .packet, !line.isDuplicate, line.from != nil, line.to != nil else { return false }
        switch line.messageType {
        case .data, .prompt, .message, .mail: return true
        case .id, .beacon, .none: return false
        }
    }

    private static func joins(_ line: ConsoleLine, after last: ConsoleLine) -> Bool {
        isJoinable(line) && line.from == last.from && line.to == last.to
            && line.timestamp.timeIntervalSince(last.timestamp) <= blockGap
    }
}
