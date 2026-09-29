import XCTest
@testable import AXTerm

/// Decoding what a TNC4 says about itself. Byte sequences marked "captured"
/// came from a TNC4 Rev B on firmware 2.5.14 on 2026-09-29.
final class MobilinkdDeviceStateTests: XCTestCase {

    private func parse(_ bytes: [UInt8]) -> MobilinkdReply? { MobilinkdReply.parse(Data(bytes)) }

    func testCapturedReplies() {
        XCTAssertEqual(parse([0x06, 0x28, 0x32, 0x2E, 0x35, 0x2E, 0x31, 0x34]), .firmwareVersion("2.5.14"))
        XCTAssertEqual(parse([0x06, 0x29] + Array("Mobilinkd TNC4 Rev B".utf8)), .hardwareVersion("Mobilinkd TNC4 Rev B"))
        XCTAssertEqual(parse([0x06, 0x0C, 0x00, 0x3F]), .outputGain(63))
        XCTAssertEqual(parse([0x06, 0x0D, 0x00, 0x04]), .inputGain(4))
        XCTAssertEqual(parse([0x06, 0x19, 0x03]), .inputTwist(3))
        XCTAssertEqual(parse([0x06, 0x1B, 0x32]), .outputTwist(50))
        XCTAssertEqual(parse([0x06, 0x21, 0x1E]), .txDelayMs(300))
        XCTAssertEqual(parse([0x06, 0x50, 0x01]), .pttMultiplex(true))
        XCTAssertEqual(parse([0x06, 0x06, 0x10, 0x7A]), .batteryMillivolts(4218))
        XCTAssertEqual(parse([0x06, 0xC1, 0x81, 0x01]), .modemType(1))
        XCTAssertEqual(parse([0x06, 0xC1, 0x83, 0x01, 0x03, 0x05]), .supportedModemTypes([1, 3, 5]))
    }

    /// Input twist is signed; the firmware's range is -3...9 dB.
    func testNegativeTwist() {
        XCTAssertEqual(parse([0x06, 0x19, 0xFD]), .inputTwist(-3))
        XCTAssertEqual(parse([0x06, 0x79, 0xFD]), .inputTwistRange(min: -3, max: nil))
    }

    func testMACAddressAndSave() {
        XCTAssertEqual(parse([0x06, 0x30, 0x00, 0x1A, 0x7D, 0xDA, 0x71, 0x13]), .macAddress("00:1A:7D:DA:71:13"))
        XCTAssertEqual(parse([0x06, 0x2A, 0x20]), .saved)
    }

    func testInputLevelStreamFrame() {
        let level = parse([0x06, 0x04, 0xBB, 0x80, 0x87, 0xE0, 0x29, 0xB0, 0xE5, 0x30])
        XCTAssertEqual(level, .inputLevel(MobilinkdInputLevel(vpp: 0xBB80, vavg: 0x87E0, vmin: 0x29B0, vmax: 0xE530)))
    }

    func testNotAHardwareFrame() {
        XCTAssertNil(parse([0x00, 0x96]))
        XCTAssertNil(parse([0x06]))
    }

    /// The state fills in reply by reply, as GET_ALL_VALUES delivers them.
    func testStateAccumulates() {
        var state = MobilinkdDeviceState()
        for frame: [UInt8] in [[0x06, 0x7B, 0x02, 0x02], [0x06, 0x7E, 0x10, 0x0E],
                               [0x06, 0x7C, 0x00, 0x00], [0x06, 0x7D, 0x00, 0x04],
                               [0x06, 0x0D, 0x00, 0x04], [0x06, 0x06, 0x10, 0x7A]] {
            if let r = parse(frame) { state.apply(r) }
        }
        XCTAssertEqual(state.apiVersion, 0x0202)
        XCTAssertTrue(state.canSave, "the TNC4 reports CAP_EEPROM_SAVE")
        XCTAssertEqual(state.minInputGain, 0)
        XCTAssertEqual(state.maxInputGain, 4)
        XCTAssertEqual(state.inputGain, 4)
        XCTAssertEqual(state.batteryFraction, 1.0, "4.218 V is past the 4.2 V full mark, so it reads full")
    }

    // MARK: Commands

    func testConfigurationFrames() {
        XCTAssertEqual(MobilinkdTNC.getAllValues(), [0xC0, 0x06, 0x7F, 0xC0])
        XCTAssertEqual(MobilinkdTNC.streamInputLevel(), [0xC0, 0x06, 0x05, 0xC0])
        XCTAssertEqual(MobilinkdTNC.sendBoth(), [0xC0, 0x06, 0x09, 0xC0])
        XCTAssertEqual(MobilinkdTNC.stopTX(), [0xC0, 0x06, 0x0A, 0xC0])
        XCTAssertEqual(MobilinkdTNC.setInputTwist(-3), [0xC0, 0x06, 0x18, 0xFD, 0xC0])
        XCTAssertEqual(MobilinkdTNC.setOutputTwist(150), [0xC0, 0x06, 0x1A, 100, 0xC0], "the firmware clamps to 100 too")
        XCTAssertEqual(MobilinkdTNC.setPTTMultiplex(true), [0xC0, 0x06, 0x4F, 0x01, 0xC0])
        XCTAssertEqual(MobilinkdTNC.saveEEPROM(), [0xC0, 0x06, 0x2A, 0xC0])
    }

    /// 2026-09-29 was a Tuesday. BCD, UTC, weekday 1 = Monday.
    func testDateTimeRoundTrip() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 19, minute: 57, second: 8)))
        let bytes = MobilinkdTNC.encodeDateTime(date)
        XCTAssertEqual(bytes, [0x26, 0x09, 0x29, 0x02, 0x19, 0x57, 0x08])
        XCTAssertEqual(MobilinkdTNC.decodeDateTime(bytes), date)
        XCTAssertEqual(MobilinkdTNC.encodeDateTime(cal.date(byAdding: .day, value: 5, to: date)!)[3], 0x07, "Sunday is 7")
    }
}
