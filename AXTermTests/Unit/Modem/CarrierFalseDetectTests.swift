#if os(macOS)
import XCTest
@testable import AXTerm

/// Does carrier detect clear on an empty channel?
///
/// The operator runs the IC-705 with its squelch fully open, which is correct
/// for packet: the modem, not the radio, decides what is a signal. That means
/// the demodulator is fed band noise continuously and carrier detect has to
/// tell noise from a transmission on its own. If it cannot, every transmission
/// waits out `maxChannelWaitSeconds` and is dropped — "channel busy" on a
/// channel nobody is using.
///
/// Measured, not argued: the audio here contains no signal at all, so any
/// carrier is by construction false.
final class CarrierFalseDetectTests: XCTestCase {

    nonisolated(unsafe) static var noiseSamples: [Float] = []
    nonisolated(unsafe) static var signalSamples: [Float] = []
    static func percentile(_ xs: [Float], _ q: Double) -> Float {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
    }

    private static let sampleRate: Double = 16_000
    private static let mode = ModemMode.afsk1200.parameters

    /// Band noise at a realistic open-squelch level, and nothing else.
    private static func noise(seconds: Double, seed: UInt64, amplitude: Float = 0.05) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return ModemChannel.gaussian(count: Int(seconds * sampleRate),
                                     sigma: amplitude, rng: &rng)
    }

    /// Run audio through the production demodulator + carrier detect and
    /// report what fraction of the time carrier reads as detected.
    private static func carrierDutyCycle(_ audio: [Float],
                                         twists: [Float]) -> (duty: Double, everClear: Bool) {
        let demod = AFSKDemodulator(inputSampleRate: sampleRate, mode: mode,
                                    slicerTwistsDB: twists)
        var carrier = DataCarrierDetect(holdSamples: Int(0.25 * sampleRate))
        var clock: Int64 = 0
        var detected = 0
        var blocks = 0
        var everClear = false
        var i = 0
        let blockSize = 256
        while i + blockSize <= audio.count {
            let block = Array(audio[i ..< i + blockSize])
            demod.process(block) { _ in }
            clock += Int64(blockSize)
            let on = carrier.update(discrimination: demod.toneDiscrimination,
                                    rmsDBFS: ModemTelemetry.dbfs(demod.rxRMS),
                                    squelchDBFS: -90, now: clock)
            if on { detected += 1 } else { everClear = true }
            blocks += 1
            i += blockSize
        }
        return (Double(detected) / Double(max(1, blocks)), everClear)
    }

    /// The headline: with the production nine-slicer comb, an empty channel
    /// must still read as clear often enough to transmit on.
    func testAnEmptyChannelReadsAsClear() throws {
        let audio = Self.noise(seconds: 12, seed: 99)
        let (duty, everClear) = Self.carrierDutyCycle(audio, twists: ModemLinkConfig.slicerTwistsDB)

        // Record the measurement where it can be read from outside the test
        // host; XCTest's own stdout does not survive xcodebuild.
        let report = """
        slicers=\(ModemLinkConfig.slicerTwistsDB.count) duty=\(String(format: "%.4f", duty)) everClear=\(everClear)
        """
        try? report.write(toFile: NSTemporaryDirectory() + "/carrier-duty.txt",
                          atomically: true, encoding: .utf8)

        XCTAssertTrue(everClear,
                      "carrier never cleared across 12 s of pure noise — every "
                      + "transmission would wait out the channel budget and drop")
        XCTAssertEqual(duty, 0, accuracy: 0.02,
                       "carrier detected for \(Int(duty * 100))% of an empty channel")
    }

    /// What separates a transmission from an empty channel, measured on both.
    func testToneDiscriminationSeparatesSignalFromNoise() throws {
        let demodNoise = AFSKDemodulator(inputSampleRate: Self.sampleRate, mode: Self.mode,
                                         slicerTwistsDB: ModemLinkConfig.slicerTwistsDB)
        var worstNoise: Float = 0
        let noise = Self.noise(seconds: 60, seed: 99)
        var i = 0
        Self.noiseSamples.removeAll()
        while i + 256 <= noise.count {
            demodNoise.process(Array(noise[i ..< i + 256])) { _ in }
            worstNoise = max(worstNoise, demodNoise.toneDiscrimination)
            Self.noiseSamples.append(demodNoise.toneDiscrimination)
            i += 256
        }

        // A real frame, at the worst signal-to-noise the bench still decodes.
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "K0EPI", ssid: 7),
            to: AX25Address(call: "APZAXT", ssid: 0),
            via: DigiPath.from([]), pid: 0xF0,
            payload: Data("CARRIER DETECT REFERENCE FRAME".utf8),
            displayInfo: "").encodeAX25()
        var best: [String: Float] = [:]
        for snr in [18.0, 12.0, 9.0, 6.0] {
            let audio = AFSKSensitivityBenchTests.audio(frame: frame, snrDB: snr,
                                                        twistDB: 0, seed: 7)
            let demod = AFSKDemodulator(inputSampleRate: Self.sampleRate, mode: Self.mode,
                                        slicerTwistsDB: ModemLinkConfig.slicerTwistsDB)
            var peak: Float = 0
            var j = 0
            while j + 256 <= audio.count {
                demod.process(Array(audio[j ..< j + 256])) { _ in }
                peak = max(peak, demod.toneDiscrimination)
                if snr == 6.0 { Self.signalSamples.append(demod.toneDiscrimination) }
                j += 256
            }
            best["snr\(Int(snr))"] = peak
        }
        let report = "noiseMax=\(worstNoise) " + best.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            + " noiseP999=\(Self.percentile(Self.noiseSamples, 0.999))"
            + " noiseMean=\(Self.noiseSamples.reduce(0, +) / Float(max(1, Self.noiseSamples.count)))"
            + " signalMedian=\(Self.percentile(Self.signalSamples, 0.5))"
        try? report.write(toFile: NSTemporaryDirectory() + "/tone-discrimination.txt",
                          atomically: true, encoding: .utf8)
        XCTAssertLessThan(worstNoise, DataCarrierDetect.discriminationThreshold,
                          "noise reached \(worstNoise), at or above the carrier threshold")
    }

    /// The other direction, which is what carrier detect is actually for: a
    /// station on the air must hold the channel busy for as long as it is
    /// transmitting, sync losses included. A detector that never fires is
    /// trivially free of false alarms and useless.
    func testARealTransmissionHoldsTheChannelBusy() {
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "K0EPI", ssid: 7),
            to: AX25Address(call: "APZAXT", ssid: 0),
            via: DigiPath.from([]), pid: 0xF0,
            payload: Data(String(repeating: "BUSY CHANNEL ", count: 12).utf8),
            displayInfo: "").encodeAX25()
        // 6 dB SNR: near the edge of what the bench decodes, so the signal is
        // not being made easy for it.
        let audio = AFSKSensitivityBenchTests.audio(frame: frame, snrDB: 6,
                                                     twistDB: 0, seed: 11)
        let (duty, _) = Self.carrierDutyCycle(audio, twists: ModemLinkConfig.slicerTwistsDB)
        // `audio` pads half a second of silence after the frame, and the
        // modulator's own preamble takes time to rise, so the whole run is
        // never busy; the transmission itself must be.
        XCTAssertGreaterThan(duty, 0.5,
                             "a station was transmitting and the channel read clear "
                             + "for \(Int((1 - duty) * 100))% of it")
    }

    /// The comparison that isolates the cause: one slicer versus the comb, on
    /// the identical audio.
    func testTheCombIsWhatFloodsCarrierDetect() {
        let audio = Self.noise(seconds: 12, seed: 99)
        let single = Self.carrierDutyCycle(audio, twists: [0]).duty
        let comb = Self.carrierDutyCycle(audio, twists: ModemLinkConfig.slicerTwistsDB).duty
        let report = "single=\(String(format: "%.4f", single)) comb=\(String(format: "%.4f", comb))"
        try? report.write(toFile: NSTemporaryDirectory() + "/carrier-comb.txt",
                          atomically: true, encoding: .utf8)
        XCTAssertEqual(comb, 0, accuracy: 0.02, "comb duty \(comb) vs single \(single)")
    }
}
#endif
