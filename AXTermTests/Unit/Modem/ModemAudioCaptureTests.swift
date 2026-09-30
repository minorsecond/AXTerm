import XCTest
@testable import AXTerm

/// A recording of what the demodulator was given.
///
/// The point of it is to answer a question the app cannot answer about itself:
/// when nothing decodes, did the signal arrive at all? That only works if the
/// file is readable by other tools and readable *while the app is still
/// running*, since the operator's instinct is to quit and go look.
final class ModemAudioCaptureTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func read(_ url: URL) throws -> (rate: Int, samples: [Int16]) {
        let d = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(d.count, 44, "no header")
        let rate = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian })
        let bytes = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self).littleEndian })
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(44 + bytes, d.count, "the declared data size does not match the file")
        var out: [Int16] = []
        for i in stride(from: 44, to: 44 + bytes, by: 2) {
            out.append(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: Int16.self).littleEndian })
        }
        return (rate, out)
    }

    /// The samples that went in are the samples that come out, at the rate the
    /// modem was running. A recording that quietly resamples would send us
    /// looking for tones at the wrong frequency.
    func testTheSamplesRoundTripAtTheModemSampleRate() throws {
        let capture = try ModemAudioCapture(directory: directory, name: "a.wav", sampleRate: 12_000)
        capture.append([0, 0.5, -0.5, 1, -1])
        capture.finish()
        let (rate, samples) = try read(capture.url)
        XCTAssertEqual(rate, 12_000)
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples[0], 0)
        XCTAssertLessThanOrEqual(abs(Int(samples[1]) - 16_383), 2, "\(samples[1])")
        XCTAssertEqual(samples[3], 32_767)
        XCTAssertEqual(samples[4], -32_767)
    }

    /// Anything beyond full scale is clamped rather than wrapped. A wrapped
    /// sample turns a loud signal into a square wave and would have us
    /// diagnosing distortion the radio never produced.
    func testOverfullScaleIsClampedNotWrapped() throws {
        let capture = try ModemAudioCapture(directory: directory, name: "b.wav", sampleRate: 8_000)
        capture.append([4, -4])
        capture.finish()
        let (_, samples) = try read(capture.url)
        XCTAssertEqual(samples, [32_767, -32_767])
    }

    /// The one that matters in the field: the operator records, then quits the
    /// app or pulls the radio. The header is rewritten on every flush, so the
    /// file already stands on its own without a clean stop.
    func testTheFileIsValidBeforeItIsFinished() throws {
        let capture = try ModemAudioCapture(directory: directory, name: "c.wav", sampleRate: 1_000)
        capture.append([Float](repeating: 0.25, count: 1_000))   // one second: flushes
        let (rate, samples) = try read(capture.url)               // never finished
        XCTAssertEqual(rate, 1_000)
        XCTAssertEqual(samples.count, 1_000, "a mid-capture file must declare what it holds")
        capture.finish()
    }

    /// A capture left switched on must not fill the disk.
    func testItStopsAtTheLimit() throws {
        let capture = try ModemAudioCapture(directory: directory, name: "d.wav",
                                            sampleRate: 100, limitSeconds: 1)
        for _ in 0..<10 { capture.append([Float](repeating: 0.1, count: 100)) }
        capture.finish()
        let (_, samples) = try read(capture.url)
        XCTAssertLessThanOrEqual(samples.count, 200, "\(samples.count) samples past a 100-sample limit")
        XCTAssertTrue(capture.hitLimit, "a capture that stopped must say it stopped")
    }

    /// The default has to outlast a bench session. Ten minutes did not: it ran
    /// out during the waiting and the recording ended before the transmission
    /// it was switched on for.
    func testTheDefaultLimitOutlastsABenchSession() {
        XCTAssertGreaterThanOrEqual(ModemAudioCapture.defaultLimitSeconds, 1800)
    }

    /// Off unless asked for. The engine calls this on every start, and a modem
    /// that silently recorded every session would be a surprise on the disk
    /// and a surprise in the privacy sense.
    func testItIsOffUnlessTheDefaultIsSet() throws {
        let defaults = TestDefaults.make("capture-test")
        XCTAssertNil(ModemAudioCapture.makeIfEnabled(sampleRate: 48_000, defaults: defaults))
        defaults.set(true, forKey: ModemAudioCapture.defaultsKey)
        defaults.set(directory.path, forKey: ModemAudioCapture.pathDefaultsKey)
        let capture = try XCTUnwrap(ModemAudioCapture.makeIfEnabled(sampleRate: 48_000, defaults: defaults))
        capture.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.url.path))
    }
}
