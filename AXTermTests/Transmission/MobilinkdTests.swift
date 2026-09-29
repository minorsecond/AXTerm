//
//  MobilinkdTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2/14/26.
//

import XCTest
@testable import AXTerm

final class MobilinkdTests: XCTestCase {

    func testFrameGeneration() {
        // Test Output Gain (0x01)
        let outGain = MobilinkdTNC.setOutputGain(128)
        XCTAssertEqual(outGain, [0xC0, 0x06, 0x01, 0x00, 128, 0xC0])
        
        // Test Input Gain (0x02)
        let inGain = MobilinkdTNC.setInputGain(4)
        XCTAssertEqual(inGain, [0xC0, 0x06, 0x02, 0x00, 4, 0xC0])
        
        // Modem type is an extended command (0xC1 0x82), carried inside a
        // SetHardware frame. The firmware only dispatches extended commands
        // from its hardware handler, so without the 0x06 the TNC4 ignored it.
        let modem1200 = MobilinkdTNC.setModemType(.afsk1200)
        XCTAssertEqual(modem1200, [0xC0, 0x06, 0xC1, 0x82, 0x01, 0xC0])

        let modem9600 = MobilinkdTNC.setModemType(.fsk9600)
        XCTAssertEqual(modem9600, [0xC0, 0x06, 0xC1, 0x82, 0x03, 0xC0])

        // Test Battery Poll
        let poll = MobilinkdTNC.pollBatteryLevel()
        XCTAssertEqual(poll, [0xC0, 0x06, 0x06, 0xC0])
    }

    /// The queries AXTerm uses to see what the TNC4 holds before changing it,
    /// with opcodes from the firmware's KissHardware.hpp.
    func testQueryFrames() {
        XCTAssertEqual(MobilinkdTNC.getFirmwareVersion(), [0xC0, 0x06, 0x28, 0xC0])
        XCTAssertEqual(MobilinkdTNC.getOutputGain(), [0xC0, 0x06, 0x0C, 0xC0])
        XCTAssertEqual(MobilinkdTNC.getInputGain(), [0xC0, 0x06, 0x0D, 0xC0])
        XCTAssertEqual(MobilinkdTNC.getModemType(), [0xC0, 0x06, 0xC1, 0x81, 0xC0])
    }

    /// Output gain is a big-endian uint16 and the firmware allows 256, which
    /// does not fit a byte.
    func testOutputGainCarriesBothBytes() {
        XCTAssertEqual(MobilinkdTNC.setOutputGain(256), [0xC0, 0x06, 0x01, 0x01, 0x00, 0xC0])
    }

    /// Replies captured from a TNC4 Rev B on firmware 2.5.14 (2026-09-29).
    func testParsesRealTNC4Replies() {
        XCTAssertEqual(MobilinkdTNC.parseFirmwareVersion(Data([0x06, 0x28, 0x32, 0x2E, 0x35, 0x2E, 0x31, 0x34])), "2.5.14")
        XCTAssertEqual(MobilinkdTNC.parseOutputGain(Data([0x06, 0x0C, 0x00, 0x3F])), 63)
        XCTAssertEqual(MobilinkdTNC.parseInputGain(Data([0x06, 0x0D, 0x00, 0x04])), 4)
        XCTAssertEqual(MobilinkdTNC.parseModemType(Data([0x06, 0xC1, 0x81, 0x01])), 1)
        XCTAssertNil(MobilinkdTNC.parseModemType(Data([0x06, 0xC1, 0x83, 0x01, 0x03, 0x05])),
                     "the supported-types list is a different reply")
        XCTAssertNil(MobilinkdTNC.parseOutputGain(Data([0x06, 0x0D, 0x00, 0x04])))
    }
    
    func testBatteryParsing() {
        // Construct a response frame: CMD=6, SUB=6, High=15, Low=160 (3840 + 160 = 4000mV = 4.0V)
        let high: UInt8 = 15
        let low: UInt8 = 160
        let data = Data([0x06, 0x06, high, low])
        
        let voltage = MobilinkdTNC.parseBatteryLevel(data)
        XCTAssertNotNil(voltage)
        XCTAssertEqual(voltage, 4000)
        
        // Test invalid
        XCTAssertNil(MobilinkdTNC.parseBatteryLevel(Data([0x06, 0x05, 0, 0]))) // Wrong subcommand
    }
    
    func testKISSParserTelemetry() {
        var parser = KISSFrameParser()
        
        // Feed a battery response frame: FEND | CMD=6 | SUB=6 | H | L | FEND
        // Note: Parser strips FEND and unescapes.
        // But our updated parser returns `mobilinkdTelemetry` for CMD=6.
        // And it reconstructs the frame with CMD byte at index 0?
        // Let's check `processKISSFrame` implementation:
        // if cmdType == 0x06 {
        //    var fullFrame = Data([command])
        //    fullFrame.append(payload)
        //    return .mobilinkdTelemetry(fullFrame)
        // }
        
        // So `fullFrame` should be [0x06, 0x06, H, L]
        
        let packet: [UInt8] = [0xC0, 0x06, 0x06, 15, 160, 0xC0]
        let results = parser.feed(Data(packet))
        
        XCTAssertEqual(results.count, 1)
        
        if case .mobilinkdTelemetry(let data) = results.first {
            XCTAssertEqual(data.count, 4)
            XCTAssertEqual(data[0], 0x06) // CMD
            XCTAssertEqual(data[1], 0x06) // SUB
            
            let voltage = MobilinkdTNC.parseBatteryLevel(data)
            XCTAssertEqual(voltage, 4000)
        } else {
            XCTFail("Expected mobilinkdTelemetry result")
        }
    }
}
