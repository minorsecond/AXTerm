import XCTest
@testable import AXTerm

/// CI-V bytes, pinned: every frame the app can send, and how replies parse.
final class CIVFrameTests: XCTestCase {

    private func hex(_ frame: CIVFrame) -> String {
        frame.encoded().map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - Commands, byte for byte

    func testIdentityAndPTT() {
        XCTAssertEqual(hex(CIVCommand.identify()), "FE FE A4 E0 19 00 FD")
        XCTAssertEqual(hex(CIVCommand.setPTT(true)), "FE FE A4 E0 1C 00 01 FD")
        XCTAssertEqual(hex(CIVCommand.setPTT(false)), "FE FE A4 E0 1C 00 00 FD")
        XCTAssertEqual(hex(CIVCommand.readPTT()), "FE FE A4 E0 1C 00 FD")
    }

    func testFrequencyAndMode() {
        XCTAssertEqual(hex(CIVCommand.readFrequency()), "FE FE A4 E0 03 FD")
        XCTAssertEqual(hex(CIVCommand.setFrequency(hz: 144_390_000)), "FE FE A4 E0 05 00 00 39 44 01 FD")
        XCTAssertEqual(hex(CIVCommand.readMode()), "FE FE A4 E0 04 FD")
        XCTAssertEqual(hex(CIVCommand.setMode(.fm)), "FE FE A4 E0 06 05 FD")
        XCTAssertEqual(hex(CIVCommand.setMode(.usb, filter: 1)), "FE FE A4 E0 06 01 01 FD")
        XCTAssertEqual(hex(CIVCommand.setDataMode(true, filter: 1)), "FE FE A4 E0 1A 06 01 01 FD")
        XCTAssertEqual(hex(CIVCommand.setDataMode(false)), "FE FE A4 E0 1A 06 00 00 FD")
        XCTAssertEqual(hex(CIVCommand.readDataMode()), "FE FE A4 E0 1A 06 FD")
    }

    func testMenuItemsAndMeters() {
        XCTAssertEqual(hex(CIVCommand.setTransceive(false)), "FE FE A4 E0 1A 05 01 31 00 FD")
        XCTAssertEqual(hex(CIVCommand.setEchoBack(false)), "FE FE A4 E0 1A 05 01 32 00 FD")
        XCTAssertEqual(hex(CIVCommand.setScopeDataOutput(false)), "FE FE A4 E0 27 11 00 FD")
        XCTAssertEqual(hex(CIVCommand.setScopeDataOutput(true)), "FE FE A4 E0 27 11 01 FD")
        XCTAssertEqual(hex(CIVCommand.setUSBSendOff()), "FE FE A4 E0 1A 05 01 25 00 FD")
        XCTAssertEqual(hex(CIVCommand.setAFSquelchOpen()), "FE FE A4 E0 1A 05 01 11 00 FD")
        XCTAssertEqual(hex(CIVCommand.setDataModUSB()), "FE FE A4 E0 1A 05 01 19 01 FD")
        XCTAssertEqual(hex(CIVCommand.setUSBModLevel(128)), "FE FE A4 E0 1A 05 01 16 01 28 FD")
        XCTAssertEqual(hex(CIVCommand.setTXDelayOff(.txDelay144M)), "FE FE A4 E0 1A 05 00 41 00 FD")
        XCTAssertEqual(hex(CIVCommand.readSquelchStatus()), "FE FE A4 E0 15 01 FD")
        XCTAssertEqual(hex(CIVCommand.readSMeter()), "FE FE A4 E0 15 02 FD")
        XCTAssertEqual(hex(CIVCommand.setIFWidth(hz: 2100)), "FE FE A4 E0 1A 03 25 FD")
        XCTAssertEqual(hex(CIVCommand.setIFWidth(hz: 1500)), "FE FE A4 E0 1A 03 19 FD")
        XCTAssertEqual(hex(CIVCommand.setIFWidth(hz: 500)), "FE FE A4 E0 1A 03 09 FD")
    }

    func testAnotherRadioAddressIsHonoured() {
        XCTAssertEqual(hex(CIVCommand.identify(radio: 0x94)), "FE FE 94 E0 19 00 FD")
    }

    // MARK: - BCD

    func testFrequencyBCDRoundTrips() {
        for hz in [144_390_000, 7_074_500, 433_500_000, 1_296_100_000, 0, 10] {
            let bytes = CIVBCD.frequencyBytes(hz: hz)
            XCTAssertEqual(bytes.count, 5)
            XCTAssertEqual(CIVBCD.frequencyHz(bytes), hz, "\(hz)")
        }
        XCTAssertEqual(CIVBCD.frequencyBytes(hz: 7_074_500), [0x00, 0x45, 0x07, 0x07, 0x00])
        XCTAssertEqual(CIVBCD.frequencyBytes(hz: 433_500_000), [0x00, 0x00, 0x50, 0x33, 0x04])
        XCTAssertNil(CIVBCD.frequencyHz([0x0A, 0, 0, 0, 0]), "not a decimal digit")
        XCTAssertNil(CIVBCD.frequencyHz([0, 0, 0]), "too short")
    }

    func testMetersAndItems() {
        XCTAssertEqual(CIVBCD.meter([0x01, 0x20]), 120)
        XCTAssertEqual(CIVBCD.meter([0x00, 0x00]), 0)
        XCTAssertEqual(CIVBCD.meter([0x02, 0x55]), 255)
        XCTAssertEqual(CIVBCD.meterBytes(120), [0x01, 0x20])
        XCTAssertEqual(CIVBCD.item(131), [0x01, 0x31])
        XCTAssertEqual(CIVBCD.item(38), [0x00, 0x38])
    }

    // MARK: - Parsing

    func testParsesRepliesWithAndWithoutSubcommands() {
        let ok = CIVFrame.parse([0xFE, 0xFE, 0xE0, 0xA4, 0xFB, 0xFD])!
        XCTAssertTrue(ok.isOK)
        XCTAssertEqual(ok.to, 0xE0); XCTAssertEqual(ok.from, 0xA4)

        let ng = CIVFrame.parse([0xFE, 0xFE, 0xE0, 0xA4, 0xFA, 0xFD])!
        XCTAssertTrue(ng.isNG)

        let freq = CIVFrame.parse([0xFE, 0xFE, 0xE0, 0xA4, 0x03, 0x00, 0x00, 0x39, 0x44, 0x01, 0xFD])!
        XCTAssertEqual(freq.command, 0x03)
        XCTAssertNil(freq.subcommand)
        XCTAssertEqual(CIVBCD.frequencyHz(freq.data), 144_390_000)

        let meter = CIVFrame.parse([0xFE, 0xFE, 0xE0, 0xA4, 0x15, 0x02, 0x01, 0x20, 0xFD])!
        XCTAssertEqual(meter.command, 0x15)
        XCTAssertEqual(meter.subcommand, 0x02)
        XCTAssertEqual(CIVBCD.meter(meter.data), 120)

        let id = CIVFrame.parse([0xFE, 0xFE, 0xE0, 0xA4, 0x19, 0x00, 0xA4, 0xFD])!
        XCTAssertEqual(id.subcommand, 0x00)
        XCTAssertEqual(id.data, [0xA4])
    }

    func testEncodeParseRoundTrip() {
        for frame in [CIVCommand.setFrequency(hz: 7_074_500), CIVCommand.setTransceive(false), CIVCommand.readMode()] {
            XCTAssertEqual(CIVFrame.parse([UInt8](frame.encoded())), frame)
        }
    }

    func testTheParserResyncsAndSpansReads() {
        var parser = CIVFrameParser()
        // Garbage, then a frame split across three reads, then a second frame.
        XCTAssertEqual(parser.feed(Data([0x00, 0x11, 0xFE])), [])
        XCTAssertEqual(parser.feed(Data([0xFE, 0xE0, 0xA4, 0x03])), [])
        let frames = parser.feed(Data([0x00, 0x00, 0x39, 0x44, 0x01, 0xFD, 0xFE, 0xFE, 0xE0, 0xA4, 0xFB, 0xFD]))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].command, 0x03)
        XCTAssertTrue(frames[1].isOK)
    }

    func testExtraPreamblesAreTolerated() {
        let frame = CIVFrame.parse([0xFE, 0xFE, 0xFE, 0xFE, 0xE0, 0xA4, 0xFB, 0xFD])
        XCTAssertEqual(frame?.isOK, true)
    }

    func testEchoAndBroadcastFiltering() {
        let echo = CIVFrame(to: 0xA4, from: 0xE0, command: 0x1C, subcommand: 0x00, data: [0x01])
        let reply = CIVFrame(to: 0xE0, from: 0xA4, command: 0xFB)
        let transceive = CIVFrame(to: 0x00, from: 0xA4, command: 0x00, data: [0x00, 0x00, 0x39, 0x44, 0x01])
        XCTAssertTrue(CIVFilter.isEcho(echo, radio: 0xA4))
        XCTAssertFalse(CIVFilter.isEcho(reply, radio: 0xA4))
        XCTAssertTrue(CIVFilter.isForUs(reply))
        XCTAssertTrue(CIVFilter.isForUs(transceive), "broadcasts are for everyone")
        XCTAssertFalse(CIVFilter.isForUs(echo))
    }

    func testRigStatusLabels() {
        var status = RigStatus()
        status.frequencyHz = 144_390_000
        status.mode = .fm
        status.dataMode = true
        XCTAssertEqual(status.frequencyLabel, "144.390 MHz")
        XCTAssertEqual(status.modeLabel, "FM-D")
        status.dataMode = false
        XCTAssertEqual(status.modeLabel, "FM")
        XCTAssertEqual(CIVKnownRadios.describe(0xA4), "IC-705 (A4)")
        XCTAssertEqual(CIVKnownRadios.describe(0x12), "radio 12")
    }

    /// A dropped UDP packet truncates a scope frame; the acknowledgement that
    /// follows must still be found. Framing on the FIRST preamble pair and the
    /// FIRST terminator makes the half scope frame swallow the ack whole.
    func testATruncatedScopeFrameDoesNotSwallowTheNextAck() {
        var parser = CIVFrameParser()
        // FE FE E0 A4 27 00 <waveform, cut off mid-frame — no FD>
        let truncatedScope: [UInt8] = [0xFE, 0xFE, 0xE0, 0xA4, 0x27, 0x00, 0x01, 0x02, 0x03]
        let ack: [UInt8] = [0xFE, 0xFE, 0xE0, 0xA4, 0xFB, 0xFD]
        let frames = parser.feed(Data(truncatedScope + ack))
        XCTAssertTrue(frames.contains { $0.isOK && $0.from == 0xA4 },
                      "the PTT ack was eaten by the truncated scope frame")
    }

    /// The same wreck arriving in pieces, as UDP delivers it.
    func testTheAckSurvivesWhenTheWreckAndTheAckArriveSeparately() {
        var parser = CIVFrameParser()
        XCTAssertTrue(parser.feed(Data([0xFE, 0xFE, 0xE0, 0xA4, 0x27, 0x00, 0xFE, 0x11, 0x42])).isEmpty,
                      "no terminator yet, so nothing is a frame")
        let frames = parser.feed(Data([0xFE, 0xFE, 0xE0, 0xA4, 0xFB, 0xFD]))
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames.first?.isOK ?? false)
    }

    /// Anchoring on the last preamble must not eat a good frame that simply
    /// follows another good frame in one read.
    func testTwoWholeFramesInOneReadBothSurvive() {
        var parser = CIVFrameParser()
        let scope: [UInt8] = [0xFE, 0xFE, 0xE0, 0xA4, 0x27, 0x00, 0x01, 0xFD]
        let ack: [UInt8] = [0xFE, 0xFE, 0xE0, 0xA4, 0xFB, 0xFD]
        let frames = parser.feed(Data(scope + ack))
        XCTAssertEqual(frames.count, 2, "a complete scope frame is still a frame of its own")
        XCTAssertEqual(frames.first?.command, 0x27)
        XCTAssertTrue(frames.last?.isOK ?? false)
    }
}
