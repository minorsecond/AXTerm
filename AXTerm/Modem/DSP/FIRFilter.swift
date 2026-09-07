import Accelerate
import Foundation

/// A streaming FIR filter with optional decimation, on vDSP.
///
/// Blocks arrive one after another; the filter keeps the tail of the previous
/// block so the output is the same as filtering one continuous signal. With
/// `decimation > 1` only every D-th output sample is computed
/// (`vDSP_desamp`), and the decimation phase is carried across blocks.
///
/// Taps are designed symmetric (windowed sinc), so vDSP's correlation is the
/// convolution we want.
nonisolated struct FIRFilter: Sendable {

    let taps: [Float]
    let decimation: Int

    /// Unconsumed input: the last `taps.count - 1` (or more, waiting for the
    /// decimation phase) samples of what has been fed so far.
    private var buffer: [Float] = []

    init(taps: [Float], decimation: Int = 1) {
        precondition(!taps.isEmpty)
        self.taps = taps
        self.decimation = max(1, decimation)
        buffer.reserveCapacity(taps.count + 4096)
    }

    /// Filter (and decimate) one block. Returns the output samples this block
    /// made available — fewer than the input by the decimation factor, and
    /// fewer still while the filter fills.
    mutating func process(_ input: [Float]) -> [Float] {
        buffer.append(contentsOf: input)
        let n = taps.count
        guard buffer.count >= n else { return [] }
        let outCount = (buffer.count - n) / decimation + 1
        var out = [Float](repeating: 0, count: outCount)
        buffer.withUnsafeBufferPointer { inPtr in
            taps.withUnsafeBufferPointer { tapPtr in
                out.withUnsafeMutableBufferPointer { outPtr in
                    if decimation == 1 {
                        vDSP_conv(inPtr.baseAddress!, 1, tapPtr.baseAddress!, 1,
                                  outPtr.baseAddress!, 1, vDSP_Length(outCount), vDSP_Length(n))
                    } else {
                        vDSP_desamp(inPtr.baseAddress!, vDSP_Stride(decimation), tapPtr.baseAddress!,
                                    outPtr.baseAddress!, vDSP_Length(outCount), vDSP_Length(n))
                    }
                }
            }
        }
        buffer.removeFirst(outCount * decimation)
        return out
    }

    mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    // MARK: - Design

    /// Odd tap count for a Hann-windowed sinc with the given transition width.
    static func tapCount(sampleRate: Double, transitionHz: Double) -> Int {
        let n = Int((3.3 * sampleRate / max(1, transitionHz)).rounded(.up))
        return n % 2 == 0 ? n + 1 : n
    }

    /// Windowed-sinc lowpass, unity gain at DC.
    static func lowPass(sampleRate: Double, cutoffHz: Double, transitionHz: Double) -> [Float] {
        let n = tapCount(sampleRate: sampleRate, transitionHz: transitionHz)
        return lowPass(sampleRate: sampleRate, cutoffHz: cutoffHz, taps: n)
    }

    static func lowPass(sampleRate: Double, cutoffHz: Double, taps n: Int) -> [Float] {
        let m = Double(n - 1) / 2
        let fc = cutoffHz / sampleRate
        var h = (0..<n).map { i -> Double in
            let x = Double(i) - m
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
            return sinc * window
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h.map(Float.init)
    }

    /// Windowed-sinc bandpass, unity gain at the band centre.
    static func bandPass(sampleRate: Double, lowHz: Double, highHz: Double, transitionHz: Double) -> [Float] {
        let n = tapCount(sampleRate: sampleRate, transitionHz: transitionHz)
        let high = lowPass(sampleRate: sampleRate, cutoffHz: highHz, taps: n).map(Double.init)
        let low = lowPass(sampleRate: sampleRate, cutoffHz: lowHz, taps: n).map(Double.init)
        var h = zip(high, low).map { $0 - $1 }
        // Normalise to the response at the band centre.
        let centre = (lowHz + highHz) / 2 / sampleRate
        var re = 0.0, im = 0.0
        for (i, v) in h.enumerated() {
            re += v * cos(2 * .pi * centre * Double(i))
            im -= v * sin(2 * .pi * centre * Double(i))
        }
        let gain = (re * re + im * im).squareRoot()
        if gain > 0 { h = h.map { $0 / gain } }
        return h.map(Float.init)
    }

    /// Frequency response magnitude at `hz`, for tests.
    static func magnitude(of taps: [Float], at hz: Double, sampleRate: Double) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * hz / sampleRate
        for (i, v) in taps.enumerated() {
            re += Double(v) * cos(w * Double(i))
            im -= Double(v) * sin(w * Double(i))
        }
        return (re * re + im * im).squareRoot()
    }
}
