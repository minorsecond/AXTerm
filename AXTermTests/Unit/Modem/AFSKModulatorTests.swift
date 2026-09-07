import XCTest
@testable import AXTerm

/// The transmitter's audio: exact timing, no clicks, tones where they belong.
final class AFSKModulatorTests: XCTestCase {

    private func bitCount(frames: [Data], txDelayMs: Int, txTailMs: Int, baud: Double) -> Int {
        var encoder = HDLCEncoder(baud: baud, txDelayMs: txDelayMs, txTailMs: txTailMs)
        for frame in frames { encoder.append(frame: frame) }
        var n = 0
        while encoder.nextBit() != nil { n += 1 }
        return n
    }

    func testSampleCountIsExactlyBitsTimesSamplesPerBitAt48k() {
        let frame = Data(repeating: 0x5A, count: 60)
        let bits = bitCount(frames: [frame], txDelayMs: 300, txTailMs: 100, baud: 1200)
        let audio = AFSKModulator.synthesize(frames: [frame], sampleRate: 48_000)
        XCTAssertEqual(audio.count, bits * 40)
    }

    func testFractionalSamplesPerBitDoNotDrift() {
        let frame = Data(repeating: 0xA5, count: 200)
        let bits = bitCount(frames: [frame], txDelayMs: 300, txTailMs: 100, baud: 1200)
        let audio = AFSKModulator.synthesize(frames: [frame], sampleRate: 44_100)
        // 36.75 samples per bit: the total is within one sample of exact.
        XCTAssertEqual(Double(audio.count), Double(bits) * 36.75, accuracy: 1.0)
    }

    func testPhaseIsContinuous() {
        let audio = AFSKModulator.synthesize(frames: [Data(repeating: 0x0F, count: 40)], sampleRate: 48_000, amplitude: 0.5)
        let maxStep = 0.5 * 2 * Float.pi * 2200 / 48_000 * 1.01
        for i in 1..<audio.count {
            XCTAssertLessThanOrEqual(abs(audio[i] - audio[i - 1]), maxStep, "sample \(i)")
        }
    }

    func testPreEmphasisNeverExceedsNinetyPercentOfFullScale() {
        let audio = AFSKModulator.synthesize(frames: [Data(repeating: 0x00, count: 40)], sampleRate: 48_000,
                                             amplitude: 0.5, spaceGainDB: 6)
        XCTAssertLessThanOrEqual(audio.map { abs($0) }.max() ?? 0, 0.9001)
        XCTAssertGreaterThan(audio.map { abs($0) }.max() ?? 0, 0.85, "still loud")
    }

    /// A held level is a pure tone: mark for the low level, space for the high.
    func testEachLevelIsItsTone() {
        func goertzel(_ audio: [Float], _ hz: Double) -> Double {
            let w = 2 * Double.pi * hz / 48_000
            let coeff = 2 * cos(w)
            var s1 = 0.0, s2 = 0.0
            for x in audio { let s = Double(x) + coeff * s1 - s2; s2 = s1; s1 = s }
            return (s1 * s1 + s2 * s2 - coeff * s1 * s2).squareRoot() / Double(audio.count)
        }
        for (level, tone, other) in [(false, 1200.0, 2200.0), (true, 2200.0, 1200.0)] {
            var modulator = AFSKModulator(sampleRate: 48_000, mode: ModemMode.afsk1200.parameters)
            var block = [Float](repeating: 0, count: 24_000)
            let n = modulator.render(into: &block, count: block.count) { level }
            XCTAssertEqual(n, block.count)
            // Skip the fade-in.
            let audio = Array(block[480..<n])
            XCTAssertGreaterThan(goertzel(audio, tone), goertzel(audio, other) * 50, "level \(level)")
            XCTAssertGreaterThan(goertzel(audio, tone), goertzel(audio, 1700) * 50)
        }
    }

    func testRenderReportsExhaustion() {
        var encoder = HDLCEncoder(baud: 1200, txDelayMs: 10, txTailMs: 10)
        encoder.append(frame: Data(repeating: 1, count: 15))
        var modulator = AFSKModulator(sampleRate: 48_000, mode: ModemMode.afsk1200.parameters)
        var block = [Float](repeating: 0, count: 100_000)
        let n = modulator.render(into: &block, count: block.count) { encoder.nextBit() }
        XCTAssertLessThan(n, block.count)
        XCTAssertTrue(modulator.isExhausted)
        XCTAssertEqual(modulator.render(into: &block, count: 10) { encoder.nextBit() }, 0)
    }
}
