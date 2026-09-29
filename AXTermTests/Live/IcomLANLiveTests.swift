import Synchronization
import XCTest
@testable import AXTerm

/// Against a real radio on the LAN. Skipped unless the environment names
/// one: TEST_RUNNER_AXTERM_IC705_HOST, _USER, _PASSWORD. Receive only —
/// nothing here keys the transmitter.
final class IcomLANLiveTests: XCTestCase {

    private var host: String { ProcessInfo.processInfo.environment["AXTERM_IC705_HOST"] ?? "" }
    private var user: String { ProcessInfo.processInfo.environment["AXTERM_IC705_USER"] ?? "" }
    private var password: String { ProcessInfo.processInfo.environment["AXTERM_IC705_PASSWORD"] ?? "" }
    private var minutes: Double { Double(ProcessInfo.processInfo.environment["AXTERM_IC705_MINUTES"] ?? "") ?? 0 }

    private func requireRadio() throws {
        try XCTSkipIf(host.isEmpty || user.isEmpty || password.isEmpty, "no radio configured in the environment")
    }

    /// Progress to the trace file, so it survives whatever the test runner
    /// does with stdout and a crash.
    private func mark(_ s: String) {
        print("LIVE:", s)
        guard ProcessInfo.processInfo.environment["AXTERM_ICOMLAN_TRACE"] != nil else { return }
        let path = NSTemporaryDirectory() + "axterm_icomlan.trace"
        let line = "TEST: " + s + "\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
    }

    /// Log in, identify, read the dial, count ten seconds of audio.
    func testLoginIdentifyAndHearAudio() async throws {
        try requireRadio()
        mark("entered testLoginIdentifyAndHearAudio")
        let session = IcomLANSession(configuration: .init(host: host, username: user, password: password))
        let transport = LANCIVTransport(session: session)
        let client = CIVClient(transport: transport, requestTimeout: 1.0)

        let audioPackets = Atomic<Int>(0)
        let audioBytes = Atomic<Int>(0)
        let peak = Atomic<Int>(0)
        session.onAudio = { pcm in
            guard let pcm else { return }
            audioPackets.add(1, ordering: .relaxed)
            audioBytes.add(pcm.count, ordering: .relaxed)
            pcm.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                var m = 0
                var i = 0
                while i + 1 < p.count {
                    let v = Int(Int16(bitPattern: UInt16(p[i]) | UInt16(p[i + 1]) << 8))
                    m = max(m, abs(v)); i += 2
                }
                if m > peak.load(ordering: .relaxed) { peak.store(m, ordering: .relaxed) }
            }
        }

        let started = Date()
        mark("calling session.open()")
        do { try await session.open() }
        catch { mark("session.open() threw: \(error)"); throw error }
        mark("logged in after \(String(format: "%.2f", Date().timeIntervalSince(started))) s; radio '\(session.radioName)', device '\(session.deviceName)'")

        // The audio is the point: measure it first and definitively.
        try await Task.sleep(for: .seconds(10))
        let n = audioPackets.load(ordering: .relaxed)
        let b = audioBytes.load(ordering: .relaxed)
        let dbfs = 20 * log10(max(1, Double(peak.load(ordering: .relaxed))) / 32768)
        mark("audio in 10 s: \(n) packets, \(b) bytes (\(b / 2 / 10) samples/s), peak \(String(format: "%.1f", dbfs)) dBFS, lost \(session.audioPacketsLost), rtt \(String(format: "%.1f", session.roundTrip * 1000)) ms")
        XCTAssertGreaterThan(n, 100, "audio should be flowing")
        let rate = Double(b / 2) / 10
        mark("measured audio rate ~\(Int(rate)) samples/s")
        XCTAssertTrue([8_000.0, 16_000, 24_000, 48_000].contains { abs($0 - rate) < 3_000 },
                      "a standard audio rate, got \(Int(rate))")

        // CI-V is a bonus here; the radio floods scope data, so give it room.
        transport.open()
        for _ in 0..<100 where transport.state != .open { try await Task.sleep(for: .milliseconds(20)) }
        mark("CI-V transport state \(transport.state)")
        do {
            try? await client.setTransceive(false)   // quiet the bus first
            let address = try await client.identify()
            mark("CI-V identify -> \(CIVKnownRadios.describe(address))")
            let hz = try await client.readFrequency()
            let mode = try await client.readMode()
            var status = RigStatus(); status.frequencyHz = hz; status.mode = mode.mode; status.filter = mode.filter
            mark("dial \(status.frequencyLabel ?? "?") \(status.modeLabel ?? "?")")
        } catch {
            mark("CI-V read did not complete (non-fatal): \(error)")
        }
        transport.close()
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Sit on the channel and decode what comes: AXTERM_IC705_MINUTES long.
    func testDecodePacketsOffTheAir() async throws {
        try requireRadio()
        try XCTSkipIf(minutes <= 0, "set AXTERM_IC705_MINUTES to listen")
        var config = ModemLinkConfig()
        config.rigLink = .lan
        config.lanHost = host
        config.lanUsername = user
        config.lanPassword = password
        config.mode = .afsk1200
        config.pttMethod = .civ
        config.followsRadioFrequency = true
        let link = ModemRadioLink(config: config, audio: nil, scheduling: .dedicatedThread)

        nonisolated final class Collector: KISSLinkDelegate, @unchecked Sendable {
            let lock = NSLock()
            var frames: [Data] = []
            var states: [KISSLinkState] = []
            var errors: [String] = []
            var parser = KISSFrameParser()
            func linkDidReceive(_ data: Data) {
                lock.withLock {
                    for f in parser.feedFrames(data) { if case .ax25(let p) = f.output { frames.append(p) } }
                }
            }
            func linkDidChangeState(_ state: KISSLinkState) { lock.withLock { states.append(state) }; print("LIVE: link \(state)") }
            func linkDidError(_ message: String) { lock.withLock { errors.append(message) }; print("LIVE: error \(message)") }
        }
        let collector = Collector()
        link.delegate = collector
        link.onRigStatus = { s in print("LIVE: rig \(s.frequencyLabel ?? "?") \(s.modeLabel ?? "?")") }
        mark("opening modem link over Wi-Fi")
        link.open()
        for _ in 0..<400 where link.state == .connecting || link.state == .disconnected { try await Task.sleep(for: .milliseconds(50)) }
        mark("link state after open: \(link.state); errors: \(collector.errors.joined(separator: "; "))")
        XCTAssertEqual(link.state, .connected, collector.errors.joined(separator: "; "))
        print("LIVE: \(link.endpointDescription) up; listening \(minutes) min on \(link.rigStatus.frequencyLabel ?? "?")")

        let end = Date().addingTimeInterval(minutes * 60)
        var reported = 0
        while Date() < end {
            try await Task.sleep(for: .seconds(5))
            let t = link.modem.telemetry
            let frames = collector.lock.withLock { collector.frames }
            if frames.count > reported {
                for f in frames[reported...] {
                    let decoded = AX25.decodeFrame(ax25: f)
                    let line = decoded.map { d in
                        let via = d.via.isEmpty ? "" : " via " + d.via.map(\.display).joined(separator: ",")
                        return "\(d.from?.display ?? "?") > \(d.to?.display ?? "?")\(via): \(String(decoding: d.info.prefix(60), as: UTF8.self))"
                    } ?? "undecodable \(f.count) bytes"
                    mark("RX \(line)")
                }
                reported = frames.count
            }
            mark(String(format: "t+%.0fs peak %.0f dBFS rms %.0f dcd %@ decoded %d fcsErr %d overruns %d rate %.0f",
                        Date().timeIntervalSince(end) + minutes * 60,
                        t.rxPeakDBFS, t.rxRMSDBFS, t.dcd ? "Y" : "n", t.framesDecoded, t.fcsErrors, t.rxOverruns,
                        link.modem.telemetry.audioFormat?.sampleRate ?? 0))
        }
        let t = link.modem.telemetry
        mark("done — \(t.framesDecoded) frames decoded, \(t.fcsErrors) FCS failures, \(collector.frames.count) delivered, peak \(String(format: "%.0f", t.rxPeakDBFS)) dBFS")
        link.close()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(collector.errors.isEmpty, collector.errors.joined(separator: "; "))
    }
}
