import AVFoundation
import XCTest
@testable import AXTerm

/// Interoperability with an independent implementation.
///
/// Direwolf's `gen_packets` wrote the small WAVs in `AXTermTests/Fixtures/
/// Modem` (each frame noisier than the last, by that tool's design); our
/// demodulator must get most of them back on every run. The other
/// direction — Direwolf's `atest` decoding our modulator — needs the rig's
/// Docker image: `TestRig/scripts/modem_xval.sh` runs this class, picks up
/// the WAVs it writes to the temporary directory, and feeds them to `atest`.
/// `AXTERM_MODEM_XVAL_DIR` may name a directory of extra `dw_*.wav` files
/// and receives our WAVs too.
final class ModemDirewolfCrossValidationTests: XCTestCase {

    private var extraDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["AXTERM_MODEM_XVAL_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Where our transmissions land for `atest`.
    static var outputDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("axterm-modem-xval", isDirectory: true)
    }

    static func ourFrames(count: Int) -> [Data] {
        (0..<count).map { i in
            AX25FrameBuilder.buildUI(from: AX25Address(call: "K0EPI", ssid: 7), to: AX25Address(call: "TEST", ssid: 0),
                                     via: DigiPath(), pid: 0xF0,
                                     payload: Data(String(format: "AXTerm soft modem test frame %03d, the quick brown fox jumps over the lazy dog", i).utf8),
                                     displayInfo: "").encodeAX25()
        }
    }

    // MARK: - Direwolf → AXTerm

    /// `gen_packets -r 12000 -B 1200 -n 5 -a 50`: five frames, each noisier
    /// than the last — steeply: Direwolf's own `atest` decodes 1 of the 5 on
    /// each of these files, and 1 of the 3 at 300 bd. Matching it is the
    /// floor; the printed count is the score.
    func testDecodesDirewolfBell202Fixture() throws {
        try assertDecodes(fixture: "dw_1200_clean_n5", mode: .afsk1200, expected: 5, atLeast: 1)
    }

    /// The same at a quiet 12 % amplitude: level must not matter.
    func testDecodesDirewolfQuietFixture() throws {
        try assertDecodes(fixture: "dw_1200_quiet_n5", mode: .afsk1200, expected: 5, atLeast: 1)
    }

    /// `gen_packets -r 12000 -B 300 -n 3 -a 50`: HF tones, 1600/1800 Hz.
    func testDecodesDirewolf300BaudFixture() throws {
        try assertDecodes(fixture: "dw_300_clean_n3", mode: .afsk300, expected: 3, atLeast: 1)
    }

    private func assertDecodes(fixture: String, mode: ModemMode, expected: Int, atLeast floor: Int) throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "wav"), "fixture \(fixture)")
        let (audio, rate) = try Self.readWAV(url)
        let decoded = Set(decodeAll(audio, sampleRate: rate, mode: mode, twists: [-6, -3, 0, 3, 6]))
        print("xval: \(fixture) at \(Int(rate)) Hz → \(decoded.count) of \(expected) frames")
        XCTAssertGreaterThanOrEqual(decoded.count, floor, fixture)
        // They are Direwolf's built-in test message, addressed WB2OSZ-15>TEST.
        for frame in decoded {
            XCTAssertEqual(Array(frame.prefix(6)),
                           Array(AX25Address(call: "TEST", ssid: 0).encodeForAX25(isLast: false).prefix(6)), "destination")
        }
    }

    /// Extra Direwolf WAVs the script generated at full size, when present.
    func testDecodesExtraDirewolfAudio() throws {
        guard let directory = extraDirectory else { throw XCTSkip("AXTERM_MODEM_XVAL_DIR not set") }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("dw_") && $0.pathExtension == "wav" }
        guard !files.isEmpty else { throw XCTSkip("no dw_*.wav in \(directory.path)") }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let (audio, rate) = try Self.readWAV(file)
            let mode: ModemMode = file.lastPathComponent.contains("300") ? .afsk300 : .afsk1200
            let decoded = Set(decodeAll(audio, sampleRate: rate, mode: mode, twists: [-6, -3, 0, 3, 6])).count
            print("xval: \(file.lastPathComponent) at \(Int(rate)) Hz → \(decoded) distinct frames")
            XCTAssertGreaterThan(decoded, 0, file.lastPathComponent)
        }
    }

    // MARK: - AXTerm → Direwolf

    func testWritesOurTransmissionsForATest() throws {
        var targets = [Self.outputDirectory]
        if let extraDirectory { targets.append(extraDirectory) }
        for directory in targets {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (mode, name) in [(ModemMode.afsk1200, "axterm_tx_1200.wav"), (.afsk300, "axterm_tx_300.wav")] {
                let audio = AFSKModulator.synthesize(frames: Self.ourFrames(count: 20), sampleRate: 48_000, mode: mode,
                                                     txDelayMs: 300, txTailMs: 100, amplitude: 0.5)
                try Self.writeWAV(audio, sampleRate: 48_000, to: directory.appendingPathComponent(name))
            }
            print("xval: wrote \(directory.path)")
        }
    }

    // MARK: - WAV

    /// A plain 16-bit mono WAV — 44-byte header, no extra chunks — because
    /// Direwolf's `atest` refuses the JUNK chunk AVAudioFile writes.
    static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                  // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2)
        append(UInt16(2)); append(UInt16(16))                 // block align, bits
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for s in samples {
            append(UInt16(bitPattern: Int16(max(-32767, min(32767, (s * 32767).rounded())))))
        }
        try data.write(to: url)
    }

    static func readWAV(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        var out: [Float] = []
        while true {
            let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
            try file.read(into: chunk)
            guard chunk.frameLength > 0 else { break }
            let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk.frameLength)!
            var error: NSError?
            var consumed = false
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return chunk
            }
            if let error { throw error }
            out.append(contentsOf: UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
            if chunk.frameLength < chunk.frameCapacity { break }
        }
        return (out, rate)
    }
}
