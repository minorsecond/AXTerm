import Foundation

/// Is somebody transmitting?
///
/// Carrier detect comes from the receiver, not the squelch: packet radios run
/// with the squelch fully open so the modem, not the radio, decides what is a
/// signal. That makes this the component that has to tell a transmission from
/// band noise, with noise present at all times.
///
/// **What noise can fake.** Two earlier inputs both turned out to be things
/// noise produces freely, and using them meant an idle channel read as busy —
/// so every transmission waited out `maxChannelWaitSeconds` and was dropped,
/// reported as "channel busy" on a channel nobody was using:
///
/// - *HDLC activity.* A flag is six ones between zeros, which random bits
///   deliver several times a second; the decoder then latches `synchronised`
///   and reports `.inFrame` until an abort. Measured on audio containing no
///   signal at all: carrier asserted for 90% of the time.
/// - *PLL lock.* A phase-locked loop locks to whatever it is given — that is
///   its job — and `isLocked` also latched, since its transition count was a
///   lifetime total that never decayed. With the nine-slicer twist comb, where
///   any one of nine independent PLLs locking counted, the same audio read as
///   busy 99.7% of the time.
///
/// **What noise cannot fake** is the thing the demodulator was already
/// computing and throwing away: the normalised difference between the two tone
/// powers. One tone present drives it to ±1; two equal powers, which is what
/// noise is, leave it near zero. Averaged over a couple of dozen bits it
/// separates cleanly — measured over 60 s of noise and frames down to 6 dB
/// SNR, noise never exceeded 0.56 while a signal held above 0.83.
nonisolated struct DataCarrierDetect: Sendable {

    /// Above this, one tone is present. Set between the two measured
    /// populations (noise ≤0.56, signal ≥0.83) — see the type comment. Nearer
    /// the noise end, because failing to hear a station and transmitting on
    /// top of it costs more than a late start.
    static let discriminationThreshold: Float = 0.65

    let holdSamples: Int64
    private var lastActiveAt: Int64 = .min / 2
    private(set) var isDetected = false

    init(holdSamples: Int) {
        self.holdSamples = Int64(max(0, holdSamples))
    }

    /// - Parameter discrimination: `AFSKDemodulator.toneDiscrimination` — how
    ///   cleanly the two tones are separated, 0…1. It does not depend on
    ///   framing or bit sync, so it holds up through the sync losses that made
    ///   the decoder go idle in the middle of other people's transmissions:
    ///   carrier used to flap clear-and-back four times inside one millisecond
    ///   and hold for only 100-200 ms across a transmission taking the best
    ///   part of a second, and every one of those gaps was an invitation for
    ///   `ChannelAccess` to start its countdown and key on top of them.
    mutating func update(discrimination: Float,
                         rmsDBFS: Float, squelchDBFS: Float, now: Int64) -> Bool {
        // The level floor still gates it: below the floor there is nothing to
        // discriminate, and a ratio of two tiny numbers is not evidence.
        if discrimination >= Self.discriminationThreshold, rmsDBFS >= squelchDBFS {
            lastActiveAt = now
        }
        isDetected = now - lastActiveAt <= holdSamples
        return isDetected
    }

    mutating func reset() {
        lastActiveAt = .min / 2
        isDetected = false
    }
}
