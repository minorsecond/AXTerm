//
//  ConnectedModeSessionTests.swift
//  AXTermIntegrationTests
//
//  Tests for AX.25 connected-mode session handling including:
//  - Connection establishment (SABM/UA)
//  - I-frame acknowledgement (RR with correct N(R))
//  - Poll/Final response handling
//  - Session state transitions
//

import XCTest
@testable import AXTerm

/// Tests AX.25 connected-mode session handling through the KISS relay simulation.
///
/// These tests verify that:
/// 1. V(R) is properly incremented when receiving I-frames
/// 2. RR acknowledgements include the correct N(R)
/// 3. Poll (P=1) requests receive Final (F=1) responses
/// 4. Session state transitions work correctly
final class ConnectedModeSessionTests: XCTestCase {

    var clientA: SimulatorClient!  // Initiating station (like AXTerm app)
    var clientB: SimulatorClient!  // Remote station (like a BBS)

    let stationA = TestAX25Address("TEST-1")
    let stationB = TestAX25Address("TEST-2")

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        clientA = SimulatorClient.stationA()
        clientB = SimulatorClient.stationB()

        try await clientA.connect()
        try await clientB.connect()

        clientA.clearReceiveBuffer()
        clientB.clearReceiveBuffer()

        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms stabilization
    }

    override func tearDown() async throws {
        clientA?.disconnect()
        clientB?.disconnect()
        clientA = nil
        clientB = nil
    }

    // MARK: - Connection Establishment Tests

    /// Test basic SABM/UA connection handshake
    func testConnectionEstablishment_SABM_UA() async throws {
        // Station A sends SABM
        let sabm = TestConnectedFrameBuilder.buildSABM(
            from: stationA,
            to: stationB
        )
        try await clientA.sendAX25Frame(sabm)

        // Station B should receive SABM
        let receivedSABM = try await clientB.waitForFrame(timeout: 5.0)
        XCTAssertFalse(receivedSABM.isEmpty, "Should receive SABM")

        // Verify it's a SABM (control byte pattern)
        if let control = TestConnectedFrameBuilder.extractControlByte(from: receivedSABM) {
            let pattern = control & 0xEF  // Mask out P/F bit
            XCTAssertEqual(pattern, 0x2F, "Should be SABM control byte")
        }

        // Station B responds with UA
        let ua = TestConnectedFrameBuilder.buildUA(
            from: stationB,
            to: stationA
        )
        try await clientB.sendAX25Frame(ua)

        // Station A should receive UA
        let receivedUA = try await clientA.waitForFrame(timeout: 5.0)
        XCTAssertFalse(receivedUA.isEmpty, "Should receive UA")

        // Verify it's a UA
        if let control = TestConnectedFrameBuilder.extractControlByte(from: receivedUA) {
            let pattern = control & 0xEF
            XCTAssertEqual(pattern, 0x63, "Should be UA control byte")
        }
    }

    // MARK: - I-Frame Sequence Number Tests

    /// Test that receiving I-frames properly increments N(R) in acknowledgements
    /// This is the core test for the bug where N(R) was always 0
    func testIFrameAcknowledgement_NR_Increments() async throws {
        // Establish connection first
        try await establishConnection()

        // Station B sends I-frame with N(S)=0
        let iFrame0 = TestConnectedFrameBuilder.buildIFrame(
            from: stationB,
            to: stationA,
            ns: 0,
            nr: 0,
            payload: Data("First message".utf8)
        )
        try await clientB.sendAX25Frame(iFrame0)

        // Wait and collect response
        try await Task.sleep(nanoseconds: 500_000_000)

        // Station B sends I-frame with N(S)=1
        let iFrame1 = TestConnectedFrameBuilder.buildIFrame(
            from: stationB,
            to: stationA,
            ns: 1,
            nr: 0,
            payload: Data("Second message".utf8)
        )
        try await clientB.sendAX25Frame(iFrame1)

        // Wait for acknowledgements
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Station B sends RR poll (P=1) to ask for status
        let rrPoll = TestConnectedFrameBuilder.buildRR(
            from: stationB,
            to: stationA,
            nr: 0,
            pf: true
        )
        try await clientB.sendAX25Frame(rrPoll)

        // Wait for response
        try await Task.sleep(nanoseconds: 500_000_000)

        // Drain all received frames at B
        let responses = clientB.drainReceivedFrames()

        // Find an RR or I-frame response and check N(R)
        var foundCorrectNR = false
        for response in responses {
            if let control = TestConnectedFrameBuilder.extractControlByte(from: response) {
                if TestConnectedFrameBuilder.isRR(control) ||
                   TestConnectedFrameBuilder.isIFrame(control) {
                    let nr = TestConnectedFrameBuilder.extractNR(from: control)
                    print("Found response with N(R)=\(nr)")

                    // After receiving I-frames with N(S)=0 and N(S)=1,
                    // the acknowledgement should have N(R)=2
                    if nr == 2 {
                        foundCorrectNR = true
                    }
                }
            }
        }

        XCTAssertTrue(foundCorrectNR,
            "Should acknowledge with N(R)=2 after receiving I-frames with N(S)=0 and N(S)=1")
    }

    /// Test that I-frame control byte decoding correctly extracts N(S), N(R), and P/F
    func testIFrameControlByteDecoding() async throws {
        // Build an I-frame with known sequence numbers
        let iFrame = TestConnectedFrameBuilder.buildIFrame(
            from: stationA,
            to: stationB,
            ns: 3,
            nr: 5,
            pf: true,
            payload: Data("Test".utf8)
        )

        // Extract and verify control byte
        if let control = TestConnectedFrameBuilder.extractControlByte(from: iFrame) {
            XCTAssertTrue(TestConnectedFrameBuilder.isIFrame(control), "Should be I-frame")

            let ns = TestConnectedFrameBuilder.extractNS(from: control)
            let nr = TestConnectedFrameBuilder.extractNR(from: control)
            let pf = (control >> 4) & 0x01

            XCTAssertEqual(ns, 3, "N(S) should be 3")
            XCTAssertEqual(nr, 5, "N(R) should be 5")
            XCTAssertEqual(pf, 1, "P/F should be 1")
        } else {
            XCTFail("Could not extract control byte")
        }
    }

    /// Test using the actual AX25ControlFieldDecoder
    func testAX25ControlFieldDecoder_IFrame() throws {
        // Test control byte: N(R)=5, P=1, N(S)=3 → 101 1 011 0 = 0xB6
        let control: UInt8 = 0xB6

        let decoded = AX25ControlFieldDecoder.decode(control: control)

        XCTAssertEqual(decoded.frameClass, .I, "Should decode as I-frame")
        XCTAssertEqual(decoded.ns, 3, "N(S) should be 3")
        XCTAssertEqual(decoded.nr, 5, "N(R) should be 5")
        XCTAssertEqual(decoded.pf, 1, "P/F should be 1")
    }

    /// Test AX25ControlFieldDecoder with various I-frame control bytes
    func testAX25ControlFieldDecoder_IFrameVariants() throws {
        // Test case: N(R)=0, P=0, N(S)=0 → 000 0 000 0 = 0x00
        var decoded = AX25ControlFieldDecoder.decode(control: 0x00)
        XCTAssertEqual(decoded.frameClass, .I)
        XCTAssertEqual(decoded.ns, 0)
        XCTAssertEqual(decoded.nr, 0)

        // Test case: N(R)=7, P=0, N(S)=7 → 111 0 111 0 = 0xEE
        decoded = AX25ControlFieldDecoder.decode(control: 0xEE)
        XCTAssertEqual(decoded.frameClass, .I)
        XCTAssertEqual(decoded.ns, 7)
        XCTAssertEqual(decoded.nr, 7)

        // Test case: N(R)=2, P=0, N(S)=1 → 010 0 001 0 = 0x42
        decoded = AX25ControlFieldDecoder.decode(control: 0x42)
        XCTAssertEqual(decoded.frameClass, .I)
        XCTAssertEqual(decoded.ns, 1)
        XCTAssertEqual(decoded.nr, 2)
    }

    // MARK: - Poll/Final Response Tests

    /// Test that RR poll (P=1) receives RR response (F=1) with correct N(R)
    func testRRPollResponse() async throws {
        try await establishConnection()

        // First, send some I-frames to increment V(R) at station A
        for i in 0..<3 {
            let iFrame = TestConnectedFrameBuilder.buildIFrame(
                from: stationB,
                to: stationA,
                ns: i,
                nr: 0,
                payload: Data("Message \(i)".utf8)
            )
            try await clientB.sendAX25Frame(iFrame)
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        // Clear buffer to only capture the poll response
        clientB.clearReceiveBuffer()

        // Station B sends RR poll
        let rrPoll = TestConnectedFrameBuilder.buildRR(
            from: stationB,
            to: stationA,
            nr: 0,
            pf: true  // Poll bit set
        )
        try await clientB.sendAX25Frame(rrPoll)

        // Wait for response
        let response = try await clientB.waitForFrame(timeout: 5.0)
        XCTAssertFalse(response.isEmpty, "Should receive poll response")

        // Verify it's an RR with F=1 and correct N(R)
        if let control = TestConnectedFrameBuilder.extractControlByte(from: response) {
            if TestConnectedFrameBuilder.isRR(control) {
                let nr = TestConnectedFrameBuilder.extractNR(from: control)
                let pf = (control >> 4) & 0x01

                XCTAssertEqual(pf, 1, "Final bit should be set")
                XCTAssertEqual(nr, 3, "N(R) should be 3 (received I-frames 0,1,2)")
            }
        }
    }

    // MARK: - Helper Methods

    /// Establish a connection between stations A and B
    private func establishConnection() async throws {
        // A sends SABM
        let sabm = TestConnectedFrameBuilder.buildSABM(from: stationA, to: stationB)
        try await clientA.sendAX25Frame(sabm)

        // Wait for it to arrive at B
        _ = try await clientB.waitForFrame(timeout: 5.0)

        // B responds with UA
        let ua = TestConnectedFrameBuilder.buildUA(from: stationB, to: stationA)
        try await clientB.sendAX25Frame(ua)

        // Wait for UA to arrive at A
        _ = try await clientA.waitForFrame(timeout: 5.0)

        // Small delay for connection stabilization
        try await Task.sleep(nanoseconds: 200_000_000)

        // Clear buffers
        clientA.clearReceiveBuffer()
        clientB.clearReceiveBuffer()
    }
}

// MARK: - Unit Tests for Control Field Decoder

/// Unit tests for AX25ControlFieldDecoder that don't require the simulator
final class ControlFieldDecoderTests: XCTestCase {

    /// Test I-frame control byte decoding (the bug fix)
    func testIFrameDecoding_SingleByte() {
        // Control byte: N(R)=2, P=0, N(S)=1 → 010 0 001 0 = 0x42
        let decoded = AX25ControlFieldDecoder.decode(control: 0x42)

        XCTAssertEqual(decoded.frameClass, .I, "Should be I-frame")
        XCTAssertEqual(decoded.ns, 1, "N(S) should be 1")
        XCTAssertEqual(decoded.nr, 2, "N(R) should be 2")
        XCTAssertEqual(decoded.pf, 0, "P/F should be 0")
    }

    /// Test S-frame (RR) control byte decoding
    func testRRDecoding() {
        // RR with N(R)=3, P=1 → 011 1 00 01 = 0x71
        let decoded = AX25ControlFieldDecoder.decode(control: 0x71)

        XCTAssertEqual(decoded.frameClass, .S, "Should be S-frame")
        XCTAssertEqual(decoded.sType, .RR, "Should be RR")
        XCTAssertEqual(decoded.nr, 3, "N(R) should be 3")
        XCTAssertEqual(decoded.pf, 1, "P/F should be 1")
    }

    /// Test U-frame (SABM) control byte decoding
    func testSABMDecoding() {
        // SABM with P=1 → 0x3F
        let decoded = AX25ControlFieldDecoder.decode(control: 0x3F)

        XCTAssertEqual(decoded.frameClass, .U, "Should be U-frame")
        XCTAssertEqual(decoded.uType, .SABM, "Should be SABM")
        XCTAssertEqual(decoded.pf, 1, "P/F should be 1")
    }

    /// Test U-frame (UA) control byte decoding
    func testUADecoding() {
        // UA with F=1 → 0x73
        let decoded = AX25ControlFieldDecoder.decode(control: 0x73)

        XCTAssertEqual(decoded.frameClass, .U, "Should be U-frame")
        XCTAssertEqual(decoded.uType, .UA, "Should be UA")
        XCTAssertEqual(decoded.pf, 1, "P/F should be 1")
    }
}
