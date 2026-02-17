import Foundation

/// Tracks whether inbound AX.25 traffic has been observed after connect and
/// decides if a one-shot Mobilinkd demodulator reset should be sent.
nonisolated final class MobilinkdStartupReceptionGuard {
    private var parser = KISSFrameParser()
    private(set) var hasSeenInboundAX25 = false
    private(set) var hasSeenInboundKISSFrame = false
    private(set) var didIssueRecoveryReset = false

    func resetForNewConnection() {
        parser.reset()
        hasSeenInboundAX25 = false
        hasSeenInboundKISSFrame = false
        didIssueRecoveryReset = false
    }

    func observeInboundChunk(_ chunk: Data) {
        guard !chunk.isEmpty, !hasSeenInboundKISSFrame else { return }

        let frames = parser.feed(chunk)
        for frame in frames {
            switch frame {
            case .ax25(let payload) where !payload.isEmpty:
                hasSeenInboundAX25 = true
                hasSeenInboundKISSFrame = true
                return
            case .mobilinkdTelemetry:
                hasSeenInboundKISSFrame = true
                return
            default:
                continue
            }
        }
    }

    func shouldIssueRecoveryReset(isConnected: Bool, isMobilinkd: Bool) -> Bool {
        guard isConnected, isMobilinkd else { return false }
        guard !hasSeenInboundKISSFrame else { return false }
        guard !didIssueRecoveryReset else { return false }

        didIssueRecoveryReset = true
        return true
    }
}
