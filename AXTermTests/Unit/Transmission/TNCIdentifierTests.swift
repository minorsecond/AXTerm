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
}
