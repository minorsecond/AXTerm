import XCTest
@testable import AXTerm

/// Counting transmissions from the way a carrier quiets an FM receiver's
/// hiss, on synthesized audio: open-squelch noise, and noise with stretches
/// where a carrier has pushed it down.
final class NoiseQuietingDetectorTests: XCTestCase {

    private let rate = 48_000.0

    /// A reproducible white-noise source (xorshift), so a failure repeats.
    private struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Double(state % 2_000_001) / 1_000_000 - 1)
        }
    }

    /// Audio described as (seconds, noise amplitude, add AFSK tones?).
    private func synthesize(_ segments: [(seconds: Double, noise: Float, tones: Bool)], seed: UInt64 = 7) -> [Float] {
        var noise = Noise(state: seed)
        var out: [Float] = []
        var t = 0
        for segment in segments {
            let n = Int(segment.seconds * rate)
            for _ in 0..<n {
                var s = segment.noise * noise.next()
                if segment.tones {
                    // A decoded-looking signal: both AFSK tones, loud, all below the band.
                    let time = Double(t) / rate
                    s += Float(0.3 * sin(2 * .pi * 1200 * time) + 0.3 * sin(2 * .pi * 2200 * time))
                }
                out.append(s)
                t += 1
            }
        }
        return out
    }

    /// Feed in 480-sample blocks, the size the modem engine uses.
    private func count(_ audio: [Float], detector: inout NoiseQuietingDetector) -> Int {
        var total = 0
        var i = 0
        while i < audio.count {
            let block = Array(audio[i..<min(i + 480, audio.count)])
            total += detector.process(block)
            i += 480
        }
        return total
    }

    private func count(_ audio: [Float]) -> Int {
        var d = NoiseQuietingDetector(sampleRate: rate)
        return count(audio, detector: &d)
    }

    func testTheFrameIsTheAnalysisFrame() {
        let d = NoiseQuietingDetector(sampleRate: 48_000)
        XCTAssertEqual(d.frameLength, 4096)
        XCTAssertEqual(d.minimumRun, 4, "4 frames of 85 ms is the first run of at least 0.3 s")
        XCTAssertTrue(d.isEnabled)
    }

    func testPlainNoiseHasNoCarriers() {
        XCTAssertEqual(count(synthesize([(20, 0.3, false)])), 0)
    }

    func testAQuietedStretchIsOneCarrier() {
        let audio = synthesize([(10, 0.3, false), (1.0, 0.03, true), (5, 0.3, false)])
        XCTAssertEqual(count(audio), 1)
    }

    func testThreeTransmissionsAreThreeCarriers() {
        let audio = synthesize([(10, 0.3, false),
                                (0.8, 0.03, true), (2, 0.3, false),
                                (0.6, 0.02, true), (3, 0.3, false),
                                (1.5, 0.03, false), (4, 0.3, false)])
        XCTAssertEqual(count(audio), 3)
    }

    /// Shorter than 0.3 s is a noise burst, not a transmission.
    func testAQuietingShorterThanAPacketIsNotCounted() {
        let audio = synthesize([(10, 0.3, false), (0.15, 0.03, false), (5, 0.3, false)])
        XCTAssertEqual(count(audio), 0)
    }

    /// Less than 6 dB of quieting is the noise wandering, not a carrier.
    func testAShallowDipIsNotCounted() {
        let audio = synthesize([(10, 0.3, false), (1.0, 0.22, false), (5, 0.3, false)])
        XCTAssertEqual(count(audio), 0)
    }

    /// A long transmission counts once, not once per 0.3 s.
    func testALongTransmissionCountsOnce() {
        let audio = synthesize([(10, 0.3, false), (4.0, 0.03, true), (5, 0.3, false)])
        XCTAssertEqual(count(audio), 1)
    }

    /// Nothing is judged before there is a noise floor to judge against.
    func testQuietingAtStartupIsNotCounted() {
        let audio = synthesize([(0.5, 0.3, false), (1.0, 0.03, false), (5, 0.3, false)])
        XCTAssertEqual(count(audio), 0)
    }

    /// A closed squelch plays silence: there is no hiss to quiet, and a
    /// packet arriving through it must not read as a carrier either way.
    func testSilenceHasNoCarriers() {
        let audio = synthesize([(10, 0, false), (1.0, 0, true), (5, 0, false)])
        XCTAssertEqual(count(audio), 0)
    }

    /// Our own transmission interrupts a run without counting it.
    func testAnInterruptEndsARunUncounted() {
        var d = NoiseQuietingDetector(sampleRate: rate)
        XCTAssertEqual(count(synthesize([(10, 0.3, false), (0.2, 0.03, false)]), detector: &d), 0)
        d.interrupt()
        XCTAssertEqual(count(synthesize([(0.2, 0.03, false), (3, 0.3, false)], seed: 11), detector: &d), 0,
                       "two 0.2 s halves across an interrupt are not one 0.4 s carrier")
        XCTAssertEqual(count(synthesize([(1.0, 0.03, false), (3, 0.3, false)], seed: 13), detector: &d), 1,
                       "the median survived the interrupt")
    }

    func testOtherSampleRates() {
        var d16 = NoiseQuietingDetector(sampleRate: 16_000)
        XCTAssertTrue(d16.isEnabled)
        let audio16 = stride(from: 0, to: 16 * 16_000, by: 1).map { _ in Float(0) }
        _ = count(audio16, detector: &d16)
        XCTAssertFalse(NoiseQuietingDetector(sampleRate: 8_000).isEnabled, "no room for a 3.5-6 kHz band")
        var d8 = NoiseQuietingDetector(sampleRate: 8_000)
        XCTAssertEqual(d8.process([Float](repeating: 0.5, count: 4800)), 0)
    }

    /// The carrier count reaches the modem's telemetry.
    func testTheEngineCountsCarriers() throws {
        let io = SyntheticModemIO()
        let engine = ModemEngine(configuration: SoftModemConfiguration(), audio: io, ptt: NoPTTController(),
                                 scheduling: .inline)
        try engine.start()
        defer { engine.stop() }
        let audio = synthesize([(10, 0.3, false), (1.0, 0.03, true), (3, 0.3, false)])
        var i = 0
        while i < audio.count {
            io.feed(Array(audio[i..<min(i + 480, audio.count)]))
            i += 480
        }
        XCTAssertEqual(engine.telemetrySnapshot().carriersHeard, 1)
    }
}
