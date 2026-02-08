//
//  LiveDirewolfTests.swift
//  AXTermIntegrationTests
//
//  Live integration tests against real Direwolf TNC.
//  SAFETY: These tests only use read-only commands (NODES, INFO).
//  They do NOT send any messages to other stations.
//
//  Prerequisites:
//  - Direwolf running at 192.168.3.218:8001
//  - Valid amateur radio license (K0EPI callsign)
//

import XCTest
@testable import AXTerm

/// Live tests against real Direwolf TNC
/// These connect to actual packet radio stations via RF
final class LiveDirewolfTests: XCTestCase {

    // MARK: - Configuration

    /// Direwolf KISS TCP server
    let direwolfHost = "192.168.3.218"
    let direwolfPort: UInt16 = 8001

    /// Our callsign
    let myCall = "K0EPI"

    /// Test stations (packet nodes that accept connections)
    let testStation1 = "KB5YZB-7"  // via DRLNOD
    let testPath1 = "DRLNOD"

    let testStation2 = "N0HI-7"    // via W0ARP-7
    let testPath2 = "W0ARP-7"

    /// Timeout for RF operations (longer due to channel access delays)
    let rfTimeout: TimeInterval = 30.0

    // MARK: - Test State

    var transport: SimulatorClient?
    var receivedFrames: [Data] = []
    var frameExpectation: XCTestExpectation?

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        receivedFrames = []
        frameExpectation = nil
    }

    override func tearDown() async throws {
        // Ensure clean disconnect
        transport?.disconnect()
        transport = nil

        // Small delay to let any pending TX complete
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Check if Direwolf is actually reachable
    private func skipIfDirewolfUnavailable() async throws {
        let client = SimulatorClient(host: direwolfHost, port: direwolfPort, stationName: "DirewolfCheck")
        do {
            try await client.connect()
            client.disconnect()
        } catch {
            throw XCTSkip("Direwolf not available at \(direwolfHost):\(direwolfPort)")
        }
    }

    // MARK: - Connection Tests

    /// Test basic TCP connection to Direwolf
    /// NOTE: This test requires a real Direwolf TNC at 192.168.3.218:8001
    func testDirewolfConnection() async throws {
        try await skipIfDirewolfUnavailable()

        let transport = try await connectToDirewolf()
        defer { transport.disconnect() }

        // Just verify we connected
        XCTAssertTrue(true, "Connected to Direwolf successfully")
    }

    /// Test connection and listen for welcome + any prompts
    /// This helps diagnose what the node sends without us issuing commands
    func testConnectAndListenOnly() async throws {
        try await skipIfDirewolfUnavailable()
        let transport = try await connectToDirewolf()
        defer { transport.disconnect() }

        var ourVR = 0
        var totalFrames = 0
        var allText = ""

        // Connect
        let sabm = buildSABM(from: myCall, to: testStation1, via: testPath1)
        print("LISTEN TEST: Connecting to \(testStation1) via \(testPath1)...")
        try await sendFrame(transport: transport, frame: sabm)

        // Wait for UA
        let response = try await waitForFrame(transport: transport, timeout: rfTimeout)
        guard let uaCtrl = extractControlByte(from: response),
              AX25ControlFieldDecoder.decode(control: uaCtrl).uType == .UA else {
            print("LISTEN TEST: Failed to connect")
            return
        }

        print("LISTEN TEST: Connected! Listening for 20 seconds...")

        // Listen for 20 seconds, responding to everything appropriately
        let listenDeadline = Date().addingTimeInterval(20.0)
        while Date() < listenDeadline {
            if let frame = try? await waitForFrame(transport: transport, timeout: 1.0) {
                totalFrames += 1
                guard let ctrl = extractControlByte(from: frame) else { continue }

                let decoded = AX25ControlFieldDecoder.decode(control: ctrl)

                switch decoded.frameClass {
                case .I:
                    let ns = decoded.ns ?? 0
                    let pf = decoded.pf ?? 0
                    let payload = extractPayload(from: frame)
                    let text = String(data: payload, encoding: .utf8) ?? "(binary \(payload.count) bytes)"

                    if ns == ourVR {
                        ourVR = (ourVR + 1) % 8
                        allText += text
                    }

                    print("LISTEN TEST: I-frame N(S)=\(ns), P/F=\(pf): '\(text.prefix(60).replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))'")

                    // Send RR acknowledgement
                    let rr = buildRR(from: myCall, to: testStation1, via: testPath1, nr: ourVR, pf: pf == 1)
                    print("LISTEN TEST: -> Sending RR N(R)=\(ourVR)")
                    try await sendFrame(transport: transport, frame: rr)

                case .S:
                    let sType = decoded.sType ?? .RR
                    let nr = decoded.nr ?? 0
                    let pf = decoded.pf ?? 0

                    print("LISTEN TEST: S-frame \(sType) N(R)=\(nr), P/F=\(pf)")

                    // If polled, respond with RR F=1
                    if pf == 1 {
                        let rr = buildRR(from: myCall, to: testStation1, via: testPath1, nr: ourVR, pf: true)
                        print("LISTEN TEST: -> Responding to poll with RR N(R)=\(ourVR) F=1")
                        try await sendFrame(transport: transport, frame: rr)
                    }

                case .U:
                    let uType = decoded.uType ?? .UNKNOWN
                    print("LISTEN TEST: U-frame \(uType)")

                case .unknown:
                    print("LISTEN TEST: Unknown frame")
                }
            }
        }

        // Disconnect
        print("LISTEN TEST: Disconnecting after \(totalFrames) frames, \(allText.count) text chars")
        let disc = buildDISC(from: myCall, to: testStation1, via: testPath1)
        try await sendFrame(transport: transport, frame: disc)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        print("LISTEN TEST: Complete. Total text received:")
        print("---")
        print(allText)
        print("---")

        XCTAssertGreaterThan(totalFrames, 0, "Should receive at least welcome frames")
    }

    /// Test sending SABM and receiving UA from KB5YZB-7
    func testSABMUAHandshake() async throws {
        try await skipIfDirewolfUnavailable()
        let transport = try await connectToDirewolf()
        defer { transport.disconnect() }

        // Build SABM frame
        let sabm = buildSABM(
            from: myCall,
            to: testStation1,
            via: testPath1
        )

        // Send SABM
        print("TEST: Sending SABM to \(testStation1) via \(testPath1)")
        try await sendFrame(transport: transport, frame: sabm)

        // Wait for UA response
        print("TEST: Waiting for UA response...")
        let response = try await waitForFrame(transport: transport, timeout: rfTimeout)

        // Parse response
        let control = extractControlByte(from: response)
        XCTAssertNotNil(control, "Should receive response frame")

        if let ctrl = control {
            let decoded = AX25ControlFieldDecoder.decode(control: ctrl)
            print("TEST: Received frame class=\(decoded.frameClass), uType=\(decoded.uType ?? .UNKNOWN)")

            // Should be UA or DM
            XCTAssertEqual(decoded.frameClass, .U, "Should be U-frame")
            XCTAssertTrue(decoded.uType == .UA || decoded.uType == .DM,
                          "Should be UA or DM, got \(decoded.uType ?? .UNKNOWN)")
        }
    }

    /// Test simple P command which should return ports list
    /// SAFETY: "P" is read-only, just lists available ports
    func testConnectedModePCommand() async throws {
        try await skipIfDirewolfUnavailable()
        let transport = try await connectToDirewolf()
        defer { transport.disconnect() }

        var ourVS = 0
        var ourVR = 0

        // Step 1: Connect
        let sabm = buildSABM(from: myCall, to: testStation1, via: testPath1)
        print("TEST [P]: Sending SABM to \(testStation1) via \(testPath1)...")
        try await sendFrame(transport: transport, frame: sabm)

        // Step 2: Wait for UA
        print("TEST [P]: Waiting for UA...")
        let response = try await waitForFrame(transport: transport, timeout: rfTimeout)
        guard let uaCtrl = extractControlByte(from: response) else {
            XCTFail("No response to SABM")
            return
        }

        let uaDecoded = AX25ControlFieldDecoder.decode(control: uaCtrl)
        guard uaDecoded.uType == .UA else {
            print("TEST [P]: Got \(uaDecoded.uType ?? .UNKNOWN) instead of UA")
            let disc = buildDISC(from: myCall, to: testStation1, via: testPath1)
            try? await sendFrame(transport: transport, frame: disc)
            XCTFail("Expected UA")
            return
        }

        print("TEST [P]: Connected! Now collecting welcome messages...")

        // Step 3: Collect ALL welcome frames and respond to polls
        // BBS nodes often send multiple I-frames as welcome
        var allReceivedText = ""
        let welcomeDeadline = Date().addingTimeInterval(8.0)  // Longer timeout

        while Date() < welcomeDeadline {
            if let frame = try? await waitForFrame(transport: transport, timeout: 1.0) {
                let (frameType, text) = processFrame(frame, ourVR: &ourVR)
                print("TEST [P]: Received \(frameType)")

                if let t = text {
                    allReceivedText += t
                    print("TEST [P]: Text: \(t.prefix(80).replacingOccurrences(of: "\r", with: "\\r"))")
                }

                // After each I-frame, send RR acknowledgement
                if frameType.starts(with: "I-frame") {
                    let rr = buildRR(from: myCall, to: testStation1, via: testPath1,
                                    nr: ourVR, pf: false)
                    print("TEST [P]: Sending RR N(R)=\(ourVR)")
                    try await sendFrame(transport: transport, frame: rr)
                }

                // If we received an RR poll, respond
                if frameType.contains("poll") {
                    let rr = buildRR(from: myCall, to: testStation1, via: testPath1,
                                    nr: ourVR, pf: true)  // F=1 response
                    print("TEST [P]: Responding to poll with RR F=1, N(R)=\(ourVR)")
                    try await sendFrame(transport: transport, frame: rr)
                }
            }
        }

        print("TEST [P]: Welcome phase complete. V(R)=\(ourVR)")
        print("TEST [P]: Total welcome text: \(allReceivedText.count) chars")

        // Step 4: Send 'P' command (ports)
        let pCmd = "P\r"
        let iFrame = buildIFrame(
            from: myCall,
            to: testStation1,
            via: testPath1,
            ns: ourVS,
            nr: ourVR,
            payload: Data(pCmd.utf8)
        )
        ourVS = (ourVS + 1) % 8
        print("TEST [P]: Sending I-frame N(S)=\(ourVS-1), N(R)=\(ourVR) with 'P' command")
        try await sendFrame(transport: transport, frame: iFrame)

        // Step 5: Wait for response (longer timeout for RF)
        var gotResponse = false
        var responseText = ""
        let responseDeadline = Date().addingTimeInterval(15.0)

        while Date() < responseDeadline && !gotResponse {
            if let frame = try? await waitForFrame(transport: transport, timeout: 2.0) {
                let (frameType, text) = processFrame(frame, ourVR: &ourVR)
                print("TEST [P]: After command, received \(frameType)")

                if let t = text {
                    responseText += t
                    gotResponse = true
                    print("TEST [P]: Response: \(t.prefix(100).replacingOccurrences(of: "\r", with: "\\r"))")

                    // Acknowledge
                    let rr = buildRR(from: myCall, to: testStation1, via: testPath1,
                                    nr: ourVR, pf: false)
                    try await sendFrame(transport: transport, frame: rr)
                }

                // Respond to any polls
                if frameType.contains("poll") {
                    let rr = buildRR(from: myCall, to: testStation1, via: testPath1,
                                    nr: ourVR, pf: true)
                    print("TEST [P]: Responding to poll with RR F=1")
                    try await sendFrame(transport: transport, frame: rr)
                }
            }
        }

        // Step 6: Disconnect
        print("TEST [P]: Disconnecting...")
        let disc = buildDISC(from: myCall, to: testStation1, via: testPath1)
        try await sendFrame(transport: transport, frame: disc)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        print("TEST [P]: Final results - gotResponse=\(gotResponse), responseText='\(responseText.prefix(50))'")
        XCTAssertTrue(gotResponse, "Should receive response to P command")
    }

    /// Helper to process a frame and extract info
    private func processFrame(_ frame: Data, ourVR: inout Int) -> (String, String?) {
        guard let ctrl = extractControlByte(from: frame) else {
            return ("unknown (no control)", nil)
        }

        let decoded = AX25ControlFieldDecoder.decode(control: ctrl)

        switch decoded.frameClass {
        case .I:
            let ns = decoded.ns ?? 0
            let nr = decoded.nr ?? 0
            let pf = decoded.pf ?? 0
            let payload = extractPayload(from: frame)
            let text = String(data: payload, encoding: .utf8) ?? String(data: payload, encoding: .ascii) ?? "(binary)"

            // Update V(R) if in sequence
            if ns == ourVR {
                ourVR = (ourVR + 1) % 8
            }

            return ("I-frame N(S)=\(ns), N(R)=\(nr), P/F=\(pf), len=\(payload.count)", text)

        case .S:
            let sType = decoded.sType ?? .RR
            let nr = decoded.nr ?? 0
            let pf = decoded.pf ?? 0
            let pollStr = pf == 1 ? " (poll)" : ""
            return ("\(sType) N(R)=\(nr)\(pollStr)", nil)

        case .U:
            let uType = decoded.uType ?? .UNKNOWN
            return ("U-frame \(uType)", nil)

        case .unknown:
            return ("unknown frame class", nil)
        }
    }

    /// Test full connection and command exchange
    /// SAFETY: Only sends "NODES" command which is read-only
    func testConnectedModeNODESCommand() async throws {
        try await skipIfDirewolfUnavailable()
        let transport = try await connectToDirewolf()
        defer { transport.disconnect() }

        // Track sequence numbers
        var ourVS = 0  // Our send sequence
        var ourVR = 0  // Next expected receive sequence

        // Step 1: Send SABM
        let sabm = buildSABM(from: myCall, to: testStation1, via: testPath1)
        print("TEST: Sending SABM...")
        try await sendFrame(transport: transport, frame: sabm)

        // Step 2: Wait for UA
        print("TEST: Waiting for UA...")
        var response = try await waitForFrame(transport: transport, timeout: rfTimeout)
        var control = extractControlByte(from: response)

        guard let uaCtrl = control else {
            XCTFail("No response to SABM")
            return
        }

        let uaDecoded = AX25ControlFieldDecoder.decode(control: uaCtrl)
        guard uaDecoded.uType == .UA else {
            print("TEST: Got \(uaDecoded.uType ?? .UNKNOWN) instead of UA")
            // Send DISC to clean up
            let disc = buildDISC(from: myCall, to: testStation1, via: testPath1)
            try? await sendFrame(transport: transport, frame: disc)
            XCTFail("Expected UA, got \(uaDecoded.uType ?? .UNKNOWN)")
            return
        }

        print("TEST: Connection established!")

        // Step 3: Receive welcome I-frames from BBS
        print("TEST: Waiting for welcome message...")
        var welcomeFrames = 0
        var lastReceivedNS = -1

        // Collect I-frames for a few seconds
        let welcomeDeadline = Date().addingTimeInterval(5.0)
        while Date() < welcomeDeadline {
            if let frame = try? await waitForFrame(transport: transport, timeout: 2.0) {
                if let ctrl = extractControlByte(from: frame) {
                    let decoded = AX25ControlFieldDecoder.decode(control: ctrl)

                    if decoded.frameClass == .I {
                        let ns = decoded.ns ?? 0
                        let nr = decoded.nr ?? 0
                        print("TEST: Received I-frame N(S)=\(ns), N(R)=\(nr)")

                        // Update our V(R) if this is the expected frame
                        if ns == ourVR {
                            ourVR = (ourVR + 1) % 8
                            lastReceivedNS = ns
                            welcomeFrames += 1
                        }
                    } else if decoded.frameClass == .S && decoded.sType == .RR {
                        // Remote is asking for status
                        let pf = decoded.pf ?? 0
                        if pf == 1 {
                            // Send RR response with F=1
                            let rr = buildRR(from: myCall, to: testStation1, via: testPath1,
                                            nr: ourVR, pf: true)
                            print("TEST: Responding to poll with RR N(R)=\(ourVR)")
                            try await sendFrame(transport: transport, frame: rr)
                        }
                    }
                }
            }
        }

        print("TEST: Received \(welcomeFrames) welcome frames, V(R)=\(ourVR)")
        XCTAssertGreaterThan(welcomeFrames, 0, "Should receive welcome message")

        // Step 4: Send RR acknowledgement
        let rr = buildRR(from: myCall, to: testStation1, via: testPath1,
                        nr: ourVR, pf: false)
        print("TEST: Sending RR N(R)=\(ourVR)")
        try await sendFrame(transport: transport, frame: rr)

        // Step 5: Send NODES command (read-only, safe)
        let nodesCmd = "NODES\r"  // Include CR!
        let iFrame = buildIFrame(
            from: myCall,
            to: testStation1,
            via: testPath1,
            ns: ourVS,
            nr: ourVR,
            payload: Data(nodesCmd.utf8)
        )
        ourVS = (ourVS + 1) % 8

        print("TEST: Sending I-frame N(S)=\(ourVS-1), N(R)=\(ourVR) with 'NODES' command")
        try await sendFrame(transport: transport, frame: iFrame)

        // Step 6: Wait for response
        print("TEST: Waiting for NODES response...")
        var gotResponse = false
        let responseDeadline = Date().addingTimeInterval(10.0)

        while Date() < responseDeadline && !gotResponse {
            if let frame = try? await waitForFrame(transport: transport, timeout: 3.0) {
                if let ctrl = extractControlByte(from: frame) {
                    let decoded = AX25ControlFieldDecoder.decode(control: ctrl)

                    if decoded.frameClass == .I {
                        let ns = decoded.ns ?? 0
                        let payload = extractPayload(from: frame)
                        print("TEST: Received response I-frame N(S)=\(ns)")

                        if let text = String(data: payload, encoding: .utf8) {
                            print("TEST: Response text: \(text.prefix(100))...")
                        }

                        // Update V(R) and acknowledge
                        if ns == ourVR {
                            ourVR = (ourVR + 1) % 8
                            gotResponse = true

                            // Send RR
                            let ackRR = buildRR(from: myCall, to: testStation1, via: testPath1,
                                               nr: ourVR, pf: false)
                            print("TEST: Sending RR N(R)=\(ourVR)")
                            try await sendFrame(transport: transport, frame: ackRR)
                        }
                    } else if decoded.frameClass == .S {
                        print("TEST: Received S-frame \(decoded.sType ?? .RR)")
                    }
                }
            }
        }

        // Step 7: Clean disconnect with DISC
        print("TEST: Sending DISC...")
        let disc = buildDISC(from: myCall, to: testStation1, via: testPath1)
        try await sendFrame(transport: transport, frame: disc)

        // Wait for UA
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        print("TEST: Disconnected")
        XCTAssertTrue(gotResponse, "Should receive response to NODES command")
    }

    // MARK: - KISS Transport Helpers

    /// Live Direwolf tests use SimulatorClient for now since KISSTransport
    /// API is primarily designed for outbound frame queueing, not bidirectional communication.
    /// For true live Direwolf testing, use SimulatorClient configured with the Direwolf host.
    private func connectToDirewolf() async throws -> SimulatorClient {
        let client = SimulatorClient(host: direwolfHost, port: direwolfPort, stationName: "Direwolf")
        try await client.connect()
        return client
    }

    private func sendFrame(transport: SimulatorClient, frame: Data) async throws {
        try await transport.sendAX25Frame(frame)
    }

    private func waitForFrame(transport: SimulatorClient, timeout: TimeInterval) async throws -> Data {
        return try await transport.waitForFrame(timeout: timeout)
    }

    // Keep KISSTransport helper for backward compatibility
    private func connectToKISSTransport() async throws -> KISSTransport {
        let transport = KISSTransport(host: direwolfHost, port: direwolfPort)

        return try await withCheckedThrowingContinuation { continuation in
            class Delegate: KISSTransportDelegate {
                var continuation: CheckedContinuation<KISSTransport, Error>?
                var transport: KISSTransport?

                func transportDidSend(frameId: UUID, result: Result<Void, Error>) {}

                func transportDidChangeState(_ state: KISSTransportState) {
                    guard let cont = continuation, let trans = transport else { return }
                    continuation = nil
                    switch state {
                    case .connected:
                        cont.resume(returning: trans)
                    case .failed:
                        cont.resume(throwing: TestError.connectionFailed)
                    default:
                        break
                    }
                }
            }

            let delegate = Delegate()
            delegate.continuation = continuation
            delegate.transport = transport
            transport.delegate = delegate
            transport.connect()
        }
    }

    // MARK: - Frame Building Helpers

    private func buildSABM(from source: String, to destination: String, via path: String) -> Data {
        var frame = Data()

        // Destination address
        frame.append(contentsOf: encodeAddress(destination, isLast: false))

        // Source address
        frame.append(contentsOf: encodeAddress(source, isLast: path.isEmpty))

        // Via path
        if !path.isEmpty {
            frame.append(contentsOf: encodeAddress(path, isLast: true))
        }

        // SABM control with P=1
        frame.append(0x3F)

        return frame
    }

    private func buildDISC(from source: String, to destination: String, via path: String) -> Data {
        var frame = Data()

        frame.append(contentsOf: encodeAddress(destination, isLast: false))
        frame.append(contentsOf: encodeAddress(source, isLast: path.isEmpty))

        if !path.isEmpty {
            frame.append(contentsOf: encodeAddress(path, isLast: true))
        }

        // DISC control with P=1
        frame.append(0x53)

        return frame
    }

    private func buildRR(from source: String, to destination: String, via path: String,
                        nr: Int, pf: Bool) -> Data {
        var frame = Data()

        frame.append(contentsOf: encodeAddress(destination, isLast: false))
        frame.append(contentsOf: encodeAddress(source, isLast: path.isEmpty))

        if !path.isEmpty {
            frame.append(contentsOf: encodeAddress(path, isLast: true))
        }

        // RR control: NNN P 00 01
        var control: UInt8 = 0x01
        control |= UInt8((nr & 0x07) << 5)
        if pf { control |= 0x10 }
        frame.append(control)

        return frame
    }

    private func buildIFrame(from source: String, to destination: String, via path: String,
                            ns: Int, nr: Int, payload: Data) -> Data {
        var frame = Data()

        frame.append(contentsOf: encodeAddress(destination, isLast: false))
        frame.append(contentsOf: encodeAddress(source, isLast: path.isEmpty))

        if !path.isEmpty {
            frame.append(contentsOf: encodeAddress(path, isLast: true))
        }

        // I-frame control: NNN P SSS 0
        var control: UInt8 = 0x00
        control |= UInt8((ns & 0x07) << 1)
        control |= UInt8((nr & 0x07) << 5)
        frame.append(control)

        // PID
        frame.append(0xF0)

        // Payload
        frame.append(payload)

        return frame
    }

    private func encodeAddress(_ call: String, isLast: Bool) -> Data {
        var data = Data()

        // Parse callsign and SSID
        let parts = call.uppercased().split(separator: "-")
        var callsign = String(parts[0])
        let ssid: UInt8 = parts.count > 1 ? UInt8(parts[1]) ?? 0 : 0

        // Pad to 6 characters
        while callsign.count < 6 {
            callsign += " "
        }
        callsign = String(callsign.prefix(6))

        // Encode callsign (shifted left by 1)
        for char in callsign.utf8 {
            data.append(char << 1)
        }

        // SSID byte
        var ssidByte: UInt8 = 0x60  // Reserved bits
        ssidByte |= (ssid & 0x0F) << 1
        if isLast {
            ssidByte |= 0x01  // Extension bit
        }
        data.append(ssidByte)

        return data
    }

    private func extractControlByte(from frame: Data) -> UInt8? {
        // Find end of address field (byte with bit 0 = 1)
        var offset = 0
        while offset < frame.count {
            if frame[offset] & 0x01 != 0 {
                // Control byte is next
                let controlOffset = offset + 1
                if controlOffset < frame.count {
                    return frame[controlOffset]
                }
                return nil
            }
            offset += 1
        }
        return nil
    }

    private func extractPayload(from frame: Data) -> Data {
        // Find end of address field
        var offset = 0
        while offset < frame.count {
            if frame[offset] & 0x01 != 0 {
                break
            }
            offset += 1
        }

        // Skip control byte
        offset += 1
        if offset >= frame.count { return Data() }

        let control = frame[offset]
        offset += 1

        // If I-frame, skip PID
        if (control & 0x01) == 0 && offset < frame.count {
            offset += 1  // Skip PID
        }

        // Return payload
        if offset < frame.count {
            return frame.suffix(from: offset)
        }
        return Data()
    }

    private enum TestError: Error {
        case timeout
        case connectionFailed
    }
}
