//
//  TNC4BLEReceiveLiveTests.swift
//  AXTermTests
//
//  Receive-only check of a real Mobilinkd TNC4 over Bluetooth LE, through the
//  same KISSLinkBLE the app uses. It never sends a data frame, so it never
//  keys the radio: the only bytes it writes are the KISS parameter frames the
//  link sends on connect and a Mobilinkd battery query. That makes it safe to
//  run with the TNC4's radio sitting on the APRS channel, which is also where
//  it gets the traffic it needs to prove receive works.
//
//  Skipped unless asked for:
//
//      TEST_RUNNER_AXTERM_TNC4_BLE=1 xcodebuild test -scheme AXTerm \
//        -only-testing:AXTermTests/TNC4BLEReceiveLiveTests
//
//  TEST_RUNNER_AXTERM_TNC4_LISTEN_SECONDS sets how long to listen (default 90).
//

import CoreBluetooth
import XCTest
@testable import AXTerm

/// Collects what the link reports. Delegate calls arrive on the link's own
/// queue, so everything goes through the lock.
nonisolated private final class TNC4Recorder: KISSLinkDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var rawBytes = 0
    private(set) var states: [KISSLinkState] = []
    private(set) var errors: [String] = []
    /// KISS payloads with the FENDs stripped and escapes undone.
    private(set) var frames: [Data] = []
    /// When each entry in `frames` arrived.
    private(set) var frameTimes: [Date] = []

    func linkDidReceive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        rawBytes += data.count
        buffer.append(data)
        while let end = buffer.dropFirst().firstIndex(of: 0xC0) {
            let raw = buffer[buffer.startIndex..<end].drop { $0 == 0xC0 }
            buffer = Data(buffer[end...])
            if !raw.isEmpty { frames.append(Self.unescape(Data(raw))); frameTimes.append(Date()) }
        }
    }

    func linkDidChangeState(_ state: KISSLinkState) {
        lock.lock(); states.append(state); lock.unlock()
    }

    func linkDidError(_ message: String) {
        lock.lock(); errors.append(message); lock.unlock()
    }

    func timedFrames() -> [(Date, Data)] {
        lock.lock(); defer { lock.unlock() }
        return Array(zip(frameTimes, frames))
    }

    func snapshot() -> (states: [KISSLinkState], errors: [String], frames: [Data], rawBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (states, errors, frames, rawBytes)
    }

    private static func unescape(_ d: Data) -> Data {
        var out = Data(); var esc = false
        for b in d {
            if esc { out.append(b == 0xDC ? 0xC0 : b == 0xDD ? 0xDB : b); esc = false }
            else if b == 0xDB { esc = true }
            else { out.append(b) }
        }
        return out
    }
}

final class TNC4BLEReceiveLiveTests: XCTestCase {

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    /// Everything the test learned, attached to the result so it can be read
    /// back from the xcresult; an app-hosted test's stdout goes nowhere useful.
    private var notes: [String] = []

    private func note(_ line: String) {
        print(line)
        notes.append(line)
    }

    override func tearDown() {
        let attachment = XCTAttachment(string: notes.joined(separator: "\n"))
        attachment.name = "TNC4 BLE receive log"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard env["AXTERM_TNC4_BLE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_AXTERM_TNC4_BLE=1 to run against a real TNC4")
        }
    }

    /// Measure the audio reaching the TNC4's input, to tell "no signal" from
    /// "signal the demodulator can't read". POLL_INPUT_LEVEL takes the
    /// demodulator off packet decoding, so RESET is sent afterwards to put it
    /// back. Still receive-only.
    func testInputLevelOverBLE() throws {
        let device = try discoverTNC4()
        let recorder = TNC4Recorder()
        let link = KISSLinkBLE(config: BLEConfig(
            peripheralUUID: device.id.uuidString, peripheralName: device.name,
            autoReconnect: false, mobilinkdConfig: MobilinkdConfig()))
        link.delegate = recorder
        link.open()
        defer { closeAndWait(link) }
        XCTAssertTrue(waitFor(seconds: 30) { link.state == .connected }, "never reached .connected over BLE")
        guard link.state == .connected else { return }

        for _ in 0..<5 {
            link.send(Data(MobilinkdTNC.pollInputLevel())) { _ in }
            _ = waitFor(seconds: 1.5) { false }
        }
        link.send(Data(MobilinkdTNC.reset())) { _ in }
        _ = waitFor(seconds: 1) { false }

        let levels = recorder.snapshot().frames.compactMap { MobilinkdTNC.parseInputLevel($0) }
        for l in levels { note("TNC4 level: vpp \(l.vpp) vavg \(l.vavg) vmin \(l.vmin) vmax \(l.vmax)") }
        note("TNC4: \(levels.count) level readings")
        XCTAssertFalse(levels.isEmpty, "the TNC4 did not answer POLL_INPUT_LEVEL")
    }

    /// Ask the TNC4 what it is and how it is set, using the read-only queries
    /// from the firmware's KissHardware.hpp. Extended commands (0xC1 xx) ride
    /// inside a hardware frame, so the modem-type query is `06 C1 81`.
    func testQuerySettingsOverBLE() throws {
        let device = try discoverTNC4()
        let recorder = TNC4Recorder()
        let link = KISSLinkBLE(config: BLEConfig(
            peripheralUUID: device.id.uuidString, peripheralName: device.name,
            autoReconnect: false, mobilinkdConfig: MobilinkdConfig()))
        link.delegate = recorder
        link.open()
        defer { closeAndWait(link) }
        XCTAssertTrue(waitFor(seconds: 30) { link.state == .connected }, "never reached .connected over BLE")
        guard link.state == .connected else { return }

        // Let the link's own connect-time writes drain before querying.
        _ = waitFor(seconds: 2) { false }
        let queries: [(String, [UInt8])] = [
            ("battery (control)", [0x06]),
            ("firmware version", [0x28]), ("hardware version", [0x29]), ("API version", [0x7B]),
            ("modem type", [0xC1, 0x81]), ("supported modem types", [0xC1, 0x83]),
            ("input gain", [0x0D]), ("input twist", [0x19]), ("output gain", [0x0C]),
            ("PTT channel", [0x50]), ("output twist", [0x1B]), ("TX delay", [0x21]),
        ]
        for (_, body) in queries {
            link.send(Data([0xC0, 0x06] + body + [0xC0])) { _ in }
            _ = waitFor(seconds: 0.7) { false }
        }
        _ = waitFor(seconds: 1.5) { false }

        let snap = recorder.snapshot()
        note("TNC4 link counters: \(link.totalBytesIn) bytes in from CoreBluetooth, \(link.totalBytesOut) bytes out")
        note("TNC4: \(snap.rawBytes) raw bytes, \(snap.frames.count) KISS frames, states \(snap.states.map(\.rawValue)), errors \(snap.errors)")
        for f in snap.frames where f.first != 0x06 {
            note("TNC4 other frame: " + f.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        let replies = snap.frames.filter { $0.first == 0x06 }
        for r in replies {
            let hex = r.map { String(format: "%02X", $0) }.joined(separator: " ")
            let text = String(decoding: r.dropFirst(2).filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            note("TNC4 reply: \(hex)\(text.count > 3 ? "  \"\(text)\"" : "")")
        }
        let modem = replies.first { $0.count >= 4 && $0[1] == 0xC1 && $0[2] == 0x81 }.map { $0[3] }
        let names: [UInt8: String] = [1: "1200 AFSK", 2: "300 AFSK", 3: "9600", 4: "PSK31", 5: "M17"]
        note("TNC4: modem type \(modem.map { "\($0) (\(names[$0] ?? "unknown"))" } ?? "no reply")")
        XCTAssertNotNil(modem, "the TNC4 did not answer EXT_GET_MODEM_TYPE")
    }

    /// THIS ONE TRANSMITS. Send one APRS status frame and listen for
    /// digipeaters repeating it, which proves the TNC4 keys the radio and puts
    /// a decodable signal on the air. Needs its own switch on top of the BLE
    /// one, so running the file never keys a radio by accident:
    ///
    ///     TEST_RUNNER_AXTERM_TNC4_BLE=1 TEST_RUNNER_AXTERM_TNC4_TX=1 xcodebuild test ...
    ///
    /// TEST_RUNNER_AXTERM_TNC4_TX_CALL and _PATH set the source and path
    /// (default K0EPI-2 via WIDE1-1,WIDE2-1).
    func testTransmitAPRSStatusOverBLE() throws {
        guard env["AXTERM_TNC4_TX"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_AXTERM_TNC4_TX=1 to transmit")
        }
        let (call, ssid) = CallsignNormalizer.parse(env["AXTERM_TNC4_TX_CALL"] ?? "K0EPI-2")
        let source = AX25Address(call: call, ssid: ssid)
        let path = (env["AXTERM_TNC4_TX_PATH"] ?? "WIDE1-1,WIDE2-1").split(separator: ",").map(String.init)
        let text = ">AXTerm TNC4 transmit test"

        // A live link first (a deaf one can't hear the digipeats), with any
        // output and input gain from the environment applied, unsaved.
        let (link, recorder) = try openLiveLink()
        defer { closeAndWait(link) }

        // Optional TX delay in ms, as a standard KISS TXDELAY frame (10 ms
        // units). The TNC4 keeps it in working memory only, like the gain.
        if let ms = env["AXTERM_TNC4_TXDELAY_MS"].flatMap(Int.init) {
            let units = UInt8(clamping: ms / 10)
            link.send(Data([0xC0, 0x01, units, 0xC0])) { _ in }
            _ = waitFor(seconds: 1) { false }
            link.send(Data([0xC0, 0x06, 0x21, 0xC0])) { _ in }   // GET_TXDELAY
            _ = waitFor(seconds: 1.5) { false }
            let echoed = recorder.snapshot().frames.last { $0.count >= 3 && $0[0] == 0x06 && $0[1] == 0x21 }.map { Int($0[2]) }
            note("TNC4: TX delay set to \(Int(units) * 10) ms, TNC4 reports \(echoed.map { "\($0 * 10) ms" } ?? "no reply")")
            XCTAssertEqual(echoed, Int(units), "the TNC4 did not confirm the TX delay")
        }

        let frame = AX25FrameBuilder.buildUI(
            from: source, to: AX25Address(call: APRSBeacon.tocall),
            via: DigiPath.from(path), payload: Data(text.utf8))
        let kiss = KISS.encodeFrame(payload: frame.encodeAX25(), port: 0)
        let sentAt = Date()
        var sendError: Error?
        link.send(kiss) { sendError = $0 }
        note("TNC4: sent \(source.display)>\(APRSBeacon.tocall),\(path.joined(separator: ",")):\(text) "
            + "(\(kiss.count) bytes) at \(sentAt)")

        let listen = Double(env["AXTERM_TNC4_LISTEN_SECONDS"] ?? "") ?? 60
        _ = waitFor(seconds: listen) { false }
        XCTAssertNil(sendError, "the BLE write failed: \(String(describing: sendError))")

        var repeats = 0
        for f in recorder.snapshot().frames where (f.first ?? 0xFF) & 0x0F == 0 {
            guard let d = AX25.decodeFrame(ax25: Data(f.dropFirst())) else { continue }
            let via = d.via.map { $0.display + ($0.repeated ? "*" : "") }.joined(separator: ",")
            let line = "\(d.from?.display ?? "?")>\(d.to?.display ?? "?")\(via.isEmpty ? "" : ",\(via)"): "
                + String(decoding: d.info.prefix(50), as: UTF8.self)
            if d.from?.call == source.call && d.from?.ssid == source.ssid {
                repeats += 1
                note("TNC4 heard our packet: \(line)")
            } else {
                note("  other: \(line)")
            }
        }
        note("TNC4: \(repeats) digipeated copies of our packet in \(Int(listen)) s")
        XCTAssertGreaterThan(repeats, 0, "no digipeater repeated the test packet — \(notes.suffix(2).joined(separator: " | "))")
    }

    /// THIS ONE TRANSMITS. Open and close an AX.25 connection with a node:
    /// SABM, wait for UA (or DM), log whatever the node sends, then DISC and
    /// wait for its UA. Proves both directions against a real peer without
    /// relying on distant digipeaters. Same TX switch as above.
    ///
    /// TEST_RUNNER_AXTERM_TNC4_NODE sets the node (default K0EPI-7) and
    /// TEST_RUNNER_AXTERM_TNC4_TX_CALL the source (default K0EPI-2).
    func testConnectToNodeOverBLE() throws {
        guard env["AXTERM_TNC4_TX"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_AXTERM_TNC4_TX=1 to transmit")
        }
        let me = { () -> AX25Address in
            let (c, s) = CallsignNormalizer.parse(env["AXTERM_TNC4_TX_CALL"] ?? "K0EPI-2"); return AX25Address(call: c, ssid: s)
        }()
        let node = { () -> AX25Address in
            let (c, s) = CallsignNormalizer.parse(env["AXTERM_TNC4_NODE"] ?? "K0EPI-7"); return AX25Address(call: c, ssid: s)
        }()

        let (link, recorder) = try openLiveLink()
        defer { closeAndWait(link) }

        func send(_ frame: OutboundFrame) {
            link.send(KISS.encodeFrame(payload: frame.encodeAX25(), port: 0)) { _ in }
            note("TNC4 >> \(me.display)>\(node.display) \(frame.displayInfo ?? "?")")
        }
        /// Frames from the node to us, decoded, from index `from` on.
        func fromNode(after from: Int) -> [(index: Int, control: UInt8, info: Data)] {
            recorder.snapshot().frames.enumerated().compactMap { i, f in
                guard i >= from, (f.first ?? 0xFF) & 0x0F == 0,
                      let d = AX25.decodeFrame(ax25: Data(f.dropFirst())),
                      d.from?.call == node.call, d.from?.ssid == node.ssid,
                      d.to?.call == me.call, d.to?.ssid == me.ssid else { return nil }
                return (i, d.control, d.info)
            }
        }
        func name(_ c: UInt8) -> String {
            if c & 0x01 == 0 { return "I ns=\((c >> 1) & 7) nr=\(c >> 5)" }
            if c & 0x03 == 0x01 { return ["RR", "RNR", "REJ", "SREJ"][Int((c >> 2) & 3)] + " nr=\(c >> 5)" }
            switch c & 0xEF {
            case 0x2F: return "SABM"; case 0x6F: return "SABME"; case 0x63: return "UA"
            case 0x0F: return "DM"; case 0x43: return "DISC"; case 0x87: return "FRMR"
            case 0x03: return "UI"; case 0xAF: return "XID"; default: return String(format: "U %02X", c)
            }
        }

        var answer: UInt8?
        for attempt in 1...3 where answer == nil {
            let mark = recorder.snapshot().frames.count
            send(AX25FrameBuilder.buildSABM(from: me, to: node))
            _ = waitFor(seconds: 8) {
                fromNode(after: mark).contains { [0x63, 0x0F].contains($0.control & 0xEF) }
            }
            answer = fromNode(after: mark).first { [0x63, 0x0F].contains($0.control & 0xEF) }?.control
            note("TNC4: SABM attempt \(attempt): \(answer.map(name) ?? "no answer")")
        }

        if let answer, answer & 0xEF == 0x63 {
            // Connected. Give the node a moment to send its greeting, then leave.
            let mark = recorder.snapshot().frames.count
            _ = waitFor(seconds: 4) { false }
            for f in fromNode(after: mark) {
                let text = String(decoding: f.info.prefix(80), as: UTF8.self).replacingOccurrences(of: "\r", with: "⏎")
                note("TNC4 << \(name(f.control)) \(text)")
            }
            let discMark = recorder.snapshot().frames.count
            send(AX25FrameBuilder.buildDISC(from: me, to: node))
            let closed = waitFor(seconds: 8) {
                fromNode(after: discMark).contains { [0x63, 0x0F].contains($0.control & 0xEF) }
            }
            note("TNC4: DISC answered: \(closed ? fromNode(after: discMark).map { name($0.control) }.joined(separator: ",") : "no")")
            XCTAssertTrue(closed, "the node never acknowledged DISC")
        }
        // Everything the TNC4 handed up during the test, from anyone, so a
        // missing answer can be told apart from a deaf receiver.
        let snap = recorder.snapshot()
        note("TNC4: \(link.totalBytesIn) bytes in, \(link.totalBytesOut) out, \(snap.frames.count) KISS frames")
        for f in snap.frames {
            guard (f.first ?? 0xFF) & 0x0F == 0, let d = AX25.decodeFrame(ax25: Data(f.dropFirst())) else {
                note("  hw: " + f.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")); continue
            }
            note("  heard: \(d.from?.display ?? "?")>\(d.to?.display ?? "?") \(name(d.control))")
        }
        XCTAssertEqual(answer.map { $0 & 0xEF }, 0x63, "the node did not accept the connection with UA")
    }

    /// THIS ONE TRANSMITS (one short UI frame). Measure the TNC4's input
    /// level before and in the seconds after a transmission, to see whether
    /// the input is knocked off centre by the unkey and how long it takes to
    /// come back. Nothing is saved; the level poll takes the demodulator off
    /// packets, so RESET is sent at the end.
    func testInputAfterTransmitOverBLE() throws {
        guard env["AXTERM_TNC4_TX"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_AXTERM_TNC4_TX=1 to transmit")
        }
        let (call, ssid) = CallsignNormalizer.parse(env["AXTERM_TNC4_TX_CALL"] ?? "K0EPI-2")
        let (link, recorder) = try openLiveLink()
        defer { closeAndWait(link) }

        let poll = Data(MobilinkdTNC.pollInputLevel())
        for _ in 0..<3 { link.send(poll) { _ in }; _ = waitFor(seconds: 0.6) { false } }
        _ = waitFor(seconds: 1) { false }

        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: call, ssid: ssid), to: AX25Address(call: "TEST"),
            payload: Data("AXTerm TNC4 turnaround test".utf8))
        let sentAt = Date()
        link.send(KISS.encodeFrame(payload: frame.encodeAX25(), port: 0)) { _ in }
        note("TNC4: sent UI frame at t=0")
        while Date().timeIntervalSince(sentAt) < 6 {
            link.send(poll) { _ in }
            _ = waitFor(seconds: 0.4) { false }
        }
        _ = waitFor(seconds: 1.5) { false }
        link.send(Data(MobilinkdTNC.reset())) { _ in }
        _ = waitFor(seconds: 0.5) { false }

        var readings = 0
        for (at, f) in recorder.timedFrames() {
            guard let l = MobilinkdTNC.parseInputLevel(f) else { continue }
            readings += 1
            note(String(format: "  t=%+5.2fs  vavg %5d  vmin %5d  vmax %5d  vpp %5d",
                        at.timeIntervalSince(sentAt), l.vavg, l.vmin, l.vmax, l.vpp))
        }
        XCTAssertGreaterThan(readings, 3, "too few level readings to say anything")
    }

    // MARK: - The app's own link, no workarounds

    /// Receive-only. Exercises KISSLinkBLE exactly as the app builds it: it
    /// has to come up able to hear every time (it probes and reconnects a deaf
    /// connection itself), apply a profile's TNC4 levels, and put the TNC4's
    /// own levels back when it closes.
    func testAppLinkAppliesAndRestoresLevelsOverBLE() throws {
        let device = try discoverTNC4()

        func open(_ mobilinkd: MobilinkdConfig?) -> (KISSLinkBLE, TNC4Recorder)? {
            let recorder = TNC4Recorder()
            let link = KISSLinkBLE(config: BLEConfig(
                peripheralUUID: device.id.uuidString, peripheralName: device.name,
                autoReconnect: false, mobilinkdConfig: mobilinkd,
                timing: KISSTimingParameters(txDelayMs: 500)))
            link.delegate = recorder
            link.open()
            guard waitFor(seconds: 45, { link.state == .connected }) else {
                note("TNC4: never connected; states \(recorder.snapshot().states.map(\.rawValue)), errors \(recorder.snapshot().errors)")
                link.close(); return nil
            }
            return (link, recorder)
        }
        /// Ask the open link for the TNC4's input gain; the reply reaches the
        /// delegate because the session has finished by now.
        func inputGain(_ link: KISSLinkBLE, _ recorder: TNC4Recorder) -> Int? {
            let mark = recorder.snapshot().frames.count
            link.send(Data(MobilinkdTNC.getInputGain())) { _ in }
            _ = waitFor(seconds: 3) { recorder.snapshot().frames.dropFirst(mark).contains { MobilinkdTNC.parseInputGain($0) != nil } }
            return recorder.snapshot().frames.dropFirst(mark).compactMap(MobilinkdTNC.parseInputGain).last
        }
        func close(_ link: KISSLinkBLE) {
            link.close()
            _ = waitFor(seconds: 3) { link.state == .disconnected }
            _ = waitFor(seconds: 2) { false }
        }

        // 1. Five plain connections: every one must come up hearing.
        var original: Int?
        var heard = 0
        for i in 1...5 {
            guard let (link, recorder) = open(nil) else { continue }
            let gain = inputGain(link, recorder)
            note("TNC4: plain connection \(i): \(gain.map { "input gain \($0)" } ?? "DEAF")")
            if gain != nil { heard += 1; original = original ?? gain }
            close(link)
        }
        XCTAssertEqual(heard, 5, "every connection the link reports as up must hear the TNC4")
        guard let original else { return }

        // 2. Mobilinkd mode with the IC-V8's input gain.
        let wanted: UInt8 = original == 0 ? 2 : 0
        guard let (link, recorder) = open(MobilinkdConfig(settings: MobilinkdSettings(outputGain: 63, inputGain: Int(wanted)))) else {
            return XCTFail("Mobilinkd-mode link never connected")
        }
        let applied = inputGain(link, recorder)
        note("TNC4: Mobilinkd mode asked for input gain \(wanted), TNC4 reports \(applied.map(String.init) ?? "nothing")")
        XCTAssertEqual(applied, Int(wanted), "the profile's input gain was not applied")
        close(link)

        // 3. Back to the TNC4's own setting after the link let go.
        guard let (after, afterRecorder) = open(nil) else { return XCTFail("could not reconnect to check") }
        let restored = inputGain(after, afterRecorder)
        note("TNC4: after closing, input gain \(restored.map(String.init) ?? "nothing") (was \(original))")
        XCTAssertEqual(restored, original, "closing did not put the TNC4's own input gain back")
        close(after)
    }

    /// Receive-only. The settings page's controls against a real TNC4: the
    /// status read brings the full report back, measuring streams levels, and
    /// afterwards the TNC4 is decoding packets again.
    func testSettingsControlsOverBLE() throws {
        let device = try discoverTNC4()
        let recorder = TNC4Recorder()
        let link = KISSLinkBLE(config: BLEConfig(
            peripheralUUID: device.id.uuidString, peripheralName: device.name, autoReconnect: false))
        link.delegate = recorder
        link.open()
        defer { closeAndWait(link) }
        XCTAssertTrue(waitFor(seconds: 45) { link.state == .connected }, "never connected")
        guard link.state == .connected else { return }
        XCTAssertTrue(link.isMobilinkd)

        func report(after mark: Int) -> MobilinkdDeviceState {
            var state = MobilinkdDeviceState()
            for f in recorder.snapshot().frames.dropFirst(mark) {
                if let r = MobilinkdReply.parse(f) { state.apply(r) }
            }
            return state
        }

        // 1. Status.
        var mark = recorder.snapshot().frames.count
        link.refreshMobilinkdStatus()
        _ = waitFor(seconds: 6) { report(after: mark).txReversePolarity != nil && report(after: mark).batteryMillivolts != nil }
        let status = report(after: mark)
        note("TNC4 status: \(status.hardwareVersion ?? "?") fw \(status.firmwareVersion ?? "?") "
            + "serial \(status.serialNumber ?? "?") battery \(status.batteryMillivolts.map(String.init) ?? "?") mV "
            + "gain in \(status.inputGain.map(String.init) ?? "?") out \(status.outputGain.map(String.init) ?? "?") "
            + "PTT \(status.pttMultiplex == true ? "multiplex" : status.pttMultiplex == false ? "simplex" : "?") "
            + "modems \(status.supportedModemTypes ?? []) canSave \(status.canSave)")
        XCTAssertNotNil(status.firmwareVersion)
        XCTAssertNotNil(status.batteryMillivolts)
        XCTAssertNotNil(MobilinkdSettings(reportedBy: status), "every managed setting reported")

        // 2. Measuring.
        _ = waitFor(seconds: 1) { false }
        mark = recorder.snapshot().frames.count
        link.startMeasuringInput()
        _ = waitFor(seconds: 4) { false }
        XCTAssertEqual(link.mobilinkdActivity, .measuring)
        link.stopMeasuringInput()
        let levels = recorder.snapshot().frames.dropFirst(mark).compactMap(MobilinkdTNC.parseInputLevel)
        note("TNC4: \(levels.count) level readings in 4 s; last vpp \(levels.last.map { String($0.vpp) } ?? "-")")
        XCTAssertGreaterThan(levels.count, 3, "the level stream did not flow")

        // 3. Back to packets.
        _ = waitFor(seconds: 1) { link.mobilinkdActivity == .idle }
        mark = recorder.snapshot().frames.count
        let listen = Double(env["AXTERM_TNC4_LISTEN_SECONDS"] ?? "") ?? 60
        _ = waitFor(seconds: listen) { false }
        let packets = recorder.snapshot().frames.dropFirst(mark)
            .filter { ($0.first ?? 0xFF) & 0x0F == 0 }
            .compactMap { AX25.decodeFrame(ax25: Data($0.dropFirst())) }
        note("TNC4: \(packets.count) packets decoded in \(Int(listen)) s after measuring")
        XCTAssertGreaterThan(packets.count, 0, "the TNC4 did not go back to decoding after measuring")
    }

    /// Receive-only. The level assistant's loop against a real TNC4, with the
    /// link's config standing in for the radio profile.
    @MainActor
    func testLevelAssistantOverBLE() throws {
        let device = try discoverTNC4()
        let recorder = TNC4Recorder()
        var config = BLEConfig(peripheralUUID: device.id.uuidString, peripheralName: device.name, autoReconnect: false)
        let link = KISSLinkBLE(config: config)
        link.delegate = recorder
        link.open()
        defer { closeAndWait(link) }
        XCTAssertTrue(waitFor(seconds: 45) { link.state == .connected }, "never connected")
        guard link.state == .connected else { return }
        _ = waitFor(seconds: 2) { false }

        var tried: [Int] = []
        let runner = MobilinkdLevelAssistantRunner()
        runner.run(control: link, gains: 0...4,
                   reading: {
                       guard let (at, frame) = recorder.timedFrames().last(where: { MobilinkdTNC.parseInputLevel($0.1) != nil })
                       else { return (nil, nil) }
                       return (MobilinkdTNC.parseInputLevel(frame), at)
                   },
                   setGain: { gain in
                       if tried.last != gain { tried.append(gain) }
                       config.mobilinkdConfig = MobilinkdConfig(settings: MobilinkdSettings(inputGain: gain))
                       link.updateConfig(config)
                   })
        _ = waitFor(seconds: 60) { !runner.running }
        note("TNC4 assistant: tried gains \(tried); result: \(runner.resultMessage ?? "none")")
        XCTAssertFalse(runner.running, "the assistant never finished")
        XCTAssertNotNil(runner.resultMessage)

        // The chosen gain is what the TNC4 now uses, and it is decoding again.
        _ = waitFor(seconds: 3) { false }
        let mark = recorder.snapshot().frames.count
        link.send(Data(MobilinkdTNC.getInputGain())) { _ in }
        _ = waitFor(seconds: 3) { recorder.snapshot().frames.dropFirst(mark).contains { MobilinkdTNC.parseInputGain($0) != nil } }
        let gain = recorder.snapshot().frames.dropFirst(mark).compactMap(MobilinkdTNC.parseInputGain).last
        note("TNC4: input gain afterwards \(gain.map(String.init) ?? "?")")
        XCTAssertEqual(gain, config.mobilinkdConfig?.settings.inputGain)

        let listenMark = recorder.snapshot().frames.count
        _ = waitFor(seconds: 45) { false }
        let packets = recorder.snapshot().frames.dropFirst(listenMark).filter { ($0.first ?? 0xFF) & 0x0F == 0 }.count
        note("TNC4: \(packets) packets in 45 s afterwards")
        XCTAssertGreaterThan(packets, 0, "not decoding after the assistant")
    }

    /// Open a link and make sure the TNC4 is actually heard before using it.
    /// About one connection in four comes up with notifications "enabled" and
    /// nothing ever arriving; a fresh connection clears it. This probes with
    /// GET_FIRMWARE_VERSION and reconnects up to three times.
    private func openLiveLink() throws -> (KISSLinkBLE, TNC4Recorder) {
        let device = try discoverTNC4()
        for attempt in 1...3 {
            let recorder = TNC4Recorder()
            let link = KISSLinkBLE(config: BLEConfig(
                peripheralUUID: device.id.uuidString, peripheralName: device.name,
                autoReconnect: false, mobilinkdConfig: MobilinkdConfig()))
            link.delegate = recorder
            link.open()
            guard waitFor(seconds: 30, { link.state == .connected }) else {
                link.close(); continue
            }
            _ = waitFor(seconds: 2) { false }
            link.send(Data([0xC0, 0x06, 0x28, 0xC0])) { _ in }
            if waitFor(seconds: 3, { recorder.snapshot().frames.contains { $0.count > 2 && $0[0] == 0x06 && $0[1] == 0x28 } }) {
                note("TNC4: link live on attempt \(attempt)")
                if let out = env["AXTERM_TNC4_OUTPUT_GAIN"].flatMap(UInt16.init) {
                    // Working memory only, like the input gain below.
                    link.send(Data([0xC0, 0x06, 0x01, UInt8(out >> 8), UInt8(out & 0xFF), 0xC0])) { _ in }
                    _ = waitFor(seconds: 1.5) { false }
                    let echoed = recorder.snapshot().frames.last { $0.count >= 4 && $0[0] == 0x06 && $0[1] == 0x0C }
                        .map { Int($0[2]) << 8 | Int($0[3]) }
                    note("TNC4: output gain set to \(out), TNC4 reports \(echoed.map(String.init) ?? "no reply") (not saved)")
                }
                if let gain = env["AXTERM_TNC4_INPUT_GAIN"].flatMap(UInt8.init) {
                    // Working memory only (no SAVE). The TNC4 re-measures its
                    // input centre for a second and starts streaming levels,
                    // so RESET afterwards to get back to packets.
                    link.send(Data(MobilinkdTNC.setInputGain(UInt16(gain)))) { _ in }
                    _ = waitFor(seconds: 2.5) { false }
                    link.send(Data(MobilinkdTNC.reset())) { _ in }
                    _ = waitFor(seconds: 1) { false }
                    let echoed = recorder.snapshot().frames.last { $0.count >= 4 && $0[0] == 0x06 && $0[1] == 0x0D }
                        .map { Int($0[2]) << 8 | Int($0[3]) }
                    note("TNC4: input gain set to \(gain), TNC4 reports \(echoed.map(String.init) ?? "no reply") (not saved)")
                }
                if env["AXTERM_TNC4_RESET_ON_CONNECT"] == "1" {
                    // Restart the demodulator, as AXTerm's own watchdog does
                    // after 30-90 s of silence, but straight away.
                    link.send(Data(MobilinkdTNC.reset())) { _ in }
                    _ = waitFor(seconds: 1) { false }
                    note("TNC4: sent demodulator RESET")
                }
                return (link, recorder)
            }
            note("TNC4: attempt \(attempt) came up deaf (\(link.totalBytesIn) bytes in); reconnecting")
            link.close()
            _ = waitFor(seconds: 3) { false }
        }
        throw XCTSkip("could not get a live BLE link to the TNC4 in three attempts")
    }

    /// Find the TNC4 by its advertised Mobilinkd service, connect, and listen.
    func testReceiveOverBLE() throws {
        let device = try discoverTNC4()
        note("TNC4: found \(device.displayName) \(device.id) rssi \(device.rssi)")

        let recorder = TNC4Recorder()
        let link = KISSLinkBLE(config: BLEConfig(
            peripheralUUID: device.id.uuidString,
            peripheralName: device.name,
            autoReconnect: false,
            mobilinkdConfig: MobilinkdConfig()))
        link.delegate = recorder
        link.open()
        defer { closeAndWait(link) }

        let connected = waitFor(seconds: 30) { link.state == .connected }
        let s0 = recorder.snapshot()
        note("TNC4: states \(s0.states.map(\.rawValue)), errors \(s0.errors)")
        XCTAssertTrue(connected, "never reached .connected over BLE")
        guard connected else { return }

        // Ask for the battery now rather than waiting out the link's own poll.
        link.send(Data(MobilinkdTNC.pollBatteryLevelAndResume())) { error in
            if let error { print("TNC4: battery query failed to send: \(error)") }
        }

        let listen = Double(env["AXTERM_TNC4_LISTEN_SECONDS"] ?? "") ?? 90
        note("TNC4: listening \(Int(listen)) s")
        _ = waitFor(seconds: listen) { false }

        let s = recorder.snapshot()
        let data = s.frames.filter { ($0.first ?? 0xFF) & 0x0F == 0x00 }
        let hardware = s.frames.filter { $0.first == MobilinkdTNC.CMD_HARDWARE }
        let battery = hardware.compactMap { MobilinkdTNC.parseBatteryLevel($0) }.last
        note("TNC4: \(s.rawBytes) raw bytes, \(s.frames.count) KISS frames, "
            + "\(data.count) data, \(hardware.count) hardware replies, "
            + "battery \(battery.map { "\($0) mV" } ?? "no reply"), errors \(s.errors)")
        var decoded = 0
        for frame in data {
            guard let f = AX25.decodeFrame(ax25: Data(frame.dropFirst())) else { continue }
            decoded += 1
            if decoded <= 12 {
                let via = f.via.map(\.display).joined(separator: ",")
                let text = String(decoding: f.info.prefix(60), as: UTF8.self)
                note("  rx: \(f.from?.display ?? "?")>\(f.to?.display ?? "?")\(via.isEmpty ? "" : ",\(via)"): \(text)")
            }
        }
        note("TNC4: \(decoded) of \(data.count) data frames decoded as AX.25")

        let summary = notes.suffix(3).joined(separator: " | ")
        XCTAssertNotNil(battery, "the TNC4 did not answer the battery query — \(summary)")
        XCTAssertGreaterThan(decoded, 0, "no AX.25 frames in \(Int(listen)) s on the APRS channel — \(summary)")
        XCTAssertEqual(link.state, .connected, "the link dropped while listening")
    }

    // MARK: - Helpers

    private func discoverTNC4() throws -> BLEDiscoveredDevice {
        let scanner = BLEDeviceScanner()
        scanner.startScan(duration: 15)
        defer { scanner.stopScan() }
        var found: BLEDiscoveredDevice?
        _ = waitFor(seconds: 15) {
            found = scanner.devices.first { $0.serviceUUIDs.contains(BLEServiceUUIDs.mobilinkd) }
            return found != nil
        }
        note("TNC4: bluetooth state \(scanner.bluetoothState.rawValue), "
            + "saw \(scanner.devices.map(\.displayName))")
        return try XCTUnwrap(found, "no BLE peripheral advertising the Mobilinkd service")
    }

    /// Close and give the link time to put the TNC4's own settings back
    /// before the test process moves on. Without this the restore writes
    /// never left, and the TNC4 kept the test's settings.
    private func closeAndWait(_ link: KISSLinkBLE) {
        link.close()
        _ = waitFor(seconds: 4) { link.state == .disconnected }
        _ = waitFor(seconds: 1) { false }
    }

    /// Spin the main run loop until the condition holds or time runs out.
    /// CoreBluetooth and the scanner's @Published updates need it turning.
    private func waitFor(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}

/// The frame the transmit test sends, pinned byte for byte. Runs everywhere;
/// no radio involved.
final class TNC4TestPacketEncodingTests: XCTestCase {

    func testTheAPRSStatusTestFrameEncodesCorrectly() {
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "K0EPI", ssid: 2), to: AX25Address(call: APRSBeacon.tocall),
            via: DigiPath.from(["WIDE2-1", "WIDE1-1"]), payload: Data(">AXTerm TNC4 transmit test".utf8))
        let ax25 = frame.encodeAX25()
        let kiss = KISS.encodeFrame(payload: ax25, port: 0)
        let hex = { (d: Data) in d.map { String(format: "%02X", $0) }.joined(separator: " ") }
        let attachment = XCTAttachment(string: "AX.25: \(hex(ax25))\nKISS:  \(hex(kiss))")
        attachment.name = "test frame bytes"
        attachment.lifetime = .keepAlways
        add(attachment)

        func call(_ s: String) -> [UInt8] { s.padding(toLength: 6, withPad: " ", startingAt: 0).utf8.map { $0 << 1 } }
        var expected: [UInt8] = []
        expected += call("APZAXT") + [0xE0]  // destination, SSID 0, C bit set (command)
        expected += call("K0EPI") + [0x64]   // source, SSID 2, C bit clear
        expected += call("WIDE2") + [0x62]   // SSID 1, H bit clear, not last
        expected += call("WIDE1") + [0x63]   // SSID 1, H bit clear, end of address field
        expected += [0x03, 0xF0]             // UI, no layer 3
        expected += Array(">AXTerm TNC4 transmit test".utf8)
        XCTAssertEqual(hex(ax25), hex(Data(expected)))
        XCTAssertEqual(kiss.first, 0xC0); XCTAssertEqual(kiss[1], 0x00); XCTAssertEqual(kiss.last, 0xC0)
        XCTAssertEqual(kiss.count, expected.count + 3, "nothing in this frame needs KISS escaping")

        let d = AX25.decodeFrame(ax25: ax25)
        XCTAssertEqual(d?.from?.display, "K0EPI-2")
        XCTAssertEqual(d?.to?.display, "APZAXT")
        XCTAssertEqual(d?.via.map(\.display), ["WIDE2-1", "WIDE1-1"])
        XCTAssertEqual(d?.frameType, .ui)
    }
}
