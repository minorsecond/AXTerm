//
//  MobilinkdInputLevelTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

final class MobilinkdInputLevelTests: XCTestCase {

    // MARK: - parseInputLevel

    func testParseInputLevelValid() {
        // CMD_HARDWARE=0x06, POLL_INPUT_LEVEL=0x04, then 4 big-endian uint16 values
        let data = Data([
            0x06, 0x04,       // header
            0x01, 0x00,       // Vpp = 256
            0x00, 0x80,       // Vavg = 128
            0x00, 0x10,       // Vmin = 16
            0x02, 0x00        // Vmax = 512
        ])

        let result = MobilinkdTNC.parseInputLevel(data)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.vpp, 256)
        XCTAssertEqual(result?.vavg, 128)
        XCTAssertEqual(result?.vmin, 16)
        XCTAssertEqual(result?.vmax, 512)
    }

    func testParseInputLevelTooShort() {
        // Only 6 bytes — needs 10
        let data = Data([0x06, 0x04, 0x01, 0x00, 0x00, 0x80])
        XCTAssertNil(MobilinkdTNC.parseInputLevel(data))
    }

    func testParseInputLevelWrongCommand() {
        // Wrong subcommand (0x06 = battery, not 0x04)
        let data = Data([0x06, 0x06, 0x01, 0x00, 0x00, 0x80, 0x00, 0x10, 0x02, 0x00])
        XCTAssertNil(MobilinkdTNC.parseInputLevel(data))
    }

    // MARK: - Frame Generators

    func testPollInputLevelFrame() {
        let frame = MobilinkdTNC.pollInputLevel()
        XCTAssertEqual(frame, [0xC0, 0x06, 0x04, 0xC0])
    }

    func testAdjustInputLevelsFrame() {
        let frame = MobilinkdTNC.adjustInputLevels()
        XCTAssertEqual(frame, [0xC0, 0x06, 0x2B, 0xC0])
    }
}
