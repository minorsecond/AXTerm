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
        
        // Test Modem Type (Extended Command 0xC1 0x82)
        let modem1200 = MobilinkdTNC.setModemType(.afsk1200)
        XCTAssertEqual(modem1200, [0xC0, 0xC1, 0x82, 0x01, 0xC0])
        
        let modem9600 = MobilinkdTNC.setModemType(.fsk9600)
        XCTAssertEqual(modem9600, [0xC0, 0xC1, 0x82, 0x03, 0xC0])
        
        // Test Battery Poll
        let poll = MobilinkdTNC.pollBatteryLevel()
        XCTAssertEqual(poll, [0xC0, 0x06, 0x06, 0xC0])
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
