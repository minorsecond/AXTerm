import Foundation

/// Bit-clock recovery.
///
/// A 32-bit phase accumulator advances by one bit's worth every sample; the
/// bit is sampled when it wraps from positive to negative, half a bit after
/// the phase zero. Every level transition in the data pulls the phase toward
/// zero by an inertia factor, so transitions (which happen at bit
/// boundaries) end up at phase zero and the sampling instant lands in the
/// middle of the bit. A slicer that is hearing data pulls gently; one still
/// searching pulls harder.
nonisolated struct DigitalPLL: Sendable {

    let step: Int32
    let lockedInertia: Float
    let searchingInertia: Float

    private var phase: Int32 = 0
    /// Mean |phase at transition| as a fraction of a bit, over recent transitions.
    private(set) var jitterBits: Float = 0.5
    private var transitions = 0

    init(samplesPerBit: Double, lockedInertia: Float = 0.70, searchingInertia: Float = 0.58) {
        precondition(samplesPerBit > 1)
        self.step = Int32(truncatingIfNeeded: Int64((4_294_967_296.0 / samplesPerBit).rounded()))
        self.lockedInertia = lockedInertia
        self.searchingInertia = searchingInertia
    }

    /// Advance one sample; true when this is the instant to sample the bit.
    mutating func advance() -> Bool {
        let previous = phase
        phase = previous &+ step
        return previous >= 0 && phase < 0
    }

    /// The input level changed on this sample.
    mutating func transition(dataDetected: Bool) {
        let error = abs(Float(phase)) / 2_147_483_648.0   // 0 = on time, 1 = half a bit off
        jitterBits = jitterBits * 0.9 + (error / 2) * 0.1
        transitions += 1
        let inertia = dataDetected ? lockedInertia : searchingInertia
        phase = Int32(Float(phase) * inertia)
    }

    /// Transitions are landing close enough to the bit boundary to trust.
    var isLocked: Bool { transitions >= 8 && jitterBits < 0.15 }

    mutating func reset() {
        phase = 0
        jitterBits = 0.5
        transitions = 0
    }
}
