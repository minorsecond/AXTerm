import Foundation

/// Writes the audio the demodulator is given to a WAV file.
///
/// When the modem hears nothing there are two very different explanations —
/// the signal never arrived, or it arrived and could not be read — and from
/// inside the app they look identical. A recording separates them: feed it
/// back through `AFSKDemodulator` offline and either the tones are in it or
/// they are not. Bench work on 2026-09-19 spent an afternoon on radio settings
/// before anybody could answer that question.
///
/// This taps the samples handed to the demodulator, so it records what the DSP
/// actually sees — after the audio device, the channel selection and the
/// network stream, which is where the signal usually goes missing.
///
/// Off unless asked for:
///
///     defaults write com.rosswardrup.AXTerm modemCaptureRx -bool true
///
/// The header is rewritten on every flush, so the file is playable at any
/// moment without stopping the app — quitting, crashing or pulling the radio
/// all leave a valid WAV.
nonisolated final class ModemAudioCapture {

    static let defaultsKey = "modemCaptureRx"
    static let pathDefaultsKey = "modemCapturePath"
    /// A bound so a capture left switched on cannot fill the disk. An hour at
    /// 48 kHz is about 330 MB.
    ///
    /// Ten minutes until 2026-09-19, which was wrong in the way that matters:
    /// a bench session is mostly waiting, the limit was reached during the
    /// waiting, and the capture stopped silently before the transmission it
    /// had been switched on for. A limit that is hit in normal use is not a
    /// safety bound, it is a bug.
    static let defaultLimitSeconds: Double = 3600

    let url: URL
    private let sampleRate: Double
    private let limitFrames: Int
    private let handle: FileHandle
    private var pending: [Int16] = []
    private var written = 0
    private var closed = false

    /// Nil unless the capture default is set, so the engine pays nothing for
    /// this in normal use.
    static func makeIfEnabled(sampleRate: Double,
                              defaults: UserDefaults = AppEnvironment.defaults,
                              now: Date = Date()) -> ModemAudioCapture? {
        guard defaults.bool(forKey: defaultsKey) else { return nil }
        let directory = defaults.string(forKey: pathDefaultsKey).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("axterm-modem-capture")
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "rx-" + stamp.string(from: now).replacingOccurrences(of: ":", with: "") + ".wav"
        return try? ModemAudioCapture(directory: directory, name: name, sampleRate: sampleRate)
    }

    init(directory: URL, name: String, sampleRate: Double,
         limitSeconds: Double = defaultLimitSeconds) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent(name)
        self.sampleRate = sampleRate
        self.limitFrames = Int(limitSeconds * sampleRate)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(frames: 0, sampleRate: sampleRate))
    }

    /// Set once the limit stops the recording, so the caller can say so
    /// rather than leaving a file that just ends.
    private(set) var hitLimit = false

    /// Mono samples at the device rate, as the demodulator receives them.
    func append(_ block: [Float]) {
        guard !closed else { return }
        guard written + pending.count < limitFrames else {
            if !hitLimit { hitLimit = true; flush() }
            return
        }
        pending.reserveCapacity(pending.count + block.count)
        for sample in block {
            let clamped = max(-1, min(1, sample))
            pending.append(Int16(clamped * 32_767))
        }
        // A second at a time: often enough that the file is never far behind
        // the radio, rarely enough that the DSP thread is not writing on every
        // pass.
        if pending.count >= Int(sampleRate) { flush() }
    }

    /// Write what is buffered and repair the header so the file stands alone.
    func flush() {
        guard !closed, !pending.isEmpty else { return }
        var bytes = Data(capacity: pending.count * 2)
        for sample in pending { withUnsafeBytes(of: sample.littleEndian) { bytes.append(contentsOf: $0) } }
        written += pending.count
        pending.removeAll(keepingCapacity: true)
        try? handle.seekToEnd()
        try? handle.write(contentsOf: bytes)
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(frames: written, sampleRate: sampleRate))
    }

    func finish() {
        guard !closed else { return }
        flush()
        closed = true
        try? handle.close()
    }

    deinit { finish() }

    /// A plain 16-bit mono WAV header — 44 bytes, no extra chunks, because
    /// Direwolf's `atest` refuses the JUNK chunk `AVAudioFile` writes and this
    /// file exists to be handed to other people's tools.
    static func header(frames: Int, sampleRate: Double) -> Data {
        var data = Data(capacity: 44)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(frames * 2)
        let rate = UInt32(sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        return data
    }
}
