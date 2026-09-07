import Foundation

/// NRZI line levels in, audio out.
///
/// Continuous-phase FSK: one phase accumulator, whose frequency switches
/// between the mark and space tones only at bit boundaries, so there are no
/// clicks and the spectrum stays where the radio's filters expect it. Bit
/// timing comes from a fractional sample-time accumulator, so 44.1 kHz
/// (36.75 samples per bit) stays exact over a long frame just as 48 kHz
/// (40) does.
nonisolated struct AFSKModulator: Sendable {

    let sampleRate: Double
    let mode: ModemMode.Parameters
    /// Peak amplitude of the mark tone, 0…1 of full scale.
    let amplitude: Float
    /// Space-tone gain relative to mark (pre-emphasis), clamped so the peak
    /// never exceeds 0.9 full scale.
    let spaceGain: Float

    /// Samples over which the first tone fades in, to spare the radio a click.
    static let fadeInSeconds = 0.002

    private var phase: Double = 0
    private var samplesIntoBit: Double
    private var currentIsSpace = false
    private var haveBit = false
    private var exhausted = false
    private var rendered: Int = 0

    init(sampleRate: Double, mode: ModemMode.Parameters, amplitude: Float = 0.5, spaceGainDB: Float = 0) {
        precondition(mode.isTxCapable, "this mode cannot transmit")
        self.sampleRate = sampleRate
        self.mode = mode
        let rawGain = Float(pow(10.0, Double(spaceGainDB) / 20))
        let peak = amplitude * max(1, rawGain)
        let scale: Float = peak > 0.9 ? 0.9 / peak : 1
        self.amplitude = amplitude * scale
        self.spaceGain = rawGain
        self.samplesIntoBit = sampleRate / mode.baud   // fetch the first bit immediately
    }

    var samplesPerBit: Double { sampleRate / mode.baud }
    /// True once the bit source ran dry and every sample of it has been rendered.
    var isExhausted: Bool { exhausted }

    /// Render up to `count` samples, pulling levels from `nextLevel` at bit
    /// boundaries. Returns how many were written — fewer than `count` only
    /// when the source is exhausted.
    mutating func render(into out: inout [Float], count: Int, nextLevel: () -> Bool?) -> Int {
        if out.count < count { out.append(contentsOf: repeatElement(0, count: count - out.count)) }
        var written = 0
        while written < count, !exhausted {
            if samplesIntoBit >= samplesPerBit {
                guard let level = nextLevel() else {
                    exhausted = true
                    haveBit = false
                    break
                }
                samplesIntoBit -= samplesPerBit
                currentIsSpace = level
                haveBit = true
            }
            guard haveBit else { exhausted = true; break }
            let frequency = currentIsSpace ? mode.spaceHz : mode.markHz
            phase += 2 * .pi * frequency / sampleRate
            if phase > 2 * .pi { phase -= 2 * .pi }
            var sample = Float(sin(phase)) * amplitude * (currentIsSpace ? spaceGain : 1)
            let fadeSamples = Self.fadeInSeconds * sampleRate
            if Double(rendered) < fadeSamples {
                let t = Double(rendered) / fadeSamples
                sample *= Float(0.5 - 0.5 * cos(.pi * t))
            }
            out[written] = sample
            written += 1
            rendered += 1
            samplesIntoBit += 1
        }
        return written
    }

    mutating func reset() {
        phase = 0
        samplesIntoBit = samplesPerBit
        currentIsSpace = false
        haveBit = false
        exhausted = false
        rendered = 0
    }

    /// One whole transmission as samples: preamble, frames, tail. For tests
    /// and for writing WAV files that an independent decoder can check.
    static func synthesize(frames: [Data], sampleRate: Double, mode: ModemMode = .afsk1200,
                           txDelayMs: Int = 300, txTailMs: Int = 100,
                           amplitude: Float = 0.5, spaceGainDB: Float = 0) -> [Float] {
        var encoder = HDLCEncoder(baud: mode.baud, txDelayMs: txDelayMs, txTailMs: txTailMs)
        for frame in frames { encoder.append(frame: frame) }
        var modulator = AFSKModulator(sampleRate: sampleRate, mode: mode.parameters,
                                      amplitude: amplitude, spaceGainDB: spaceGainDB)
        var out: [Float] = []
        var block = [Float](repeating: 0, count: 4096)
        while true {
            let n = modulator.render(into: &block, count: block.count) { encoder.nextBit() }
            out.append(contentsOf: block[0..<n])
            if n < block.count { break }
        }
        return out
    }
}
