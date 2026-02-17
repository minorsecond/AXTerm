import Foundation

/// Tracks whether inbound AX.25 traffic has been observed after connect and
/// decides if a one-shot Mobilinkd demodulator reset should be sent.
nonisolated final class MobilinkdStartupReceptionGuard {
    private var parser = KISSFrameParser()
    private(set) var hasSeenInboundAX25 = false
    private(set) var didIssueRecoveryReset = false

    func resetForNewConnection() {
        parser.reset()
        hasSeenInboundAX25 = false
        didIssueRecoveryReset = false
    }

    func observeInboundChunk(_ chunk: Data) {
        guard !chunk.isEmpty, !hasSeenInboundAX25 else { return }

        let frames = parser.feed(chunk)
        for frame in frames {
            if case .ax25(let payload) = frame, !payload.isEmpty {
                hasSeenInboundAX25 = true
                return
            }
        }
    }

    func shouldIssueRecoveryReset(isConnected: Bool, isMobilinkd: Bool) -> Bool {
        guard isConnected, isMobilinkd else { return false }
        guard !hasSeenInboundAX25 else { return false }
        guard !didIssueRecoveryReset else { return false }

        didIssueRecoveryReset = true
        return true
    }
}
