import Foundation

/// The knobs of p-persistence CSMA, in samples of the input clock.
nonisolated struct ChannelAccessParameters: Equatable, Sendable {
    var slotTimeSamples: Int
    var persist: UInt8
    var dwaitSamples: Int
    var fullDuplex: Bool

    init(sampleRate: Double, configuration c: SoftModemConfiguration) {
        slotTimeSamples = max(1, Int(Double(c.slotTimeMs) / 1000 * sampleRate))
        persist = c.persist
        dwaitSamples = Int(Double(c.dwaitMs) / 1000 * sampleRate)
        fullDuplex = c.fullDuplex
    }

    init(slotTimeSamples: Int, persist: UInt8, dwaitSamples: Int = 0, fullDuplex: Bool = false) {
        self.slotTimeSamples = max(1, slotTimeSamples)
        self.persist = persist
        self.dwaitSamples = dwaitSamples
        self.fullDuplex = fullDuplex
    }
}

nonisolated enum ChannelAccessDecision: Equatable, Sendable {
    case idle
    case waiting(nextCheck: Int64)
    case transmit
}

/// p-persistence CSMA, clocked in samples.
///
/// While the channel is busy, wait, however long that takes: the frame is
/// held, never dropped, as every KISS TNC does. Once it clears, wait DWAIT,
/// then at every SLOTTIME boundary draw a byte and transmit if it is
/// ≤ PERSIST (63 ≈ one chance in four per slot). Everything is measured in samples of the input
/// clock and the randomness is injected, so a test replays a decision trace
/// exactly.
nonisolated struct ChannelAccess<RNG: RandomNumberGenerator> {

    typealias Parameters = ChannelAccessParameters
    typealias Decision = ChannelAccessDecision

    var parameters: Parameters
    private var rng: RNG
    private var requestedAt: Int64?
    private var clearSince: Int64?
    private var nextSlotAt: Int64?

    init(parameters: Parameters, rng: RNG) {
        self.parameters = parameters
        self.rng = rng
    }

    var isRequesting: Bool { requestedAt != nil }

    mutating func requestChannel(now: Int64) {
        requestedAt = now
        clearSince = nil
        nextSlotAt = nil
    }

    mutating func cancel() {
        requestedAt = nil
        clearSince = nil
        nextSlotAt = nil
    }

    /// Decide at `now`, given the carrier-detect state.
    mutating func evaluate(now: Int64, dcd: Bool) -> Decision {
        guard requestedAt != nil else { return .idle }
        if parameters.fullDuplex {
            cancel()
            return .transmit
        }
        if dcd {
            clearSince = nil
            nextSlotAt = nil
            return .waiting(nextCheck: now + 1)
        }
        if clearSince == nil {
            clearSince = now
            nextSlotAt = now + Int64(parameters.dwaitSamples)
        }
        guard let slot = nextSlotAt, now >= slot else {
            return .waiting(nextCheck: nextSlotAt ?? now + 1)
        }
        // A slot boundary on a clear channel: roll the dice.
        let roll = UInt8(truncatingIfNeeded: rng.next())
        if roll <= parameters.persist {
            cancel()
            return .transmit
        }
        nextSlotAt = slot + Int64(parameters.slotTimeSamples)
        return .waiting(nextCheck: nextSlotAt!)
    }
}
