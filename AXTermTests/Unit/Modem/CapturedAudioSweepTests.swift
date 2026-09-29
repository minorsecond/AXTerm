import XCTest
@testable import AXTerm

/// Sweep the 300 bd detector filter against a real recording.
///
/// The sharp lowpass is `3.3 / transitionHz` seconds long whatever the sample
/// rate, so at 60 Hz it spans 16.5 bit periods at 300 bd — every decision is
/// smeared across eight bits either side. That is a guess until it is measured
/// on a signal off the air, which is what this does.
///
///     TEST_RUNNER_AXTERM_CAPTURE_WAV=/path/to/rx.wav xcodebuild test \
///       -only-testing:AXTermTests/CapturedAudioSweepTests
final class CapturedAudioSweepTests: XCTestCase {

    func testSweepTheDetectorFilterAgainstACapture() throws {
        guard let path = ProcessInfo.processInfo.environment["AXTERM_CAPTURE_WAV"] else {
            throw XCTSkip("AXTERM_CAPTURE_WAV not set")
        }
        let (audio, rate) = try CapturedAudioDecodeTests.readWAV(URL(fileURLWithPath: path))
        let base = ModemMode.afsk300.parameters
        print("sweep on \(URL(fileURLWithPath: path).lastPathComponent) — "
            + "\(String(format: "%.0f", Double(audio.count)/rate)) s at \(Int(rate)) Hz")
        print("  transition   filter len   bit periods   frames   fcsErr   peak discrimination")
        for transition in [60.0, 100, 150, 200, 250, 300, 400, 600] {
            let p = ModemMode.Parameters(
                markHz: base.markHz, spaceHz: base.spaceHz, baud: base.baud,
                demodSampleRate: base.demodSampleRate, isTxCapable: base.isTxCapable,
                detectorFilter: .sharpLowpass(transitionHz: transition))
            let demod = AFSKDemodulator(inputSampleRate: rate, mode: p,
                                        slicerTwistsDB: ModemLinkConfig.slicerTwistsDB)
            var frames = 0, fcs = 0
            var best: Float = 0
            demod.process(audio) { event in
                switch event {
                case .frame: frames += 1
                case .fcsError: fcs += 1
                }
                best = max(best, demod.toneDiscrimination)
            }
            let ms = 3300.0 / transition
            print(String(format: "  %8.0f Hz %9.1f ms %11.1f %10d %8d %12.2f",
                         transition, ms, ms / (1000.0 / base.baud), frames, fcs, best))
        }
    }
}
