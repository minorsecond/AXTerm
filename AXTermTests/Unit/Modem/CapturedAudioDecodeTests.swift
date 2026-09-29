import XCTest
@testable import AXTerm

/// Decode a recording made by `ModemAudioCapture` (or any 16-bit mono WAV),
/// at every mode, and print what each one found.
///
/// The question a capture exists to answer is "did the signal arrive, and in
/// what". Trying one mode cannot answer the second half: a station that is
/// really transmitting 1200 bd into an HF radio and a station transmitting
/// nothing look the same to a 300 bd demodulator. So try them all and print
/// the scores rather than asserting one.
///
///     TEST_RUNNER_AXTERM_CAPTURE_WAV=/path/to/rx.wav xcodebuild test \
///       -only-testing:AXTermTests/CapturedAudioDecodeTests
final class CapturedAudioDecodeTests: XCTestCase {

    func testDecodeACapturedFileAtEveryMode() throws {
        guard let path = ProcessInfo.processInfo.environment["AXTERM_CAPTURE_WAV"] else {
            throw XCTSkip("AXTERM_CAPTURE_WAV not set")
        }
        let url = URL(fileURLWithPath: path)
        let (audio, rate) = try Self.readWAV(url)
        let seconds = Double(audio.count) / rate
        let peak = audio.map { abs($0) }.max() ?? 0
        let rms = (audio.reduce(0) { $0 + Double($1 * $1) } / Double(max(audio.count, 1))).squareRoot()
        print("capture: \(url.lastPathComponent) — \(Int(rate)) Hz, \(String(format: "%.1f", seconds)) s, "
            + "peak \(String(format: "%.1f", 20 * log10(Double(max(peak, 1e-9)))) ) dBFS, "
            + "rms \(String(format: "%.1f", 20 * log10(max(rms, 1e-9)))) dBFS")

        for mode in [ModemMode.afsk300, .afsk1200] {
            let demod = AFSKDemodulator(inputSampleRate: rate, mode: mode.parameters,
                                        slicerTwistsDB: ModemLinkConfig.slicerTwistsDB)
            var frames = 0, fcsErrors = 0
            var best: Float = 0
            demod.process(audio) { event in
                switch event {
                case .frame: frames += 1
                case .fcsError: fcsErrors += 1
                }
                best = max(best, demod.toneDiscrimination)
            }
            print("  \(mode.rawValue): \(frames) frames, \(fcsErrors) failed checksum, "
                + "peak tone discrimination \(String(format: "%.2f", best)) "
                + "(carrier needs \(DataCarrierDetect.discriminationThreshold))")
        }
    }

    /// A plain 16-bit mono WAV, as `ModemAudioCapture` writes and as
    /// Direwolf's tools read.
    static func readWAV(_ url: URL) throws -> ([Float], Double) {
        let d = try Data(contentsOf: url)
        guard d.count >= 44 else { throw XCTSkip("not a WAV: \(url.path)") }
        let rate = Double(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian })
        let bytes = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian })
        let count = min(bytes, d.count - 44) / 2
        var out = [Float](); out.reserveCapacity(count)
        for i in 0..<count {
            let s = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 44 + i * 2, as: Int16.self).littleEndian }
            out.append(Float(s) / 32_768)
        }
        return (out, rate)
    }
}
