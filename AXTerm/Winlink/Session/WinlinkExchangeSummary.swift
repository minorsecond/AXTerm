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
    var startedAt: Date

    var fraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(1.0, Double(bytesDone) / Double(bytesTotal))
    }

    /// Smoothed transfer rate in bytes/second since this message started.
    func bytesPerSecond(now: Date = Date()) -> Double? {
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed > 1, bytesDone > 0 else { return nil }
        return Double(bytesDone) / elapsed
    }

    /// Seconds remaining at the current rate.
    func estimatedSecondsRemaining(now: Date = Date()) -> Int? {
        guard bytesTotal > 0, let rate = bytesPerSecond(now: now), rate > 0 else { return nil }
        let remaining = Double(bytesTotal - bytesDone) / rate
        return remaining.isFinite ? max(0, Int(remaining)) : nil
    }
}
