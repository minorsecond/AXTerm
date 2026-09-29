import XCTest
@testable import AXTerm

/// Modulator → channel → demodulator. The channel is deterministic, so a
/// decode rate is a fact about the code, not the weather.
final class AFSKLoopbackTests: XCTestCase {

    private func successRate(frames: [Data], audio: [Float], sampleRate: Double,
                             mode: ModemMode = .afsk1200, twists: [Float] = [0]) -> Double {
        let decoded = decodeAll(audio, sampleRate: sampleRate, mode: mode, twists: twists)
        var remaining = frames
        var hits = 0
        for frame in decoded {
            if let i = remaining.firstIndex(of: frame) { remaining.remove(at: i); hits += 1 }
        }
        return Double(hits) / Double(frames.count)
    }

    // MARK: - Clean channel

    func testACleanChannelDecodesEveryFrameAtEveryCommonRate() {
        for sampleRate in [48_000.0, 44_100.0, 96_000.0] {
            var rng = SplitMix64(seed: 1)
            let frames = randomFrames(count: 40, rng: &rng)
            let audio = AFSKModulator.synthesize(frames: frames, sampleRate: sampleRate)
            XCTAssertEqual(successRate(frames: frames, audio: audio, sampleRate: sampleRate), 1.0, "at \(sampleRate) Hz")
        }
    }

    func testBackToBackFramesInOneTransmissionAllDecode() {
        var rng = SplitMix64(seed: 2)
        let frames = randomFrames(count: 200, rng: &rng, minLength: 15, maxLength: 300)
        let audio = AFSKModulator.synthesize(frames: frames, sampleRate: 48_000)
        XCTAssertEqual(successRate(frames: frames, audio: audio, sampleRate: 48_000), 1.0)
    }

    func testLevelDoesNotMatter() {
        var rng = SplitMix64(seed: 3)
        let frames = randomFrames(count: 30, rng: &rng)
        let audio = AFSKModulator.synthesize(frames: frames, sampleRate: 48_000)
        for dbfs: Float in [-1, -12, -30, -40] {
            let scaled = ModemChannel.scale(audio, dbfs: dbfs)
            XCTAssertEqual(successRate(frames: frames, audio: scaled, sampleRate: 48_000), 1.0, "\(dbfs) dBFS")
        }
    }

    func testDCOffsetDoesNotMatter() {
        var rng = SplitMix64(seed: 4)
        let frames = randomFrames(count: 30, rng: &rng)
        let audio = ModemChannel.scale(AFSKModulator.synthesize(frames: frames, sampleRate: 48_000), dbfs: -12)
        for dc: Float in [0.2, -0.2] {
            XCTAssertEqual(successRate(frames: frames, audio: ModemChannel.offset(audio, dc: dc), sampleRate: 48_000), 1.0)
        }
    }

    func testTheThreeHundredBaudModeRoundTrips() {
        var rng = SplitMix64(seed: 5)
        let frames = randomFrames(count: 20, rng: &rng, minLength: 15, maxLength: 80)
        let audio = AFSKModulator.synthesize(frames: frames, sampleRate: 48_000, mode: .afsk300)
        XCTAssertEqual(successRate(frames: frames, audio: audio, sampleRate: 48_000, mode: .afsk300), 1.0)
    }

    // MARK: - Impairments

    /// A radio's de-emphasis tilts the two tones several dB apart; the
    /// ratio decision tolerates it, and a twist slicer removes it.
    func testDeEmphasisTiltStillDecodes() {
        var rng = SplitMix64(seed: 6)
        let frames = randomFrames(count: 40, rng: &rng)
        let audio = ModemChannel.tilt(AFSKModulator.synthesize(frames: frames, sampleRate: 48_000), sampleRate: 48_000)
        XCTAssertGreaterThanOrEqual(successRate(frames: frames, audio: audio, sampleRate: 48_000), 0.9)
        XCTAssertGreaterThanOrEqual(successRate(frames: frames, audio: audio, sampleRate: 48_000, twists: [-6, -3, 0, 3, 6]), 0.99)
    }

    func testTwistedTransmitterStillDecodes() {
        var rng = SplitMix64(seed: 7)
        let frames = randomFrames(count: 40, rng: &rng)
        for twist: Float in [6, -6] {
            let audio = AFSKModulator.synthesize(frames: frames, sampleRate: 48_000, amplitude: 0.4, spaceGainDB: twist)
            XCTAssertGreaterThanOrEqual(successRate(frames: frames, audio: audio, sampleRate: 48_000), 0.9, "twist \(twist)")
            XCTAssertGreaterThanOrEqual(successRate(frames: frames, audio: audio, sampleRate: 48_000, twists: [-6, -3, 0, 3, 6]), 0.99, "twist \(twist)")
        }
    }

    /// Noise: the v1 targets. 15 dB is a clean VHF channel; 12 dB is a
    /// weak one; 8 dB is where half the frames should still get through.
    func testNoiseTargets() {
        var rng = SplitMix64(seed: 8)
        let frames = randomFrames(count: 100, rng: &rng, minLength: 40, maxLength: 120)
        let clean = ModemChannel.scale(AFSKModulator.synthesize(frames: frames, sampleRate: 48_000), dbfs: -6)
        var results: [Float: Double] = [:]
        for snr: Float in [20, 15, 12, 8] {
            var noiseRNG = SplitMix64(seed: UInt64(snr) * 977)
            let noisy = ModemChannel.addNoise(clean, snrDB: snr, sampleRate: 48_000, rng: &noiseRNG)
            results[snr] = successRate(frames: frames, audio: noisy, sampleRate: 48_000)
        }
        print("AFSK1200 loopback decode rates:", results.sorted { $0.key > $1.key }.map { "\($0.key) dB: \(Int($0.value * 100))%" }.joined(separator: ", "))
        XCTAssertEqual(results[20]!, 1.0)
        XCTAssertGreaterThanOrEqual(results[15]!, 0.98)
        XCTAssertGreaterThanOrEqual(results[12]!, 0.90)
        XCTAssertGreaterThanOrEqual(results[8]!, 0.4)
    }

    // MARK: - Counters

    func testTelemetryCountsFramesAndErrors() {
        var rng = SplitMix64(seed: 9)
        let frames = randomFrames(count: 10, rng: &rng)
        let audio = AFSKModulator.synthesize(frames: frames, sampleRate: 48_000)
        let demod = AFSKDemodulator(inputSampleRate: 48_000, mode: ModemMode.afsk1200.parameters, slicerTwistsDB: [-3, 0, 3])
        var events: [AFSKDemodulator.Event] = []
        demod.process(audio) { events.append($0) }
        XCTAssertGreaterThan(demod.rxPeak, 0.4, "the level meter saw the signal")
        demod.process([Float](repeating: 0, count: 48_000)) { events.append($0) }
        XCTAssertEqual(demod.rxPeak, 0, "and the silence after it")
        XCTAssertEqual(demod.framesDecoded, 10)
        XCTAssertEqual(demod.framesPerSlicer.reduce(0, +), 10, "each frame counted for one slicer only")
        XCTAssertGreaterThan(demod.duplicatesSuppressed, 0, "the other slicers heard them too")
        XCTAssertEqual(events.filter { if case .frame = $0 { return true } else { return false } }.count, 10)
    }
}
