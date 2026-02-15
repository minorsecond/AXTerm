//
//  TNC4LiveConnectionTests.swift
//  AXTermTests
//
//  RF integration tests that exercise the full AXTerm stack against real hardware.
//  These tests transmit on amateur radio frequencies and MUST NOT run as part of
//  the normal test suite. They require manual setup and operator supervision.
//
//  TO RUN: Use the run_rf_tests.sh script in the project root, or set the
//  environment variable AXTERM_RF_TESTS=1 before running via xcodebuild.
//
//  REQUIREMENTS:
//  - Mobilinkd TNC4 connected via USB-C
//  - Radio tuned to a clear simplex frequency
//  - K0EPI-7 node (ham-pi LinBPQ) reachable on-air
//  - ham-pi Direwolf at 192.168.3.218:8001 (for dual-radio tests)
//  - Valid amateur radio license
//
//  These tests will be SKIPPED if AXTERM_RF_TESTS is not set or TNC is not connected.
//

import XCTest
import Combine
@testable import AXTerm

// MARK: - Test Link Delegate

/// Simple delegate for low-level KISSLink testing without PacketEngine.
@MainActor
private final class TestLinkDelegate: KISSLinkDelegate {
    var onStateChange: ((KISSLinkState) -> Void)?
    var onReceive: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    func linkDidChangeState(_ state: KISSLinkState) {
        onStateChange?(state)
    }
    func linkDidReceive(_ data: Data) {
        onReceive?(data)
    }
    func linkDidError(_ message: String) {
        onError?(message)
        print("[TEST DELEGATE] Error: \(message)")
    }
}

@MainActor
final class TNC4LiveConnectionTests: XCTestCase {

    // MARK: - Configuration

    /// TNC4 USB serial device path.
    /// Auto-detected from /dev/cu.usbmodem* if this specific path is missing.
    private let preferredDevicePath = "/dev/cu.usbmodem204B316146521"
    private let baudRate = 115200
    private let localCallsign = "K0EPI-6"
    private let remoteCallsign = "K0EPI-7"

    // MARK: - Shared State

    private var settings: AppSettingsStore!
    private var engine: PacketEngine!
    private var coordinator: SessionCoordinator!
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()

        // RF tests must be explicitly opted in — they transmit on amateur radio frequencies.
        // The run_rf_tests.sh script creates this sentinel file before running.
        guard FileManager.default.fileExists(atPath: "/tmp/axterm_rf_tests_enabled") else {
            throw XCTSkip("RF tests disabled — use run_rf_tests.sh to enable")
        }

        // Resolve device path (auto-detect if preferred path is gone after re-plug)
        let devicePath = resolveDevicePath()
        guard let devicePath else {
            throw XCTSkip("TNC4 not connected — no /dev/cu.usbmodem* device found")
        }

        // Create isolated settings so we don't touch the user's real config
        let suiteName = "AXTermTests.TNC4Live.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = localCallsign
        settings.transportType = "serial"
        settings.serialDevicePath = devicePath
        settings.serialBaudRate = baudRate
        // NOTE: Mobilinkd config is disabled for connection tests because
        // SET_MODEM_TYPE causes a demodulator restart that can interfere with
        // receiving the UA response. Enable only when testing Mobilinkd-specific features.
        settings.mobilinkdEnabled = false
    }

    /// Lazy setup of PacketEngine + SessionCoordinator for tests that need the full stack.
    /// Separated from setUpWithError() because PacketEngine init has side effects
    /// (Sentry, NET/ROM, timers) that can cause issues in some test environments.
    private func setupFullStack() {
        guard engine == nil else { return }
        engine = PacketEngine(settings: settings)
        coordinator = SessionCoordinator()
        coordinator.localCallsign = localCallsign
        coordinator.subscribeToPackets(from: engine)
    }

    override func tearDown() {
        cancellables.removeAll()
        engine?.disconnect(reason: "Test teardown")
        // Give the link time to close cleanly
        let cleanupExpectation = expectation(description: "cleanup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            cleanupExpectation.fulfill()
        }
        wait(for: [cleanupExpectation], timeout: 2.0)
        engine = nil
        coordinator = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Test 0: KISSLinkSerial Opens Directly (no PacketEngine)

    /// Verify that KISSLinkSerial can open the TNC4 USB serial port
    /// at the lowest level — bypasses PacketEngine entirely.
    func testKISSLinkSerialOpensDirectly() async throws {
        let devicePath = resolveDevicePath()
        guard let devicePath else {
            throw XCTSkip("TNC4 not connected")
        }

        let config = SerialConfig(
            devicePath: devicePath,
            baudRate: baudRate,
            autoReconnect: false,
            mobilinkdConfig: MobilinkdConfig(
                modemType: .afsk1200,
                outputGain: 128,
                inputGain: 0,
                isBatteryMonitoringEnabled: false
            )
        )

        let link = KISSLinkSerial(config: config)
        var stateChanges: [KISSLinkState] = []
        var receivedBytes = 0

        // Use a simple delegate to track state changes
        let delegate = TestLinkDelegate()
        delegate.onStateChange = { state in
            stateChanges.append(state)
        }
        delegate.onReceive = { data in
            receivedBytes += data.count
        }
        link.delegate = delegate

        link.open()

        // Wait for connection (USB open is fast, but KISS init takes ~1s + stabilization)
        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            if link.state == .connected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertEqual(link.state, .connected, "KISSLinkSerial should reach .connected after opening TNC4")
        XCTAssertTrue(stateChanges.contains(.connecting), "Should have transitioned through .connecting")
        XCTAssertTrue(stateChanges.contains(.connected), "Should have reached .connected")

        // Wait a few seconds to see if we receive any bytes (telemetry responses to KISS init)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        print("[TEST] Received \(receivedBytes) bytes from TNC4 after KISS init")

        link.close()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(link.state, .disconnected)
    }

    // MARK: - Test 1: TNC4 Serial Link Opens via PacketEngine

    /// Verify that PacketEngine + KISSLinkSerial can open the TNC4 USB serial port
    /// and transition to .connected state.
    func testTNC4SerialLinkOpens() async throws {
        setupFullStack()
        // Connect to TNC4
        engine.connectUsingSettings()

        // Wait for connection (KISS init + stabilization takes ~1-2s for USB)
        let connected = await waitForStatus(.connected, timeout: 10.0)
        XCTAssertTrue(connected, "PacketEngine should reach .connected status after opening TNC4 serial port")
        XCTAssertEqual(engine.status, .connected)
    }

    // MARK: - Test 2: TNC4 Receives RF Packets

    /// Verify that the TNC4 demodulator is running and the app receives
    /// decoded AX.25 packets from RF traffic.
    /// NOTE: This test requires active RF traffic on frequency. If no
    /// traffic is heard within the timeout, the test is skipped.
    func testTNC4ReceivesPackets() async throws {
        setupFullStack()
        engine.connectUsingSettings()
        guard await waitForStatus(.connected, timeout: 10.0) else {
            XCTFail("Failed to connect to TNC4")
            return
        }

        // Wait for at least one packet from RF (up to 30s)
        let receivedPacket = await waitForPacket(timeout: 30.0)
        if receivedPacket == nil {
            throw XCTSkip("No RF packets heard within 30s — frequency may be quiet")
        }

        XCTAssertNotNil(receivedPacket, "Should have received at least one decoded packet")
        XCTAssertGreaterThan(engine.bytesReceived, 0, "Should have received bytes from TNC4")
    }

    // MARK: - Test 2b: TNC4 Receives After Manual RESET

    /// Verify that after sending a RESET command, the demodulator starts and we can receive packets.
    func testTNC4ReceivesAfterManualReset() async throws {
        let devicePath = resolveDevicePath()
        guard let devicePath else {
            throw XCTSkip("TNC4 not connected")
        }

        // Use a config WITHOUT mobilinkd so no POLL_INPUT_LEVEL is sent
        let config = SerialConfig(
            devicePath: devicePath,
            baudRate: baudRate,
            autoReconnect: false,
            mobilinkdConfig: nil  // No Mobilinkd config = no POLL/RESET in KISS init
        )

        let link = KISSLinkSerial(config: config)
        var receivedBytes = 0
        var receivedKISSFrames = 0
        var parser = KISSFrameParser()

        let delegate = TestLinkDelegate()
        delegate.onReceive = { data in
            receivedBytes += data.count
            let frames = parser.feed(data)
            receivedKISSFrames += frames.count
            for frame in frames {
                switch frame {
                case .ax25(let ax25):
                    if let decoded = AX25.decodeFrame(ax25: ax25) {
                        print("[TEST] RX AX.25: \(decoded.from?.display ?? "?") > \(decoded.to?.display ?? "?") type=\(decoded.frameType.rawValue)")
                    }
                default:
                    break
                }
            }
        }
        link.delegate = delegate

        link.open()
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if link.state == .connected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(link.state, .connected, "Should connect to TNC4")

        // Send a manual RESET to ensure demodulator is running
        let resetFrame = Data(MobilinkdTNC.reset())
        link.send(resetFrame) { _ in }
        print("[TEST] Sent manual RESET, waiting for RF packets...")

        // Wait up to 30s for any RF packet
        let packetDeadline = Date().addingTimeInterval(30.0)
        while Date() < packetDeadline {
            if receivedKISSFrames > 0 { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        print("[TEST] Received \(receivedBytes) bytes, \(receivedKISSFrames) KISS frames")

        link.close()
        try await Task.sleep(nanoseconds: 500_000_000)

        if receivedKISSFrames == 0 {
            throw XCTSkip("No RF packets heard within 30s after RESET — frequency may be quiet")
        }
        XCTAssertGreaterThan(receivedKISSFrames, 0)
    }

    // MARK: - Test 3: Connect to K0EPI-7

    /// Initiate a connected-mode AX.25 session to K0EPI-7 and verify
    /// that we receive a UA response (connection accepted).
    func testConnectToK0EPI7() async throws {
        setupFullStack()
        engine.connectUsingSettings()
        guard await waitForStatus(.connected, timeout: 10.0) else {
            XCTFail("Failed to connect to TNC4")
            return
        }

        // Wait for KISS init + POLL/RESET sequence to complete (4.5s) + demodulator stabilization
        try await Task.sleep(nanoseconds: 7_000_000_000)

        let destination = AX25Address(call: "K0EPI", ssid: 7)
        let sessionManager = coordinator.sessionManager

        // Initiate connection — this generates SABM
        let sabmFrame = sessionManager.connect(to: destination, path: DigiPath(), channel: 0)
        XCTAssertNotNil(sabmFrame, "Should generate SABM frame")

        // Send the SABM via PacketEngine
        if let frame = sabmFrame {
            engine.send(frame: frame)
        }

        // Wait for UA response from K0EPI-7 (up to 30s — allows for retransmits over RF)
        let sessionConnected = await waitForSessionState(
            destination: destination,
            expectedState: .connected,
            timeout: 30.0
        )

        if !sessionConnected {
            // Check if we got a DM (disconnect mode) instead
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            if session.state == .disconnected {
                throw XCTSkip("K0EPI-7 responded with DM (busy or not accepting connections)")
            }
            XCTFail("Session did not reach .connected state within 15s (current: \(session.state.rawValue))")
            return
        }

        let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
        XCTAssertEqual(session.state, .connected, "Session to K0EPI-7 should be connected")
    }

    // MARK: - Test 4: Send and Receive Data

    /// Establish a connection to K0EPI-7, send data, and verify we get
    /// a response back (most BBS nodes echo or send a prompt).
    func testSendAndReceiveData() async throws {
        setupFullStack()
        engine.connectUsingSettings()
        guard await waitForStatus(.connected, timeout: 10.0) else {
            XCTFail("Failed to connect to TNC4")
            return
        }

        // Wait for KISS init + RESET (2s) + demodulator stabilization
        try await Task.sleep(nanoseconds: 7_000_000_000)

        let destination = AX25Address(call: "K0EPI", ssid: 7)
        let sessionManager = coordinator.sessionManager

        // Connect
        if let sabmFrame = sessionManager.connect(to: destination, path: DigiPath(), channel: 0) {
            engine.send(frame: sabmFrame)
        }

        guard await waitForSessionState(destination: destination, expectedState: .connected, timeout: 30.0) else {
            throw XCTSkip("Could not establish connection to K0EPI-7")
        }

        // Track data received from the remote node
        var receivedData = Data()

        // Save existing callback and chain ours
        let previousDataCallback = sessionManager.onDataDeliveredForReassembly
        sessionManager.onDataDeliveredForReassembly = { session, data in
            previousDataCallback?(session, data)
            if session.remoteAddress.call.uppercased() == "K0EPI" && session.remoteAddress.ssid == 7 {
                receivedData.append(data)
                print("[TEST] Received \(data.count) bytes from K0EPI-7: \(String(data: data, encoding: .ascii) ?? "(binary)")")
            }
        }

        // Many BBS nodes send a welcome/prompt immediately after UA.
        // Wait a moment to see if we get unsolicited data first.
        try await Task.sleep(nanoseconds: 3_000_000_000)

        if receivedData.isEmpty {
            // No unsolicited data — send a newline to prompt a response
            let newline = Data("\r".utf8)
            let iFrames = sessionManager.sendData(
                newline,
                to: destination,
                path: DigiPath(),
                channel: 0,
                pid: 0xF0
            )
            for frame in iFrames {
                engine.send(frame: frame)
            }
            print("[TEST] Sent \\r to K0EPI-7, waiting for response...")
        }

        // Wait for response (up to 15s, poll-based)
        _ = await waitForData(from: "K0EPI", peerSsid: 7, receivedData: &receivedData, timeout: 15.0)
        XCTAssertGreaterThan(receivedData.count, 0, "Should have received data from K0EPI-7")

        // Disconnect cleanly
        let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
        if let discFrame = sessionManager.disconnect(session: session) {
            engine.send(frame: discFrame)
        }

        // Wait for disconnect to complete
        try await Task.sleep(nanoseconds: 3_000_000_000)
    }

    // MARK: - Test 5: Mobilinkd Battery Telemetry

    /// Verify that the TNC4 responds to battery level queries.
    /// NOTE: Requires mobilinkdEnabled = true for battery polling to start.
    func testMobilinkdBatteryTelemetry() async throws {
        settings.mobilinkdEnabled = true
        setupFullStack()
        engine.connectUsingSettings()
        guard await waitForStatus(.connected, timeout: 10.0) else {
            XCTFail("Failed to connect to TNC4")
            return
        }

        // Wait for KISS init + battery poll cycle.
        // KISS init completes ~4.5s after connect, battery poll starts at +5s from link open,
        // then TNC4 responds within ~1s. Total: ~7-8s from connect.
        let batteryReceived = await waitForBattery(timeout: 25.0)
        XCTAssertTrue(batteryReceived, "Should receive battery level telemetry from TNC4")
        XCTAssertNotNil(engine.mobilinkdBatteryLevel, "Battery level should be populated")

        if let level = engine.mobilinkdBatteryLevel {
            // TNC4 returns battery voltage in millivolts (e.g. 4221 = 4.221V)
            print("[TEST] TNC4 battery level: \(level) mV")
            XCTAssertGreaterThan(level, 0, "Battery level should be > 0")
            XCTAssertGreaterThan(level, 2000, "Battery voltage should be > 2000 mV (reasonable for Li-ion)")
            XCTAssertLessThanOrEqual(level, 5000, "Battery voltage should be <= 5000 mV")
        }
    }

    // MARK: - Helpers

    /// Find a USB modem device, preferring the configured path.
    private func resolveDevicePath() -> String? {
        if FileManager.default.fileExists(atPath: preferredDevicePath) {
            return preferredDevicePath
        }
        // Auto-detect: scan /dev for usbmodem devices
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: "/dev") {
            let usbDevices = contents
                .filter { $0.hasPrefix("cu.") && $0.lowercased().contains("usbmodem") }
                .sorted()
            if let first = usbDevices.first {
                let path = "/dev/\(first)"
                print("[TEST] Auto-detected TNC4 at \(path)")
                return path
            }
        }
        return nil
    }

    /// Poll-based wait for PacketEngine to reach a specific connection status.
    /// Uses Task.sleep to yield the MainActor, avoiding Combine deadlocks.
    private func waitForStatus(_ target: ConnectionStatus, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.status == target { return true }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return engine.status == target
    }

    /// Poll-based wait for at least one packet to arrive.
    private func waitForPacket(timeout: TimeInterval) async -> Packet? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let first = engine.packets.first { return first }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }
        return engine.packets.first
    }

    /// Poll-based wait for a session to reach a specific state.
    private func waitForSessionState(
        destination: AX25Address,
        expectedState: AX25SessionState,
        timeout: TimeInterval
    ) async -> Bool {
        let sessionManager = coordinator.sessionManager
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            if session.state == expectedState { return true }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return false
    }

    /// Poll-based wait for battery telemetry to arrive.
    private func waitForBattery(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.mobilinkdBatteryLevel != nil { return true }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }
        return engine.mobilinkdBatteryLevel != nil
    }

    /// Poll-based wait for data to arrive from a session peer.
    private func waitForData(from peerCall: String, peerSsid: Int, receivedData: inout Data, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !receivedData.isEmpty { return true }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }
        return !receivedData.isEmpty
    }

    // MARK: - Direwolf Helper

    /// ham-pi Direwolf KISS TCP server — same frequency as TNC4, different radio.
    /// Used as a monitor/cross-verification endpoint.
    private let direwolfHost = "192.168.3.218"
    private let direwolfPort: UInt16 = 8001

    /// Create a PacketEngine connected to ham-pi Direwolf via TCP KISS.
    private func connectDirewolfEngine() async throws -> PacketEngine {
        let suiteName = "AXTermTests.DW.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let dwSettings = AppSettingsStore(defaults: defaults)
        dwSettings.myCallsign = localCallsign

        let dwEngine = PacketEngine(settings: dwSettings)
        dwEngine.connect(host: direwolfHost, port: direwolfPort)

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            if dwEngine.status == .connected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard dwEngine.status == .connected else {
            throw XCTSkip("Cannot reach Direwolf at \(direwolfHost):\(direwolfPort)")
        }
        return dwEngine
    }

    // MARK: - Test 6: Direwolf TCP — basic connectivity

    /// Verify we can reach ham-pi Direwolf via TCP KISS and it delivers
    /// decoded packets from RF (or at least bytes from the link).
    func testDirewolfTCPConnects() async throws {
        let dwEngine = try await connectDirewolfEngine()
        defer { dwEngine.disconnect(reason: "Test teardown") }

        XCTAssertEqual(dwEngine.status, .connected)
        print("[TEST] Direwolf TCP connected, bytesReceived=\(dwEngine.bytesReceived)")
    }

    // MARK: - Test 7: Cross-verify TNC4 TX via Direwolf monitor

    /// Dual-radio test: TNC4 (local USB serial) sends SABM to K0EPI-7.
    /// ham-pi Direwolf (TCP) monitors RF and should see our frame.
    /// This confirms the TNC4 is actually transmitting over RF and
    /// ham-pi's radio can hear it.
    func testDirewolfSeesOurSABM() async throws {
        // 1. Connect Direwolf monitor
        let dwEngine = try await connectDirewolfEngine()
        defer { dwEngine.disconnect(reason: "Test teardown") }
        print("[TEST] Direwolf monitor connected")

        // 2. Connect TNC4
        setupFullStack()
        engine.connectUsingSettings()
        guard await waitForStatus(.connected, timeout: 10.0) else {
            XCTFail("Failed to connect to TNC4")
            return
        }
        try await Task.sleep(nanoseconds: 7_000_000_000) // KISS init + RESET

        // 3. Send SABM from TNC4 to K0EPI-7
        let destination = AX25Address(call: "K0EPI", ssid: 7)
        let sessionManager = coordinator.sessionManager
        if let sabmFrame = sessionManager.connect(to: destination, path: DigiPath(), channel: 0) {
            engine.send(frame: sabmFrame)
            print("[TEST] Sent SABM to K0EPI-7 via TNC4")
        }

        // 4. Direwolf should hear our SABM on RF
        var sawOurFrame = false
        let monitorDeadline = Date().addingTimeInterval(15.0)
        while Date() < monitorDeadline {
            for pkt in dwEngine.packets {
                if pkt.from?.call.uppercased() == "K0EPI" && pkt.from?.ssid == 6 {
                    print("[TEST] Direwolf heard: \(pkt.from?.display ?? "?") > \(pkt.to?.display ?? "?") type=\(pkt.frameType.rawValue)")
                    sawOurFrame = true
                    break
                }
            }
            if sawOurFrame { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(sawOurFrame, "Direwolf should hear our SABM from K0EPI-6 over RF")

        // 5. Also check if TNC4 got the UA back (session connected via RF)
        let connected = await waitForSessionState(
            destination: destination, expectedState: .connected, timeout: 15.0)
        if connected {
            print("[TEST] TNC4 received UA — full RF round-trip confirmed")
        } else {
            print("[TEST] TNC4 did not receive UA within timeout")
        }
    }

    // MARK: - Test 8: TNC4 receives frame sent from Direwolf

    /// Dual-radio test: Direwolf (TCP) sends a UI frame on RF.
    /// TNC4 (local USB serial) should receive it via PacketEngine.
    /// This confirms the full RX pipeline: RF → TNC4 → KISS → PacketEngine → decoded packet.
    func testTNC4ReceivesFrameFromDirewolf() async throws {
        // 1. Connect TNC4
        setupFullStack()
        engine.connectUsingSettings()
        guard await waitForStatus(.connected, timeout: 10.0) else {
            XCTFail("Failed to connect to TNC4")
            return
        }
        try await Task.sleep(nanoseconds: 7_000_000_000) // KISS init + RESET

        // 2. Connect Direwolf
        let dwEngine = try await connectDirewolfEngine()
        defer { dwEngine.disconnect(reason: "Test teardown") }
        print("[TEST] Both TNC4 and Direwolf connected")

        // 3. Build a UI frame from K0EPI-7 to K0EPI-6 and send via Direwolf
        //    (This simulates K0EPI-7 sending unsolicited data)
        let source = AX25Address(call: "K0EPI", ssid: 7)
        let dest = AX25Address(call: "K0EPI", ssid: 6)
        let testPayload = "TEST FRAME FROM DIREWOLF \(Date())\r"
        let uiFrame = OutboundFrame(
            destination: dest,
            source: source,
            payload: Data(testPayload.utf8),
            frameType: "ui",
            controlByte: 0x03  // UI
        )
        dwEngine.send(frame: uiFrame)
        print("[TEST] Sent UI frame via Direwolf: '\(testPayload.prefix(40))'")

        // 4. Wait for TNC4 to receive the frame
        var sawFrame = false
        let rxDeadline = Date().addingTimeInterval(15.0)
        while Date() < rxDeadline {
            for pkt in engine.packets {
                if pkt.from?.call.uppercased() == "K0EPI" && pkt.from?.ssid == 7 {
                    print("[TEST] TNC4 received: \(pkt.from?.display ?? "?") > \(pkt.to?.display ?? "?") type=\(pkt.frameType.rawValue)")
                    sawFrame = true
                    break
                }
            }
            if sawFrame { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        XCTAssertTrue(sawFrame, "TNC4 should receive the UI frame sent by Direwolf over RF")
    }

    // MARK: - Test 9: Full dual-stack session — TNC4 + Direwolf monitor

    /// Complete integration test: TNC4 connects to K0EPI-7, sends data,
    /// receives response. Direwolf monitors the entire exchange from RF.
    /// This verifies the full AXTerm pipeline end-to-end with RF cross-verification.
    func testDualStackSessionWithMonitor() async throws {
        // 1. Connect Direwolf monitor
        let dwEngine = try await connectDirewolfEngine()
        defer { dwEngine.disconnect(reason: "Test teardown") }

        // 2. Connect TNC4 and establish session to K0EPI-7
        setupFullStack()
        engine.connectUsingSettings()
        guard await waitForStatus(.connected, timeout: 10.0) else {
            XCTFail("Failed to connect to TNC4")
            return
        }
        try await Task.sleep(nanoseconds: 7_000_000_000)

        let destination = AX25Address(call: "K0EPI", ssid: 7)
        let sessionManager = coordinator.sessionManager

        if let sabmFrame = sessionManager.connect(to: destination, path: DigiPath(), channel: 0) {
            engine.send(frame: sabmFrame)
        }

        guard await waitForSessionState(destination: destination, expectedState: .connected, timeout: 30.0) else {
            throw XCTSkip("Could not connect to K0EPI-7 (may be busy)")
        }
        print("[TEST] Connected to K0EPI-7 via TNC4")

        // 3. Track data from K0EPI-7
        var receivedData = Data()
        let prevCallback = sessionManager.onDataDeliveredForReassembly
        sessionManager.onDataDeliveredForReassembly = { session, data in
            prevCallback?(session, data)
            if session.remoteAddress.call.uppercased() == "K0EPI" && session.remoteAddress.ssid == 7 {
                receivedData.append(data)
                let text = String(data: data, encoding: .ascii) ?? "(binary)"
                print("[TEST] RX from K0EPI-7: \(text.prefix(80))")
            }
        }

        // 4. Wait for welcome, then send newline if needed
        try await Task.sleep(nanoseconds: 3_000_000_000)
        if receivedData.isEmpty {
            let iFrames = sessionManager.sendData(Data("\r".utf8), to: destination, path: DigiPath(), channel: 0, pid: 0xF0)
            for frame in iFrames { engine.send(frame: frame) }
        }

        let responseDeadline = Date().addingTimeInterval(15.0)
        while Date() < responseDeadline {
            if !receivedData.isEmpty { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertGreaterThan(receivedData.count, 0, "Should receive data from K0EPI-7")

        // 5. Check Direwolf saw the exchange
        let dwPacketCount = dwEngine.packets.count
        print("[TEST] Direwolf saw \(dwPacketCount) packets during the exchange")
        print("[TEST] TNC4 received \(receivedData.count) bytes from K0EPI-7")

        // Report all Direwolf-observed frames
        for pkt in dwEngine.packets {
            print("[TEST] DW: \(pkt.from?.display ?? "?") > \(pkt.to?.display ?? "?") type=\(pkt.frameType.rawValue)")
        }

        // 6. Disconnect
        let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
        if let discFrame = sessionManager.disconnect(session: session) {
            engine.send(frame: discFrame)
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
    }

    // MARK: - BPQ Command Tests via TNC4

    /// Helper: Connect TNC4 to K0EPI-7 and return the session manager.
    /// Sets up data capture callback and returns initial welcome text.
    private func connectToK0EPI7ForBPQ() async throws -> (AX25SessionManager, AX25Address, DataCapture) {
        setupFullStack()
        engine.connectUsingSettings()
        guard await waitForStatus(.connected, timeout: 10.0) else {
            throw XCTSkip("TNC4 not ready")
        }
        try await Task.sleep(nanoseconds: 7_000_000_000) // KISS init + RESET

        let destination = AX25Address(call: "K0EPI", ssid: 7)
        let sessionManager = coordinator.sessionManager

        if let sabmFrame = sessionManager.connect(to: destination, path: DigiPath(), channel: 0) {
            engine.send(frame: sabmFrame)
        }

        guard await waitForSessionState(destination: destination, expectedState: .connected, timeout: 30.0) else {
            throw XCTSkip("Cannot connect to K0EPI-7")
        }

        let capture = DataCapture()
        let prevCallback = sessionManager.onDataDeliveredForReassembly
        sessionManager.onDataDeliveredForReassembly = { session, data in
            prevCallback?(session, data)
            if session.remoteAddress.call.uppercased() == "K0EPI" && session.remoteAddress.ssid == 7 {
                capture.data.append(data)
            }
        }

        // Collect welcome text
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let welcomeText = String(data: capture.data, encoding: .ascii) ?? ""
        print("[BPQ] Welcome: \(welcomeText.prefix(120))")

        return (sessionManager, destination, capture)
    }

    /// Send a command to K0EPI-7 and wait for response text.
    private func sendBPQCommand(
        _ command: String,
        sessionManager: AX25SessionManager,
        destination: AX25Address,
        capture: DataCapture,
        timeout: TimeInterval = 15.0
    ) async -> String {
        // Clear previous data
        let beforeCount = capture.data.count

        let cmdData = Data("\(command)\r".utf8)
        let iFrames = sessionManager.sendData(cmdData, to: destination, path: DigiPath(), channel: 0, pid: 0xF0)
        for frame in iFrames {
            engine.send(frame: frame)
        }

        // Wait for new data
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if capture.data.count > beforeCount { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // Extract response (everything after the command was sent)
        let responseData = capture.data.suffix(from: beforeCount)
        return String(data: responseData, encoding: .ascii) ?? "(binary \(responseData.count) bytes)"
    }

    /// Disconnect from K0EPI-7.
    private func disconnectFromK0EPI7(sessionManager: AX25SessionManager, destination: AX25Address) async {
        let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
        if let discFrame = sessionManager.disconnect(session: session) {
            engine.send(frame: discFrame)
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    // MARK: - Test 10: BPQ NODES command

    /// Connect to K0EPI-7 via TNC4 and send the NODES command.
    /// LinBPQ should respond with a list of known nodes.
    func testBPQNodesCommand() async throws {
        let (sessionManager, destination, capture) = try await connectToK0EPI7ForBPQ()
        defer { Task { await disconnectFromK0EPI7(sessionManager: sessionManager, destination: destination) } }

        let response = await sendBPQCommand("NODES", sessionManager: sessionManager, destination: destination, capture: capture)
        print("[BPQ] NODES response: \(response.prefix(200))")

        XCTAssertFalse(response.isEmpty, "NODES command should return a response")
        // LinBPQ NODES output typically contains node callsigns
        // At minimum, K0EPI-7 should list itself or known routes
    }

    // MARK: - Test 11: BPQ INFO command

    /// Connect to K0EPI-7 and send the INFO command.
    /// Should return the INFOMSG from bpq32.cfg.
    func testBPQInfoCommand() async throws {
        let (sessionManager, destination, capture) = try await connectToK0EPI7ForBPQ()
        defer { Task { await disconnectFromK0EPI7(sessionManager: sessionManager, destination: destination) } }

        let response = await sendBPQCommand("INFO", sessionManager: sessionManager, destination: destination, capture: capture)
        print("[BPQ] INFO response: \(response.prefix(300))")

        XCTAssertFalse(response.isEmpty, "INFO command should return a response")
        // The INFOMSG in bpq32.cfg mentions "K0EPI LinBPQ Node"
        XCTAssertTrue(
            response.uppercased().contains("K0EPI") || response.contains("LinBPQ") || response.contains("Denver"),
            "INFO should contain K0EPI or LinBPQ or Denver (from INFOMSG config)"
        )
    }

    // MARK: - Test 12: BPQ PORTS command

    /// Send PORTS command — lists available BPQ ports.
    func testBPQPortsCommand() async throws {
        let (sessionManager, destination, capture) = try await connectToK0EPI7ForBPQ()
        defer { Task { await disconnectFromK0EPI7(sessionManager: sessionManager, destination: destination) } }

        let response = await sendBPQCommand("PORTS", sessionManager: sessionManager, destination: destination, capture: capture)
        print("[BPQ] PORTS response: \(response.prefix(300))")

        XCTAssertFalse(response.isEmpty, "PORTS command should return a response")
    }

    // MARK: - Test 13: BPQ MHEARD command

    /// Send MHEARD command — shows recently heard stations.
    func testBPQMheardCommand() async throws {
        let (sessionManager, destination, capture) = try await connectToK0EPI7ForBPQ()
        defer { Task { await disconnectFromK0EPI7(sessionManager: sessionManager, destination: destination) } }

        let response = await sendBPQCommand("MHEARD", sessionManager: sessionManager, destination: destination, capture: capture)
        print("[BPQ] MHEARD response: \(response.prefix(400))")

        XCTAssertFalse(response.isEmpty, "MHEARD command should return a response")
        // We just connected from K0EPI-6, so it should appear in MHEARD
    }

    // MARK: - Test 14: BPQ USERS command

    /// Send USERS command — shows connected users.
    func testBPQUsersCommand() async throws {
        let (sessionManager, destination, capture) = try await connectToK0EPI7ForBPQ()
        defer { Task { await disconnectFromK0EPI7(sessionManager: sessionManager, destination: destination) } }

        let response = await sendBPQCommand("USERS", sessionManager: sessionManager, destination: destination, capture: capture)
        print("[BPQ] USERS response: \(response.prefix(300))")

        XCTAssertFalse(response.isEmpty, "USERS command should return a response")
        // We should see ourselves listed as a connected user
    }
}

// MARK: - Data Capture Helper

/// Thread-safe data accumulator for test callbacks.
@MainActor
private final class DataCapture {
    var data = Data()
}
