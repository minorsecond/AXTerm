import XCTest
@testable import AXTerm

/// The terminal line for a frame we sent.
final class TransmittedConsoleLineTests: XCTestCase {

    private let radio = RadioID(rawValue: "a-705")

    /// Our own beacon reads like everyone else's, so the terminal can draw it
    /// decoded and mark it as ours. It printed as `!/:Kls4#---  A`.
    func testAnAPRSFrameWeSendIsDecoded() {
        let info = "!3953.70N/10505.14W>AXTerm"
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "K0EPI", ssid: 2),
            to: AX25Address(call: "APZAXT", ssid: 0),
            via: DigiPath.from(["WIDE1-1", "WIDE2-1"]),
            payload: Data(info.utf8), displayInfo: info).onRadio(radio)
        let line = ConsoleLine.transmitted(frame, text: info)
        XCTAssertNotNil(line.aprs)
        XCTAssertEqual(line.radioID, radio)
        XCTAssertEqual(line.via, ["WIDE1-1", "WIDE2-1"])
    }

    /// A connected-mode frame is never read as APRS, whatever its text.
    func testASessionFrameIsNotDecoded() {
        let text = "!3953.70N/10505.14W>looks like APRS"
        let frame = AX25FrameBuilder.buildIFrame(
            from: AX25Address(call: "K0EPI", ssid: 2),
            to: AX25Address(call: "N0CALL", ssid: 0),
            ns: 0, nr: 0, payload: Data(text.utf8), displayInfo: text).onRadio(radio)
        let line = ConsoleLine.transmitted(frame, text: text)
        XCTAssertNil(line.aprs)
        XCTAssertEqual(line.radioID, radio)
    }
}
