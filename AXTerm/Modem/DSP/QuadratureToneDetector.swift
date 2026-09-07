import Accelerate
import Foundation

/// How much of one tone is in the signal, sample by sample.
///
/// A free-running oscillator at the tone mixes the input down to baseband in
/// quadrature; lowpassing I and Q and summing their squares gives the tone's
/// power regardless of its phase. Two of these — one per tone — compared
/// against each other are the AFSK detector: no tuning, no AGC, and a tilt
/// in the audio path only shifts the comparison, which the slicers absorb.
nonisolated struct QuadratureToneDetector: Sendable {

    let sampleRate: Double
    let toneHz: Double

    private var phase: Double = 0
    private let increment: Double
    private var iFilter: FIRFilter
    private var qFilter: FIRFilter

    init(sampleRate: Double, toneHz: Double, lowpassTaps: [Float]) {
        self.sampleRate = sampleRate
        self.toneHz = toneHz
        self.increment = 2 * .pi * toneHz / sampleRate
        self.iFilter = FIRFilter(taps: lowpassTaps)
        self.qFilter = FIRFilter(taps: lowpassTaps)
    }

    /// The tone's power (I² + Q²) for this block, delayed by the lowpass.
    mutating func process(_ input: [Float]) -> [Float] {
        let n = input.count
        guard n > 0 else { return [] }
        var phases = [Float](repeating: 0, count: n)
        for k in 0..<n {
            phases[k] = Float(phase)
            phase += increment
            if phase > 2 * .pi { phase -= 2 * .pi }
        }
        var cosines = [Float](repeating: 0, count: n)
        var sines = [Float](repeating: 0, count: n)
        var count = Int32(n)
        vvcosf(&cosines, phases, &count)
        vvsinf(&sines, phases, &count)
        var i = [Float](repeating: 0, count: n)
        var q = [Float](repeating: 0, count: n)
        vDSP_vmul(input, 1, cosines, 1, &i, 1, vDSP_Length(n))
        vDSP_vmul(input, 1, sines, 1, &q, 1, vDSP_Length(n))
        let iOut = iFilter.process(i)
        let qOut = qFilter.process(q)
        let m = min(iOut.count, qOut.count)
        guard m > 0 else { return [] }
        var i2 = [Float](repeating: 0, count: m)
        var q2 = [Float](repeating: 0, count: m)
        vDSP_vsq(iOut, 1, &i2, 1, vDSP_Length(m))
        vDSP_vsq(qOut, 1, &q2, 1, vDSP_Length(m))
        var power = [Float](repeating: 0, count: m)
        vDSP_vadd(i2, 1, q2, 1, &power, 1, vDSP_Length(m))
        return power
    }

    mutating func reset() {
        phase = 0
        iFilter.reset()
        qFilter.reset()
    }
}
