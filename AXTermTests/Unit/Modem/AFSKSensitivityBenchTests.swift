#if os(macOS)
import XCTest
@testable import AXTerm

/// How weak a signal our demodulator can still read, and what the slicers buy.
///
/// Written to answer a measurement, not a hunch. Comparing K0EPI-7's own
/// reception against the APRS-IS feed on 2026-09-09 showed our station hearing
/// 14% of frames as original transmissions where every Direwolf-based igate on
/// the same channel averaged 73% — and three stations at 10, 15 and 17 km that
/// we only ever heard through a digipeater. The radio was ruled out: squelch
/// fully open, FM-D not narrow. That leaves the demodulator.
///
/// This bench generates AFSK with our own modulator, adds white noise at a
/// measured signal-to-noise ratio and a tilt between the two tones, and counts
/// what comes back. The same audio is written to `/tmp` as WAV so Direwolf's
/// `atest` can be run over it for a head-to-head — see `Docs/SoundModem.md`.
final class AFSKSensitivityBenchTests: XCTestCase {

    /// 16 kHz, which is what an IC-705 streams over its WLAN whatever rate is
    /// asked for, so the bench runs at the rate the operator's radio uses.
    static let sampleRate: Double = 16_000
    static let mode = ModemMode.afsk1200.parameters

    /// One frame's worth of AFSK, at `snrDB` in the tone bandwidth, with
    /// `twistDB` of tilt between mark and space.
    static func audio(frame: Data, snrDB: Double, twistDB: Double, seed: UInt64) -> [Float] {
        var encoder = HDLCEncoder(baud: mode.baud, txDelayMs: 300, txTailMs: 100)
        _ = encoder.append(frame: frame)
        var modulator = AFSKModulator(sampleRate: sampleRate, mode: mode,
                                      amplitude: 0.5, spaceGainDB: Float(twistDB))
        var out: [Float] = []
        var block = [Float](repeating: 0, count: 4096)
        while !modulator.isExhausted {
            let n = modulator.render(into: &block, count: 4096) { encoder.nextBit() }
            out.append(contentsOf: block[0..<n])
            if n == 0 { break }
        }
        // Signal power, then noise scaled to the requested ratio. A plain
        // deterministic generator so a failure is reproducible.
        var sum: Double = 0
        for s in out { sum += Double(s) * Double(s) }
        let signalPower = sum / Double(max(1, out.count))
        let noisePower = signalPower / pow(10, snrDB / 10)
        let sigma = Float(noisePower.squareRoot())
        var rng = SystemRandomNumberGenerator2(seed: seed)
        var noisy = [Float](repeating: 0, count: out.count + Int(sampleRate / 2))
        for i in noisy.indices {
            let signal = i < out.count ? out[i] : 0
            noisy[i] = signal + sigma * rng.nextGaussian()
        }
        return noisy
    }

    /// A small deterministic Gaussian source: the bench must be repeatable.
    struct SystemRandomNumberGenerator2 {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func nextGaussian() -> Float {
            // Box-Muller, one of the pair.
            let u1 = Double(next() >> 11) / Double(1 << 53)
            let u2 = Double(next() >> 11) / Double(1 << 53)
            return Float((-2 * Foundation.log(max(u1, 1e-12))).squareRoot()
                         * Foundation.cos(2 * .pi * u2))
        }
    }

    /// How many of `trials` frames decode, for one slicer configuration.
    static func decodeRate(twists: [Float], snrDB: Double, twistDB: Double,
                           detectorFilter: AFSKDemodulator.DetectorFilter? = nil,
                           trials: Int = 40, payloadLength: Int = 34) -> Int {
        var decoded = 0
        for trial in 0..<trials {
            let base = "TEST\(trial) DE K0EPI-7 SENSITIVITY BENCH "
            var text = ""
            while text.count < payloadLength { text += base }
            let payload = Data(text.prefix(payloadLength).utf8)
            let frame = AX25FrameBuilder.buildUI(
                from: AX25Address(call: "K0EPI", ssid: 7),
                to: AX25Address(call: "APZAXT", ssid: 0),
                via: DigiPath.from([]), pid: 0xF0, payload: payload,
                displayInfo: "").onRadio(RadioID(rawValue: "bench")).encodeAX25()
            let samples = audio(frame: frame, snrDB: snrDB, twistDB: twistDB,
                                seed: UInt64(trial) &+ 1)
            let demod = AFSKDemodulator(inputSampleRate: sampleRate, mode: mode,
                                        slicerTwistsDB: twists,
                                        detectorFilter: detectorFilter)
            var got = false
            demod.process(samples) { event in
                if case .frame = event { got = true }
            }
            if got { decoded += 1 }
        }
        return decoded
    }

    /// One buffer holding `count` frames separated by silence, so the very
    /// same audio can be fed to our demodulator and written out for Direwolf's
    /// `atest`. Comparing two decoders on two different noise realisations
    /// would measure the noise.
    static func run(count: Int, snrDB: Double, twistDB: Double) -> [Float] {
        var out: [Float] = []
        for trial in 0..<count {
            let payload = Data("TEST\(trial) DE K0EPI-7 SENSITIVITY BENCH".utf8)
            let frame = AX25FrameBuilder.buildUI(
                from: AX25Address(call: "K0EPI", ssid: 7),
                to: AX25Address(call: "APZAXT", ssid: 0),
                via: DigiPath.from([]), pid: 0xF0, payload: payload,
                displayInfo: "").onRadio(RadioID(rawValue: "bench")).encodeAX25()
            out.append(contentsOf: audio(frame: frame, snrDB: snrDB, twistDB: twistDB,
                                         seed: UInt64(trial) &+ 1))
        }
        return out
    }

    /// Emit the head-to-head material: raw 16-bit PCM per condition, plus our
    /// own score on the identical samples. `atest` reads the PCM (wrapped as
    /// WAV by the shell script) and its numbers go beside ours.
    ///
    /// Not a pass/fail test — a measurement, run on demand. Shelling out to
    /// another project's binary from the suite would be a test that breaks
    /// when somebody upgrades Homebrew.
    func testEmitHeadToHeadMaterial() {
        let dir = NSTemporaryDirectory()
        var ours = "condition,ours_of_40\n"
        for snr in [6.0, 8.0, 10.0, 12.0] {
            for twist in [0.0, 6.0] {
                let samples = Self.run(count: 40, snrDB: snr, twistDB: twist)
                let demod = AFSKDemodulator(inputSampleRate: Self.sampleRate, mode: Self.mode,
                                            slicerTwistsDB: ModemLinkConfig.slicerTwistsDB)
                var decoded = 0
                demod.process(samples) { if case .frame = $0 { decoded += 1 } }
                let name = String(format: "snr%02.0f_twist%02.0f", snr, twist)
                ours += "\(name),\(decoded)\n"

                var pcm = Data()
                for s in samples {
                    let v = Int16(max(-32767, min(32767, s * 20_000)))
                    pcm.append(UInt8(truncatingIfNeeded: v))
                    pcm.append(UInt8(truncatingIfNeeded: v >> 8))
                }
                try? pcm.write(to: URL(fileURLWithPath: dir + "bench_\(name).pcm"))
            }
        }
        FileManager.default.createFile(atPath: dir + "axterm_headtohead.csv",
                                       contents: Data(ours.utf8))
    }

    /// Which spread of slicers actually works at the hard end.
    ///
    /// At 6 dB SNR with 6 dB of twist the shipped spread decodes far fewer
    /// than Direwolf does on identical audio. The ±6 slicer should cancel 6 dB
    /// of twist exactly, so if a different spread helps it is not the twist
    /// that is being missed — a power detector in noise picks up a positive
    /// bias on *both* tones, which moves the best threshold away from the
    /// arithmetic answer.
    func testWriteTheSpreadSweep() {
        let spreads: [(String, [Float])] = [
            ("[0]", [0]),
            ("+-6 step3 (shipped)", [-6, -3, 0, 3, 6]),
            ("+-9 step3", [-9, -6, -3, 0, 3, 6, 9]),
            ("+-12 step3", [-12, -9, -6, -3, 0, 3, 6, 9, 12]),
            ("+-6 step1.5", [-6, -4.5, -3, -1.5, 0, 1.5, 3, 4.5, 6]),
            ("+-12 step1.5", stride(from: Float(-12), through: 12, by: 1.5).map { $0 }),
        ]
        var out = "spread, snr6/twist6, snr6/twist0, snr8/twist6, snr10/twist6  (of 40)\n"
        for (name, twists) in spreads {
            let a = Self.decodeRate(twists: twists, snrDB: 6, twistDB: 6)
            let b = Self.decodeRate(twists: twists, snrDB: 6, twistDB: 0)
            let c = Self.decodeRate(twists: twists, snrDB: 8, twistDB: 6)
            let d = Self.decodeRate(twists: twists, snrDB: 10, twistDB: 6)
            out += String(format: "%-22s %11d %11d %11d %12d\n",
                          (name as NSString).utf8String!, a, b, c, d)
        }
        FileManager.default.createFile(atPath: NSTemporaryDirectory() + "axterm_spread_sweep.txt",
                                       contents: Data(out.utf8))
    }

    /// Where the best single threshold actually sits, and what it scores.
    ///
    /// The comb exists because we do not know the audio path's tilt. If we
    /// could measure it — and owning the radio, we nearly can — the question
    /// is whether a correctly centred slicer beats a comb that merely brackets
    /// it. This says how much is on the table before any of it is built.
    func testWriteTheOptimumSweep() {
        var out = "single-slicer score at 6 dB SNR, 6 dB twist (of 40)\n"
        for twist in stride(from: Float(-9), through: 3, by: 0.75) {
            out += String(format: "  twist %+5.2f dB : %2d\n", twist,
                          Self.decodeRate(twists: [twist], snrDB: 6, twistDB: 6))
        }
        out += "\nfor comparison, combs at the same condition:\n"
        out += "  shipped 9 @1.5 : \(Self.decodeRate(twists: ModemLinkConfig.slicerTwistsDB, snrDB: 6, twistDB: 6))\n"
        out += "  Direwolf atest : 36\n"
        FileManager.default.createFile(atPath: NSTemporaryDirectory() + "axterm_optimum.txt",
                                       contents: Data(out.utf8))
    }

    /// Is the detector's integration window the remaining gap?
    ///
    /// The threshold is not: the best single slicer scores below the comb.
    /// The other constant in the chain is how long each tone detector
    /// averages — one window, fixed at 1.5 bits, where Direwolf runs several
    /// demodulator profiles at once.
    func testWriteTheIntegrationSweep() {
        var out = "integration sweep, shipped comb (of 40)\n"
        out += "bits   snr6/tw6  snr6/tw0  snr8/tw6  snr10/tw0\n"
        for bits in [0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0] {
            let a = Self.decodeRate(twists: ModemLinkConfig.slicerTwistsDB, snrDB: 6, twistDB: 6,
                                    detectorFilter: .integrator(bits: bits))
            let b = Self.decodeRate(twists: ModemLinkConfig.slicerTwistsDB, snrDB: 6, twistDB: 0,
                                    detectorFilter: .integrator(bits: bits))
            let c = Self.decodeRate(twists: ModemLinkConfig.slicerTwistsDB, snrDB: 8, twistDB: 6,
                                    detectorFilter: .integrator(bits: bits))
            let d = Self.decodeRate(twists: ModemLinkConfig.slicerTwistsDB, snrDB: 10, twistDB: 0,
                                    detectorFilter: .integrator(bits: bits))
            out += String(format: "%4.2f %9d %9d %9d %10d\n", bits, a, b, c, d)
        }
        FileManager.default.createFile(atPath: NSTemporaryDirectory() + "axterm_integration.txt",
                                       contents: Data(out.utf8))
    }

    /// Before adopting a long integration window, check what it costs.
    ///
    /// A longer window averages noise away and smears neighbouring bits into
    /// the decision. The hard, noisy condition likes long windows; the place
    /// they should hurt is a clean signal with a long frame, where
    /// inter-symbol interference accumulates and there is no noise to trade it
    /// against. If 2.5 bits wins there too, it is not an overfit.
    func testWriteTheIntegrationValidation() {
        var out = "validation: score of 40, shipped comb\n\n"
        out += "clean channel, growing payload (ISI, no noise to hide it)\n"
        out += "payload  sharp   1.5b   2.0b   2.5b   3.0b\n"
        for length in [16, 64, 200] {
            let row: [Int] = ([nil, .integrator(bits: 1.5), .integrator(bits: 2.0),
                               .integrator(bits: 2.5), .integrator(bits: 3.0)]
                              as [AFSKDemodulator.DetectorFilter?]).map { f in
                Self.decodeRate(twists: ModemLinkConfig.slicerTwistsDB, snrDB: 30, twistDB: 0,
                                detectorFilter: f ?? .sharpLowpass, trials: 20,
                                payloadLength: length)
            }
            out += String(format: "%7d %6d %6d %6d %6d %6d\n", length,
                          row[0], row[1], row[2], row[3], row[4])
        }
        out += "\nacross the noise/twist matrix\n"
        out += "snr twist  sharp   1.5b   2.0b   2.5b   3.0b\n"
        for snr in [6.0, 8.0, 12.0] {
            for twist in [0.0, 3.0, 6.0, -6.0] {
                let row: [Int] = ([nil, .integrator(bits: 1.5), .integrator(bits: 2.0),
                                   .integrator(bits: 2.5), .integrator(bits: 3.0)]
                                  as [AFSKDemodulator.DetectorFilter?]).map { f in
                    Self.decodeRate(twists: ModemLinkConfig.slicerTwistsDB, snrDB: snr,
                                    twistDB: twist, detectorFilter: f ?? .sharpLowpass)
                }
                out += String(format: "%3.0f %5.0f %6d %6d %6d %6d %6d\n", snr, twist,
                              row[0], row[1], row[2], row[3], row[4])
            }
        }
        FileManager.default.createFile(atPath: NSTemporaryDirectory() + "axterm_validation.txt",
                                       contents: Data(out.utf8))
    }

    /// One transmission must be delivered once, however many slicers read it.
    ///
    /// The deduplicator windows on a bit clock, and each slicer used to carry
    /// its own — a clock that only advances when *that* slicer's PLL does. A
    /// slicer that misses transitions falls behind, so over a long run the
    /// clocks drift apart, the same frame arrives outside the window and is
    /// delivered twice. Invisible with one slicer; with nine it means the app
    /// counting a packet, a position or an APRS message more than once.
    ///
    /// Caught by the bench scoring 45 out of 40.
    func testALongRunDeliversEachFrameExactlyOnce() {
        let samples = Self.run(count: 40, snrDB: 10, twistDB: 6)
        let demod = AFSKDemodulator(inputSampleRate: Self.sampleRate, mode: Self.mode,
                                    slicerTwistsDB: ModemLinkConfig.slicerTwistsDB)
        var decoded = 0
        demod.process(samples) { if case .frame = $0 { decoded += 1 } }
        XCTAssertLessThanOrEqual(decoded, 40,
                                 "\(decoded) deliveries for 40 transmissions: duplicates escaped")
        XCTAssertGreaterThan(decoded, 30, "and it must still be decoding: \(decoded)")
    }

    /// 300 baud must be unharmed. Its 200 Hz shift falls below its 300 bd bit
    /// rate, so no short window separates the tones — the reason it keeps the
    /// sharp filter while 1200 baud moves to an integrator. Asserted rather
    /// than assumed, because the two modes now differ deliberately.
    func testThreeHundredBaudKeepsTheSharpFilterAndStillDecodes() {
        XCTAssertEqual(ModemMode.afsk300.parameters.detectorFilter, .sharpLowpass)
        XCTAssertEqual(ModemMode.afsk1200.parameters.detectorFilter, .integrator(bits: 2.5))

        let mode = ModemMode.afsk300.parameters
        var encoder = HDLCEncoder(baud: mode.baud, txDelayMs: 500, txTailMs: 100)
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "K0EPI", ssid: 7), to: AX25Address(call: "APZAXT", ssid: 0),
            via: DigiPath.from([]), pid: 0xF0, payload: Data("300 BAUD".utf8),
            displayInfo: "").onRadio(RadioID(rawValue: "bench")).encodeAX25()
        _ = encoder.append(frame: frame)
        var modulator = AFSKModulator(sampleRate: Self.sampleRate, mode: mode, amplitude: 0.5)
        var audio: [Float] = []
        var block = [Float](repeating: 0, count: 4096)
        while !modulator.isExhausted {
            let n = modulator.render(into: &block, count: 4096) { encoder.nextBit() }
            if n == 0 { break }
            audio.append(contentsOf: block[0..<n])
        }
        let demod = AFSKDemodulator(inputSampleRate: Self.sampleRate, mode: mode,
                                    slicerTwistsDB: ModemLinkConfig.slicerTwistsDB)
        var decoded = 0
        demod.process(audio) { if case .frame = $0 { decoded += 1 } }
        XCTAssertEqual(decoded, 1, "300 baud stopped decoding")
    }

    /// The measurement itself, written where it can be read back. Assertion
    /// messages do not survive to xcodebuild's stdout, and the numbers are the
    /// point: they are what `Docs/SoundModem.md` quotes.
    func testWriteTheSensitivityTable() {
        let n = ModemLinkConfig.slicerTwistsDB.count
        var out = "snr  twist   1 slicer   \(n) slicers   (of 40)\n"
        for snr in [8.0, 10.0, 12.0, 14.0] {
            for twist in [0.0, 3.0, 6.0] {
                let one = Self.decodeRate(twists: [0], snrDB: snr, twistDB: twist)
                let five = Self.decodeRate(twists: ModemLinkConfig.slicerTwistsDB,
                                           snrDB: snr, twistDB: twist)
                out += String(format: "%4.0f %5.0f %9d %11d\n", snr, twist, one, five)
            }
        }
        let path = NSTemporaryDirectory() + "axterm_afsk_bench.txt"
        FileManager.default.createFile(atPath: path, contents: Data(out.utf8))
    }

    /// Sanity: a clean signal decodes every time, or the bench is measuring
    /// its own generator rather than the demodulator.
    func testACleanSignalAlwaysDecodes() {
        XCTAssertEqual(Self.decodeRate(twists: [0], snrDB: 40, twistDB: 0, trials: 10), 10)
    }

    /// The finding. A real receiver's audio is never flat — FM de-emphasis, a
    /// radio's data-jack response and the 705's WLAN codec all tilt the two
    /// tones relative to each other. One slicer at 0 dB assumes no tilt.
    func testSlicersRecoverFramesASingleSlicerLosesToTwist() {
        // At 6 dB SNR the tilt still bites hard. Higher up the detector's own
        // integration now carries most of it, which is why this asserts at the
        // hard end rather than the comfortable one.
        let single = Self.decodeRate(twists: [0], snrDB: 6, twistDB: 6)
        let several = Self.decodeRate(twists: ModemLinkConfig.slicerTwistsDB,
                                      snrDB: 6, twistDB: 6)
        XCTAssertGreaterThan(several, single + 8,
                             "slicers bought nothing: \(single) -> \(several) of 40")
    }

    /// And they must not cost anything when the path happens to be flat.
    func testSlicersDoNotHurtAFlatPath() {
        let single = Self.decodeRate(twists: [0], snrDB: 12, twistDB: 0)
        let several = Self.decodeRate(twists: [-6, -3, 0, 3, 6], snrDB: 12, twistDB: 0)
        XCTAssertGreaterThanOrEqual(several, single,
                                    "\(single) -> \(several) of 40 on a flat path")
    }

    /// What the operator's radio will actually run, once configured.
    func testTheShippedConfigurationUsesMoreThanOneSlicer() {
        var config = ModemLinkConfig()
        config.mode = .afsk1200
        XCTAssertGreaterThan(config.softModemConfiguration.slicerTwistsDB.count, 1,
                             "the live modem is running a single centre slicer")
    }
}
#endif
