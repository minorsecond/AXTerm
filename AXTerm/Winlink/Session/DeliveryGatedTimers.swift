import Foundation

/// Winlink's waits for the other station, started once what we sent has
/// been delivered (park rehearsal 2026-10-08).
///
/// The engine arms a two-minute reply timer as soon as it hands our
/// messages to the link. On a slow link a 25 KB photo takes about nine
/// minutes on the air, and the peer cannot reply to what it has not
/// received, so the wait has to count from delivery. The transport reports
/// delivery (AX.25: bytes acknowledged; Telnet: written to the socket); a
/// wait requested while bytes are still outstanding is held until they are
/// all delivered, then started with its full length.
///
/// The operator's selection deadline is never held: it measures a person,
/// not the link.
@MainActor
final class DeliveryGatedTimers {
    typealias Kind = B2FSessionEngine.TimerKind

    private let start: (Kind, Int) -> Void
    private let cancelTimer: (Kind) -> Void
    private var submitted = 0
    private var delivered = 0
    private var held: [Kind: Int] = [:]

    init(start: @escaping (Kind, Int) -> Void, cancel: @escaping (Kind) -> Void) {
        self.start = start
        self.cancelTimer = cancel
    }

    /// Bytes handed to the transport.
    func noteSubmitted(_ bytes: Int) {
        submitted += bytes
    }

    /// The transport's running count of bytes delivered.
    func noteDelivered(_ total: Int) {
        delivered = max(delivered, total)
        guard delivered >= submitted, !held.isEmpty else { return }
        let ready = held
        held = [:]
        for (kind, seconds) in ready.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            start(kind, seconds)
        }
    }

    func request(_ kind: Kind, seconds: Int) {
        if kind == .selection || delivered >= submitted {
            held[kind] = nil
            start(kind, seconds)
        } else {
            held[kind] = seconds
        }
    }

    func cancel(_ kind: Kind) {
        held[kind] = nil
        cancelTimer(kind)
    }

    /// A fresh link: nothing submitted, nothing delivered, nothing held.
    func reset() {
        submitted = 0
        delivered = 0
        held = [:]
    }
}
