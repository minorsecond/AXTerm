//
//  AFSKNoisePropertyTests.swift
//  AXTermTests
//
//  The sound modem end to end, modulator to demodulator, with random
//  frames, levels, twist and noise. Seeded properties:
//
//  - whatever the noise does, every frame the demodulator hands up is one
//    that was sent, byte for byte: a damaged frame is dropped, never
//    delivered as a different packet;
//  - on a clean channel (20 dB and up) every frame gets through, in order.
//
//  AXTERM_FUZZ_ITERATIONS, AXTERM_FUZZ_SEED and AXTERM_FUZZ_BASE work as in
//  the other property tests.
//

import XCTest
@testable import AXTerm

@MainActor
final class AFSKNoisePropertyTests: XCTestCase {

    func testNoFrameIsDeliveredDamagedAndCleanChannelsLoseNothing() {
        checkProperty("afsk.noise.integrity", cases: 60) { rng, violations in
            var dsp = SplitMix64(seed: rng.next())
            let frames = randomFrames(count: rng.int(in: 1...4), rng: &dsp, minLength: 20, maxLength: 160)
            let sampleRate = rng.pick([44_100.0, 48_000.0])
            let snr = Float(rng.double(in: 4...32))
            var audio = AFSKModulator.synthesize(frames: frames, sampleRate: sampleRate,
                                                 txDelayMs: rng.int(in: 30...300))
            audio = ModemChannel.scale(audio, dbfs: Float(rng.double(in: -30 ... -3)))
            if rng.chance(0.3) { audio = ModemChannel.tilt(audio, sampleRate: sampleRate) }
            audio = ModemChannel.addNoise(audio, snrDB: snr, sampleRate: sampleRate, rng: &dsp)

            let decoded = decodeAll(audio, sampleRate: sampleRate, twists: [-3, 0, 3])
            let sent = Set(frames)
            for frame in decoded where !sent.contains(frame) {
                violations.record(String(format: "a %d-byte frame nobody sent came out at %.1f dB", frame.count, snr))
            }
            if snr >= 20 {
                // Slicers may each deliver a frame; order of first sight is
                // what reaches the TNC layer after deduplication.
                var firstSeen: [Data] = []
                for frame in decoded where !firstSeen.contains(frame) { firstSeen.append(frame) }
                violations.check(firstSeen == frames,
                                 String(format: "%.1f dB: sent %d frames, got %d distinct", snr, frames.count, firstSeen.count))
            }
        }
    }
}
