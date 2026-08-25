import Foundation

/// The outcome of one Winlink mail exchange session.
nonisolated struct WinlinkExchangeSummary: Equatable, Sendable {
    var sentMIDs: [String] = []
    var receivedMIDs: [String] = []
    var rejectedMIDs: [String] = []
    var deferredMIDs: [String] = []
    var bytesSent: Int = 0
    var bytesReceived: Int = 0
    var aborted: Bool = false
    var failureReason: String?

    var succeeded: Bool { failureReason == nil && !aborted }
}

/// Live progress of the running exchange, for the progress card.
nonisolated struct WinlinkExchangeProgress: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        case connecting
        case handshake
        case sending
        case receiving
    }

    var kind: Kind
    var mid: String?
    var subject: String?
    /// Bytes done / total for the current message (compressed sizes —
    /// what actually travels on the air). Total 0 means indeterminate.
    var bytesDone: Int = 0
    var bytesTotal: Int = 0
    /// Bytes carried in from an interrupted session (B2F resume). They are
    /// part of `bytesDone` because the bar measures the whole message, but
    /// they never crossed the air here — the rate must not count them.
    var baselineBytes: Int = 0
    var startedAt: Date

    var fraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(1.0, Double(bytesDone) / Double(bytesTotal))
    }

    /// Bytes actually moved over the air during this session.
    var bytesThisSession: Int { max(0, bytesDone - baselineBytes) }

    /// Smoothed transfer rate in bytes/second since this message started.
    func bytesPerSecond(now: Date = Date()) -> Double? {
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed > 1, bytesThisSession > 0 else { return nil }
        return Double(bytesThisSession) / elapsed
    }

    /// Seconds remaining at the current rate.
    func estimatedSecondsRemaining(now: Date = Date()) -> Int? {
        guard bytesTotal > 0, let rate = bytesPerSecond(now: now), rate > 0 else { return nil }
        let remaining = Double(bytesTotal - bytesDone) / rate
        return remaining.isFinite ? max(0, Int(remaining)) : nil
    }
}


/// One line of the live exchange transcript (the popdown console).
nonisolated struct WinlinkTranscriptEntry: Identifiable, Equatable, Sendable {

    enum Direction: Equatable, Sendable {
        case sent
        case received
        case event
    }

    let id: UUID
    var timestamp: Date
    var direction: Direction
    var text: String

    init(direction: Direction, text: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.direction = direction
        self.timestamp = timestamp
        self.text = text
    }

    /// Renders a wire chunk for display: printable line-mode text becomes
    /// lines; binary blocks become a byte-count summary.
    static func describeWireChunk(_ data: Data) -> [String] {
        let printable = data.filter { (0x20...0x7e).contains($0) || $0 == 0x0d || $0 == 0x0a || $0 == 0x09 }
        guard data.count > 0 else { return [] }
        if printable.count * 10 >= data.count * 9 {
            // Text: split into lines, drop empties.
            let text = String(decoding: data, as: UTF8.self)
            let lines = text
                .split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\r\n" || $0 == "\r" || $0 == "\n" })
                .map(String.init)
            return lines.isEmpty ? ["‹\(data.count) bytes›"] : lines
        }
        return ["‹\(data.count) bytes of compressed message data›"]
    }
}
