import XCTest
@testable import AXTerm

/// What a transmitted frame says on one line.
///
/// Our own frames never enter the packet log — that array is what was heard —
/// so anything showing both directions of a channel is fed from the send path
/// instead, and this is the text it carries.
final class PacketEngineTransmitTextTests: XCTestCase {

    private func frame(payload: String, displayInfo: String?) -> OutboundFrame {
        OutboundFrame(
            destination: AX25Address(call: "APZAXT", ssid: 0),
            source: AX25Address(call: "K0EPI", ssid: 7),
            payload: Data(payload.utf8),
            frameType: "ui",
            displayInfo: displayInfo)
    }

    func testThePayloadIsTheLine() {
        let text = PacketEngine.transmittedText(
            frame(payload: "!3930.00N/10515.00W-", displayInfo: "!3930.00N/10515.00W-"),
            description: nil)
        XCTAssertEqual(text, "!3930.00N/10515.00W-")
    }

    /// A beacon ends with a CR on the air; the strip is one row per frame.
    func testNewlinesAreFlattened() {
        let text = PacketEngine.transmittedText(
            frame(payload: "K0EPI\r\nCENTCO", displayInfo: "K0EPI\r\nCENTCO"),
            description: nil)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertFalse(text.contains("\r"))
    }

    /// An RR or a SABM has no payload, and naming the frame is more use to
    /// somebody watching a connect than an empty row.
    func testAControlFrameIsNamed() {
        let text = PacketEngine.transmittedText(
            frame(payload: "", displayInfo: nil), description: "RR P/F=1 N(R)=3")
        XCTAssertEqual(text, "RR P/F=1 N(R)=3")
    }

    func testWithNothingAtAllTheFrameTypeIsTheLine() {
        let text = PacketEngine.transmittedText(
            frame(payload: "", displayInfo: nil), description: nil)
        XCTAssertEqual(text, "UI")
    }
}
