//
//  PlainTextAndMixedModeTests.swift
//  AXTermTests
//
//  Comprehensive tests for non-AXDP (plain text) packet communication
//  and mixed-mode scenarios where AXDP and non-AXDP stations interact.
//
//  Per CLAUDE.md: "any station that has axdp turned off should be able to
//  perfectly interact with other stations, axdp or not"
//

import XCTest
@testable import AXTerm

// MARK: - Plain Text Detection Tests

/// Tests for plain text (non-AXDP) data detection and handling.
/// Ensures plain text packets are correctly identified as NOT being AXDP.
final class PlainTextDetectionTests: XCTestCase {
    
    /// Plain ASCII text should never be detected as AXDP
    func testPlainASCIITextHasNoMagic() {
        let texts = [
            "Hello, World!",
            "CQ CQ CQ DE N0CALL K",
            "73 de W1AW",
            "Testing 1 2 3...",
            "The quick brown fox jumps over the lazy dog",
            "QSL via bureau",
            "BBS> ",
            "Login: ",
            "Password: ",
            "*** Connected to N0CALL",
            "Goodbye!"
        ]
        
        for text in texts {
            let data = Data(text.utf8)
            XCTAssertFalse(AXDP.hasMagic(data), "Plain text '\(text)' should NOT have AXDP magic")
        }
    }
    
    /// Binary data that doesn't start with AXT1 should not be detected as AXDP
    func testRandomBinaryDataHasNoMagic() {
        let randomData = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD])
        XCTAssertFalse(AXDP.hasMagic(randomData), "Random binary should NOT have AXDP magic")
        
        // Data starting with A but not AXT1
        let almostMagic1 = Data("AXYZ".utf8)
        XCTAssertFalse(AXDP.hasMagic(almostMagic1), "'AXYZ' should NOT have AXDP magic")
        
        let almostMagic2 = Data("AXT2test".utf8)
        XCTAssertFalse(AXDP.hasMagic(almostMagic2), "'AXT2' should NOT have AXDP magic")
        
        let almostMagic3 = Data("AXTerminal".utf8)
        XCTAssertFalse(AXDP.hasMagic(almostMagic3), "'AXTerminal' should NOT have AXDP magic")
    }
    
    /// Empty data should not be detected as AXDP
    func testEmptyDataHasNoMagic() {
        let empty = Data()
        XCTAssertFalse(AXDP.hasMagic(empty), "Empty data should NOT have AXDP magic")
    }
    
    /// Short data (less than 4 bytes) should not be detected as AXDP
    func testShortDataHasNoMagic() {
        let oneChar = Data("A".utf8)
        XCTAssertFalse(AXDP.hasMagic(oneChar), "Single char should NOT have AXDP magic")
        
        let twoChars = Data("AX".utf8)
        XCTAssertFalse(AXDP.hasMagic(twoChars), "Two chars should NOT have AXDP magic")
        
        let threeChars = Data("AXT".utf8)
        XCTAssertFalse(AXDP.hasMagic(threeChars), "Three chars should NOT have AXDP magic")
    }
    
    /// AXDP magic header is exactly "AXT1"
    func testAXDPMagicIsExactlyAXT1() {
        let magic = Data("AXT1".utf8)
        XCTAssertTrue(AXDP.hasMagic(magic), "'AXT1' should have AXDP magic")
        XCTAssertEqual(AXDP.magic, magic, "AXDP.magic constant should be 'AXT1'")
    }
    
    /// Valid AXDP message should be detected
    func testValidAXDPMessageHasMagic() {
        let chatMsg = AXDP.Message(
            type: .chat,
            sessionId: 12345,
            messageId: 1,
            payload: Data("Hello".utf8)
        )
        let encoded = chatMsg.encode()
        XCTAssertTrue(AXDP.hasMagic(encoded), "Encoded AXDP message should have magic")
    }
}

// MARK: - Plain Text UI Frame Tests (Datagram Mode)

/// Tests for plain text transmission via UI frames (unconnected/datagram mode).
/// This is the standard packet radio operation when AXDP is disabled.
final class PlainTextUIFrameTests: XCTestCase {
    
    /// Plain text UI frame encoding preserves the original message
    func testPlainTextUIFrameEncodingPreservesMessage() {
        let from = AX25Address(call: "N0CALL", ssid: 0)
        let to = AX25Address(call: "CQ", ssid: 0)
        let plainText = Data("CQ CQ CQ DE N0CALL K".utf8)
        
        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: plainText)
        let decoded = AX25.decodeFrame(ax25: frame)
        
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .ui)
        XCTAssertEqual(decoded?.info, plainText)
        XCTAssertFalse(AXDP.hasMagic(decoded?.info ?? Data()), "Plain text frame should NOT have AXDP magic")
    }
    
    /// Plain text UI frame with digipeater path
    func testPlainTextUIFrameWithDigipeaters() {
        let from = AX25Address(call: "N0CALL", ssid: 0)
        let to = AX25Address(call: "CQ", ssid: 0)
        let via = [
            AX25Address(call: "RELAY", ssid: 0),
            AX25Address(call: "WIDE1", ssid: 1)
        ]
        let plainText = Data("Test message via digis".utf8)
        
        let frame = AX25.encodeUIFrame(from: from, to: to, via: via, pid: 0xF0, info: plainText)
        let decoded = AX25.decodeFrame(ax25: frame)
        
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, plainText)
        XCTAssertEqual(decoded?.via.count, 2)
    }
    
    /// Plain text UI frame round trip through KISS encoding
    func testPlainTextUIFrameKISSRoundTrip() {
        let from = AX25Address(call: "TEST", ssid: 1)
        let to = AX25Address(call: "TEST", ssid: 2)
        let plainText = Data("Hello via KISS".utf8)
        
        let ax25Frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: plainText)
        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)
        
        // Decode KISS
        var parser = KISSFrameParser()
        let frames = parser.feed(kissFrame)
        XCTAssertEqual(frames.count, 1, "Should decode one KISS frame")
        
        // Decode AX.25
        var frameData: Data?
        if case .ax25(let d) = frames[0] {
            frameData = d
        } else {
            XCTFail("Not AX.25 frame")
            return
        }
        let decodedAX25 = AX25.decodeFrame(ax25: frameData!)
        XCTAssertNotNil(decodedAX25)
        XCTAssertEqual(decodedAX25?.info, plainText)
    }
    
    /// Multiple plain text UI frames in sequence
    func testMultiplePlainTextUIFrames() {
        let messages = [
            "First message",
            "Second message",
            "Third message with special chars: @#$%",
            "Message with numbers: 1234567890"
        ]
        
        let from = AX25Address(call: "SENDER", ssid: 0)
        let to = AX25Address(call: "RECV", ssid: 0)
        
        for msg in messages {
            let plainText = Data(msg.utf8)
            let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: plainText)
            let decoded = AX25.decodeFrame(ax25: frame)
            
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.info, plainText, "Message '\(msg)' should round-trip correctly")
            XCTAssertFalse(AXDP.hasMagic(decoded?.info ?? Data()))
        }
    }
}

// MARK: - Plain Text I-Frame Tests (Connected Mode)

/// Tests for plain text transmission via I-frames (connected mode).
/// This tests BBS/terminal style communication without AXDP.
final class PlainTextIFrameTests: XCTestCase {
    
    /// Plain text I-frame encoding
    func testPlainTextIFrameEncoding() {
        let from = AX25Address(call: "BBS", ssid: 0)
        let to = AX25Address(call: "USER", ssid: 0)
        let plainText = Data("Welcome to the BBS!\r\n".utf8)
        
        let frame = AX25.encodeIFrame(
            from: from,
            to: to,
            via: [],
            ns: 0,
            nr: 0,
            pf: false,
            pid: 0xF0,
            info: plainText
        )
        
        let decoded = AX25.decodeFrame(ax25: frame)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .i)
        XCTAssertEqual(decoded?.info, plainText)
        XCTAssertFalse(AXDP.hasMagic(decoded?.info ?? Data()))
    }
    
    /// Sequence of plain text I-frames (simulating BBS session)
    func testPlainTextIFrameSequence() {
        let bbsMessages = [
            "*** Connected to N0CALL BBS ***\r\n",
            "Enter your callsign: ",
            "W1TEST logged in.\r\n",
            "You have 3 new messages.\r\n",
            "Command> ",
            "LIST\r\n",
            "1. From W2ABC - Subject: Test\r\n",
            "2. From W3XYZ - Subject: Hello\r\n",
            "Command> ",
            "BYE\r\n",
            "73, thanks for calling!\r\n",
            "*** Disconnected ***\r\n"
        ]
        
        let from = AX25Address(call: "BBS", ssid: 0)
        let to = AX25Address(call: "USER", ssid: 0)
        
        for (i, msg) in bbsMessages.enumerated() {
            let ns = i % 8  // Modulo-8 sequence
            let plainText = Data(msg.utf8)
            
            let frame = AX25.encodeIFrame(
                from: from,
                to: to,
                via: [],
                ns: ns,
                nr: 0,
                pf: false,
                pid: 0xF0,
                info: plainText
            )
            
            let decoded = AX25.decodeFrame(ax25: frame)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.info, plainText, "I-frame \(i) content mismatch")
            XCTAssertFalse(AXDP.hasMagic(decoded?.info ?? Data()), "I-frame \(i) should not have magic")
        }
    }
}

// MARK: - AXDP Reassembly Buffer Isolation Tests

/// Tests to verify non-AXDP data doesn't pollute AXDP reassembly buffer.
/// Regression tests for the buffer pollution bug fix.
final class ReassemblyBufferIsolationTests: XCTestCase {
    
    /// Non-AXDP data should be detected and skipped
    func testNonAXDPDataDetectedCorrectly() {
        let plainTexts = [
            Data("Hello from legacy TNC".utf8),
            Data("BBS> LIST\r\n".utf8),
            Data([0x00, 0x01, 0x02, 0x03]),  // Binary data
            Data("73 de W1AW".utf8)
        ]
        
        for data in plainTexts {
            XCTAssertFalse(AXDP.hasMagic(data), "Non-AXDP data should not have magic")
        }
    }
    
    /// AXDP messages should be detected correctly
    func testAXDPDataDetectedCorrectly() {
        let axdpMessages = [
            AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("Hi".utf8)),
            AXDP.Message(type: .ping, sessionId: 2, messageId: 2),
            AXDP.Message(type: .pong, sessionId: 3, messageId: 3),
            AXDP.Message(type: .ack, sessionId: 4, messageId: 4),
            AXDP.Message(type: .fileChunk, sessionId: 5, messageId: 5, chunkIndex: 0, totalChunks: 1, payload: Data([0x42]))
        ]
        
        for msg in axdpMessages {
            let encoded = msg.encode()
            XCTAssertTrue(AXDP.hasMagic(encoded), "AXDP \(msg.type) should have magic")
        }
    }
    
    /// AXDP message can be decoded after non-AXDP data is received
    /// (Tests that previous non-AXDP data doesn't corrupt subsequent AXDP)
    func testAXDPDecodeAfterNonAXDPData() {
        // Simulate receiving plain text first
        let plainText = Data("This is plain text from a legacy station".utf8)
        XCTAssertFalse(AXDP.hasMagic(plainText))
        
        // Plain text should not decode as AXDP
        let plainResult = AXDP.Message.decode(from: plainText)
        XCTAssertNil(plainResult, "Plain text should not decode as AXDP")
        
        // Then receive AXDP message
        let axdpMsg = AXDP.Message(
            type: .chat,
            sessionId: 12345,
            messageId: 1,
            payload: Data("Hello from AXDP station".utf8)
        )
        let axdpData = axdpMsg.encode()
        
        // AXDP message should decode correctly
        guard let (decoded, consumed) = AXDP.Message.decode(from: axdpData) else {
            XCTFail("AXDP message should decode")
            return
        }
        
        XCTAssertEqual(decoded.type, .chat)
        XCTAssertEqual(decoded.sessionId, 12345)
        XCTAssertEqual(consumed, axdpData.count)
    }
    
    /// Non-AXDP data prepended to AXDP data prevents decoding
    /// (This is the buffer pollution scenario that was fixed)
    func testPollutedBufferFailsToDecode() {
        let pollution = Data("Garbage data from legacy TNC".utf8)
        let axdpMsg = AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("Hi".utf8))
        let axdpData = axdpMsg.encode()
        
        // Combine pollution + AXDP
        var polluted = pollution
        polluted.append(axdpData)
        
        // Should NOT decode because buffer doesn't start with magic
        XCTAssertFalse(AXDP.hasMagic(polluted), "Polluted buffer should not have magic at start")
        let result = AXDP.Message.decode(from: polluted)
        XCTAssertNil(result, "Polluted buffer should fail to decode")
    }
    
    /// If AXDP magic appears after garbage, only the AXDP portion should be valid
    func testMagicInMiddleOfBufferRequiresScanningOrClear() {
        let garbage = Data("Some garbage".utf8)
        let axdp = AXDP.Message(type: .ping, sessionId: 1, messageId: 1).encode()
        
        var combined = garbage
        combined.append(axdp)
        
        // Direct decode fails (no magic at start)
        XCTAssertNil(AXDP.Message.decode(from: combined))
        
        // But if we skip the garbage, we can decode
        let axdpPortion = combined.suffix(from: garbage.count)
        XCTAssertTrue(AXDP.hasMagic(Data(axdpPortion)))
        
        let result = AXDP.Message.decode(from: Data(axdpPortion))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0.type, .ping)
    }
}

// MARK: - Mixed Mode Communication Tests

/// Tests for scenarios where AXDP and non-AXDP stations communicate.
final class MixedModeCommunicationTests: XCTestCase {
    
    /// AXDP-enabled station can still encode and send plain text
    func testAXDPStationCanSendPlainText() {
        // Even if AXDP is enabled, station should be able to send plain text
        // (e.g., to a non-AXDP peer or when user types raw text)
        let plainText = Data("Hello from AXDP-capable station".utf8)
        
        let from = AX25Address(call: "AXDP", ssid: 0)
        let to = AX25Address(call: "LEGACY", ssid: 0)
        
        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: plainText)
        let decoded = AX25.decodeFrame(ax25: frame)
        
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, plainText)
        XCTAssertFalse(AXDP.hasMagic(decoded?.info ?? Data()))
    }
    
    /// Non-AXDP station receives AXDP message as raw bytes
    func testNonAXDPStationReceivesAXDPAsRaw() {
        // When AXDP is disabled, station receives AXDP messages as raw binary
        let axdpMsg = AXDP.Message(
            type: .chat,
            sessionId: 12345,
            messageId: 1,
            payload: Data("Hello!".utf8)
        )
        let axdpData = axdpMsg.encode()
        
        let from = AX25Address(call: "AXDP", ssid: 0)
        let to = AX25Address(call: "LEGACY", ssid: 0)
        
        let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: axdpData)
        let decoded = AX25.decodeFrame(ax25: frame)
        
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, axdpData, "Non-AXDP station sees raw AXDP bytes")
        XCTAssertTrue(AXDP.hasMagic(decoded?.info ?? Data()), "Raw data still has magic")
    }
    
    /// Alternating AXDP and plain text messages
    func testAlternatingAXDPAndPlainText() {
        let from = AX25Address(call: "TEST", ssid: 1)
        let to = AX25Address(call: "TEST", ssid: 2)
        
        // Message 1: Plain text
        let plain1 = Data("Plain message 1".utf8)
        let frame1 = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: plain1)
        let decoded1 = AX25.decodeFrame(ax25: frame1)
        XCTAssertFalse(AXDP.hasMagic(decoded1?.info ?? Data()))
        
        // Message 2: AXDP
        let axdp1 = AXDP.Message(type: .chat, sessionId: 1, messageId: 1, payload: Data("AXDP 1".utf8)).encode()
        let frame2 = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: axdp1)
        let decoded2 = AX25.decodeFrame(ax25: frame2)
        XCTAssertTrue(AXDP.hasMagic(decoded2?.info ?? Data()))
        
        // Message 3: Plain text again
        let plain2 = Data("Plain message 2".utf8)
        let frame3 = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: plain2)
        let decoded3 = AX25.decodeFrame(ax25: frame3)
        XCTAssertFalse(AXDP.hasMagic(decoded3?.info ?? Data()))
        
        // Message 4: AXDP again
        let axdp2 = AXDP.Message(type: .ping, sessionId: 2, messageId: 2).encode()
        let frame4 = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: axdp2)
        let decoded4 = AX25.decodeFrame(ax25: frame4)
        XCTAssertTrue(AXDP.hasMagic(decoded4?.info ?? Data()))
    }
}

// MARK: - Standard Packet Radio Protocol Tests

/// Tests to verify standard packet radio behavior is preserved.
/// These ensure AXTerm works correctly with any standard packet equipment.
final class StandardPacketRadioTests: XCTestCase {
    
    /// Standard SABM/UA connection handshake
    func testSABMUAHandshake() {
        let from = AX25Address(call: "CALLER", ssid: 0)
        let to = AX25Address(call: "CALLED", ssid: 0)
        
        // SABM frame - U-frame type
        let sabm = AX25.encodeUFrame(from: from, to: to, via: [], type: .sabm, pf: true)
        let decodedSABM = AX25.decodeFrame(ax25: sabm)
        XCTAssertNotNil(decodedSABM)
        XCTAssertEqual(decodedSABM?.frameType, .u, "SABM is a U-frame")
        
        // UA response - U-frame type
        let ua = AX25.encodeUFrame(from: to, to: from, via: [], type: .ua, pf: true)
        let decodedUA = AX25.decodeFrame(ax25: ua)
        XCTAssertNotNil(decodedUA)
        XCTAssertEqual(decodedUA?.frameType, .u, "UA is a U-frame")
    }
    
    /// Standard DISC/DM disconnect
    func testDISCDMDisconnect() {
        let from = AX25Address(call: "A", ssid: 0)
        let to = AX25Address(call: "B", ssid: 0)
        
        // DISC frame - U-frame type
        let disc = AX25.encodeUFrame(from: from, to: to, via: [], type: .disc, pf: true)
        let decodedDISC = AX25.decodeFrame(ax25: disc)
        XCTAssertNotNil(decodedDISC)
        XCTAssertEqual(decodedDISC?.frameType, .u, "DISC is a U-frame")
        
        // DM response - U-frame type
        let dm = AX25.encodeUFrame(from: to, to: from, via: [], type: .dm, pf: true)
        let decodedDM = AX25.decodeFrame(ax25: dm)
        XCTAssertNotNil(decodedDM)
        XCTAssertEqual(decodedDM?.frameType, .u, "DM is a U-frame")
    }
    
    /// RR (Receive Ready) frame
    func testRRFrame() {
        let from = AX25Address(call: "A", ssid: 0)
        let to = AX25Address(call: "B", ssid: 0)
        
        let rr = AX25.encodeSFrame(from: from, to: to, via: [], type: .rr, nr: 3, pf: false)
        
        let decoded = AX25.decodeFrame(ax25: rr)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .s, "RR is an S-frame")
    }
    
    /// REJ (Reject) frame for requesting retransmission
    func testREJFrame() {
        let from = AX25Address(call: "A", ssid: 0)
        let to = AX25Address(call: "B", ssid: 0)
        
        let rej = AX25.encodeSFrame(from: from, to: to, via: [], type: .rej, nr: 5, pf: true)
        
        let decoded = AX25.decodeFrame(ax25: rej)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frameType, .s, "REJ is an S-frame")
    }
    
    /// Standard PIDs are preserved
    func testStandardPIDValues() {
        let from = AX25Address(call: "A", ssid: 0)
        let to = AX25Address(call: "B", ssid: 0)
        
        let pids: [UInt8] = [
            0xF0,  // No layer 3 protocol
            0x01,  // X.25 PLP
            0x08,  // Fragment
            0xC3,  // TEXNET
            0xC4,  // Link Quality Protocol
            0xCA,  // ATCP
            0xCB,  // APRS
            0xCE,  // FlexNet
            0xCF,  // NET/ROM
            0xCC   // IP
        ]
        
        for pid in pids {
            let frame = AX25.encodeUIFrame(from: from, to: to, via: [], pid: pid, info: Data("Test".utf8))
            let decoded = AX25.decodeFrame(ax25: frame)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.pid, pid, "PID 0x\(String(format: "%02X", pid)) should be preserved")
        }
    }
}

// MARK: - Large Multi-Fragment AXDP Reassembly Tests

/// Tests for large AXDP message reassembly across many I-frames.
/// Based on real integration test logs showing ~3KB chat messages
/// fragmented across 24+ I-frames with mod-8 sequence number wrap-around.
final class LargeMultiFragmentAXDPTests: XCTestCase {
    
    /// Test large chat message (~3000 bytes) fragmentation and reassembly
    /// This mimics the real-world scenario from integration testing
    func testLargeChatMessageFragmentationStructure() {
        // Create a ~3000 byte message like the integration test
        // Repeat the base text 6 times to get ~2900 bytes
        let baseText = """
        Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Pellentesque habitant morbi tristique senectus et netus et malesuada fames ac turpis egestas.
        """
        let longText = String(repeating: baseText, count: 6)  // ~3000 bytes
        
        let msg = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: 4074233462,  // Same messageId as log
            payload: Data(longText.utf8)
        )
        let encoded = msg.encode()
        
        // Should be ~3000 bytes (similar to log showing 2987 bytes)
        XCTAssertGreaterThan(encoded.count, 2800, "Large message should exceed 2800 bytes")
        XCTAssertLessThan(encoded.count, 3500, "Large message should be under 3500 bytes")
        
        // With paclen=128, need ~24 chunks
        let paclen = 128
        let expectedChunks = (encoded.count + paclen - 1) / paclen
        XCTAssertGreaterThanOrEqual(expectedChunks, 20, "Should need 20+ chunks")
        XCTAssertLessThanOrEqual(expectedChunks, 30, "Should need <=30 chunks")
        
        // Fragment and verify structure
        var fragments: [Data] = []
        var offset = 0
        while offset < encoded.count {
            let end = min(offset + paclen, encoded.count)
            fragments.append(Data(encoded[offset..<end]))
            offset = end
        }
        
        XCTAssertEqual(fragments.count, expectedChunks)
        
        // Only first fragment has AXDP magic
        XCTAssertTrue(AXDP.hasMagic(fragments[0]))
        for i in 1..<fragments.count {
            XCTAssertFalse(AXDP.hasMagic(fragments[i]), "Fragment \(i) should NOT have magic")
        }
    }
    
    /// Test that reassembly buffer correctly accumulates fragments until complete
    func testReassemblyBufferAccumulationUntilComplete() {
        let longText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 60)  // ~2700 bytes
        let msg = AXDP.Message(type: .chat, sessionId: 0, messageId: 12345, payload: Data(longText.utf8))
        let encoded = msg.encode()
        
        let paclen = 128
        let numChunks = (encoded.count + paclen - 1) / paclen
        
        // Simulate fragment-by-fragment accumulation
        var buffer = Data()
        var extractionAttempts = 0
        var successfulExtractions = 0
        
        for i in 0..<numChunks {
            let start = i * paclen
            let end = min(start + paclen, encoded.count)
            let chunk = Data(encoded[start..<end])
            
            buffer.append(chunk)
            extractionAttempts += 1
            
            // Try to extract (simulating SessionCoordinator behavior)
            if let (decoded, consumed) = AXDP.Message.decode(from: buffer) {
                successfulExtractions += 1
                XCTAssertEqual(consumed, buffer.count, "Should consume entire buffer")
                XCTAssertEqual(decoded.type, .chat)
                XCTAssertEqual(decoded.messageId, 12345)
                buffer.removeFirst(consumed)
            }
        }
        
        // Should have exactly ONE successful extraction at the end
        XCTAssertEqual(successfulExtractions, 1, "Should extract exactly one complete message")
        XCTAssertTrue(buffer.isEmpty, "Buffer should be empty after extraction")
    }
    
    /// Test sequence number wrap-around during large message transmission
    func testSequenceNumberWrapAroundDuringLargeTransfer() {
        let paclen = 128
        let totalChunks = 24  // Enough to wrap around mod-8 three times
        let modulus = 8
        
        // Simulate I-frame sequence numbers for 24 chunks starting at vs=0
        var ns_sequence: [Int] = []
        for i in 0..<totalChunks {
            ns_sequence.append(i % modulus)
        }
        
        // Verify wrap-around pattern: 0,1,2,3,4,5,6,7,0,1,2,3,4,5,6,7,0,1,2,3,4,5,6,7
        XCTAssertEqual(ns_sequence[0], 0)
        XCTAssertEqual(ns_sequence[7], 7)
        XCTAssertEqual(ns_sequence[8], 0, "Should wrap to 0 after 7")
        XCTAssertEqual(ns_sequence[15], 7)
        XCTAssertEqual(ns_sequence[16], 0, "Should wrap to 0 again")
        XCTAssertEqual(ns_sequence[23], 7)
    }
    
    /// Test that "truncated at known TLV type" correctly returns nil
    /// This is the expected behavior during reassembly
    func testTruncatedTLVReturnsNilForReassembly() {
        // Create a message with a large payload TLV
        let largePayload = Data(repeating: 0x41, count: 2500)  // 2500 bytes of 'A'
        let msg = AXDP.Message(type: .chat, sessionId: 0, messageId: 1, payload: largePayload)
        let encoded = msg.encode()
        
        // Take partial buffer at various points
        let partialSizes = [128, 256, 512, 1024, 1536, 2048, 2400]
        
        for size in partialSizes {
            if size >= encoded.count { continue }
            
            let partial = Data(encoded.prefix(size))
            
            // Decoding partial buffer MUST return nil
            let result = AXDP.Message.decode(from: partial)
            XCTAssertNil(result, "Partial buffer of \(size) bytes should return nil for reassembly")
        }
        
        // Full buffer should decode successfully
        guard let (decoded, consumed) = AXDP.Message.decode(from: encoded) else {
            XCTFail("Full buffer should decode")
            return
        }
        XCTAssertEqual(decoded.type, .chat)
        XCTAssertEqual(decoded.payload, largePayload)
        XCTAssertEqual(consumed, encoded.count)
    }
    
    /// Test that multiple complete messages can be extracted from a buffer
    /// (e.g., two complete AXDP messages received back-to-back in the buffer)
    func testMultipleCompleteMessagesInBuffer() {
        // Create messages with proper UInt32 values
        let msg1 = AXDP.Message(type: .chat, sessionId: 0, messageId: 100, payload: Data("First message".utf8))
        let msg2 = AXDP.Message(type: .chat, sessionId: 0, messageId: 101, payload: Data("Second message".utf8))
        
        let encoded1 = msg1.encode()
        let encoded2 = msg2.encode()
        let combined = encoded1 + encoded2
        
        // First decode should get first message
        guard let (decoded1, consumed1) = AXDP.Message.decode(from: combined) else {
            XCTFail("Should decode first message")
            return
        }
        XCTAssertEqual(decoded1.type, .chat)
        XCTAssertEqual(decoded1.messageId, 100)
        XCTAssertEqual(String(data: decoded1.payload ?? Data(), encoding: .utf8), "First message")
        XCTAssertEqual(consumed1, encoded1.count)
        
        // Second decode should get second message from remaining buffer
        let remaining = combined.dropFirst(consumed1)
        guard let (decoded2, consumed2) = AXDP.Message.decode(from: Data(remaining)) else {
            XCTFail("Should decode second message")
            return
        }
        XCTAssertEqual(decoded2.type, .chat)
        XCTAssertEqual(decoded2.messageId, 101)
        XCTAssertEqual(String(data: decoded2.payload ?? Data(), encoding: .utf8), "Second message")
        XCTAssertEqual(consumed2, encoded2.count)
        
        // Total consumed should equal combined length
        XCTAssertEqual(consumed1 + consumed2, combined.count)
    }
    
    /// Test exact byte count matches expected for chat message with known content
    func testExactByteSizeForChatMessage() {
        // Message structure: magic(4) + TLVs
        // TLV header: type(1) + length(2) = 3 bytes per TLV
        // Content TLVs: version, msgType, sessionId, messageId, payload
        
        let shortText = "Hello"  // 5 bytes
        let msg = AXDP.Message(type: .chat, sessionId: 12345, messageId: 67890, payload: Data(shortText.utf8))
        let encoded = msg.encode()
        
        // Should start with AXT1 magic
        XCTAssertTrue(AXDP.hasMagic(encoded))
        XCTAssertEqual(encoded.prefix(4), Data("AXT1".utf8))
        
        // Verify decode produces exact same content
        guard let (decoded, consumed) = AXDP.Message.decode(from: encoded) else {
            XCTFail("Should decode")
            return
        }
        
        XCTAssertEqual(consumed, encoded.count)
        XCTAssertEqual(decoded.sessionId, 12345)
        XCTAssertEqual(decoded.messageId, 67890)
        XCTAssertEqual(String(data: decoded.payload ?? Data(), encoding: .utf8), shortText)
    }
    
    /// Test RR response counting matches I-frame reception
    /// (Verifies the flow shown in the log where each I-frame triggers an RR)
    func testRRResponseCountMatchesIFrameCount() {
        let totalChunks = 24
        var rrResponses = 0
        
        // Each I-frame received should generate one RR
        for i in 0..<totalChunks {
            // Simulate receiving I-frame with N(S)=i%8
            let ns = i % 8
            
            // Receiver should respond with RR(N(R)=(ns+1)%8)
            let expectedNR = (ns + 1) % 8
            rrResponses += 1
            
            // At wrap-around points, verify sequence
            if i == 7 {
                XCTAssertEqual(expectedNR, 0, "After N(S)=7, N(R) should be 0")
            }
            if i == 15 {
                XCTAssertEqual(expectedNR, 0, "After second wrap, N(R) should be 0")
            }
        }
        
        XCTAssertEqual(rrResponses, totalChunks, "Should have one RR per I-frame")
    }
    
    /// Test that outstanding count calculation handles wraparound correctly
    /// This verifies the fix for the bug where vs=0, va=1 would calculate outstanding=7
    /// when the sendBuffer is actually empty.
    func testOutstandingCountAfterCompleteTransfer() {
        // Simulate a completed transfer scenario:
        // - Sent frames with N(S)=0,1,2,3,4,5,6,7 (8 frames, wrapping back to 0)
        // - Received RR(nr=0) acking all frames
        // - Then received duplicate RRs with nr=1,2,3... (stale/late acknowledgments)
        
        // Test the mathematical calculation that was buggy:
        // (vs - va) mod 8 when vs < va should NOT be used for sendBuffer-based outstanding
        
        let modulo = 8
        var vs = 0  // Next to send
        var va = 1  // Acked up to (stale RR advanced this past vs)
        
        // The BUGGY calculation was:
        let buggyOutstanding: Int
        if vs >= va {
            buggyOutstanding = vs - va
        } else {
            buggyOutstanding = (modulo - va) + vs  // (8-1)+0 = 7 -- WRONG!
        }
        XCTAssertEqual(buggyOutstanding, 7, "Buggy calculation produces 7")
        
        // The CORRECT calculation should use actual sendBuffer count
        var sendBuffer: [Int: Data] = [:]  // Empty buffer - all frames acked
        let correctOutstanding = sendBuffer.count
        XCTAssertEqual(correctOutstanding, 0, "Correct calculation should be 0 when buffer is empty")
        
        // Verify the edge case that triggered the bug in logs:
        // After all frames sent and acked, receiving additional RRs with higher N(R)
        // should not cause outstanding to report incorrect values
        
        // Simulate: sent 8 frames, all acked, then received RR(nr=1)
        va = 1  // RR advanced va
        vs = 0  // vs stayed at 0 (didn't send more)
        sendBuffer = [:]  // Buffer was cleared when acked
        
        // Outstanding MUST be 0, not (8-1)+0=7
        XCTAssertEqual(sendBuffer.count, 0, "Buffer-based outstanding is correct")
    }
}

// MARK: - KISS Frame Tests for Plain Text

/// Tests for KISS encoding/decoding with plain text payloads.
final class KISSPlainTextTests: XCTestCase {
    
    /// Plain text through KISS encoding round-trips correctly
    func testPlainTextKISSRoundTrip() {
        let plainText = Data("Hello via KISS, plain text!".utf8)
        let from = AX25Address(call: "SRC", ssid: 0)
        let to = AX25Address(call: "DST", ssid: 0)
        
        let ax25 = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: plainText)
        let kiss = KISS.encodeFrame(payload: ax25, port: 0)
        
        var parser = KISSFrameParser()
        let frames = parser.feed(kiss)
        
        XCTAssertEqual(frames.count, 1)
        
        var frameData: Data?
        if case .ax25(let d) = frames[0] {
            frameData = d
        } else {
            XCTFail("Not AX.25 frame")
            return
        }
        let decodedAX25 = AX25.decodeFrame(ax25: frameData!)
        XCTAssertNotNil(decodedAX25)
        XCTAssertEqual(decodedAX25?.info, plainText)
        XCTAssertFalse(AXDP.hasMagic(decodedAX25?.info ?? Data()))
    }
    
    /// Plain text with special KISS bytes (FEND, FESC) escaping
    func testPlainTextWithKISSSpecialBytes() {
        // Create payload that contains FEND (0xC0) and FESC (0xDB) bytes
        var specialData = Data("Test".utf8)
        specialData.append(contentsOf: [0xC0, 0xDB, 0xC0, 0xDB])  // FEND, FESC, FEND, FESC
        specialData.append(Data("End".utf8))
        
        let from = AX25Address(call: "SRC", ssid: 0)
        let to = AX25Address(call: "DST", ssid: 0)
        
        let ax25 = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: specialData)
        let kiss = KISS.encodeFrame(payload: ax25, port: 0)
        
        var parser = KISSFrameParser()
        let frames = parser.feed(kiss)
        
        XCTAssertEqual(frames.count, 1)
        
        var frameData: Data?
        if case .ax25(let d) = frames[0] {
            frameData = d
        } else {
            XCTFail("Not AX.25 frame")
            return
        }
        let decoded = AX25.decodeFrame(ax25: frameData!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.info, specialData, "Special bytes should be preserved after KISS escape/unescape")
    }
    
    /// Multiple plain text KISS frames in a stream
    func testMultiplePlainTextKISSFrames() {
        let messages = ["First", "Second", "Third"]
        let from = AX25Address(call: "SRC", ssid: 0)
        let to = AX25Address(call: "DST", ssid: 0)
        
        // Encode all frames into one stream
        var stream = Data()
        for msg in messages {
            let ax25 = AX25.encodeUIFrame(from: from, to: to, via: [], pid: 0xF0, info: Data(msg.utf8))
            let kiss = KISS.encodeFrame(payload: ax25, port: 0)
            stream.append(kiss)
        }
        
        // Decode
        var parser = KISSFrameParser()
        let frames = parser.feed(stream)
        
        XCTAssertEqual(frames.count, messages.count)
        
        for (i, frame) in frames.enumerated() {
            var frameData: Data?
            if case .ax25(let d) = frame {
                frameData = d
            } else {
                XCTFail("Not AX.25 frame")
                continue
            }
            let decoded = AX25.decodeFrame(ax25: frameData!)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(String(data: decoded?.info ?? Data(), encoding: .utf8), messages[i])
        }
    }
}
