import Accelerate
import Foundation

/// How much of one tone is in the signal, sample by sample.
///
/// A free-running oscillator at the tone mixes the input down to baseband in
/// quadrature; lowpassing I and Q and summing their squares gives the tone's
/// power regardless of its phase. Two of these — one per tone — compared
/// against each other are the AFSK detector: no tuning, no AGC, and a tilt
/// in the audio path only shifts the comparison, which the slicers absorb.
///
/// The oscillator is a table, not a sine call. Its frequency never changes,
/// so cos(φ₀ + kΔ) for a chunk is cos φ₀·cos kΔ − sin φ₀·sin kΔ with the
/// two tables fixed and only φ₀ moving between chunks: two vector
/// multiply-adds per chunk and one sin/cos pair, instead of a scalar loop
/// writing every phase and a transcendental per sample. This ran as the
/// hottest code in the demodulator on an unoptimised build, and most of
/// that was eight arrays allocated per block per tone plus the phase loop,
/// not the arithmetic. Every buffer here is now kept and reused.
///
/// The tables cover one chunk of `chunk` samples and a block longer than
/// that is walked in chunks, the filters carrying their state across. Sizing
/// the tables to the block instead meant a test feeding a whole run at once
/// built a million-entry table per tone, per demodulator.
nonisolated struct QuadratureToneDetector: Sendable {

    let sampleRate: Double
    let toneHz: Double

    /// Oscillator phase at the start of the next block, radians.
    private var phase: Double = 0
    private let increment: Double
    private var iFilter: FIRFilter
    private var qFilter: FIRFilter

    /// Samples per chunk; the modem's blocks are smaller than this, so the
    /// app never takes the chunk loop more than once.
    static let chunk = 1024

    /// cos(k·Δ) and sin(k·Δ) for k in 0..<chunk.
    private let cosTable: [Float]
    private let sinTable: [Float]
    /// Per-chunk scratch.
    private var cosines: [Float]
    private var sines: [Float]
    private var mixedI: [Float]
    private var mixedQ: [Float]
    private var filteredI: [Float] = []
    private var filteredQ: [Float] = []

    init(sampleRate: Double, toneHz: Double, lowpassTaps: [Float]) {
        self.sampleRate = sampleRate
        self.toneHz = toneHz
        let increment = 2 * .pi * toneHz / sampleRate
        self.increment = increment
        self.iFilter = FIRFilter(taps: lowpassTaps)
        self.qFilter = FIRFilter(taps: lowpassTaps)
        cosTable = (0..<Self.chunk).map { Float(cos(Double($0) * increment)) }
        sinTable = (0..<Self.chunk).map { Float(sin(Double($0) * increment)) }
        cosines = [Float](repeating: 0, count: Self.chunk)
        sines = [Float](repeating: 0, count: Self.chunk)
        mixedI = [Float](repeating: 0, count: Self.chunk)
        mixedQ = [Float](repeating: 0, count: Self.chunk)
    }

    /// The tone's power (I² + Q²) for this block, delayed by the lowpass,
    /// written into `power` (grown if needed). Returns how many samples are
    /// valid; `power` may be longer than that from an earlier, bigger block.
    mutating func process(_ input: UnsafeBufferPointer<Float>, into power: inout [Float]) -> Int {
        guard input.count > 0, let base = input.baseAddress else { return 0 }
        var produced = 0
        var offset = 0
        while offset < input.count {
            let n = min(Self.chunk, input.count - offset)
            let chunkBase = base + offset

            // This chunk's oscillator by angle addition from the tables.
            var c0 = Float(cos(phase))
            var s0 = Float(sin(phase))
            var negS0 = -s0
            cosTable.withUnsafeBufferPointer { ct in
                sinTable.withUnsafeBufferPointer { st in
                    cosines.withUnsafeMutableBufferPointer { co in
                        // cos(φ₀+kΔ) = cos φ₀·cos kΔ + (−sin φ₀)·sin kΔ
                        vDSP_vsmsma(ct.baseAddress!, 1, &c0, st.baseAddress!, 1, &negS0,
                                    co.baseAddress!, 1, vDSP_Length(n))
                    }
                    sines.withUnsafeMutableBufferPointer { si in
                        // sin(φ₀+kΔ) = sin φ₀·cos kΔ + cos φ₀·sin kΔ
                        vDSP_vsmsma(ct.baseAddress!, 1, &s0, st.baseAddress!, 1, &c0,
                                    si.baseAddress!, 1, vDSP_Length(n))
                    }
                }
            }
            phase = (phase + Double(n) * increment).truncatingRemainder(dividingBy: 2 * .pi)

            // Mix to baseband in quadrature.
            cosines.withUnsafeBufferPointer { co in
                mixedI.withUnsafeMutableBufferPointer { mi in
                    vDSP_vmul(chunkBase, 1, co.baseAddress!, 1, mi.baseAddress!, 1, vDSP_Length(n))
                }
            }
            sines.withUnsafeBufferPointer { si in
                mixedQ.withUnsafeMutableBufferPointer { mq in
                    vDSP_vmul(chunkBase, 1, si.baseAddress!, 1, mq.baseAddress!, 1, vDSP_Length(n))
                }
            }

            let ni = mixedI.withUnsafeBufferPointer { mi in
                iFilter.process(UnsafeBufferPointer(rebasing: mi[0..<n]), into: &filteredI)
            }
            let nq = mixedQ.withUnsafeBufferPointer { mq in
                qFilter.process(UnsafeBufferPointer(rebasing: mq[0..<n]), into: &filteredQ)
            }
            let m = min(ni, nq)
            if m > 0 {
                if power.count < produced + m {
                    power.append(contentsOf: repeatElement(0, count: produced + m - power.count))
                }
                // I² + Q² in one pass.
                filteredI.withUnsafeBufferPointer { fi in
                    filteredQ.withUnsafeBufferPointer { fq in
                        power.withUnsafeMutableBufferPointer { p in
                            vDSP_vmma(fi.baseAddress!, 1, fi.baseAddress!, 1,
                                      fq.baseAddress!, 1, fq.baseAddress!, 1,
                                      p.baseAddress! + produced, 1, vDSP_Length(m))
                        }
                    }
                }
                produced += m
            }
            offset += n
        }
        return produced
    }

    /// Array in, array out, for callers that do not keep buffers.
    mutating func process(_ input: [Float]) -> [Float] {
        var out: [Float] = []
        let n = input.withUnsafeBufferPointer { process($0, into: &out) }
        if out.count > n { out.removeLast(out.count - n) }
        return out
    }

    mutating func reset() {
        phase = 0
        iFilter.reset()
        qFilter.reset()
    }
}
