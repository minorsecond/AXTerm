import Accelerate
import Foundation

/// Audio in, AX.25 frames out, for the two AFSK modes.
///
/// The chain: decimate to the mode's demodulation rate → bandpass around the
/// two tones → measure each tone's power with a quadrature detector →
/// compare them → one or more slicers, each a hypothesis about the audio
/// path's tilt, each with its own bit clock, NRZI and HDLC decoder → one
/// deduplicator so a frame several slicers agree on is one frame.
///
/// Level-independent by construction (the decision is a ratio of powers),
/// so there is no AGC; a signal from −40 dBFS up to clipping decodes the same.
nonisolated final class AFSKDemodulator {

    enum Event: Equatable, Sendable {
        case frame(Data, slicer: Int)
        case fcsError(slicer: Int)
    }

    let inputSampleRate: Double
    let mode: ModemMode.Parameters
    let decimation: Int
    let demodSampleRate: Double
    let slicerTwistsDB: [Float]

    private var decimator: FIRFilter?
    private var prefilter: FIRFilter
    private var markDetector: QuadratureToneDetector
    private var spaceDetector: QuadratureToneDetector

    /// Per-block scratch, grown on demand and reused. The chain used to
    /// allocate every stage's output on every block.
    private var baseband: [Float] = []
    private var filtered: [Float] = []
    private var mark: [Float] = []
    private var space: [Float] = []

    private struct Slicer {
        let twistGain: Float
        var pll: DigitalPLL
        var nrzi = NRZIDecoder()
        var hdlc: HDLCDecoder
        var lastLevel = false
    }

    /// Detector output samples seen since the demodulator started.
    ///
    /// The deduplicator's window has to be measured on a clock every slicer
    /// shares. Each slicer used to carry its own bit clock, advanced only when
    /// *that* slicer's PLL advanced — so a slicer that missed transitions fell
    /// behind, the clocks drifted apart over a long run, and the same frame
    /// arriving from two slicers looked like two transmissions minutes apart.
    /// With one slicer nothing showed; with nine the app would count a packet,
    /// a position or a message more than once.
    private var sampleClock: Int64 = 0
    /// A sample clock reading in bit times, which is what the window is
    /// expressed in.
    private func bitClock(at samples: Int64) -> Int64 {
        Int64(Double(samples) * mode.baud / demodSampleRate)
    }
    private var slicers: [Slicer]
    private let discriminationAlpha: Float
    private var dedup = FrameDeduplicator()
    /// The slicer with no tilt hypothesis; its FCS errors are the honest count.
    private let centreSlicer: Int

    // Telemetry, read from the DSP thread that drives `process`.
    private(set) var framesDecoded: UInt64 = 0
    private(set) var fcsErrors: UInt64 = 0
    private(set) var duplicatesSuppressed: UInt64 = 0
    private(set) var framesPerSlicer: [UInt64]
    private(set) var lastDecodingSlicer: Int?
    private(set) var rxPeak: Float = 0
    private(set) var rxRMS: Float = 0

    /// Whether any slicer is hearing flags or data — the carrier detect input.
    var activity: HDLCDecoder.Activity {
        var best = HDLCDecoder.Activity.idle
        for slicer in slicers {
            switch slicer.hdlc.activity {
            case .inFrame: return .inFrame
            case .flags: best = .flags
            case .idle: break
            }
        }
        return best
    }
    var slicerLocked: [Bool] { slicers.map { $0.pll.isLocked } }

    /// How cleanly the two tones are separated, 0…1 — the carrier-detect input.
    ///
    /// The slicer's decision variable is already normalised: `(mark - space) /
    /// (mark + space)` swings to ±1 when one tone is present and sits near 0
    /// when the two powers are equal, which is what band noise looks like.
    /// Its smoothed magnitude is therefore signal presence, measured, and it
    /// is the only one of the demodulator's outputs that noise cannot fake:
    /// HDLC activity latches into `.inFrame` on the first random flag and a
    /// PLL will lock its phase to anything with transitions in it. Both were
    /// carrier-detect inputs, and on an open squelch both read as a busy
    /// channel essentially all of the time (measured: 90% for one slicer,
    /// 99.7% for the nine-slicer comb, on audio containing no signal at all).
    private(set) var toneDiscrimination: Float = 0
    var pllJitterBits: [Float] { slicers.map { $0.pll.jitterBits } }

    /// How each tone detector's power is smoothed before the comparison.
    enum DetectorFilter: Equatable, Sendable {
        /// A short boxcar over `bits` bit periods.
        case integrator(bits: Double)
        /// A sharp lowpass: passband to about half the baud, stopband before
        /// the shift. Needed when the beat between the two tones falls below
        /// the bit rate and a short window cannot separate them.
        case sharpLowpass
    }

    /// Which smoothing a mode wants — the mode says so itself.
    ///
    /// This used to be `shift < baud`, which is true for *both* AFSK modes
    /// (1000 < 1200 and 200 < 300), so the integrator branch beside it was
    /// unreachable and the comment describing 1200 baud as an integrator case
    /// described code that had never run. 1200 baud was decoding through a
    /// filter meant for 300.
    static func defaultFilter(for mode: ModemMode.Parameters) -> DetectorFilter {
        mode.detectorFilter
    }

    init(inputSampleRate: Double, mode: ModemMode.Parameters, slicerTwistsDB: [Float] = [0],
         detectorFilter: DetectorFilter? = nil,
         limits: HDLCDecoder.Limits = HDLCDecoder.Limits()) {
        precondition(mode.markHz > 0 && mode.spaceHz > 0, "not an AFSK mode")
        self.inputSampleRate = inputSampleRate
        self.mode = mode
        let d = max(1, Int((inputSampleRate / mode.demodSampleRate).rounded()))
        self.decimation = d
        self.demodSampleRate = inputSampleRate / Double(d)
        self.slicerTwistsDB = slicerTwistsDB.isEmpty ? [0] : slicerTwistsDB
        self.centreSlicer = self.slicerTwistsDB.firstIndex(of: 0) ?? 0

        if d > 1 {
            // Keep everything below the tones' upper sidebands, kill the rest
            // before decimation folds it back.
            let cutoff = min(4000, demodSampleRate / 2 * 0.85)
            decimator = FIRFilter(taps: FIRFilter.lowPass(sampleRate: inputSampleRate, cutoffHz: cutoff, transitionHz: 2000),
                                  decimation: d)
        }
        let low = min(mode.markHz, mode.spaceHz), high = max(mode.markHz, mode.spaceHz)
        let shift = high - low
        // Pass both tones plus a bit more than the modulation bandwidth;
        // narrower at 300 bd where the shift is only 200 Hz.
        let margin = mode.baud >= 1200 ? 200.0 : 300.0
        let transition = mode.baud >= 1200 ? 300.0 : 150.0
        prefilter = FIRFilter(taps: FIRFilter.bandPass(
            sampleRate: demodSampleRate, lowHz: max(100, low - margin), highHz: high + margin + (shift < 300 ? 0 : 0),
            transitionHz: transition))
        // Each detector mixes one tone to baseband; the other tone appears as
        // a beat at the shift frequency. At 1200 bd (1000 Hz beat, 1200 bd
        // data) a short integrator over a bit and a half is enough. At 300 bd
        // the 200 Hz beat lies *below* the bit rate, so it takes a sharp
        // lowpass — passband to about half the baud, stopband before the
        // shift — to keep the two tones apart.
        let lpf: [Float]
        switch detectorFilter ?? Self.defaultFilter(for: mode) {
        case .sharpLowpass:
            lpf = FIRFilter.lowPass(sampleRate: demodSampleRate, cutoffHz: mode.baud * 0.45, transitionHz: shift * 0.3)
        case .integrator(let bits):
            let integration = Int((bits * demodSampleRate / mode.baud).rounded())
            lpf = FIRFilter.lowPass(sampleRate: demodSampleRate, cutoffHz: mode.baud / 2, taps: integration | 1)
        }
        markDetector = QuadratureToneDetector(sampleRate: demodSampleRate, toneHz: mode.markHz, lowpassTaps: lpf)
        spaceDetector = QuadratureToneDetector(sampleRate: demodSampleRate, toneHz: mode.spaceHz, lowpassTaps: lpf)

        let samplesPerBit = demodSampleRate / mode.baud
        slicers = self.slicerTwistsDB.map { twist in
            Slicer(twistGain: Float(pow(10.0, Double(twist) / 10)),
                   pll: DigitalPLL(samplesPerBit: samplesPerBit),
                   hdlc: HDLCDecoder(limits: limits))
        }
        framesPerSlicer = Array(repeating: 0, count: slicers.count)
        // Averaged over ~24 bits. Long enough that band noise — whose
        // decision variable is very nearly uniform over ±1, so its mean is
        // 0.5 with a tail that a short average does not suppress — settles
        // well below a real signal's; short enough (20 ms at 1200 baud) to
        // rise inside the opening flags of a transmission, whose TXDELAY
        // preamble is hundreds of milliseconds.
        discriminationAlpha = Float(1 / (24 * samplesPerBit))
    }

    /// Feed one block of input audio (mono, at `inputSampleRate`).
    func process(_ input: [Float], emit: (Event) -> Void) {
        input.withUnsafeBufferPointer { process($0, emit: emit) }
    }

    func process(_ input: UnsafeBufferPointer<Float>, emit: (Event) -> Void) {
        guard let base = input.baseAddress, input.count > 0 else { return }
        var peak: Float = 0
        var rms: Float = 0
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(input.count))
        vDSP_rmsqv(base, 1, &rms, vDSP_Length(input.count))
        rxPeak = peak
        rxRMS = rms

        let nFiltered: Int
        if decimator != nil {
            guard let nb = decimator?.process(input, into: &baseband), nb > 0 else { return }
            nFiltered = baseband.withUnsafeBufferPointer { bb in
                prefilter.process(UnsafeBufferPointer(rebasing: bb[0..<nb]), into: &filtered)
            }
        } else {
            nFiltered = prefilter.process(input, into: &filtered)
        }
        guard nFiltered > 0 else { return }

        let n: Int = filtered.withUnsafeBufferPointer { f in
            let block = UnsafeBufferPointer(rebasing: f[0..<nFiltered])
            let nm = markDetector.process(block, into: &mark)
            let ns = spaceDetector.process(block, into: &space)
            return min(nm, ns)
        }
        guard n > 0 else { return }
        slice(n, emit: emit)
    }

    /// A slicer finishing something on a sample, held until every slicer
    /// has walked the block.
    private struct Completion {
        let sample: Int
        let slicer: Int
        let result: HDLCDecoder.Event
    }

    /// The bit decisions and everything downstream of them, for one block.
    ///
    /// Slicer-outer rather than sample-outer: each slicer walks the block
    /// with its state in a local, written back once, instead of nine array
    /// elements being reached into on every sample. The element is moved out
    /// for the walk and initialised back in, which keeps the HDLC decoder's
    /// byte buffer uniquely owned — a copy would share it and the first byte
    /// appended would copy the whole thing.
    ///
    /// What a slicer finishes is not acted on inside its walk. Completions
    /// are recorded with their sample, sorted by sample and slicer once the
    /// array is whole again, and only then run through the deduplicator,
    /// the counters and `emit`. That is the order the sample-outer loop
    /// produced, reproduced exactly, and the deduplicator depends on it: its
    /// window is measured in bit times, and a slicer that had already walked
    /// past the whole of a long block would have aged its own sightings out
    /// before the next slicer reported the same frames. Two tests feed a
    /// whole run in one block and caught precisely that.
    ///
    /// The level is the sign of `(mark − gain·space)·(mark + gain·space + ε)`,
    /// which is the sign of the old normalised quotient in every case that
    /// arises, for a multiply instead of nine divisions a sample. The
    /// quotient itself is still taken once per sample, untwisted, for tone
    /// discrimination, which needs the magnitude.
    private func slice(_ n: Int, emit: (Event) -> Void) {
        let baseClock = sampleClock
        sampleClock += Int64(n)
        var completions: [Completion] = []

        mark.withUnsafeBufferPointer { mp in
            space.withUnsafeBufferPointer { sp in
                let m = mp.baseAddress!, s = sp.baseAddress!

                // Signal presence, from the untwisted comparison: a real tone
                // pushes |decision| toward 1, equal powers leave it near 0.
                // `while` rather than `for k in 0..<n` in the two kernels
                // below: on an unoptimised build a range loop steps through
                // the Collection protocol witnesses on every iteration, and
                // a sample of the DSP thread showed those witnesses as its
                // top two self-time frames.
                var disc = toneDiscrimination
                let alpha = discriminationAlpha
                var k = 0
                while k < n {
                    let plain = (m[k] - s[k]) / (m[k] + s[k] + 1e-12)
                    disc += (abs(plain) - disc) * alpha
                    k += 1
                }
                toneDiscrimination = disc

                slicers.withUnsafeMutableBufferPointer { table in
                    guard let first = table.baseAddress else { return }
                    for index in 0..<table.count {
                        let slot = first + index
                        var slicer = slot.move()
                        let g = slicer.twistGain
                        var k = 0
                        while k < n {
                            defer { k += 1 }
                            let mk = m[k], gs = g * s[k]
                            let level = (mk - gs) * (mk + gs + 1e-12) > 0
                            if level != slicer.lastLevel {
                                slicer.lastLevel = level
                                slicer.pll.transition(dataDetected: slicer.hdlc.activity != .idle)
                            }
                            guard slicer.pll.advance() else { continue }
                            let bit = slicer.nrzi.decode(level: level)
                            let result = slicer.hdlc.push(bit: bit)
                            switch result {
                            case .frame, .fcsError:
                                completions.append(Completion(sample: k, slicer: index, result: result))
                            case .none, .flag, .abort, .tooLong:
                                break
                            }
                        }
                        slot.initialize(to: slicer)
                    }
                }
            }
        }

        completions.sort { ($0.sample, $0.slicer) < ($1.sample, $1.slicer) }
        for completion in completions {
            let index = completion.slicer
            switch completion.result {
            case .frame(let data):
                let atBit = bitClock(at: baseClock + Int64(completion.sample) + 1)
                if dedup.shouldDeliver(data, slicer: index, atBit: atBit) {
                    framesDecoded += 1
                    framesPerSlicer[index] += 1
                    lastDecodingSlicer = index
                    emit(.frame(data, slicer: index))
                } else {
                    duplicatesSuppressed += 1
                }
            case .fcsError:
                if index == centreSlicer { fcsErrors += 1 }
                emit(.fcsError(slicer: index))
            case .none, .flag, .abort, .tooLong:
                break
            }
        }
    }

    /// Forget everything about the current signal (after our own transmission).
    func reset() {
        decimator?.reset()
        prefilter.reset()
        markDetector.reset()
        spaceDetector.reset()
        for index in slicers.indices {
            slicers[index].pll.reset()
            slicers[index].nrzi.reset()
            slicers[index].hdlc.reset()
            slicers[index].lastLevel = false
        }
        toneDiscrimination = 0
        dedup.reset()
    }
}
