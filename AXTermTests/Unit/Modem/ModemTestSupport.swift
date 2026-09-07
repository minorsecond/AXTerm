import Foundation
@testable import AXTerm

/// Deterministic randomness for DSP tests: the same seed is the same noise.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A channel between modulator and demodulator: gain, DC, tilt, noise.
enum ModemChannel {

    /// Gaussian noise with the given standard deviation (Box–Muller).
    static func gaussian(count: Int, sigma: Float, rng: inout SplitMix64) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var i = 0
        while i < count {
            let u1 = max(Float.leastNonzeroMagnitude, Float(rng.next() >> 11) / Float(1 << 53))
            let u2 = Float(rng.next() >> 11) / Float(1 << 53)
            let r = (-2 * log(u1)).squareRoot()
            out[i] = r * cos(2 * .pi * u2) * sigma
            i += 1
            if i < count { out[i] = r * sin(2 * .pi * u2) * sigma; i += 1 }
        }
        return out
    }

    /// Add white noise so the signal-to-noise ratio, referenced to a 3 kHz
    /// noise bandwidth, is `snrDB`.
    static func addNoise(_ signal: [Float], snrDB: Float, sampleRate: Double, rng: inout SplitMix64) -> [Float] {
        var sum: Float = 0
        for s in signal { sum += s * s }
        let rms = (sum / Float(max(1, signal.count))).squareRoot()
        let noiseRMSInBand = rms / pow(10, snrDB / 20)
        // White noise spreads over fs/2; the in-band share is 3 kHz of it.
        let sigma = noiseRMSInBand * Float((sampleRate / 2 / 3000).squareRoot())
        let noise = gaussian(count: signal.count, sigma: sigma, rng: &rng)
        return zip(signal, noise).map { $0 + $1 }
    }

    static func scale(_ signal: [Float], dbfs: Float) -> [Float] {
        // Scale so the peak sits at `dbfs`.
        let peak = signal.map { abs($0) }.max() ?? 1
        let target = pow(10, dbfs / 20)
        let g = peak > 0 ? target / peak : 1
        return signal.map { $0 * g }
    }

    static func offset(_ signal: [Float], dc: Float) -> [Float] { signal.map { $0 + dc } }

    /// A one-pole highpass shelf approximating a −6 dB/octave de-emphasis
    /// tilt above `cornerHz` — what an FM radio's audio output can do to
    /// the two tones.
    static func tilt(_ signal: [Float], sampleRate: Double, cornerHz: Double = 500) -> [Float] {
        let rc = 1 / (2 * .pi * cornerHz)
        let dt = 1 / sampleRate
        let alpha = Float(rc / (rc + dt))
        var out = [Float](repeating: 0, count: signal.count)
        var previousIn: Float = 0, previousOut: Float = 0
        for (i, x) in signal.enumerated() {
            // Leaky integrator: rolls off 6 dB/octave above the corner.
            let y = alpha * previousOut + (1 - alpha) * x
            out[i] = y
            previousIn = x
            previousOut = y
        }
        _ = previousIn
        // Restore the level so the tilt, not the attenuation, is the test.
        return scale(out, dbfs: 20 * log10(signal.map { abs($0) }.max() ?? 1))
    }
}

/// Runs a demodulator over audio in modem-sized blocks and collects frames.
func decodeAll(_ audio: [Float], sampleRate: Double, mode: ModemMode = .afsk1200,
               twists: [Float] = [0], blockSize: Int = 480) -> [Data] {
    let demod = AFSKDemodulator(inputSampleRate: sampleRate, mode: mode.parameters, slicerTwistsDB: twists)
    var frames: [Data] = []
    var index = 0
    while index < audio.count {
        let end = min(index + blockSize, audio.count)
        demod.process(Array(audio[index..<end])) { event in
            if case .frame(let data, _) = event { frames.append(data) }
        }
        index = end
    }
    // Flush: a second of silence lets the filters drain the last frame.
    demod.process([Float](repeating: 0, count: Int(sampleRate))) { event in
        if case .frame(let data, _) = event { frames.append(data) }
    }
    return frames
}

/// Random AX.25-shaped payloads (addresses + control + text).
func randomFrames(count: Int, rng: inout SplitMix64, minLength: Int = 15, maxLength: Int = 200) -> [Data] {
    (0..<count).map { _ in
        let n = Int(rng.next() % UInt64(maxLength - minLength + 1)) + minLength
        return Data((0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
    }
}
