import Foundation

/// Tracks whether inbound AX.25 traffic has been observed after connect and
/// decides if a one-shot Mobilinkd demodulator reset should be sent.
nonisolated final class MobilinkdStartupReceptionGuard {
    enum RecoveryTrigger {
        case noInboundKISS
        case noInboundAX25
    }

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

    /// Mark that a RESET was already sent during KISS init, so the startup
    /// watchdog does not send a redundant second RESET. Double-resetting the
    /// demodulator prevents the analog front end (AGC, DC offset) from fully
    /// settling, degrading sensitivity for weaker signals.
    func markInitResetSent() {
        didIssueRecoveryReset = true
    }

    func observeInboundChunk(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        // We only need to keep parsing until first AX.25 is observed.
        // Telemetry may arrive before data, so do not stop early on first KISS frame.
        guard !hasSeenInboundAX25 else { return }

        let frames = parser.feed(chunk)
        for frame in frames {
            switch frame {
            case .ax25(let payload) where !payload.isEmpty:
                hasSeenInboundAX25 = true
                hasSeenInboundKISSFrame = true
                return
            case .ax25:
                hasSeenInboundKISSFrame = true
            case .mobilinkdTelemetry:
                hasSeenInboundKISSFrame = true
            case .unknown:
                hasSeenInboundKISSFrame = true
            default:
                continue
            }
        }
    }

    func shouldIssueRecoveryReset(
        isConnected: Bool,
        isMobilinkd: Bool,
        trigger: RecoveryTrigger
    ) -> Bool {
        guard isConnected, isMobilinkd else { return false }
        guard !didIssueRecoveryReset else { return false }

        switch trigger {
        case .noInboundKISS:
            guard !hasSeenInboundKISSFrame else { return false }
        case .noInboundAX25:
            guard !hasSeenInboundAX25 else { return false }
        }

        didIssueRecoveryReset = true
        return true
    }
}
