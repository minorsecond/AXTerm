import XCTest
@testable import AXTerm

/// The in-band KISS hardware query — how a Direwolf connection names
/// itself over the very link it serves, with nothing sent on RF.
final class TNCIdentifierTests: XCTestCase {

    func testTheQueryIsAWellFormedSetHardwareFrame() {
        let frame = TNCIdentifier.queryFrame()
        XCTAssertEqual(Array(frame), [0xC0, 0x06] + Array("TNC:".utf8) + [0xC0],
                       "FEND, SetHardware on port 0, the TNC: question, FEND")
    }

    func testADirewolfReplyYieldsItsIdentity() {
        // Telemetry frames arrive as [command byte, payload...]; Direwolf
        // answers the TNC: query on the same SetHardware command.
        var frame = Data([0x06])
        frame.append(Data("TNC:direwolf 1.7".utf8))
        XCTAssertEqual(TNCIdentifier.identity(fromTelemetryFrame: frame),
                       "direwolf 1.7")
        XCTAssertTrue(TNCIdentifier.isDirewolf("direwolf 1.7"))
    }

    func testTrailingPaddingIsStripped() {
        var frame = Data([0x06])
        frame.append(Data("TNC:direwolf 1.7".utf8))
        frame.append(Data([0x00, 0x0A]))
        XCTAssertEqual(TNCIdentifier.identity(fromTelemetryFrame: frame),
                       "direwolf 1.7")
    }

    func testOtherHardwareChatterIsNotAnIdentity() {
        // A Mobilinkd battery report rides the same 0x06 command and must
        // fall through to the existing telemetry parsers untouched.
        let battery = Data([0x06, 0x06, 0x0F, 0xA0])
        XCTAssertNil(TNCIdentifier.identity(fromTelemetryFrame: battery))
        // An answered query with nothing after the prefix says nothing.
        var empty = Data([0x06])
        empty.append(Data("TNC:".utf8))
        XCTAssertNil(TNCIdentifier.identity(fromTelemetryFrame: empty))
    }

    // MARK: - The reply that carries no prefix

    /// Real bytes off the air, 2026-09-10: Direwolf 1.8 answers the `TNC:`
    /// query with the bare name and echoes nothing. Requiring the echo filed
    /// this as unknown Mobilinkd telemetry and the link showed no identity.
    func testDirewolfIsIdentifiedWhenItDoesNotEchoThePrefix() {
        let frame = Data([0x06] + Array("DIREWOLF 1.8".utf8))
        XCTAssertEqual(TNCIdentifier.identity(fromTelemetryFrame: frame), "DIREWOLF 1.8")
        XCTAssertTrue(TNCIdentifier.isDirewolf("DIREWOLF 1.8"), "case must not matter")
    }

    /// The guard that replaces the prefix. Mobilinkd telemetry rides the same
    /// SetHardware command; without the prefix to lean on, only "every byte is
    /// printable" keeps a battery reading from being read as a station name.
    func testMobilinkdTelemetryStillFallsThrough() {
        // battery: CMD_HARDWARE, GET_BATTERY_LEVEL, then two binary bytes
        let battery = Data([0x06, 0x06, 0x0F, 0xA0])
        XCTAssertNil(TNCIdentifier.identity(fromTelemetryFrame: battery))

        // input level: CMD_HARDWARE, POLL_INPUT_LEVEL, four 16-bit readings
        let level = Data([0x06, 0x04, 0x01, 0x2C, 0x00, 0x64, 0x00, 0x10, 0x02, 0x58])
        XCTAssertNil(TNCIdentifier.identity(fromTelemetryFrame: level))

        // input gain
        let gain = Data([0x06, 0x02, 0x00, 0x0B])
        XCTAssertNil(TNCIdentifier.identity(fromTelemetryFrame: gain))
    }

    /// Printable but not a name: nothing to show the operator.
    func testAPrintableRunWithNoLettersIsNotAnIdentity() {
        XCTAssertNil(TNCIdentifier.identity(fromTelemetryFrame: Data([0x06] + Array("   ".utf8))))
        XCTAssertNil(TNCIdentifier.identity(fromTelemetryFrame: Data([0x06] + Array("1.8".utf8))))
    }
}
