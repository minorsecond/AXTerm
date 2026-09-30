import Foundation

/// Counts transmissions on the channel from the way a carrier quiets an FM
/// receiver's noise, whether or not the demodulator can read them.
///
/// With the squelch open, an FM receiver with no signal plays loud,
/// wideband hiss. A carrier captures the discriminator and the hiss drops,
/// most visibly above the voice band where the transmitted audio has little
/// energy of its own: AFSK sits at 1200 and 2200 Hz, so 3.5 to 6 kHz is
/// nearly all receiver noise. A stretch where that band falls well below
/// its usual level is somebody transmitting.
///
/// This exists for the 2026-09-30 failure. An IC-705 with its notch on by
/// accident decoded about one APRS frame a minute on a busy 144.390, and
/// every other sign said the station was fine: audio level in range, carrier
/// detect firing now and then, frames arriving. What gave it away was the
/// mismatch between how much the receiver was hearing and how little the
/// modem decoded. The offline analysis of that audio found the transmissions
/// by exactly this measurement, and the constants here are the ones it used.
///
/// The modem's own carrier detect cannot stand in for this: it is judged
/// from the tones, and the tones are what a notch or a filter removes.
///
/// Cheap by design, since it runs on the DSP thread: five biquads and a sum
/// of squares per sample, and a sort of a hundred-odd numbers every 85 ms.
nonisolated struct NoiseQuietingDetector: Sendable {

    // From the offline analysis of the 2026-09-30 recording: 4096-sample
    // frames at 48 kHz, energy in 3.5-6 kHz, a carrier being that energy at
    // least 6 dB under its running median for at least 0.3 s.
    static let bandLowHz = 3500.0
    static let bandHighHz = 6000.0
    /// 4096 samples at 48 kHz, about 85 ms; scaled to other rates.
    static let frameSeconds = 4096.0 / 48_000
    static let quietingDB: Float = 6
    static let minimumCarrierSeconds = 0.3
    /// The running median's memory, about 11 s. Long enough that the packets
    /// on a busy APRS channel (under a second each, a few seconds apart) are
    /// a minority of it, so the median stays the noise floor.
    static let medianFrames = 128
    /// About 2 s of noise before anything is judged.
    static let minimumHistory = 24
    /// Below this the audio is silence (the radio's squelch closed, a muted
    /// input), which has no noise to quiet and must not count as a carrier.
    static let silenceDBFS: Float = -90

    /// False when the sample rate cannot carry the band (under about 13 kHz).
    let isEnabled: Bool
    let frameLength: Int
    let minimumRun: Int

    /// Four high-pass sections, 48 dB an octave. The analysis measured the
    /// band from an FFT, whose edges are sharp; a single section passes the
    /// 2200 Hz tone only 9 dB down, and on a loud signal that tone alone
    /// fills the band and hides the quieting it was meant to reveal. Four
    /// put it 35 dB down.
    private var hp1: Biquad, hp2: Biquad, hp3: Biquad, hp4: Biquad
    private var lowPass: Biquad
    private var sumOfSquares: Float = 0
    private var samplesInFrame = 0
    private var history: [Float] = []
    private var historyNext = 0
    private var run = 0
    private var runCounted = false
    /// Carriers counted since this detector was made.
    private(set) var carriers: UInt64 = 0

    init(sampleRate: Double) {
        let high = min(Self.bandHighHz, 0.45 * sampleRate)
        isEnabled = high > Self.bandLowHz + 500
        frameLength = max(1, Int((sampleRate * Self.frameSeconds).rounded()))
        let frameDuration = Double(frameLength) / max(sampleRate, 1)
        minimumRun = max(1, Int((Self.minimumCarrierSeconds / frameDuration).rounded(.up)))
        let highPass = Biquad.highPass(cutoff: Self.bandLowHz, sampleRate: sampleRate)
        (hp1, hp2, hp3, hp4) = (highPass, highPass, highPass, highPass)
        lowPass = Biquad.lowPass(cutoff: max(high, Self.bandLowHz + 1), sampleRate: sampleRate)
        history.reserveCapacity(Self.medianFrames)
    }

    /// Feed received audio. Returns how many carriers this block finished
    /// counting (almost always 0 or 1).
    mutating func process(_ block: [Float]) -> Int {
        guard isEnabled else { return 0 }
        var counted = 0
        for sample in block {
            let band = lowPass.run(hp4.run(hp3.run(hp2.run(hp1.run(sample)))))
            sumOfSquares += band * band
            samplesInFrame += 1
            if samplesInFrame == frameLength {
                if endFrame(energy: sumOfSquares / Float(frameLength)) { counted += 1 }
                sumOfSquares = 0
                samplesInFrame = 0
            }
        }
        return counted
    }

    /// Our own transmission, or anything else that makes the input not the
    /// channel: end a run without counting it, and drop the partial frame.
    /// The median is kept, since the channel's noise has not changed.
    mutating func interrupt() {
        run = 0
        runCounted = false
        sumOfSquares = 0
        samplesInFrame = 0
    }

    /// Judge one frame against the median of the frames before it, then add
    /// it. Returns true when this frame completes a carrier.
    private mutating func endFrame(energy: Float) -> Bool {
        let db = 10 * log10(max(energy, 1e-20))
        var completes = false
        if history.count >= Self.minimumHistory {
            let median = Self.median(history)
            let quiet = median > Self.silenceDBFS && db <= median - Self.quietingDB
            if quiet {
                run += 1
                if run >= minimumRun, !runCounted {
                    runCounted = true
                    carriers &+= 1
                    completes = true
                }
            } else {
                run = 0
                runCounted = false
            }
        }
        if history.count < Self.medianFrames {
            history.append(db)
        } else {
            history[historyNext] = db
            historyNext = (historyNext + 1) % Self.medianFrames
        }
        return completes
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// A second-order IIR section, transposed direct form II, with the Audio EQ
/// Cookbook's Butterworth coefficients (Q = 1/sqrt 2).
nonisolated struct Biquad: Sendable {
    private let b0, b1, b2, a1, a2: Float
    private var z1: Float = 0, z2: Float = 0

    private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }

    static func highPass(cutoff: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * cutoff / sampleRate, alpha = sin(w) / (2 * 0.5.squareRoot())
        let c = cos(w)
        return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func lowPass(cutoff: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * cutoff / sampleRate, alpha = sin(w) / (2 * 0.5.squareRoot())
        let c = cos(w)
        return Biquad(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
