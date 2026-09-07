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

    private struct Slicer {
        let twistGain: Float
        var pll: DigitalPLL
        var nrzi = NRZIDecoder()
        var hdlc: HDLCDecoder
        var lastLevel = false
        var bitClock: Int64 = 0
    }
    private var slicers: [Slicer]
    private var dedup = FrameDeduplicator()

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
    var pllJitterBits: [Float] { slicers.map { $0.pll.jitterBits } }

    init(inputSampleRate: Double, mode: ModemMode.Parameters, slicerTwistsDB: [Float] = [0],
         limits: HDLCDecoder.Limits = HDLCDecoder.Limits()) {
        precondition(mode.markHz > 0 && mode.spaceHz > 0, "not an AFSK mode")
        self.inputSampleRate = inputSampleRate
        self.mode = mode
        let d = max(1, Int((inputSampleRate / mode.demodSampleRate).rounded()))
        self.decimation = d
        self.demodSampleRate = inputSampleRate / Double(d)
        self.slicerTwistsDB = slicerTwistsDB.isEmpty ? [0] : slicerTwistsDB

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
        if shift < mode.baud {
            lpf = FIRFilter.lowPass(sampleRate: demodSampleRate, cutoffHz: mode.baud * 0.45, transitionHz: shift * 0.3)
        } else {
            let integration = Int((1.5 * demodSampleRate / mode.baud).rounded())
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
    }

    /// Feed one block of input audio (mono, at `inputSampleRate`).
    func process(_ input: [Float], emit: (Event) -> Void) {
        guard !input.isEmpty else { return }
        var peak: Float = 0
        var rms: Float = 0
        vDSP_maxmgv(input, 1, &peak, vDSP_Length(input.count))
        vDSP_rmsqv(input, 1, &rms, vDSP_Length(input.count))
        rxPeak = peak
        rxRMS = rms

        let baseband: [Float]
        if var dec = decimator {
            baseband = dec.process(input)
            decimator = dec
        } else {
            baseband = input
        }
        let filtered = prefilter.process(baseband)
        guard !filtered.isEmpty else { return }
        let mark = markDetector.process(filtered)
        let space = spaceDetector.process(filtered)
        let n = min(mark.count, space.count)
        guard n > 0 else { return }

        for k in 0..<n {
            let m = mark[k], s = space[k]
            for index in slicers.indices {
                let g = slicers[index].twistGain
                let decision = (m - g * s) / (m + g * s + 1e-12)
                let level = decision > 0
                if level != slicers[index].lastLevel {
                    slicers[index].lastLevel = level
                    slicers[index].pll.transition(dataDetected: slicers[index].hdlc.activity != .idle)
                }
                guard slicers[index].pll.advance() else { continue }
                slicers[index].bitClock += 1
                let bit = slicers[index].nrzi.decode(level: level)
                switch slicers[index].hdlc.push(bit: bit) {
                case .frame(let data):
                    if dedup.shouldDeliver(data, slicer: index, atBit: slicers[index].bitClock) {
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
    }

    /// The slicer with no tilt hypothesis; its FCS errors are the honest count.
    private var centreSlicer: Int {
        slicerTwistsDB.firstIndex(of: 0) ?? 0
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
        dedup.reset()
    }
}
