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

    // MARK: - What the TNC4 can actually report

    /// tnc4-firmware Core/TNC/AudioInput.cpp, streamLevels: when no ADC block
    /// arrives within its 1 s wait, `count` stays 0, `vmin` and `vmax` keep
    /// their starting values (0xFFFF and 0), and every value is shifted left
    /// by 2. The report reads Vpp 4, Vavg 0 (the divide by zero gives 0 on a
    /// Cortex-M that doesn't trap it), Vmin 0xFFFC, Vmax 0. It measures
    /// nothing, and read as a level it is near-silence.
    private let starvedReport = Data([
        0x06, 0x04,
        0x00, 0x04,       // Vpp = (0 - 0xFFFF) << 2, wrapped
        0x00, 0x00,       // Vavg = accum / 0
        0xFF, 0xFC,       // Vmin = 0xFFFF << 2
        0x00, 0x00        // Vmax = 0
    ])

    func testAReportFromAStarvedStreamIsNotALevel() {
        XCTAssertNil(MobilinkdTNC.parseInputLevel(starvedReport))
        XCTAssertNil(MobilinkdReply.parse(starvedReport), "nothing downstream may take it for a reading")
    }

    /// A minimum above the maximum can't come from samples. Equal is fine:
    /// a perfectly steady input.
    func testOnlyAMinimumAboveTheMaximumIsRejected() {
        let steady = Data([0x06, 0x04, 0x00, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00])
        XCTAssertEqual(MobilinkdTNC.parseInputLevel(steady)?.vmin, 0x8000)
    }

    /// The ADC is 12 bits, oversampled 16 times and shifted right 2: 14-bit
    /// samples, 0...16383 (Core/Src/main.c, MX_ADC2_Init). Reports shift them
    /// left by the demodulator's ADC exponent, 2 for AFSK 1200, 9600 and M17.
    func testFullScaleIsTheFourteenBitADCShiftedLeftTwo() {
        XCTAssertEqual(MobilinkdInputLevel.fullScale, 16_383 << 2)
        XCTAssertEqual(MobilinkdInputLevel.fullScale, 65_532)
        XCTAssertEqual(TNC4LevelSample.fullScale, MobilinkdInputLevel.fullScale)
    }

    /// The largest swing a TNC4 can report is the whole range.
    func testAFullSwingReadsAsTheWholeRange() {
        let rail = MobilinkdInputLevel(vpp: 65_532, vavg: 32_768, vmin: 0, vmax: 65_532)
        XCTAssertEqual(rail.fraction, 1.0)
        XCTAssertTrue(rail.clipped)
        XCTAssertEqual(TNC4LevelSample(t: 0, level: rail).fraction, 1.0)
    }

    /// The top of the range is 65,532, so 65,535 is never reported; a reading
    /// at the real top must count as clipped.
    func testAReadingAtTheTopOfTheRealRangeIsClipped() {
        let top = MobilinkdInputLevel(vpp: 900, vavg: 65_000, vmin: 64_632, vmax: 65_532)
        XCTAssertTrue(top.clipped)
        XCTAssertTrue(TNC4LevelSample(t: 0, level: top).clipped)
        let quiet = MobilinkdInputLevel(vpp: 2_000, vavg: 32_768, vmin: 31_768, vmax: 33_768)
        XCTAssertFalse(quiet.clipped)
    }

    /// The level assistant reads the same scale.
    func testTheLevelAssistantCallsAFullSwingClipping() {
        let rail = MobilinkdInputLevel(vpp: 65_532, vavg: 32_768, vmin: 0, vmax: 65_532)
        XCTAssertEqual(MobilinkdLevelAssistant.judge([rail]), .clipping)
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
