//
//  DRLNODLiveTest.swift
//  AXTermTests
//
//  Live TCP integration test: connect to DRLNOD (KE0NCQ) at 100.77.243.13:8001,
//  wait for the welcome banner, then send "Help" and observe what happens.
//
//  This test is specifically designed to reproduce and diagnose the disconnect
//  that occurs when sending a command to DRLNOD after connection.
//
//  SETUP:
//    touch /tmp/axterm_net_tests_enabled
//
//  RUN:
//    Scripts/run-drlnod-test.sh
//    — or —
//    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//      xcodebuild test -scheme AXTerm -destination "platform=macOS" \
//      -only-testing:AXTermTests/DRLNODLiveTest/testConnectAndSendHelp
//
//  Disable when done:
//    rm /tmp/axterm_net_tests_enabled
//

import XCTest
import Combine
@testable import AXTerm

@MainActor
final class DRLNODLiveTest: XCTestCase {

    // MARK: - Configuration

    private let drlnodHost = "100.77.243.13"
    private let drlnodPort: UInt16 = 8001
    private let destination = AX25Address(call: "DRLNOD", ssid: 0)

    /// Test callsign. Defaults to the user's live station identity from the
    /// DRLNOD failure trace, but can be overridden for supervised experiments.
    private let localCallsign = ProcessInfo.processInfo.environment["AXTERM_DRLNOD_LOCAL_CALLSIGN"] ?? "K0EPI-7"

    // MARK: - Shared State

    private var settings: AppSettingsStore!
    private var engine: PacketEngine!
    private var coordinator: SessionCoordinator!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()

        guard FileManager.default.fileExists(atPath: "/tmp/axterm_net_tests_enabled") else {
            throw XCTSkip("Network tests disabled — touch /tmp/axterm_net_tests_enabled to enable")
        }

        let suiteName = "AXTermTests.DRLNODLive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = localCallsign

        engine = PacketEngine(settings: settings)
        coordinator = SessionCoordinator()
        coordinator.localCallsign = localCallsign
        coordinator.subscribeToPackets(from: engine)
    }

    override func tearDown() {
        engine?.disconnect(reason: "DRLNOD test teardown")
        engine = nil
        coordinator = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Test: Connect and Send Help (immediate — baseline)

    /// Baseline: send Help immediately after banner. Should always pass.
    func testConnectAndSendHelp() async throws {
        try await connectAndSendHelp(delayAfterBanner: 0)
    }

    /// Replays the live failure shape from 2026-05-28 05:43:
    /// SABM, UA, a short human-scale pause, then "Help\r" without waiting for
    /// any banner. This is the minimum on-air test for the DRLNOD disconnect.
    func testConnectThenSendHelpAfterUAWith3sDelay() async throws {
        try await connectThenSendHelpAfterUA(delayAfterUA: 3.0)
    }

    /// Replays the full user-reported DRLNOD command sequence:
    /// connect, send "Help\r", wait for DRLNOD's command prompt, then send
    /// "c kb5yzb-7\r" and verify DRLNOD does not immediately DM/disconnect us.
    func testConnectHelpThenConnectKB5YZB7() async throws {
        try await connectHelpThenCommand(
            secondCommand: "c kb5yzb-7\r",
            secondCommandLabel: "c kb5yzb-7"
        )
    }

    // MARK: - Test: Connect and Send Help (typing delay — reproduces user scenario)

    /// Simulates human typing delay after banner: waits 4s before sending "Help".
    /// If DRLNOD's idle timer is ~13s from banner send, this should still pass.
    /// If it fails, DRLNOD is disconnecting us before we can respond — confirms timing issue.
    func testConnectAndSendHelpWith4sDelay() async throws {
        try await connectAndSendHelp(delayAfterBanner: 4.0)
    }

    /// Simulates a slower typist: waits 8s before sending "Help".
    /// This is the boundary case — if DRLNOD's timer is ~13s, 8s should still pass.
    func testConnectAndSendHelpWith8sDelay() async throws {
        try await connectAndSendHelp(delayAfterBanner: 8.0)
    }

    /// Worst-case: waits 12s before sending "Help".
    /// If DRLNOD's timer is ~13s from banner, this should barely pass (1s margin).
    /// If it fails, confirms the idle timer is tighter than 12s.
    func testConnectAndSendHelpWith12sDelay() async throws {
        try await connectAndSendHelp(delayAfterBanner: 12.0)
    }


    // MARK: - Shared: Connect + (optional delay) + Send Help

    private func connectAndSendHelp(delayAfterBanner: TimeInterval) async throws {

        // ── 1. Open TCP KISS link ──────────────────────────────────────────
        diag("Connecting to \(drlnodHost):\(drlnodPort)...")
        engine.connect(host: drlnodHost, port: drlnodPort)

        guard await waitForStatus(.connected, timeout: 10.0) else {
            throw XCTSkip("Cannot reach \(drlnodHost):\(drlnodPort) — is the TNC/direwolf online?")
        }
        diag("TCP KISS link connected at \(timestamp())")

        // ── 2. Wire session-state and data callbacks BEFORE sending SABM ──
        let sessionManager = coordinator.sessionManager
        var receivedData    = Data()
        var stateLog        = [(when: Date, old: String, new: String)]()

        let prevDataCB  = sessionManager.onDataDeliveredForReassembly
        let prevStateCB = sessionManager.onSessionStateChanged

        sessionManager.onDataDeliveredForReassembly = { [weak self] session, data in
            prevDataCB?(session, data)
            guard session.remoteAddress.call.uppercased() == "DRLNOD" else { return }
            receivedData.append(data)
            let text = String(data: data, encoding: .ascii) ?? "(binary \(data.count) B)"
            self?.diag("RX [\(self?.timestamp() ?? "?")]: \(Self.escape(text))")
        }

        sessionManager.onSessionStateChanged = { [weak self] session, old, new in
            prevStateCB?(session, old, new)
            guard session.remoteAddress.call.uppercased() == "DRLNOD" else { return }
            let entry = (when: Date(), old: old.rawValue, new: new.rawValue)
            stateLog.append(entry)
            self?.diag("STATE [\(self?.timestamp() ?? "?")]: \(old.rawValue) → \(new.rawValue)")
        }

        // ── 3. Send SABM ──────────────────────────────────────────────────
        let sabmFrame = sessionManager.connect(to: destination, path: DigiPath(), channel: 0)
        XCTAssertNotNil(sabmFrame, "connect() must return a SABM frame")
        if let frame = sabmFrame { engine.send(frame: frame) }
        let t_sabm = Date()
        diag("SABM sent at \(timestamp(t_sabm))")

        // ── 4. Wait for UA ─────────────────────────────────────────────────
        guard await waitForSessionState(expectedState: .connected, sessionManager: sessionManager, timeout: 30.0) else {
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            diag("FAIL: No UA after 30s — state=\(session.state.rawValue)")
            flushLog()
            XCTFail("Session did not reach .connected within 30s")
            return
        }
        let t_ua = Date()
        diag("UA received — connected. RTT=\(String(format: "%.3f", t_ua.timeIntervalSince(t_sabm)))s at \(timestamp(t_ua))")

        // ── 5. Wait for welcome banner ─────────────────────────────────────
        diag("Waiting for welcome banner (up to 45s)...")
        var bannerReceived = false
        var t_banner       = Date()

        let bannerDeadline = Date().addingTimeInterval(45.0)
        while Date() < bannerDeadline {
            // Check for banner keywords
            let text = String(data: receivedData, encoding: .ascii) ?? ""
            if text.uppercased().contains("ENTER COMMAND")
                || text.uppercased().contains("HELP")
                || text.count > 20 {
                bannerReceived = true
                t_banner = Date()
                break
            }

            // Premature disconnect?
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            if session.state == .disconnected {
                diag("PREMATURE DISCONNECT before banner! elapsed=\(String(format: "%.3f", Date().timeIntervalSince(t_ua)))s")
                diag("Data so far (\(receivedData.count) bytes): '\(Self.escape(String(data: receivedData, encoding: .ascii) ?? ""))'")
                flushLog()
                XCTFail("Disconnected before banner arrived")
                return
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }

        guard bannerReceived else {
            let text = String(data: receivedData, encoding: .ascii) ?? "(none)"
            diag("Banner timeout after 45s. Received: '\(text.prefix(200))'")
            flushLog()
            XCTFail("Did not receive banner from DRLNOD within 45s")
            return
        }

        let bannerText = String(data: receivedData, encoding: .ascii) ?? ""
        diag("Banner received at \(timestamp(t_banner)) (+\(String(format: "%.3f", t_banner.timeIntervalSince(t_ua)))s after UA)")
        diag("Full banner:\n\(bannerText)")

        // ── 5b. Simulate typing delay (if requested) ──────────────────────
        if delayAfterBanner > 0 {
            diag("Simulating \(String(format: "%.1f", delayAfterBanner))s typing delay before sending Help...")
            let delayNs = UInt64(delayAfterBanner * 1_000_000_000)
            // Poll for premature disconnect every 100ms during the wait
            let delayDeadline = Date().addingTimeInterval(delayAfterBanner)
            while Date() < delayDeadline {
                let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
                if session.state == .disconnected {
                    let elapsedSinceBanner = Date().timeIntervalSince(t_banner)
                    diag("PREMATURE DISCONNECT during typing delay at +\(String(format: "%.3f", elapsedSinceBanner))s after banner!")
                    diag("DRLNOD idle timer appears to be ~\(String(format: "%.1f", elapsedSinceBanner))s from banner send.")
                    flushLog()
                    XCTFail("DRLNOD disconnected after \(String(format: "%.1f", elapsedSinceBanner))s — before Help was sent. Idle timer too short.")
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            _ = delayNs
            diag("Typing delay complete. Sending Help now.")
        }

        // ── 6. Send "Help\r" ───────────────────────────────────────────────
        let helpPayload = Data("Help\r".utf8)
        let t_help_sent = Date()
        let iFrames = sessionManager.sendData(
            helpPayload,
            to: destination,
            path: DigiPath(),
            channel: 0,
            pid: 0xF0
        )
        XCTAssertFalse(iFrames.isEmpty, "sendData must produce at least one I-frame")
        for frame in iFrames { engine.send(frame: frame) }
        let elapsed_to_send = t_help_sent.timeIntervalSince(t_banner)
        diag("Sent 'Help\\r' (\(helpPayload.count) bytes, \(iFrames.count) I-frame(s)) at \(timestamp(t_help_sent)) (+\(String(format: "%.3f", elapsed_to_send))s after banner)")

        // ── 7. Monitor for response or disconnect ──────────────────────────
        let beforeHelpCount = receivedData.count
        var gotResponse     = false
        var t_final         = t_help_sent
        var finalState      = "unknown"

        let monitorDeadline = Date().addingTimeInterval(60.0)
        var lastLoggedElapsed = -1

        while Date() < monitorDeadline {
            let elapsed = Int(Date().timeIntervalSince(t_help_sent))
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            finalState = session.state.rawValue

            // Log every second so we can see T1 firings from the timing
            if elapsed != lastLoggedElapsed {
                lastLoggedElapsed = elapsed
                let curBytesNew = receivedData.count - beforeHelpCount
                diag("t+\(elapsed)s  state=\(session.state.rawValue)  newBytes=\(curBytesNew)")
            }

            // Got a response?
            if receivedData.count > beforeHelpCount {
                let newData = receivedData.suffix(from: beforeHelpCount)
                let newText = String(data: newData, encoding: .ascii) ?? "(binary \(newData.count) B)"
                diag("RESPONSE to Help [\(timestamp())]: '\(newText.prefix(400))'")
                gotResponse = true
                t_final = Date()
                break
            }

            // Disconnected?
            if session.state == .disconnected {
                t_final = Date()
                let elapsed_disc = t_final.timeIntervalSince(t_help_sent)
                diag("DISCONNECTED at \(timestamp(t_final)) — \(String(format: "%.3f", elapsed_disc))s after sending Help")
                diag("Banner-to-send=\(String(format: "%.3f", elapsed_to_send))s, send-to-disconnect=\(String(format: "%.3f", elapsed_disc))s")

                // Determine likely cause
                if elapsed_disc < 1.0 {
                    diag("LIKELY CAUSE: DM received immediately — node refused the data frame")
                } else if elapsed_disc < 7.0 {
                    diag("LIKELY CAUSE: DM received before T1 fired (T1≈6.3s) — node disconnected while ACK was in flight")
                } else if elapsed_disc < 14.0 {
                    diag("LIKELY CAUSE: T1 fired (no ACK in ~6.3s), retransmit sent, then DM — node idle timer expired")
                } else {
                    diag("LIKELY CAUSE: Multiple T1 retransmits exhausted — node unreachable or timer expired")
                }
                break
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }

        // ── 8. Final report ────────────────────────────────────────────────
        diag("=== FINAL REPORT ===")
        diag("Local callsign    : \(localCallsign)")
        diag("Destination       : \(destination.display)")
        diag("Typing delay      : \(delayAfterBanner > 0 ? String(format: "%.1fs", delayAfterBanner) : "none (immediate)")")
        diag("SABM→UA RTT       : \(String(format: "%.3f", t_ua.timeIntervalSince(t_sabm)))s")
        diag("UA→banner         : \(String(format: "%.3f", t_banner.timeIntervalSince(t_ua)))s")
        diag("banner→Help sent  : \(String(format: "%.3f", elapsed_to_send))s")
        diag("Help sent→final   : \(String(format: "%.3f", t_final.timeIntervalSince(t_help_sent)))s")
        diag("Final state       : \(finalState)")
        diag("Got response      : \(gotResponse)")
        diag("Total RX bytes    : \(receivedData.count)")

        diag("State transitions:")
        for entry in stateLog {
            diag("  \(entry.old) → \(entry.new)")
        }

        let fullText = String(data: receivedData, encoding: .ascii) ?? "(binary)"
        diag("Full received text:\n\(fullText)")

        // ── 9. Clean disconnect ────────────────────────────────────────────
        let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
        if session.state == .connected, let discFrame = sessionManager.disconnect(session: session) {
            engine.send(frame: discFrame)
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }

        // ── 10. Dump log and assert ────────────────────────────────────────
        flushLog()
        XCTAssertTrue(
            gotResponse,
            "Expected a response to 'Help' from DRLNOD but the session was disconnected. " +
            "Final state: \(finalState). " +
            "See NSLog output for timing analysis."
        )
    }

    private func connectThenSendHelpAfterUA(delayAfterUA: TimeInterval) async throws {
        diag("Connecting to \(drlnodHost):\(drlnodPort)...")
        engine.connect(host: drlnodHost, port: drlnodPort)

        guard await waitForStatus(.connected, timeout: 10.0) else {
            throw XCTSkip("Cannot reach \(drlnodHost):\(drlnodPort) — is the TNC/direwolf online?")
        }
        diag("TCP KISS link connected at \(timestamp())")

        let sessionManager = coordinator.sessionManager
        var receivedData = Data()
        var stateLog = [(when: Date, old: String, new: String)]()

        let prevDataCB = sessionManager.onDataDeliveredForReassembly
        let prevStateCB = sessionManager.onSessionStateChanged
        sessionManager.onDataDeliveredForReassembly = { [weak self] session, data in
            prevDataCB?(session, data)
            guard session.remoteAddress.call.uppercased() == "DRLNOD" else { return }
            receivedData.append(data)
            let text = String(data: data, encoding: .ascii) ?? "(binary \(data.count) B)"
            self?.diag("RX [\(self?.timestamp() ?? "?")]: \(Self.escape(text))")
        }
        sessionManager.onSessionStateChanged = { [weak self] session, old, new in
            prevStateCB?(session, old, new)
            guard session.remoteAddress.call.uppercased() == "DRLNOD" else { return }
            stateLog.append((when: Date(), old: old.rawValue, new: new.rawValue))
            self?.diag("STATE [\(self?.timestamp() ?? "?")]: \(old.rawValue) → \(new.rawValue)")
        }

        let sabmFrame = sessionManager.connect(to: destination, path: DigiPath(), channel: 0)
        XCTAssertNotNil(sabmFrame, "connect() must return a SABM frame")
        if let frame = sabmFrame { engine.send(frame: frame) }
        let tSABM = Date()
        diag("SABM sent at \(timestamp(tSABM)) as \(localCallsign)")

        guard await waitForSessionState(expectedState: .connected, sessionManager: sessionManager, timeout: 30.0) else {
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            diag("FAIL: No UA after 30s — state=\(session.state.rawValue)")
            flushLog()
            XCTFail("Session did not reach .connected within 30s")
            return
        }
        let tUA = Date()
        diag("UA received — connected. RTT=\(String(format: "%.3f", tUA.timeIntervalSince(tSABM)))s at \(timestamp(tUA))")

        if delayAfterUA > 0 {
            diag("Waiting \(String(format: "%.1f", delayAfterUA))s after UA before Help...")
            try await Task.sleep(nanoseconds: UInt64(delayAfterUA * 1_000_000_000))
        }

        let payload = Data("Help\r".utf8)
        let beforeHelpCount = receivedData.count
        let tHelp = Date()
        let frames = sessionManager.sendData(payload, to: destination, path: DigiPath(), channel: 0, pid: 0xF0)
        XCTAssertFalse(frames.isEmpty, "sendData must produce at least one I-frame")
        for frame in frames {
            let ctl = frame.controlByte.map { String(format: "0x%02X", $0) } ?? "nil"
            diag("TX Help I-frame: type=\(frame.frameType) ns=\(frame.ns.map(String.init) ?? "nil") nr=\(frame.nr.map(String.init) ?? "nil") ctl=\(ctl) payload=\(frame.payload.count)B")
            engine.send(frame: frame)
        }
        diag("Sent 'Help\\r' at \(timestamp(tHelp)) (+\(String(format: "%.3f", tHelp.timeIntervalSince(tUA)))s after UA)")

        var gotResponse = false
        var disconnected = false
        var finalState = "unknown"
        let monitorDeadline = Date().addingTimeInterval(20.0)
        var lastLoggedElapsed = -1
        while Date() < monitorDeadline {
            let elapsed = Int(Date().timeIntervalSince(tHelp))
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            finalState = session.state.rawValue

            if elapsed != lastLoggedElapsed {
                lastLoggedElapsed = elapsed
                diag("t+\(elapsed)s state=\(session.state.rawValue) outstanding=\(session.outstandingCount) va=\(session.va) vs=\(session.vs) vr=\(session.vr) rxNew=\(receivedData.count - beforeHelpCount)")
            }

            if receivedData.count > beforeHelpCount {
                let newData = receivedData.suffix(from: beforeHelpCount)
                let text = String(data: newData, encoding: .ascii) ?? "(binary \(newData.count) B)"
                diag("RESPONSE to Help [\(timestamp())]: '\(Self.escape(String(text.prefix(400))))'")
                gotResponse = true
                break
            }

            if session.state == .disconnected {
                disconnected = true
                diag("DISCONNECTED at \(timestamp()) — \(String(format: "%.3f", Date().timeIntervalSince(tHelp)))s after Help")
                break
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        diag("=== FINAL REPORT ===")
        diag("Local callsign    : \(localCallsign)")
        diag("Destination       : \(destination.display)")
        diag("SABM→UA RTT       : \(String(format: "%.3f", tUA.timeIntervalSince(tSABM)))s")
        diag("UA→Help sent      : \(String(format: "%.3f", tHelp.timeIntervalSince(tUA)))s")
        diag("Final state       : \(finalState)")
        diag("Got response      : \(gotResponse)")
        diag("Disconnected      : \(disconnected)")
        diag("Total RX bytes    : \(receivedData.count)")
        diag("State transitions:")
        for entry in stateLog {
            diag("  \(entry.old) → \(entry.new)")
        }
        diag("Full received text:\n\(String(data: receivedData, encoding: .ascii) ?? "(binary)")")

        let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
        if session.state == .connected, let discFrame = sessionManager.disconnect(session: session) {
            engine.send(frame: discFrame)
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }

        flushLog()
        XCTAssertFalse(disconnected, "DRLNOD disconnected after Help; see DRLNOD log for wire timing")
    }

    private func connectHelpThenCommand(
        secondCommand: String,
        secondCommandLabel: String
    ) async throws {
        diag("Connecting to \(drlnodHost):\(drlnodPort)...")
        engine.connect(host: drlnodHost, port: drlnodPort)

        guard await waitForStatus(.connected, timeout: 10.0) else {
            throw XCTSkip("Cannot reach \(drlnodHost):\(drlnodPort) — is the TNC/direwolf online?")
        }
        diag("TCP KISS link connected at \(timestamp())")

        let sessionManager = coordinator.sessionManager
        var receivedData = Data()
        var stateLog = [(when: Date, old: String, new: String)]()

        let prevDataCB = sessionManager.onDataDeliveredForReassembly
        let prevStateCB = sessionManager.onSessionStateChanged
        sessionManager.onDataDeliveredForReassembly = { [weak self] session, data in
            prevDataCB?(session, data)
            guard session.remoteAddress.call.uppercased() == "DRLNOD" else { return }
            receivedData.append(data)
            let text = String(data: data, encoding: .ascii) ?? "(binary \(data.count) B)"
            self?.diag("RX [\(self?.timestamp() ?? "?")]: \(Self.escape(text))")
        }
        sessionManager.onSessionStateChanged = { [weak self] session, old, new in
            prevStateCB?(session, old, new)
            guard session.remoteAddress.call.uppercased() == "DRLNOD" else { return }
            stateLog.append((when: Date(), old: old.rawValue, new: new.rawValue))
            self?.diag("STATE [\(self?.timestamp() ?? "?")]: \(old.rawValue) → \(new.rawValue)")
        }

        let sabmFrame = sessionManager.connect(to: destination, path: DigiPath(), channel: 0)
        XCTAssertNotNil(sabmFrame, "connect() must return a SABM frame")
        if let frame = sabmFrame { engine.send(frame: frame) }
        let tSABM = Date()
        diag("SABM sent at \(timestamp(tSABM)) as \(localCallsign)")

        guard await waitForSessionState(expectedState: .connected, sessionManager: sessionManager, timeout: 30.0) else {
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            diag("FAIL: No UA after 30s — state=\(session.state.rawValue)")
            flushLog()
            XCTFail("Session did not reach .connected within 30s")
            return
        }
        let tUA = Date()
        diag("UA received — connected. RTT=\(String(format: "%.3f", tUA.timeIntervalSince(tSABM)))s at \(timestamp(tUA))")

        try await Task.sleep(nanoseconds: 3_000_000_000)

        let beforeHelpCount = receivedData.count
        let tHelp = Date()
        try sendCommand(Data("Help\r".utf8), label: "Help", via: sessionManager)
        diag("Sent 'Help\\r' at \(timestamp(tHelp)) (+\(String(format: "%.3f", tHelp.timeIntervalSince(tUA)))s after UA)")

        let helpOutcome = await waitForAckOrNewData(
            after: beforeHelpCount,
            receivedData: { receivedData },
            sessionManager: sessionManager,
            timeout: 12.0,
            context: "Help response"
        )

        guard helpOutcome != .disconnected else {
            flushLog()
            XCTFail("DRLNOD disconnected before the second command could be sent")
            return
        }

        if receivedData.count > beforeHelpCount {
            let helpResponse = receivedData.suffix(from: beforeHelpCount)
            diag("RESPONSE to Help [\(timestamp())]: '\(Self.escape(String(data: helpResponse, encoding: .ascii) ?? "(binary \(helpResponse.count) B)"))'")
        } else {
            diag("No text response to Help before second command; continuing after ACK/settle to reproduce typed sequence.")
        }

        let beforeSecondCount = receivedData.count
        let tSecond = Date()
        try sendCommand(Data(secondCommand.utf8), label: secondCommandLabel, via: sessionManager)
        diag("Sent '\(secondCommandLabel)\\r' at \(timestamp(tSecond)) (+\(String(format: "%.3f", tSecond.timeIntervalSince(tHelp)))s after Help)")

        var gotSecondResponse = false
        var disconnected = false
        var finalState = "unknown"
        let monitorDeadline = Date().addingTimeInterval(35.0)
        var lastLoggedElapsed = -1

        while Date() < monitorDeadline {
            let elapsed = Int(Date().timeIntervalSince(tSecond))
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            finalState = session.state.rawValue

            if elapsed != lastLoggedElapsed {
                lastLoggedElapsed = elapsed
                diag("post-command t+\(elapsed)s state=\(session.state.rawValue) outstanding=\(session.outstandingCount) va=\(session.va) vs=\(session.vs) vr=\(session.vr) rxNew=\(receivedData.count - beforeSecondCount)")
            }

            if receivedData.count > beforeSecondCount {
                let newData = receivedData.suffix(from: beforeSecondCount)
                let text = String(data: newData, encoding: .ascii) ?? "(binary \(newData.count) B)"
                diag("RESPONSE to \(secondCommandLabel) [\(timestamp())]: '\(Self.escape(String(text.prefix(800))))'")
                gotSecondResponse = true
                break
            }

            if session.state == .disconnected {
                disconnected = true
                diag("DISCONNECTED at \(timestamp()) — \(String(format: "%.3f", Date().timeIntervalSince(tSecond)))s after \(secondCommandLabel)")
                break
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        diag("=== FINAL REPORT ===")
        diag("Local callsign       : \(localCallsign)")
        diag("Destination          : \(destination.display)")
        diag("Command sequence     : Help -> \(secondCommandLabel)")
        diag("SABM→UA RTT          : \(String(format: "%.3f", tUA.timeIntervalSince(tSABM)))s")
        diag("UA→Help sent         : \(String(format: "%.3f", tHelp.timeIntervalSince(tUA)))s")
        diag("Help→second sent     : \(String(format: "%.3f", tSecond.timeIntervalSince(tHelp)))s")
        diag("Second response      : \(gotSecondResponse)")
        diag("Disconnected         : \(disconnected)")
        diag("Final state          : \(finalState)")
        diag("Total RX bytes       : \(receivedData.count)")
        diag("State transitions:")
        for entry in stateLog {
            diag("  \(entry.old) → \(entry.new)")
        }
        diag("Full received text:\n\(String(data: receivedData, encoding: .ascii) ?? "(binary)")")

        let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
        if session.state == .connected, let discFrame = sessionManager.disconnect(session: session) {
            engine.send(frame: discFrame)
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }

        flushLog()
        XCTAssertFalse(disconnected, "DRLNOD disconnected after \(secondCommandLabel); see DRLNOD log for wire timing")
    }

    private func sendCommand(
        _ payload: Data,
        label: String,
        via sessionManager: AX25SessionManager
    ) throws {
        let frames = sessionManager.sendData(payload, to: destination, path: DigiPath(), channel: 0, pid: 0xF0)
        XCTAssertFalse(frames.isEmpty, "\(label) must produce at least one I-frame")
        for frame in frames {
            let ctl = frame.controlByte.map { String(format: "0x%02X", $0) } ?? "nil"
            let ns = frame.ns.map(String.init) ?? "nil"
            let nr = frame.nr.map(String.init) ?? "nil"
            diag("TX \(label) I-frame: type=\(frame.frameType) ns=\(ns) nr=\(nr) ctl=\(ctl) payload=\(frame.payload.count)B")
            engine.send(frame: frame)
        }
    }

    private enum CommandWaitOutcome {
        case newData
        case ackedOrSettled
        case disconnected
        case timedOut
    }

    private func waitForAckOrNewData(
        after byteCount: Int,
        receivedData: () -> Data,
        sessionManager: AX25SessionManager,
        timeout: TimeInterval,
        context: String
    ) async -> CommandWaitOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLoggedElapsed = -1
        var ackedAt: Date?

        while Date() < deadline {
            let elapsed = Int(timeout - deadline.timeIntervalSinceNow)
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)

            if elapsed != lastLoggedElapsed {
                lastLoggedElapsed = elapsed
                diag("\(context) t+\(elapsed)s state=\(session.state.rawValue) outstanding=\(session.outstandingCount) va=\(session.va) vs=\(session.vs) vr=\(session.vr) rxNew=\(receivedData().count - byteCount)")
            }

            if receivedData().count > byteCount {
                return .newData
            }

            if session.outstandingCount == 0 {
                if ackedAt == nil {
                    ackedAt = Date()
                    diag("\(context) ACK/settled: va=\(session.va) vs=\(session.vs) outstanding=0")
                } else if let ackedAt, Date().timeIntervalSince(ackedAt) >= 3.0 {
                    return .ackedOrSettled
                }
            }

            if session.state == .disconnected {
                diag("DISCONNECTED while waiting for \(context)")
                return .disconnected
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        diag("TIMEOUT waiting for \(context)")
        return .timedOut
    }

    // MARK: - Helpers

    /// Formatted timestamp for log lines (HH:MM:SS.mmm).
    private func timestamp(_ date: Date = Date()) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour,        from: date)
        let m = cal.component(.minute,      from: date)
        let s = cal.component(.second,      from: date)
        let ms = Int((date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// Make control characters visible in log output.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "↵")
            .replacingOccurrences(of: "\r",   with: "↵")
            .replacingOccurrences(of: "\n",   with: "↵")
    }

    // Log accumulator — dumped as XCTAttachment at test end.
    private var logLines: [String] = []
    // NSTemporaryDirectory() returns the process-specific temp dir that is always writable
    private let logPath = NSTemporaryDirectory() + "axterm_drlnod_\(Int(Date().timeIntervalSince1970)).log"

    /// Accumulate log lines and flush to file.
    private func diag(_ msg: String) {
        let stamped = "[DRLNOD] \(msg)"
        logLines.append(stamped)
        // Append to file immediately so it's readable even if test crashes
        let line = stamped + "\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: logPath)
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = try? FileHandle(forUpdating: url) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: url, options: [])
            }
        }
    }

    /// Call at the end of each test to attach the log and print the path.
    private func flushLog() {
        let fullLog = logLines.joined(separator: "\n")
        // Attach as XCTAttachment so it appears in result bundle
        let attachment = XCTAttachment(string: fullLog)
        attachment.name = "DRLNOD-Session-Log"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Print the log path so it can be found on disk
        let logURL = URL(fileURLWithPath: logPath)
        print("\n▶▶▶ DRLNOD LOG PATH: \(logPath) ◀◀◀\n\(fullLog)\n")
        // Copy to a predictable path as well
        let fixed = "/Users/rwardrup/axterm_drlnod_last.log"
        try? fullLog.write(toFile: fixed, atomically: true, encoding: .utf8)
        print("▶▶▶ ALSO WRITTEN TO: \(fixed) ◀◀◀")
        _ = logURL  // suppress unused warning
    }

    /// Poll until PacketEngine reaches the target status.
    private func waitForStatus(_ target: ConnectionStatus, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.status == target { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return engine.status == target
    }

    /// Poll until the DRLNOD session reaches the expected state.
    private func waitForSessionState(
        expectedState: AX25SessionState,
        sessionManager: AX25SessionManager,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let session = sessionManager.session(for: destination, path: DigiPath(), channel: 0)
            if session.state == expectedState { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
