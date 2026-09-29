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

    func linkDidReceive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        rawBytes += data.count
        buffer.append(data)
        while let end = buffer.dropFirst().firstIndex(of: 0xC0) {
            let raw = buffer[buffer.startIndex..<end].drop { $0 == 0xC0 }
            buffer = Data(buffer[end...])
            if !raw.isEmpty { frames.append(Self.unescape(Data(raw))) }
        }
    }

    func linkDidChangeState(_ state: KISSLinkState) {
        lock.lock(); states.append(state); lock.unlock()
    }

    func linkDidError(_ message: String) {
        lock.lock(); errors.append(message); lock.unlock()
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
        defer { link.close() }
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
        defer { link.close() }
        XCTAssertTrue(waitFor(seconds: 30) { link.state == .connected }, "never reached .connected over BLE")
        guard link.state == .connected else { return }

        // Let the link's own connect-time writes drain before querying.
        _ = waitFor(seconds: 2) { false }
        let queries: [(String, [UInt8])] = [
            ("battery (control)", [0x06]),
            ("firmware version", [0x28]), ("hardware version", [0x29]), ("API version", [0x7B]),
            ("modem type", [0xC1, 0x81]), ("supported modem types", [0xC1, 0x83]),
            ("input gain", [0x0D]), ("input twist", [0x19]), ("output gain", [0x0C]),
        ]
        for (_, body) in queries {
            link.send(Data([0xC0, 0x06] + body + [0xC0])) { _ in }
            _ = waitFor(seconds: 0.7) { false }
        }
        _ = waitFor(seconds: 1.5) { false }

        let snap = recorder.snapshot()
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
        defer { link.close() }

        let connected = waitFor(seconds: 30) { link.state == .connected }
        let s0 = recorder.snapshot()
        note("TNC4: states \(s0.states.map(\.rawValue)), errors \(s0.errors)")
        XCTAssertTrue(connected, "never reached .connected over BLE")
        guard connected else { return }

        // Ask for the battery now rather than waiting out the link's own poll.
        link.send(Data(MobilinkdTNC.pollBatteryLevel())) { error in
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
