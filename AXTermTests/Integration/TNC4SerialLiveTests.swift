//
//  TNC4SerialLiveTests.swift
//  AXTermTests
//
//  A real Mobilinkd TNC4 on USB, through the app's own KISSLinkSerial. All
//  receive-only: nothing here sends a data frame or a test tone. Skipped
//  unless asked for:
//
//      TEST_RUNNER_AXTERM_TNC4_USB=1 xcodebuild test -scheme AXTerm \
//        -only-testing:AXTermTests/TNC4SerialLiveTests
//
//  The device is the first /dev/cu.usbmodem*, or TEST_RUNNER_AXTERM_TNC4_PORT.
//

#if os(macOS)
import XCTest
@testable import AXTerm

nonisolated private final class SerialRecorder: KISSLinkDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var parser = KISSFrameParser()
    private var _frames: [Data] = []
    private var _states: [KISSLinkState] = []
    private var _errors: [String] = []

    func linkDidReceive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        for frame in parser.feedFrames(data) {
            switch frame.output {
            case .ax25(let payload): _frames.append(Data([frame.port << 4]) + payload)
            case .mobilinkdTelemetry(let hw): _frames.append(hw)
            case .unknown: break
            }
        }
    }
    func linkDidChangeState(_ state: KISSLinkState) { lock.lock(); _states.append(state); lock.unlock() }
    func linkDidError(_ message: String) { lock.lock(); _errors.append(message); lock.unlock() }

    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return _frames }
    var states: [KISSLinkState] { lock.lock(); defer { lock.unlock() }; return _states }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return _errors }
}

final class TNC4SerialLiveTests: XCTestCase {

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var notes: [String] = []

    private func note(_ line: String) {
        print(line)
        notes.append(line)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard env["AXTERM_TNC4_USB"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_AXTERM_TNC4_USB=1 to run against a TNC4 on USB")
        }
    }

    override func tearDown() {
        let attachment = XCTAttachment(string: notes.joined(separator: "\n"))
        attachment.name = "TNC4 USB log"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    // MARK: Tests

    /// The session over USB: the probe, the settings read, status, measuring,
    /// and decoding afterwards.
    func testSerialSessionAndControls() throws {
        let (link, recorder) = try open(MobilinkdConfig())
        defer { closeAndWait(link) }
        XCTAssertTrue(link.isMobilinkd, "the TNC4 did not answer the probe over USB")

        var mark = recorder.frames.count
        link.refreshMobilinkdStatus()
        _ = waitFor(seconds: 6) { self.report(recorder, after: mark).batteryMillivolts != nil
            && self.report(recorder, after: mark).pttMultiplex != nil }
        let status = report(recorder, after: mark)
        note("TNC4 USB status: \(status.hardwareVersion ?? "?") fw \(status.firmwareVersion ?? "?") "
            + "battery \(status.batteryMillivolts.map(String.init) ?? "?") mV gain in \(status.inputGain.map(String.init) ?? "?") "
            + "out \(status.outputGain.map(String.init) ?? "?") modems \(status.supportedModemTypes ?? [])")
        XCTAssertNotNil(status.firmwareVersion)
        XCTAssertNotNil(status.batteryMillivolts)

        _ = waitFor(seconds: 1) { false }
        mark = recorder.frames.count
        link.startMeasuringInput()
        _ = waitFor(seconds: 4) { false }
        link.stopMeasuringInput()
        let levels = recorder.frames.dropFirst(mark).compactMap(MobilinkdTNC.parseInputLevel)
        note("TNC4 USB: \(levels.count) level readings in 4 s; last vpp \(levels.last.map { String($0.vpp) } ?? "-")")
        XCTAssertGreaterThan(levels.count, 3)

        _ = waitFor(seconds: 1) { false }
        mark = recorder.frames.count
        let listen = Double(env["AXTERM_TNC4_LISTEN_SECONDS"] ?? "") ?? 60
        _ = waitFor(seconds: listen) { false }
        let packets = decoded(recorder, after: mark)
        note("TNC4 USB: \(packets.count) packets in \(Int(listen)) s after measuring")
        for p in packets.prefix(5) { note("  rx: \(p)") }
        XCTAssertGreaterThan(packets.count, 0)
    }

    /// Mobilinkd settings applied on connect, and the TNC4's own put back on close.
    func testSerialAppliesAndRestores() throws {
        var (link, recorder) = try open(MobilinkdConfig())
        let original = inputGain(link, recorder)
        note("TNC4 USB: input gain before \(original.map(String.init) ?? "?")")
        closeAndWait(link)
        guard let original else { return XCTFail("could not read the input gain") }

        let wanted = original == 0 ? 2 : 0
        (link, recorder) = try open(MobilinkdConfig(settings: MobilinkdSettings(inputGain: wanted)))
        let applied = inputGain(link, recorder)
        note("TNC4 USB: asked for \(wanted), TNC4 reports \(applied.map(String.init) ?? "?")")
        XCTAssertEqual(applied, wanted)
        closeAndWait(link)

        (link, recorder) = try open(MobilinkdConfig())
        let restored = inputGain(link, recorder)
        note("TNC4 USB: after closing \(restored.map(String.init) ?? "?") (was \(original))")
        XCTAssertEqual(restored, original)
        closeAndWait(link)
    }

    /// TEST_RUNNER_AXTERM_TNC4_MINUTES of decoding (default 5), through the
    /// link's battery polls.
    func testSerialLongReceive() throws {
        let minutes = Int(env["AXTERM_TNC4_MINUTES"] ?? "") ?? 5
        let (link, recorder) = try open(MobilinkdConfig())
        defer { closeAndWait(link) }
        var perMinute: [Int] = []
        for _ in 0..<minutes {
            let mark = recorder.frames.count
            _ = waitFor(seconds: 60) { false }
            perMinute.append(decoded(recorder, after: mark).count)
            if link.state != .connected { break }
        }
        note("TNC4 USB long receive: per minute \(perMinute), total \(perMinute.reduce(0, +)); "
            + "battery \(recorder.frames.compactMap(MobilinkdTNC.parseBatteryLevel)); still \(link.state.rawValue)")
        XCTAssertEqual(link.state, .connected)
        XCTAssertGreaterThan(perMinute.suffix(2).reduce(0, +), 0, "decoding stopped")
    }

    /// Needs a person: unplug the USB cable and plug it back in while this
    /// waits. The link has to notice, come back by itself and be decoding.
    func testSerialReplug() throws {
        let (link, recorder) = try open(MobilinkdConfig(), autoReconnect: true)
        defer { closeAndWait(link) }
        note("TNC4 USB: connected; waiting up to 3 minutes for the cable to come out")
        let dropped = waitFor(seconds: 180) { link.state != .connected }
        guard dropped else { throw XCTSkip("the cable was not unplugged") }
        note("TNC4 USB: dropped (\(link.state.rawValue))")
        let back = waitFor(seconds: 120) { link.state == .connected }
        note("TNC4 USB: \(back ? "back by itself" : "did not come back"); states \(recorder.states.map(\.rawValue))")
        XCTAssertTrue(back)
        guard back else { return }
        let mark = recorder.frames.count
        _ = waitFor(seconds: 60) { false }
        let packets = decoded(recorder, after: mark).count
        note("TNC4 USB: \(packets) packets in 60 s after replugging; answers: \(inputGain(link, recorder) != nil)")
        XCTAssertGreaterThan(packets, 0)
    }

    /// THIS ONE TRANSMITS: a three-second test tone, with the output level
    /// changed while it plays. Needs TEST_RUNNER_AXTERM_TNC4_TX=1 as well.
    func testSerialTestTone() throws {
        guard env["AXTERM_TNC4_TX"] == "1" else { throw XCTSkip("Set TEST_RUNNER_AXTERM_TNC4_TX=1 to transmit") }
        let seconds = Double(env["AXTERM_TNC4_TONE_SECONDS"] ?? "") ?? 3
        var config = try serialConfig(MobilinkdConfig())
        let recorder = SerialRecorder()
        let link = KISSLinkSerial(config: config)
        link.delegate = recorder
        link.open()
        defer { closeAndWait(link) }
        XCTAssertTrue(waitFor(seconds: 30) { link.state == .connected }, "never connected")
        guard link.state == .connected else { return }
        _ = waitFor(seconds: 2) { false }

        let start = Date()
        link.startTestTone(.both, for: seconds)
        note(String(format: "TNC4 USB: tone on at %.2f", start.timeIntervalSince1970))
        _ = waitFor(seconds: 0.2) { false }
        XCTAssertEqual(link.mobilinkdActivity, .sendingTone(.both))
        // The output level moves while the tone plays; the firmware keeps the
        // tone going through gain changes.
        for gain in [50, 63] {
            _ = waitFor(seconds: seconds / 3) { false }
            config.mobilinkdConfig = MobilinkdConfig(settings: MobilinkdSettings(outputGain: gain))
            link.updateConfig(config)
            note(String(format: "TNC4 USB: output gain %d at +%.2f s", gain, Date().timeIntervalSince(start)))
        }
        let stopped = waitFor(seconds: seconds + 2) { link.mobilinkdActivity == .idle }
        note(String(format: "TNC4 USB: tone %@ at +%.2f s", stopped ? "stopped" : "STILL ON", Date().timeIntervalSince(start)))
        XCTAssertTrue(stopped, "the tone did not stop on its own")

        let mark = recorder.frames.count
        let listen = Double(env["AXTERM_TNC4_LISTEN_SECONDS"] ?? "") ?? 45
        _ = waitFor(seconds: listen) { false }
        let packets = decoded(recorder, after: mark).count
        note("TNC4 USB: after the tone, still \(link.state.rawValue), \(packets) packets in \(Int(listen)) s, "
            + "output gain now \(outputGain(link, recorder).map(String.init) ?? "?")")
        XCTAssertEqual(link.state, .connected)
    }

    // MARK: Helpers

    private func serialConfig(_ mobilinkd: MobilinkdConfig?) throws -> SerialConfig {
        SerialConfig(devicePath: try port(), autoReconnect: false, mobilinkdConfig: mobilinkd,
                     timing: KISSTimingParameters(txDelayMs: 500))
    }

    private func outputGain(_ link: KISSLinkSerial, _ recorder: SerialRecorder) -> Int? {
        let mark = recorder.frames.count
        link.send(Data(MobilinkdTNC.getOutputGain())) { _ in }
        _ = waitFor(seconds: 3) { recorder.frames.dropFirst(mark).contains { MobilinkdTNC.parseOutputGain($0) != nil } }
        return recorder.frames.dropFirst(mark).compactMap(MobilinkdTNC.parseOutputGain).last
    }

    private func port() throws -> String {
        if let p = env["AXTERM_TNC4_PORT"] { return p }
        let dev = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        guard let name = dev.filter({ $0.hasPrefix("cu.usbmodem") }).sorted().first else {
            throw XCTSkip("no /dev/cu.usbmodem* device")
        }
        return "/dev/" + name
    }

    private func open(_ mobilinkd: MobilinkdConfig?, autoReconnect: Bool = false) throws -> (KISSLinkSerial, SerialRecorder) {
        let path = try port()
        let recorder = SerialRecorder()
        let link = KISSLinkSerial(config: SerialConfig(devicePath: path, autoReconnect: autoReconnect,
                                                       mobilinkdConfig: mobilinkd,
                                                       timing: KISSTimingParameters(txDelayMs: 500)))
        link.delegate = recorder
        link.open()
        guard waitFor(seconds: 30, { link.state == .connected }) else {
            note("TNC4 USB: never connected on \(path); states \(recorder.states.map(\.rawValue)) errors \(recorder.errors)")
            link.close()
            throw XCTSkip("could not connect on \(path)")
        }
        note("TNC4 USB: connected on \(path)")
        return (link, recorder)
    }

    private func closeAndWait(_ link: KISSLinkSerial) {
        link.close()
        _ = waitFor(seconds: 5) { link.state == .disconnected }
        _ = waitFor(seconds: 1) { false }
    }

    private func inputGain(_ link: KISSLinkSerial, _ recorder: SerialRecorder) -> Int? {
        let mark = recorder.frames.count
        link.send(Data(MobilinkdTNC.getInputGain())) { _ in }
        _ = waitFor(seconds: 3) { recorder.frames.dropFirst(mark).contains { MobilinkdTNC.parseInputGain($0) != nil } }
        return recorder.frames.dropFirst(mark).compactMap(MobilinkdTNC.parseInputGain).last
    }

    private func report(_ recorder: SerialRecorder, after mark: Int) -> MobilinkdDeviceState {
        var state = MobilinkdDeviceState()
        for f in recorder.frames.dropFirst(mark) { if let r = MobilinkdReply.parse(f) { state.apply(r) } }
        return state
    }

    private func decoded(_ recorder: SerialRecorder, after mark: Int) -> [String] {
        recorder.frames.dropFirst(mark).compactMap { f -> String? in
            guard (f.first ?? 0xFF) & 0x0F == 0, let d = AX25.decodeFrame(ax25: Data(f.dropFirst())) else { return nil }
            return "\(d.from?.display ?? "?")>\(d.to?.display ?? "?"): " + String(decoding: d.info.prefix(40), as: UTF8.self)
        }
    }

    private func waitFor(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
#endif
