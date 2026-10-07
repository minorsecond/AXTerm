import Foundation

/// Whether a radio is transmitting, for the light that shows it.
///
/// A sound modem reports its PTT, so the light follows the radio exactly.
/// A TNC reports nothing once it has a frame, so the light is an estimate:
/// from the hand-off, the TX delay and the frame's airtime, with frames
/// handed over back to back sharing one key-up. The toolbar's dot used to
/// flash a quarter second per frame whatever the radio did (operator,
/// 2026-10-07).
nonisolated struct TransmitIndicator: Equatable, Sendable {
    /// When the estimate says a TNC's transmission ends.
    private(set) var endsAt: Date?
    /// The modem's own PTT, once it has reported one.
    private var ptt: Bool?

    /// Flags and FCS around each frame's address, control and info bytes.
    static let framingBytes = 4

    mutating func noteHandedOff(bytes: Int, txDelay: TimeInterval, at now: Date, bitRate: Double = 1200) {
        guard ptt == nil else { return }   // the modem says when it keys
        let airtime = Double((bytes + Self.framingBytes) * 8) / bitRate
        if let endsAt, endsAt > now {
            self.endsAt = endsAt.addingTimeInterval(airtime)   // same key-up
        } else {
            endsAt = now.addingTimeInterval(txDelay + airtime)
        }
    }

    mutating func notePTT(_ on: Bool) {
        ptt = on
        endsAt = nil
    }

    func isTransmitting(at now: Date) -> Bool {
        if let ptt { return ptt }
        guard let endsAt else { return false }
        return now < endsAt
    }
}
