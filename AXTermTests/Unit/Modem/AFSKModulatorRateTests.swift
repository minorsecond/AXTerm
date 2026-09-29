//
//  AFSKModulatorRateTests.swift
//  AXTermTests
//
//  The modulator at the rates radios actually give us.
//
//  Every existing modulator test runs at 48 kHz, with one at 44.1 kHz. An
//  IC-705 streams its audio over WLAN at 16 kHz, and `LANModemAudioIO`
//  measures that and hands it to the DSP — so on that radio the transmitter
//  has been running at a rate nothing covered. The 16 kHz coverage that does
//  exist is all receive-side (carrier detect, the sensitivity bench).
//
//  At 1200 baud, 16 kHz is 13.333 samples per bit: the worst of the three for
//  fractional-bit accumulation, and the one with the fewest samples per cycle
//  of the 2200 Hz tone.
//

import XCTest
@testable import AXTerm

final class AFSKModulatorRateTests: XCTestCase {

    private static let rates: [Double] = [8_000, 16_000, 24_000, 44_100, 48_000]

    /// The rates `LANModemAudioIO.measureSampleRate` can snap to, plus the two
    /// sound-card rates. A transmitter that goes silent at one of them is a
    /// transmitter that goes silent on that radio.
    func testEveryRateProducesAudibleAudio() {
        let frame = Data(repeating: 0x5A, count: 32)
        for rate in Self.rates {
            let audio = AFSKModulator.synthesize(frames: [frame], sampleRate: rate, amplitude: 0.5)
            XCTAssertFalse(audio.isEmpty, "\(rate) Hz produced no samples")

            let peak = audio.reduce(0) { max($0, abs($1)) }
            let rms = (audio.reduce(0) { $0 + Double($1 * $1) } / Double(audio.count)).squareRoot()
            XCTAssertGreaterThan(peak, 0.4, "\(rate) Hz: peak is not near the requested amplitude")
            XCTAssertGreaterThan(rms, 0.2, "\(rate) Hz: audio is there but far too quiet")
        }
    }

    /// Round trip at each rate: what we transmit is what a receiver reads.
    func testEveryRateRoundTrips() {
        let frame = Data(repeating: 0x5A, count: 32)
        for rate in Self.rates {
            let audio = AFSKModulator.synthesize(frames: [frame], sampleRate: rate, amplitude: 0.5)
            XCTAssertEqual(decodeAll(audio, sampleRate: rate), [frame], "\(rate) Hz did not round trip")
        }
    }

    /// The streaming path the engine actually uses, rather than `synthesize`.
    func testTheStreamingModulatorIsAudibleAtSixteenKilohertz() {
        var encoder = HDLCEncoder(baud: 1200, txDelayMs: 300, txTailMs: 100)
        encoder.append(frame: Data(repeating: 0x5A, count: 32))
        var modulator = AFSKModulator(sampleRate: 16_000, mode: ModemMode.afsk1200.parameters,
                                      amplitude: 0.5)
        var block = [Float](repeating: 0, count: 64_000)
        let n = modulator.render(into: &block, count: block.count) { encoder.nextBit() }

        XCTAssertGreaterThan(n, 0, "nothing rendered")
        let audio = Array(block[0..<n])
        XCTAssertGreaterThan(audio.reduce(0) { max($0, abs($1)) }, 0.4)
        XCTAssertEqual(decodeAll(audio, sampleRate: 16_000), [Data(repeating: 0x5A, count: 32)])
    }

    /// Fractional samples per bit must not drift at 16 kHz either: 13.333 per
    /// bit accumulates a third of a sample every bit, and a modulator that
    /// truncates instead of carrying loses a bit period every three.
    func testBitTimingHoldsAtSixteenKilohertz() {
        var modulator = AFSKModulator(sampleRate: 16_000, mode: ModemMode.afsk1200.parameters)
        XCTAssertEqual(modulator.samplesPerBit, 16_000.0 / 1200.0, accuracy: 1e-9)

        var block = [Float](repeating: 0, count: 16_000)
        var bits = 0
        let n = modulator.render(into: &block, count: block.count) {
            bits += 1
            return bits <= 1200 ? (bits % 2 == 0) : nil
        }
        // 1200 bits at 16 kHz is exactly one second of audio.
        XCTAssertEqual(n, 16_000, "1200 bits should be 16000 samples, got \(n)")
    }
}
