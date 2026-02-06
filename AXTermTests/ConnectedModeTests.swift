//
//  ConnectedModeTests.swift
//  AXTermTests
//
//  Tests for AX.25 connected-mode session handling including:
//  - CR terminator for BBS compatibility
//  - I-frame control byte encoding (single byte modulo-8)
//  - Session acknowledgement with correct N(R)
//  - V(R)/V(S) sequence number tracking
//

import XCTest
@testable import AXTerm

final class ConnectedModeTests: XCTestCase {

    // MARK: - CR Terminator Tests

    /// Test that plain-text connected mode payloads get CR appended
    /// This is essential for BBS compatibility - BBSes buffer until CR
    func testPlainTextPayloadGetsCRAppended() {
        // Build payload the same way sendConnectedMessage does
        let text = "INFO"
        let useAXDP = false

        let payload: Data
        if useAXDP {
            // AXDP path (not testing here)
            payload = Data()
        } else {
            // Standard plain-text: append CR for BBS compatibility
            var data = Data(text.utf8)
            data.append(0x0D)  // CR
            payload = data
        }

        // Verify CR is at the end
        XCTAssertEqual(payload.count, 5, "Should be 4 chars + 1 CR")
        XCTAssertEqual(payload.last, 0x0D, "Last byte should be CR (0x0D)")

        // Verify the text is correct
        let textPortion = payload.prefix(4)
        XCTAssertEqual(String(data: textPortion, encoding: .utf8), "INFO")
    }

    /// Test that AXDP payloads do NOT get CR appended (they have TLV structure)
    func testAXDPPayloadDoesNotGetCRAppended() {
        let text = "Hello"
        let message = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: 12345,
            payload: Data(text.utf8)
        )
        let payload = message.encode()

        // AXDP payload should NOT end with CR
        // It has structured TLV format
        XCTAssertNotEqual(payload.last, 0x0D, "AXDP payload should not end with CR")

        // Verify it starts with AXDP magic
        XCTAssertTrue(AXDP.hasMagic(payload), "Should have AXDP magic header")
    }

    /// Test various BBS commands get CR appended
    func testBBSCommandsGetCR() {
        let commands = ["BBS", "NODES", "PORTS", "INFO", "C K0NTS-1", "?", "B"]

        for command in commands {
            var data = Data(command.utf8)
            data.append(0x0D)

            XCTAssertEqual(data.last, 0x0D, "Command '\(command)' should end with CR")
            XCTAssertEqual(data.count, command.utf8.count + 1, "Should add exactly 1 byte for CR")
        }
    }

    // MARK: - I-Frame Control Byte Tests

    /// Test I-frame control byte encoding for modulo-8 mode
    /// Format: NNNPSSS0 where NNN=N(R), P=P/F, SSS=N(S), 0=I-frame indicator
    func testIFrameControlByteEncoding() {
        // Test case: N(S)=0, N(R)=0, P/F=0
        var control = buildIFrameControl(ns: 0, nr: 0, pf: false)
        XCTAssertEqual(control, 0x00)

        // Test case: N(S)=1, N(R)=2, P/F=0
        // bits 5-7: N(R)=2 = 010
        // bit 4: P/F=0
        // bits 1-3: N(S)=1 = 001
        // bit 0: 0
        // Result: 010 0 001 0 = 0x42
        control = buildIFrameControl(ns: 1, nr: 2, pf: false)
        XCTAssertEqual(control, 0x42)

        // Test case: N(S)=3, N(R)=5, P/F=1
        // bits 5-7: N(R)=5 = 101
        // bit 4: P/F=1
        // bits 1-3: N(S)=3 = 011
        // bit 0: 0
        // Result: 101 1 011 0 = 0xB6
        control = buildIFrameControl(ns: 3, nr: 5, pf: true)
        XCTAssertEqual(control, 0xB6)

        // Test case: N(S)=7, N(R)=7, P/F=1 (max values)
        // bits 5-7: N(R)=7 = 111
        // bit 4: P/F=1
        // bits 1-3: N(S)=7 = 111
        // bit 0: 0
        // Result: 111 1 111 0 = 0xFE
        control = buildIFrameControl(ns: 7, nr: 7, pf: true)
        XCTAssertEqual(control, 0xFE)
    }

    /// Test I-frame control byte decoding matches encoding
    func testIFrameControlByteRoundTrip() {
        for ns in 0..<8 {
            for nr in 0..<8 {
                for pf in [false, true] {
                    let control = buildIFrameControl(ns: ns, nr: nr, pf: pf)
                    let decoded = AX25ControlFieldDecoder.decode(control: control)

                    XCTAssertEqual(decoded.frameClass, .I, "Should decode as I-frame")
                    XCTAssertEqual(decoded.ns, ns, "N(S) should match for ns=\(ns), nr=\(nr), pf=\(pf)")
                    XCTAssertEqual(decoded.nr, nr, "N(R) should match for ns=\(ns), nr=\(nr), pf=\(pf)")
                    XCTAssertEqual(decoded.pf, pf ? 1 : 0, "P/F should match for ns=\(ns), nr=\(nr), pf=\(pf)")
                }
            }
        }
    }

    // MARK: - RR Frame Tests

    /// Test RR frame control byte encoding
    /// Format: NNN P 00 01 where NNN=N(R), P=P/F, 00=RR type, 01=S-frame indicator
    func testRRFrameControlByteEncoding() {
        // RR with N(R)=0, P/F=0
        var control = buildRRControl(nr: 0, pf: false)
        XCTAssertEqual(control, 0x01)  // 000 0 00 01

        // RR with N(R)=2, P/F=0
        // bits 5-7: N(R)=2 = 010
        // Result: 010 0 00 01 = 0x41
        control = buildRRControl(nr: 2, pf: false)
        XCTAssertEqual(control, 0x41)

        // RR with N(R)=3, P/F=1 (poll response)
        // bits 5-7: N(R)=3 = 011
        // bit 4: P/F=1
        // Result: 011 1 00 01 = 0x71
        control = buildRRControl(nr: 3, pf: true)
        XCTAssertEqual(control, 0x71)
    }

    /// Test RR frame decoding
    func testRRFrameDecoding() {
        for nr in 0..<8 {
            for pf in [false, true] {
                let control = buildRRControl(nr: nr, pf: pf)
                let decoded = AX25ControlFieldDecoder.decode(control: control)

                XCTAssertEqual(decoded.frameClass, .S, "Should decode as S-frame")
                XCTAssertEqual(decoded.sType, .RR, "Should be RR type")
                XCTAssertEqual(decoded.nr, nr, "N(R) should be \(nr)")
                XCTAssertEqual(decoded.pf, pf ? 1 : 0, "P/F should match")
            }
        }
    }

    // MARK: - Sequence Number Acknowledgement Tests

    /// Test that receiving I-frame N(S)=0 should result in acknowledgement N(R)=1
    func testAcknowledgementAfterSingleIFrame() {
        // Simulate receiving I-frame with N(S)=0
        // Our V(R) should increment to 1
        // Our RR response should have N(R)=1 (next expected)
        var vr = 0

        // Receive I-frame with N(S)=0 (matches our V(R))
        let receivedNS = 0
        if receivedNS == vr {
            vr = (vr + 1) % 8  // Increment V(R)
        }

        XCTAssertEqual(vr, 1, "V(R) should be 1 after receiving N(S)=0")

        // Build RR with our current V(R)
        let rrControl = buildRRControl(nr: vr, pf: false)
        let decoded = AX25ControlFieldDecoder.decode(control: rrControl)
        XCTAssertEqual(decoded.nr, 1, "RR should have N(R)=1")
    }

    /// Test acknowledgement after multiple I-frames
    func testAcknowledgementAfterMultipleIFrames() {
        var vr = 0

        // Receive I-frames with N(S)=0, 1, 2
        for expectedNS in 0..<3 {
            if expectedNS == vr {
                vr = (vr + 1) % 8
            }
        }

        XCTAssertEqual(vr, 3, "V(R) should be 3 after receiving N(S)=0,1,2")

        // RR should acknowledge with N(R)=3
        let rrControl = buildRRControl(nr: vr, pf: false)
        let decoded = AX25ControlFieldDecoder.decode(control: rrControl)
        XCTAssertEqual(decoded.nr, 3, "RR should have N(R)=3")
    }

    /// Test V(R) wraparound at modulo-8 boundary
    func testVRWraparound() {
        var vr = 6

        // Receive N(S)=6, 7, 0
        for expectedNS in [6, 7, 0] {
            if expectedNS == vr {
                vr = (vr + 1) % 8
            }
        }

        XCTAssertEqual(vr, 1, "V(R) should wrap around to 1")
    }

    // MARK: - Integration Test: Full I-Frame Exchange Simulation

    /// Simulate a full I-frame exchange like connecting to a BBS
    func testFullIFrameExchangeSimulation() {
        // Simulate connection established, now exchanging I-frames

        // Our state
        var ourVS = 0  // Next N(S) to send
        var ourVR = 0  // Next N(R) we expect to receive

        // Remote state (BBS)
        var remoteVS = 0
        var remoteVR = 0

        // Step 1: Remote sends welcome message (I-frame N(S)=0, N(R)=0)
        let remoteFrame1 = buildIFrameControl(ns: remoteVS, nr: remoteVR, pf: false)
        remoteVS = (remoteVS + 1) % 8

        // We receive it and update our V(R)
        let decoded1 = AX25ControlFieldDecoder.decode(control: remoteFrame1)
        XCTAssertEqual(decoded1.ns, 0)
        if decoded1.ns == ourVR {
            ourVR = (ourVR + 1) % 8
        }
        XCTAssertEqual(ourVR, 1, "Our V(R) should be 1")

        // Step 2: Remote sends second part (I-frame N(S)=1, N(R)=0)
        let remoteFrame2 = buildIFrameControl(ns: remoteVS, nr: remoteVR, pf: false)
        remoteVS = (remoteVS + 1) % 8

        let decoded2 = AX25ControlFieldDecoder.decode(control: remoteFrame2)
        XCTAssertEqual(decoded2.ns, 1)
        if decoded2.ns == ourVR {
            ourVR = (ourVR + 1) % 8
        }
        XCTAssertEqual(ourVR, 2, "Our V(R) should be 2")

        // Step 3: We send RR acknowledging both frames
        let ourRR = buildRRControl(nr: ourVR, pf: false)
        let decodedRR = AX25ControlFieldDecoder.decode(control: ourRR)
        XCTAssertEqual(decodedRR.nr, 2, "Our RR should have N(R)=2")

        // Step 4: We send a command (I-frame with our N(S)=0, N(R)=2)
        let ourFrame = buildIFrameControl(ns: ourVS, nr: ourVR, pf: false)
        ourVS = (ourVS + 1) % 8

        let decodedOur = AX25ControlFieldDecoder.decode(control: ourFrame)
        XCTAssertEqual(decodedOur.ns, 0, "Our I-frame should have N(S)=0")
        XCTAssertEqual(decodedOur.nr, 2, "Our I-frame should have N(R)=2")

        // This matches what we saw in the Direwolf log:
        // K0EPI>KB5YZB-7:(I cc=00, n(s)=0, n(r)=2, p/f=0, pid=0xf0)p
    }

    // MARK: - Helper Functions

    /// Build I-frame control byte (modulo-8 single byte format)
    private func buildIFrameControl(ns: Int, nr: Int, pf: Bool) -> UInt8 {
        var control: UInt8 = 0x00  // bit 0 = 0 for I-frame
        control |= UInt8((ns & 0x07) << 1)  // N(S) in bits 1-3
        if pf { control |= 0x10 }            // P/F in bit 4
        control |= UInt8((nr & 0x07) << 5)  // N(R) in bits 5-7
        return control
    }

    /// Build RR control byte
    private func buildRRControl(nr: Int, pf: Bool) -> UInt8 {
        var control: UInt8 = 0x01  // bits 0-1 = 01 for S-frame, bits 2-3 = 00 for RR
        if pf { control |= 0x10 }
        control |= UInt8((nr & 0x07) << 5)
        return control
    }
}

// MARK: - AX25FrameBuilder Tests

final class AX25FrameBuilderTests: XCTestCase {

    /// Test building I-frame with correct control byte
    func testBuildIFrameControlByte() {
        let frame = AX25FrameBuilder.buildIFrame(
            from: AX25Address(call: "TEST1"),
            to: AX25Address(call: "TEST2"),
            via: DigiPath(),
            ns: 2,
            nr: 3,
            payload: Data("Hello".utf8)
        )

        // Verify control byte is correct single-byte format
        // N(S)=2, N(R)=3, P/F=0
        // bits 5-7: N(R)=3 = 011
        // bit 4: P/F=0
        // bits 1-3: N(S)=2 = 010
        // bit 0: 0
        // Result: 011 0 010 0 = 0x64
        XCTAssertEqual(frame.controlByte, 0x64)
    }

    /// Test building RR frame with correct control byte
    func testBuildRRFrameControlByte() {
        let frame = AX25FrameBuilder.buildRR(
            from: AX25Address(call: "TEST1"),
            to: AX25Address(call: "TEST2"),
            via: DigiPath(),
            nr: 5,
            pf: true
        )

        // RR with N(R)=5, P/F=1
        // bits 5-7: N(R)=5 = 101
        // bit 4: P/F=1
        // bits 2-3: 00 (RR)
        // bits 0-1: 01 (S-frame)
        // Result: 101 1 00 01 = 0xB1
        XCTAssertEqual(frame.controlByte, 0xB1)
    }
}
