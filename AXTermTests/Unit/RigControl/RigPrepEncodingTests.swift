import XCTest
@testable import AXTerm

/// Every CI-V frame the prepare-and-restore path reads or writes, byte for
/// byte, against the IC-705 CI-V Reference Guide (Icom, 2020 edition,
/// command table p. 4), and what each reply decodes to, including the
/// replies that must decode to nothing.
final class RigPrepEncodingTests: XCTestCase {

    private func hex(_ frame: CIVFrame) -> String {
        frame.encoded().map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func reply(_ command: UInt8, _ sub: UInt8?, _ data: [UInt8]) -> CIVFrame {
        CIVFrame(to: 0xE0, from: 0xA4, command: command, subcommand: sub, data: data)
    }

    // MARK: - Read frames per setting

    func testReadFramesForEverySetting() {
        let expected: [(RigPrepSetting, [String])] = [
            (.mode, ["FE FE A4 E0 04 FD", "FE FE A4 E0 1A 06 FD"]),
            (.menuItem(119), ["FE FE A4 E0 1A 05 01 19 FD"]),
            (.menuItem(38), ["FE FE A4 E0 1A 05 00 38 FD"]),
            (.attenuator, ["FE FE A4 E0 11 FD"]),
            (.rfGain, ["FE FE A4 E0 14 02 FD"]),
            (.squelch, ["FE FE A4 E0 14 03 FD"]),
            (.noiseReduction, ["FE FE A4 E0 16 40 FD"]),
            (.noiseBlanker, ["FE FE A4 E0 16 22 FD"]),
            (.autoNotch, ["FE FE A4 E0 16 41 FD"]),
            (.manualNotch, ["FE FE A4 E0 16 48 FD"]),
            (.toneSquelch, ["FE FE A4 E0 16 5D FD"]),
        ]
        for (setting, frames) in expected {
            XCTAssertEqual(setting.readFrames(radio: 0xA4, controller: 0xE0).map(hex), frames, setting.key)
        }
    }

    // MARK: - Write frames per setting

    func testWriteFramesForEverySetting() {
        let expected: [(RigPrepSetting, [UInt8], [String])] = [
            (.mode, [0x01, 0x02, 0x00, 0x00], ["FE FE A4 E0 06 01 02 FD", "FE FE A4 E0 1A 06 00 00 FD"]),
            (.mode, [0x05, 0x01, 0x01, 0x01], ["FE FE A4 E0 06 05 01 FD", "FE FE A4 E0 1A 06 01 01 FD"]),
            (.menuItem(119), [0x01], ["FE FE A4 E0 1A 05 01 19 01 FD"]),
            (.menuItem(131), [0x00], ["FE FE A4 E0 1A 05 01 31 00 FD"]),
            (.attenuator, [0x20], ["FE FE A4 E0 11 20 FD"]),
            (.attenuator, [0x00], ["FE FE A4 E0 11 00 FD"]),
            (.rfGain, [0x02, 0x55], ["FE FE A4 E0 14 02 02 55 FD"]),
            (.squelch, [0x00, 0x00], ["FE FE A4 E0 14 03 00 00 FD"]),
            (.noiseReduction, [0x00], ["FE FE A4 E0 16 40 00 FD"]),
            (.noiseBlanker, [0x01], ["FE FE A4 E0 16 22 01 FD"]),
            (.autoNotch, [0x00], ["FE FE A4 E0 16 41 00 FD"]),
            (.manualNotch, [0x01], ["FE FE A4 E0 16 48 01 FD"]),
            (.toneSquelch, [0x06], ["FE FE A4 E0 16 5D 06 FD"]),
        ]
        for (setting, value, frames) in expected {
            XCTAssertEqual(setting.writeFrames(value, radio: 0xA4, controller: 0xE0).map(hex), frames,
                           "\(setting.key) \(value)")
        }
    }

    /// Mode first, then data: `06` clears the data flag, so the other order
    /// would leave a radio that was in USB-D in plain USB.
    func testTheModeIsWrittenBeforeTheDataFlag() {
        let frames = RigPrepSetting.mode.writeFrames([0x01, 0x01, 0x01, 0x02], radio: 0xA4, controller: 0xE0)
        XCTAssertEqual(frames.map(\.command), [0x06, 0x1A])
        XCTAssertEqual(frames.last?.data, [0x01, 0x02], "USB-D on FIL2 comes back as USB-D on FIL2")
    }

    func testMalformedValuesAreNeverSent() {
        let bad: [(RigPrepSetting, [UInt8])] = [
            (.mode, [0x05, 0x01, 0x01]),        // short
            (.mode, [0x42, 0x01, 0x00, 0x00]),  // no such mode
            (.mode, [0x05, 0x01, 0x07, 0x00]),  // data flag not 0/1
            (.menuItem(119), []),
            (.attenuator, [0x2A]),              // not BCD
            (.attenuator, []),
            (.rfGain, [0x02]),                  // short
            (.rfGain, [0x03, 0x00]),            // 300, over 255
            (.squelch, [0x0A, 0x00]),           // not BCD
            (.noiseReduction, [0x02]),
            (.autoNotch, [0x00, 0x00]),
            (.manualNotch, []),
            (.toneSquelch, [0x04]),             // not a guide value
            (.toneSquelch, [0x01, 0x00]),
        ]
        for (setting, value) in bad {
            XCTAssertFalse(setting.isWellFormed(value), "\(setting.key) \(value)")
            XCTAssertTrue(setting.writeFrames(value, radio: 0xA4, controller: 0xE0).isEmpty, "\(setting.key) \(value)")
        }
    }

    // MARK: - Decoding replies

    func testDecodingGoodReplies() {
        XCTAssertEqual(RigPrepSetting.mode.decode([reply(0x04, nil, [0x05, 0x01]), reply(0x1A, 0x06, [0x01, 0x01])]),
                       [0x05, 0x01, 0x01, 0x01])
        XCTAssertEqual(RigPrepSetting.menuItem(119).decode([reply(0x1A, 0x05, [0x01, 0x19, 0x03])]), [0x03])
        XCTAssertEqual(RigPrepSetting.attenuator.decode([reply(0x11, nil, [0x20])]), [0x20])
        XCTAssertEqual(RigPrepSetting.rfGain.decode([reply(0x14, 0x02, [0x01, 0x28])]), [0x01, 0x28])
        XCTAssertEqual(RigPrepSetting.squelch.decode([reply(0x14, 0x03, [0x00, 0x00])]), [0x00, 0x00])
        XCTAssertEqual(RigPrepSetting.noiseReduction.decode([reply(0x16, 0x40, [0x01])]), [0x01])
        XCTAssertEqual(RigPrepSetting.noiseBlanker.decode([reply(0x16, 0x22, [0x00])]), [0x00])
        XCTAssertEqual(RigPrepSetting.autoNotch.decode([reply(0x16, 0x41, [0x01])]), [0x01])
        XCTAssertEqual(RigPrepSetting.manualNotch.decode([reply(0x16, 0x48, [0x00])]), [0x00])
        XCTAssertEqual(RigPrepSetting.toneSquelch.decode([reply(0x16, 0x5D, [0x09])]), [0x09])
    }

    /// A radio may answer the mode without a filter byte, or data mode with
    /// only the flag. Those take the guide's defaults, as `readMode` always
    /// has, rather than failing the read.
    func testDecodingShortModeRepliesTakesTheDefaults() {
        XCTAssertEqual(RigPrepSetting.mode.decode([reply(0x04, nil, [0x01]), reply(0x1A, 0x06, [0x00])]),
                       [0x01, 0x01, 0x00, 0x00])
        XCTAssertEqual(RigPrepSetting.mode.decode([reply(0x04, nil, [0x05, 0x02]), reply(0x1A, 0x06, [0x01])]),
                       [0x05, 0x02, 0x01, 0x01])
    }

    func testMalformedOrMismatchedRepliesDecodeToNothing() {
        // Empty data.
        XCTAssertNil(RigPrepSetting.autoNotch.decode([reply(0x16, 0x41, [])]))
        XCTAssertNil(RigPrepSetting.mode.decode([reply(0x04, nil, []), reply(0x1A, 0x06, [0x01])]))
        XCTAssertNil(RigPrepSetting.mode.decode([reply(0x04, nil, [0x05]), reply(0x1A, 0x06, [])]))
        // Out of range.
        XCTAssertNil(RigPrepSetting.autoNotch.decode([reply(0x16, 0x41, [0x05])]))
        XCTAssertNil(RigPrepSetting.toneSquelch.decode([reply(0x16, 0x5D, [0x04])]))
        XCTAssertNil(RigPrepSetting.attenuator.decode([reply(0x11, nil, [0xFF])]))
        XCTAssertNil(RigPrepSetting.mode.decode([reply(0x04, nil, [0x77, 0x01]), reply(0x1A, 0x06, [0x01])]))
        // Short level.
        XCTAssertNil(RigPrepSetting.rfGain.decode([reply(0x14, 0x02, [0x02])]))
        // The answer to a different question.
        XCTAssertNil(RigPrepSetting.autoNotch.decode([reply(0x16, 0x48, [0x00])]))
        XCTAssertNil(RigPrepSetting.rfGain.decode([reply(0x14, 0x03, [0x00, 0x00])]))
        // A menu reply for another item is stale, not this one.
        XCTAssertNil(RigPrepSetting.menuItem(119).decode([reply(0x1A, 0x05, [0x01, 0x11, 0x00])]))
        // A menu reply with no value after the item.
        XCTAssertNil(RigPrepSetting.menuItem(119).decode([reply(0x1A, 0x05, [0x01, 0x19])]))
        // Too few or too many replies.
        XCTAssertNil(RigPrepSetting.mode.decode([reply(0x04, nil, [0x05, 0x01])]))
        XCTAssertNil(RigPrepSetting.autoNotch.decode([]))
        XCTAssertNil(RigPrepSetting.autoNotch.decode([reply(0x16, 0x41, [0x00]), reply(0x16, 0x41, [0x00])]))
    }

    /// Extra bytes after a function's value are ignored, not taken as the value.
    func testTrailingBytesAreIgnored() {
        XCTAssertEqual(RigPrepSetting.autoNotch.decode([reply(0x16, 0x41, [0x01, 0x00])]), [0x01])
        XCTAssertEqual(RigPrepSetting.squelch.decode([reply(0x14, 0x03, [0x01, 0x28, 0x99])]), [0x01, 0x28])
    }

    // MARK: - Setting names

    func testSettingKeysRoundTrip() {
        let all: [RigPrepSetting] = [.mode, .menuItem(119), .menuItem(38), .attenuator, .rfGain, .squelch,
                                     .noiseReduction, .noiseBlanker, .autoNotch, .manualNotch, .toneSquelch]
        for setting in all { XCTAssertEqual(RigPrepSetting(key: setting.key), setting) }
        XCTAssertNil(RigPrepSetting(key: "vsc"))
        XCTAssertNil(RigPrepSetting(key: "menu.abc"))
        XCTAssertNil(RigPrepSetting(key: "menu.12345"))
    }

    func testLabelsNameTheRadiosOwnSettings() {
        XCTAssertEqual(RigPrepSetting.menuItem(119).label, "DATA MOD")
        XCTAssertEqual(RigPrepSetting.menuItem(131).label, "CI-V transceive")
        XCTAssertEqual(RigPrepSetting.menuItem(41).label, "TX delay (144 MHz)")
        XCTAssertEqual(RigPrepSetting.menuItem(7).label, "menu item 0007")
        XCTAssertEqual(RigPrepSetting.autoNotch.label, "auto notch")
    }
}
