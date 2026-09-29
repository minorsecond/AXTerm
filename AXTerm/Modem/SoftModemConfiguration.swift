import Foundation

/// Which channel of a stereo capture carries the radio.
nonisolated enum ModemInputChannel: String, Codable, CaseIterable, Sendable {
    case left, right, mono
}

/// Every knob the built-in modem has, with the defaults a VHF FM station
/// wants. The radio profile derives one of these; KISS command frames
/// (TXDELAY, P, SlotTime, TXtail, FullDuplex) adjust the live copy.
nonisolated struct SoftModemConfiguration: Equatable, Sendable {
    var mode: ModemMode = .afsk1200
    var inputDeviceUID: String?
    var outputDeviceUID: String?
    var inputChannel: ModemInputChannel = .left
    var kissPort: UInt8 = 0

    // Channel access, in the units KISS uses times ten (milliseconds here).
    var txDelayMs = 300
    var txTailMs = 100
    /// p-persistence: transmit in a clear slot when a random byte ≤ this.
    var persist: UInt8 = 63
    var slotTimeMs = 100
    var dwaitMs = 0
    var fullDuplex = false

    // Levels.
    var txLevelDBFS: Float = -6
    /// Space-tone gain relative to mark (pre-emphasis).
    var txSpaceGainDB: Float = 0
    /// Tilt hypotheses, one slicer each; `[0]` is a single centre slicer.
    var slicerTwistsDB: [Float] = [0]
    /// Below this RMS level nothing counts as carrier.
    var rxSquelchDBFS: Float = -50
    /// After our own transmission the radio's audio is garbage for a moment.
    var rxMuteAfterTxMs = 50

    // Limits.
    var maxQueuedFrames = 32
    var maxChannelWaitSeconds: Double = 10
    var pttWatchdogSeconds: Double = 30

    init() {}

    var txAmplitude: Float { Float(pow(10.0, Double(txLevelDBFS) / 20)) }

    /// Apply a KISS command frame's parameter (commands 1–5), which arrive
    /// in units of 10 ms.
    mutating func apply(kissCommand command: UInt8, value: UInt8) -> Bool {
        switch command {
        case 0x01: txDelayMs = Int(value) * 10
        case 0x02: persist = value
        case 0x03: slotTimeMs = Int(value) * 10
        case 0x04: txTailMs = Int(value) * 10
        case 0x05: fullDuplex = value != 0
        default: return false
        }
        return true
    }
}
